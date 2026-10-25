import Foundation
import CryptoKit
import SQLite3

// MARK: - Device transport: real loopback implementation
//
// Talks to the device's own lockdownd over the loopback tunnel (LocalDevVPN
// tunnel app installed separately; presence detected by
// DeviceStatus.vpnTunnelActive()). Pure Swift, no FFI:
//   LockdownClient (CFStream, STARTTLS) + MobileBackup2Client
//   (Network.framework), both verified against libimobiledevice.
//
// Prerequisites (device side): the tunnel app installed + running, and a
// valid pairing record imported in the app (Settings).

protocol DeviceTransport: Sendable {
    /// Pull a FULL device backup into `stagingDir`. Progress 0...1.
    func pullFullBackup(to stagingDir: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    /// Push `backupRoot` back as a full restore. Progress 0...1.
    /// The device itself must confirm success — a transport return value
    /// alone is never reported as success (a restore once stopped at 55%
    /// and was misreported as done).
    func pushFullRestore(from backupRoot: URL, progress: @Sendable @escaping (Double) -> Void) async throws
    /// Ask the device whether the restore landed. Must come from the
    /// device response, not from local bookkeeping.
    func verifyRestore(of backupRoot: URL) async throws -> Bool
    /// Reboot the device over lockdown.
    func rebootDevice() async throws
    /// Block until the device answers lockdown again (post-reboot),
    /// polling with a FRESH session each time — the pre-reboot session
    /// is dead by definition (desktop: wait_for_ios27_device_online).
    /// Returns true as soon as the device is back, false on timeout.
    /// A false is honest, not a brick verdict: the device may still be
    /// booting or stuck on the Apple logo.
    func waitForDeviceOnline(timeoutSeconds: TimeInterval) async -> Bool
    /// The device's UDID from a live lockdown query — never guessed.
    /// Needed to name a synthesized backup's device directory.
    func deviceUDID() async throws -> String
    /// Push a SYNTHESIZED sparse backup (legacy Manifest.mbdb, payloads
    /// flat by fileID) as a partial restore — iOS 16–26. No wipe, no
    /// reboot. Returns the number of files the device actually
    /// requested and received. The device itself must confirm success —
    /// see verifyRestore.
    func pushPartialRestore(from backupRoot: URL, udid: String,
                            progress: @Sendable @escaping (Double) -> Void) async throws -> Int
}

/// Real transport over the loopback tunnel. An actor: one transport =
/// serialized operations, never interleaved on the sockets.
actor LoopbackTransport: DeviceTransport {
    private let backupPassword: String?

    /// The device's own final verdict from the last push, captured verbatim
    /// from the DLMessageProcessMessage ErrorCode. verifyRestore() reports
    /// THIS value — there is no re-query protocol in mobilebackup2, so the
    /// captured device verdict is the honest maximum (it is the device's
    /// response, not an assumed success).
    private var lastRestoreDeviceConfirmed: Bool?

    init(backupPassword: String? = nil) {
        self.backupPassword = backupPassword
    }

    // MARK: - helpers

    private func requireTunnel() throws {
        guard DeviceStatus.vpnTunnelActive() else {
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "Loopback tunnel not detected. Install and start the tunnel app first.")
        }
    }

    private func loadIdentity() throws -> PairingIdentity {
        guard PairingStore.isImported, let identity = PairingIdentity.load() else {
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "No readable pairing record. Import it in Settings first.")
        }
        return identity
    }

    /// Fresh lockdown handshake (mirrors libimobiledevice's per-operation
    /// lockdownd_client_new_with_handshake pattern).
    private func handshakedLockdown() async throws -> (LockdownClient, PairingIdentity, String) {
        try requireTunnel()
        let identity = try loadIdentity()
        let lockdown = LockdownClient()
        do {
            try await lockdown.connect()
            try await lockdown.handshake(identity: identity)
        } catch {
            lockdown.close()
            throw error
        }
        // Never guessed: a literal fallback here would run the
        // backup/restore exchanges against targetID "device" — a
        // wrong-identity run that fails confusingly downstream.
        // Refuse loudly at the source instead.
        guard let udid = try? await lockdown.getValue(domain: nil, key: "UniqueDeviceID") as? String,
              !udid.isEmpty
        else {
            lockdown.close()
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "Device did not report a UDID — refusing to guess one for the backup/restore exchange.")
        }
        return (lockdown, identity, udid)
    }

    // MARK: - DeviceTransport

    /// Runs one mobilebackup2 exchange with REAL user cancellation:
    /// - the client's cooperative checks follow Task.isCancelled
    /// - on task cancellation the socket is disconnected, which unblocks
    ///   any hung read immediately — nothing keeps running in the
    ///   background after cancel (this is the fix for "cancel only hides
    ///   the UI while the run continues")
    /// - any error raised while the task is cancelled is reported as
    ///   .cancelled, not as a transport failure (the socket error from
    ///   the disconnect is the mechanism, not the cause)
    private func cancellableExchange<T: Sendable>(
        _ mb2: MobileBackup2Client,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await mb2.setCancelled { Task.isCancelled }
        do {
            return try await withTaskCancellationHandler(operation: body) {
                // Unblock hung reads: NWConnection.cancel() fires the
                // pending receive completion with an error.
                Task { await mb2.disconnect() }
            }
        } catch {
            await mb2.disconnect()
            if Task.isCancelled { throw RestoreError.cancelled }
            if let mb2err = error as? MobileBackup2Error, case .cancelled = mb2err {
                throw RestoreError.cancelled
            }
            throw error
        }
    }

    func pullFullBackup(to stagingDir: URL,
                        progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let (lockdown, identity, udid) = try await handshakedLockdown()
        defer { lockdown.close() }

        let (port, serviceSSL) = try await lockdown.startService(
            "com.apple.mobilebackup2", escrowBag: identity.escrowBag)
        if serviceSSL {
            // UNVERIFIED: service-level SSL on the mobilebackup2 channel is
            // not covered by the examined libimobiledevice sources
            // (device_link_service.c has no SSL path). Fail loudly.
            throw RestoreError.phaseFailed(
                phase: .backup, message: "mobilebackup2 asked for service-level SSL; no verified flow")
        }

        let mb2 = MobileBackup2Client(port: port)
        // Hoisted for the @Sendable closures below (actor-isolated
        // state cannot be captured by them under Swift 6).
        let password = backupPassword
        do {
            _ = try await mb2.connect()
            // Inner I/O watchdog (desktop: run_with_stall_watchdog, 300s):
            // a wedged device aborts here instead of hanging forever.
            let count = try await cancellableExchange(mb2) {
                try await withIOWatchdog(
                    phase: .backup, operation: "backup",
                    onStall: { await mb2.disconnect() }
                ) { tick in
                    try await mb2.runBackup(
                        targetID: udid, sourceID: udid, password: password,
                        to: stagingDir,
                        progress: { f, _ in tick(); if f >= 0 { progress(f) } })
                }
            }
            // A pulled backup that yielded zero files is not a backup.
            guard count > 0 else {
                throw RestoreError.phaseFailed(
                    phase: .backup, message: "device sent zero files; refusing to continue on an empty pull")
            }
            await mb2.disconnect()
            return stagingDir
        } catch {
            await mb2.disconnect()
            if Task.isCancelled { throw RestoreError.cancelled }
            throw error
        }
    }

    func pushFullRestore(from backupRoot: URL,
                         progress: @Sendable @escaping (Double) -> Void) async throws {
        // Injection now happens in ModifyPhase (Apple layout
        // <aa>/<fileID> + Manifest.db rows), BEFORE this push — the
        // mandated BACKUP → PAYLOAD → MODIF → RESTORE order. This method
        // only pushes; it never mutates the backup.
        let (lockdown, identity, udid) = try await handshakedLockdown()
        defer { lockdown.close() }

        let (port, serviceSSL) = try await lockdown.startService(
            "com.apple.mobilebackup2", escrowBag: identity.escrowBag)
        if serviceSSL {
            throw RestoreError.phaseFailed(
                phase: .restore, message: "mobilebackup2 asked for service-level SSL; no verified flow")
        }

        let mb2 = MobileBackup2Client(port: port)
        // Hoisted for the @Sendable closures below.
        let password = backupPassword
        let root = backupRoot
        do {
            _ = try await mb2.connect()

            let confirmed = try await cancellableExchange(mb2) {
                try await withIOWatchdog(
                    phase: .restore, operation: "restore",
                    onStall: { await mb2.disconnect() }
                ) { tick in
                    try await mb2.runRestore(
                        targetID: udid, sourceID: udid, password: password,
                        from: root,
                        fileResolver: { [root] path in
                            let direct = root.appendingPathComponent(path)
                            if FileManager.default.fileExists(atPath: direct.path) { return direct }
                            // Injected payloads live at <aa>/<fileID> (Apple
                            // layout, written by ModifyPhase); the device may
                            // request the bare fileID.
                            if path.count == 40,
                               path.allSatisfy({ $0.isHexDigit }) {
                                let aa = root
                                    .appendingPathComponent(String(path.prefix(2)))
                                    .appendingPathComponent(path)
                                if FileManager.default.fileExists(atPath: aa.path) { return aa }
                            }
                            return nil
                        },
                        progress: { f, _ in tick(); if f >= 0 { progress(f) } })
                }
            }

            lastRestoreDeviceConfirmed = confirmed
            guard confirmed else {
                // Unreachable in practice (runRestore throws on ErrorCode != 0),
                // kept as a second gate: never report success without the device.
                throw RestoreError.phaseFailed(
                    phase: .restore, message: "The device did not confirm the restore landed.")
            }
            await mb2.disconnect()
        } catch {
            await mb2.disconnect()
            if Task.isCancelled { throw RestoreError.cancelled }
            throw error
        }
    }

    func verifyRestore(of backupRoot: URL) async throws -> Bool {
        guard let confirmed = lastRestoreDeviceConfirmed else {
            throw RestoreError.phaseFailed(
                phase: .restore,
                message: "No restore has been pushed in this session — nothing device-confirmed to report.")
        }
        return confirmed
    }

    func rebootDevice() async throws {
        let (lockdown, _, _) = try await handshakedLockdown()
        defer { lockdown.close() }
        try await lockdown.reboot()
    }

    // MARK: - Partial restore (iOS 16–26, synthesized sparse backup)

    func deviceUDID() async throws -> String {
        let (lockdown, _, udid) = try await handshakedLockdown()
        defer { lockdown.close() }
        guard !udid.isEmpty, udid != "device" else {
            throw RestoreError.phaseFailed(
                phase: .restore,
                message: "Device did not report a UDID — refusing to guess one for the synthetic backup.")
        }
        return udid
    }

    func pushPartialRestore(from backupRoot: URL, udid: String,
                            progress: @Sendable @escaping (Double) -> Void) async throws -> Int {
        let (lockdown, identity, handshakeUDID) = try await handshakedLockdown()
        defer { lockdown.close() }
        guard handshakeUDID == udid else {
            throw RestoreError.phaseFailed(
                phase: .restore,
                message: "Device identity changed mid-run (backup built for \(udid), now \(handshakeUDID)) — refusing to push to the wrong device.")
        }

        let (port, serviceSSL) = try await lockdown.startService(
            "com.apple.mobilebackup2", escrowBag: identity.escrowBag)
        if serviceSSL {
            throw RestoreError.phaseFailed(
                phase: .restore, message: "mobilebackup2 asked for service-level SSL; no verified flow")
        }

        let mb2 = MobileBackup2Client(port: port)
        // Real user cancel, same as the full route. Cutting a PARTIAL
        // restore mid-write is safe: no wipe is involved, files land
        // individually, and re-running Apply re-sends everything —
        // an interrupted run is completed, not bricked.
        let password = backupPassword
        let root = backupRoot
        do {
            _ = try await mb2.connect()
            // Inner I/O watchdog, same as the full route: a wedged
            // device aborts instead of hanging forever.
            let (confirmed, served) = try await cancellableExchange(mb2) {
                try await withIOWatchdog(
                    phase: .restore, operation: "partial restore",
                    onStall: { await mb2.disconnect() }
                ) { tick in
                    try await mb2.runPartialRestore(
                        targetID: udid, sourceID: udid, password: password,
                        from: root,
                        progress: { f, _ in tick(); if f >= 0 { progress(f) } })
                }
            }

            lastRestoreDeviceConfirmed = confirmed
            guard confirmed else {
                throw RestoreError.phaseFailed(
                    phase: .restore, message: "The device did not confirm the partial restore landed.")
            }
            await mb2.disconnect()
            return served
        } catch {
            await mb2.disconnect()
            if Task.isCancelled { throw RestoreError.cancelled }
            throw error
        }
    }

    func waitForDeviceOnline(timeoutSeconds: TimeInterval = 300) async -> Bool {
        // Fresh handshake on every poll — the pre-reboot session is dead
        // by definition (desktop: wait_for_ios27_device_online).
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            do {
                let (lockdown, _, _) = try await handshakedLockdown()
                lockdown.close()
                return true
            } catch {
                // Not back yet (or trust dialog pending) — keep polling.
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return false
    }
}
