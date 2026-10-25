import Foundation

// MARK: - Phase 1: BACKUP ALL DATA FULL
//
// Real work done here: prerequisite gates (pairing, tunnel, disk, Find My
// attestation, version) and backup staging preparation. The actual
// mobilebackup2 pull goes over the loopback transport (DeviceTransport).

enum BackupPhase {
    struct Result: Sendable {
        let backupRoot: URL
        let prerequisites: [PrerequisiteCheck]
    }

    static func run(
        request: RestoreRequest,
        stagingRoot: URL,
        transport: DeviceTransport,
        watchdog: StallWatchdog,
        progress: @Sendable @escaping (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Result {
        progress(RestoreProgress(phase: .backup, fraction: 0.05, message: "Checking prerequisites…"))
        let checks = checkPrerequisites(request: request)
        if checks.contains(where: { !$0.isOK }) {
            throw RestoreError.prerequisitesFailed(checks)
        }
        if isCancelled() { throw RestoreError.cancelled }

        progress(RestoreProgress(phase: .backup, fraction: 0.15, message: "Preparing backup staging…"))
        let backupRoot = stagingRoot.appendingPathComponent("FullBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        progress(RestoreProgress(phase: .backup, fraction: 0.25, message: "Pulling full backup from device…"))
        // Gap 12 fix: every device progress tick proves liveness
        // (desktop's _backup_cb). The closure is synchronous, so the
        // actor tick goes through a Task hop — the tick is idempotent.
        let pulledRoot = try await transport.pullFullBackup(to: backupRoot) { f in
            Task { await watchdog.noteProgress() }
            if f >= 0 {
                progress(RestoreProgress(phase: .backup,
                                         fraction: 0.25 + 0.70 * f,
                                         message: "Pulling full backup… \(Int(f * 100))%"))
            }
        }

        // Encrypted PRE-check (desktop: pre-check before anything is
        // written). The injector re-checks before touching Manifest.db
        // (post-check). Encrypted backups are refused at both gates:
        // plaintext injection has no matching wrapped key (MBErrorDomain/205).
        if BackupInjector.isEncryptedBackup(at: pulledRoot) {
            throw RestoreError.phaseFailed(
                phase: .backup,
                message: "The pulled backup is encrypted (Manifest.plist IsEncrypted). " +
                "This route cannot write into an encrypted backup safely — turn off backup " +
                "encryption and try again. Nothing was written; the device was not changed.")
        }

        return Result(backupRoot: pulledRoot, prerequisites: checks)
    }

    // MARK: - Prerequisite gates (all real, all local)

    static func checkPrerequisites(request: RestoreRequest) -> [PrerequisiteCheck] {
        var checks: [PrerequisiteCheck] = []

        checks.append(PrerequisiteCheck(
            name: "Pairing record",
            status: PairingStore.isImported
                ? .passed
                : .failed(reason: "No pairing record imported — import it in Settings first.")
        ))

        checks.append(PrerequisiteCheck(
            name: "VPN tunnel",
            status: DeviceStatus.vpnTunnelActive()
                ? .passed
                : .failed(reason: "Loopback VPN tunnel not detected. Install and start the tunnel app first.")
        ))

        checks.append(PrerequisiteCheck(
            name: "Device version",
            status: .passed // the engine already refused unknown / <27 before phase 1
        ))

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let free = BackupPhase.freeBytes(at: docs)
        checks.append(PrerequisiteCheck(
            name: "Staging disk space",
            status: .attestedUnverifiable(note: "\(free) bytes free on the staging volume. Whether that fits the device's full backup is verified at pull time, over the transport.")
        ))

        checks.append(PrerequisiteCheck(
            name: "Find My",
            status: request.findMyDisabledAttested
                ? .attestedUnverifiable(note: "User attested Find My is OFF. The sandbox cannot verify this — restoring with Find My ON risks activation issues.")
                : .failed(reason: "Find My must be OFF before a full restore. Confirm it in Settings, then attest.")
        ))

        checks.append(PrerequisiteCheck(
            name: "iOS 27 risk warning",
            // G1 full route only: the partial (sparse) engine reuses these
            // checks but never writes a full backup, so the bootloop
            // warning does not apply there.
            status: request.deviceVersion.major < 27 || request.riskWarningAccepted
                ? .passed
                : .failed(reason: G1Support.riskWarningText)
        ))

        return checks
    }

    private static func freeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
    }
}
