import Foundation

// MARK: - Restore request

/// Everything the engine needs up front. The backup password (if the
/// device backup is encrypted) is passed at call time and never stored.
struct RestoreRequest: Sendable {
    /// From lockdown at run time — never guessed, never empty.
    let deviceVersion: DeviceVersion
    /// Build number from lockdown ("24A5355q"); nil when the caller
    /// couldn't read it — the version gate still applies (all 27.0
    /// variants report ProductVersion "27.0").
    let deviceBuild: String?
    /// Feature IDs the user staged (from PayloadSpec catalog).
    let stagedFeatureIDs: Set<String>
    /// Find My cannot be verified from the sandbox; the user attests it.
    /// Restoring with Find My ON risks activation issues — recorded, not faked.
    let findMyDisabledAttested: Bool
    /// The iOS 27 bootloop risk warning was shown and explicitly accepted.
    /// Fail-closed: BackupPhase refuses the run without it.
    let riskWarningAccepted: Bool
    /// Label for the staging directory (UDID when known, else "device").
    let deviceLabel: String
    let backupPassword: String?

    /// Explicit init: the synthesized memberwise order is fragile when
    /// defaulted properties sit mid-struct, so the order is fixed here
    /// with the optional tail defaulted.
    init(deviceVersion: DeviceVersion,
         stagedFeatureIDs: Set<String>,
         findMyDisabledAttested: Bool,
         deviceLabel: String,
         backupPassword: String?,
         deviceBuild: String? = nil,
         riskWarningAccepted: Bool = false) {
        self.deviceVersion = deviceVersion
        self.deviceBuild = deviceBuild
        self.stagedFeatureIDs = stagedFeatureIDs
        self.findMyDisabledAttested = findMyDisabledAttested
        self.riskWarningAccepted = riskWarningAccepted
        self.deviceLabel = deviceLabel
        self.backupPassword = backupPassword
    }
}

// MARK: - Engine state

enum RestoreState: Sendable {
    case idle
    case running(RestorePhaseID)
    case succeeded
    case failed(String)
    case cancelled
}

// MARK: - Cooperative cancellation

/// Lock-guarded flag shared with phases. A cancelled run stops between
/// phases and inside long local loops; transport calls check it too.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
}

// MARK: - Stall watchdog (stall-based, no hard deadline)

/// Abort only after 10 minutes with zero progress. A healthy full
/// backup/restore is never cut off for being slow — the old hard
/// 12-minute deadline is gone on purpose.
///
/// NOTE (Gap 12 fix): the actor is kept (the parallel partial engine
/// calls it the same way), but ticks now come from EVERY transport
/// progress callback via a Task hop — the progress closures are
/// synchronous and cannot await. `check()` gates the START of the next
/// phase; it is never run after a phase completed (that was the old
/// false-stall wiring: note-then-check always passed, and real mid-phase
/// stalls were invisible).
actor StallWatchdog {
    private var lastProgress = Date()
    private let stallLimit: TimeInterval = 600

    func noteProgress() { lastProgress = Date() }

    func check(phase: RestorePhaseID) throws {
        if Date().timeIntervalSince(lastProgress) > stallLimit {
            throw RestoreError.stalled(phase: phase)
        }
    }
}

// MARK: - Inner device-I/O watchdog (desktop: run_with_stall_watchdog)

/// Lock-guarded last-tick timestamp. Sync-tickable from non-async
/// progress closures; read by the watchdog poll loop.
final class IOActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTick = Date()

    func tick() { lock.withLock { lastTick = Date() } }
    func silentFor() -> TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastTick) }
    }
}

/// Runs one transport call under the inner stall watchdog (desktop:
/// run_with_stall_watchdog, 300s). Every progress tick proves the device
/// alive. If the device goes quiet for `stallSeconds` mid-transfer, the
/// call is abandoned via `onStall` (which must unblock the hung socket —
/// without it the body child would never finish and the task group
/// would hang on exit) and `.ioStalled` is thrown.
///
/// This is NOT user cancel: a wedged device (zero progress for 5 minutes)
/// is already dead — desktop treats the same condition as retryable.
/// User cancel stays phase-boundary-only (see start()).
func withIOWatchdog<T>(
    phase: RestorePhaseID,
    operation: String,
    stallSeconds: TimeInterval = 300,
    onStall: (@Sendable () async -> Void)? = nil,
    body: @escaping @Sendable (@Sendable () -> Void) async throws -> T
) async throws -> T {
    let activity = IOActivity()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await body { activity.tick() }
        }
        group.addTask { () throws -> T in
            while true {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if activity.silentFor() >= stallSeconds {
                    if let onStall { await onStall() }
                    throw RestoreError.ioStalled(
                        phase: phase, operation: operation,
                        seconds: Int(stallSeconds))
                }
            }
        }
        guard let result = try await group.next() else {
            throw RestoreError.ioStalled(
                phase: phase, operation: operation, seconds: Int(stallSeconds))
        }
        group.cancelAll()
        return result
    }
}

// MARK: - Orchestrator

/// The iOS 27 method, in the exact mandated order:
/// BACKUP ALL DATA FULL → PAYLOAD → MODIF → RESTORE FULL → RESTART.
///
/// An actor: state transitions are serialized, and `start` while a run is
/// in flight throws `.alreadyInFlight` instead of stacking runs.
/// Backup/restore phase progress closures also tick the stall watchdog
/// (via a Task hop — the closures are synchronous), so a quiet device
/// trips the watchdog instead of hanging the run.
actor RestoreEngine {
    static let shared = RestoreEngine()

    private(set) var state: RestoreState = .idle
    private var cancelFlag: CancelFlag?

    /// Request cancellation of the in-flight run, if any.
    ///
    /// REAL cancel (not UI-only): the view also cancels the Swift Task
    /// running start(), which (a) trips Task.isCancelled inside every
    /// phase and transport loop, and (b) disconnects the device socket
    /// via withTaskCancellationHandler, unblocking hung reads. The flag
    /// here is the backstop for callers that never cancel the task.
    /// After cancel: state .cancelled, sockets closed, no background
    /// work survives.
    func cancel() {
        cancelFlag?.cancel()
    }

    /// Run the method for this device's iOS version.
    ///
    /// Version routing (the old code threw `.unsupportedVersion` for
    /// iOS <27 and left iOS 26 as UI text only):
    /// - iOS 16–26 → PartialRestoreEngine (sparse restore, no full
    ///   backup). The agreed seam; that engine owns its own phases.
    /// - iOS 27+   → the strict allowlist below (G1Support), then the
    ///   full BACKUP → PAYLOAD → MODIF → RESTORE → RESTART method.
    ///
    /// Cancel is honored MID-FLIGHT, not just between phases: the view
    /// cancels the Task running start(); Task.isCancelled is checked in
    /// every phase loop and transport loop, and the socket is
    /// disconnected on cancellation so hung reads unblock immediately.
    /// After cancel the engine reports .cancelled with sockets closed
    /// and no background work remaining.
    func start(
        request: RestoreRequest,
        transport: DeviceTransport? = nil,
        onProgress: @Sendable @escaping (RestoreProgress) -> Void
    ) async throws {
        // Only an actually-running run blocks a new one. Terminal states
        // (.succeeded/.failed/.cancelled) stay observable, but a new run
        // may start from them — the old `guard case .idle` made the
        // engine single-use per app launch (every second apply threw
        // .alreadyInFlight with nothing in flight).
        if case .running = state { throw RestoreError.alreadyInFlight }
        guard !request.stagedFeatureIDs.isEmpty else {
            throw RestoreError.nothingStaged
        }

        // The request's backup password must reach the transport: the old
        // default `LoopbackTransport()` silently dropped it (the user
        // typed a password, the pull/restore ran without it). An
        // explicitly passed transport is used as-is (caller-owned).
        let transport = transport ?? LoopbackTransport(backupPassword: request.backupPassword)

        let flag = CancelFlag()
        cancelFlag = flag
        let watchdog = StallWatchdog()
        let stagingRoot = RestoreEngine.stagingRoot(label: request.deviceLabel)
        // Both the engine flag (view's cancel button) and Task.isCancelled
        // (view cancelling the Task): either one stops the run.
        let cancelled: @Sendable () -> Bool = { flag.isCancelled || Task.isCancelled }

        func throwIfCancelled() throws {
            if flag.isCancelled || Task.isCancelled { throw RestoreError.cancelled }
        }

        // — Version routing —
        let major = request.deviceVersion.major
        if (16...26).contains(major) {
            // Partial-restore route: no full backup, no G1 phases.
            // Progress flows through onProgress; the phase vocabulary
            // below is the G1 route's (the partial engine reports bare
            // fractions, mapped here onto .restore).
            state = .running(.restore)
            defer { cancelFlag = nil }
            do {
                let partialProgress: @Sendable (Double) -> Void = { f in
                    onProgress(RestoreProgress(
                        phase: .restore, fraction: f,
                        message: "Partial restore… \(Int(f * 100))%"))
                }
                try await PartialRestoreEngine.shared.run(
                    request: request, transport: transport,
                    onProgress: partialProgress)
                state = .succeeded
            } catch let error as RestoreError {
                if case .cancelled = error {
                    state = .cancelled
                } else {
                    state = .failed(error.localizedDescription)
                }
                throw error
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
            return
        }
        guard G1Support.isSupported(version: request.deviceVersion,
                                    build: request.deviceBuild)
        else {
            throw RestoreError.osVersionNotSupported(
                version: request.deviceVersion.description,
                build: request.deviceBuild)
        }

        do {
            // — Phase 1: BACKUP ALL DATA FULL —
            // check() gates the START of each phase: a stall between
            // phases aborts before new work begins, never after it landed.
            try await watchdog.check(phase: .backup)
            try throwIfCancelled()
            state = .running(.backup)
            await watchdog.noteProgress()
            let backupResult = try await BackupPhase.run(
                request: request, stagingRoot: stagingRoot, transport: transport,
                watchdog: watchdog, progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()

            // — Phase 2: PAYLOAD FILE (dozens of locations, per active tweaks) —
            try await watchdog.check(phase: .payload)
            try throwIfCancelled()
            state = .running(.payload)
            await watchdog.noteProgress()
            let payloadResult = try await PayloadPhase.run(
                request: request, stagingRoot: stagingRoot,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()

            // — Phase 3: MODIF (real injection into the pulled backup) —
            try await watchdog.check(phase: .modify)
            try throwIfCancelled()
            state = .running(.modify)
            await watchdog.noteProgress()
            _ = try await ModifyPhase.run(
                request: request,
                backupRoot: backupResult.backupRoot,
                payloadManifest: payloadResult.manifestURL,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()

            // — Phase 4: RESTORE FULL —
            // Last cancel point before the device is written. After the
            // push starts, cancel no longer interrupts it.
            try await watchdog.check(phase: .restore)
            try throwIfCancelled()
            state = .running(.restore)
            await watchdog.noteProgress()
            try await RestorePhase.run(
                request: request,
                backupRoot: backupResult.backupRoot,
                transport: transport, watchdog: watchdog,
                progress: onProgress, isCancelled: cancelled
            )
            await watchdog.noteProgress()

            // — Phase 5: RESTART (with restart notification) —
            // Part of the same atomic unit as the restore once it landed:
            // not skipped by a mid-restore cancel. The reboot kills this
            // app too (it runs on the device), so no post-reboot
            // verification is possible — the reboot command being accepted
            // is the honest completion signal.
            try await watchdog.check(phase: .restart)
            state = .running(.restart)
            await watchdog.noteProgress()
            _ = try await RestartPhase.run(transport: transport, progress: onProgress)
            await watchdog.noteProgress()

            state = .succeeded
            cancelFlag = nil
        } catch let error as RestoreError {
            switch error {
            case .cancelled:
                state = .cancelled
            default:
                state = .failed(error.localizedDescription)
            }
            cancelFlag = nil
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            cancelFlag = nil
            throw error
        }
    }

    // MARK: - Staging

    static func stagingRoot(label: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return docs.appendingPathComponent("RestoreEngine/\(safe)", isDirectory: true)
    }
}
