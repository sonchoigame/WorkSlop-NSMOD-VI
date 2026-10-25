import Foundation
import CryptoKit

// MARK: - Partial restore engine (iOS 16–26, sparse restore)
//
// The method GoldenNugget-mobile uses for iOS 26 (itself a port of the
// desktop's legacy-MBDB branch), now wired end to end in this app:
//
//   1. Prerequisites — pairing record, VPN tunnel, Find My attestation.
//      Reuses BackupPhase.checkPrerequisites (all real, all local).
//   2. Payload — PayloadBuilder.build(staged:) (real plist files on disk).
//   3. Synthesize a minimal backup from NOTHING (no device pull, no wipe):
//      Info.plist / Status.plist / Manifest.plist + legacy Manifest.mbdb
//      + payloads flat in <backupRoot>/<udid>/, named by fileID.
//   4. Push via mobilebackup2 "Restore" with RestoreSystemFiles=true and
//      RestoreShouldReboot=false — the device writes the listed system
//      files in place. No wipe, no reboot (the user reboots manually,
//      like GoldenNugget-mobile).
//   5. The device's own verdict: DLMessageProcessMessage ErrorCode==0 AND
//      the device actually pulled files (a confirmed-but-empty restore is
//      refused as a failure, not reported as success).
//
// WHAT IS MEASURED (not invented) — see the reference audit:
// - MBDB record layout: desktop src/restore/mbdb.py + backup.py, and
//   GoldenNugget-mobile Nugget/Core/MBDBManifest.swift (verbatim port).
// - fileID = hex SHA1("domain-path"), payloads flat by fileID:
//   desktop backup.py:118-130.
// - Legacy-branch manifest versions (Status 2.4, Manifest 9.1/20.0):
//   desktop backup.py comment + GoldenNugget-mobile HostManifests.
// - BackupKeyBag in Manifest.plist is NOT optional: without it the device
//   pulls every payload, then refuses with MBErrorDomain/205 "No keybag
//   in manifest" (measured in GoldenNugget-mobile; the blob below is
//   libimobiledevice's public hardcoded keybag, also shipped there).
// - Directory rows (domain root + every intermediate dir) are required:
//   without them the restore fails renameatx ENOENT (GoldenNugget-mobile).
// - Restore options reboot=false + system_files=true: GoldenNugget-mobile
//   Rust RestoreOptions via RestoreRunner (shouldReboot:false,
//   systemFiles:true).
// - AppDomain-* rows need an Applications entry in Manifest.plist or the
//   device answers 205 "Unknown domain name" (both references).
// - The device requests "<udid>/<fileID>": idevicebackup2.c's remove
//   handler matches "<udid>/Manifest.mbdx" after the slash.
//
// WHAT IS ASSUMED (needs a device to confirm):
// - Row owner 501/501, DatabaseDomain 0/0 — from GoldenNugget-mobile's
//   rowOwner; coincides with the desktop's root-owned launchd
//   disabled.plist (the only DatabaseDomain payload in this catalog).
// - Leading "/" stripped from restore paths (desktop paths have none;
//   device tolerance for the slash is unproven).
// - The compact Applications entry {CFBundleIdentifier} suffices —
//   proven by GoldenNugget-mobile's earlier app-container PoC; the full
//   installation_proxy record is the safer variant if a device rejects it.
// - DLContentsOfDirectory is handled defensively (idevicebackup2.c does);
//   it may never arrive during a restore.
// - The entire wire exchange: zero device tests so far.

actor PartialRestoreEngine {
    static let shared = PartialRestoreEngine()

    private var inFlight = false
    private var cancelFlag: CancelFlag?

    /// Request cancellation. Honored mid-flight: the view cancels the
    /// Task and the transport disconnects the socket, so an in-flight
    /// exchange aborts cleanly instead of running on in the background.
    func cancel() {
        cancelFlag?.cancel()
    }

    /// Run the sparse-restore method for iOS 16–26.
    ///
    /// - Throws: `.alreadyInFlight` when a run is active (runs are never
    ///   stacked); `.versionOutsidePartialRange` for iOS 27+ (that is the
    ///   full engine's job); `.nothingStaged` with no staged tweaks;
    ///   `.prerequisitesFailed`; `.cancelled`; `.phaseFailed` with the
    ///   device's own refusal reason.
    func run(request: RestoreRequest,
             transport: DeviceTransport,
             onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard !inFlight else { throw RestoreError.alreadyInFlight }
        let major = request.deviceVersion.major
        guard (16...26).contains(major) else {
            throw RestoreError.versionOutsidePartialRange(major: major)
        }
        guard !request.stagedFeatureIDs.isEmpty else { throw RestoreError.nothingStaged }

        inFlight = true
        let flag = CancelFlag()
        cancelFlag = flag
        let watchdog = StallWatchdog()
        let stagingRoot = RestoreEngine.stagingRoot(label: request.deviceLabel)
        // Both the engine flag and Task.isCancelled stop the run —
        // cancel works mid-exchange, not just between phases.
        let cancelled: @Sendable () -> Bool = { flag.isCancelled || Task.isCancelled }

        func throwIfCancelled() throws {
            if flag.isCancelled || Task.isCancelled { throw RestoreError.cancelled }
        }

        do {
            // — 1. Prerequisites: pairing, tunnel, disk, Find My attestation —
            onProgress(0.02)
            let checks = BackupPhase.checkPrerequisites(request: request)
            if checks.contains(where: { !$0.isOK }) {
                throw RestoreError.prerequisitesFailed(checks)
            }
            try throwIfCancelled()
            await watchdog.noteProgress()

            // — 2. Device identity, from lockdown — never guessed —
            onProgress(0.05)
            let udid = try await transport.deviceUDID()
            try throwIfCancelled()
            await watchdog.noteProgress()

            // — 3. Payload from the staged features (real local files) —
            onProgress(0.10)
            let built = PayloadBuilder.build(staged: request.stagedFeatureIDs)
            guard !built.files.isEmpty else { throw RestoreError.nothingStaged }
            try throwIfCancelled()
            await watchdog.noteProgress()

            // — 4. Synthesize the minimal backup (no pull, no wipe) —
            onProgress(0.20)
            let synth = try PartialBackupSynthesizer.synthesize(
                stagingRoot: stagingRoot, udid: udid,
                built: built, isCancelled: cancelled)
            try throwIfCancelled()
            await watchdog.noteProgress()
            try await watchdog.check(phase: .restore)

            // — 5. Push. Cancel is honored mid-exchange: the transport
            // disconnects the socket on task cancellation. No wipe is
            // involved on this route, so an interrupted push is safe —
            // re-running Apply completes it.
            let served = try await transport.pushPartialRestore(
                from: synth.backupRoot, udid: udid
            ) { f in
                if f >= 0 { onProgress(0.35 + 0.60 * f) }
            }
            await watchdog.noteProgress()
            try await watchdog.check(phase: .restore)
            guard served > 0 else {
                throw RestoreError.phaseFailed(
                    phase: .restore,
                    message: "Device requested zero files — the synthetic backup was ignored; nothing was delivered.")
            }

            // — 6. Device verdict, from the restore response —
            onProgress(0.97)
            let confirmed = try await transport.verifyRestore(of: synth.backupRoot)
            guard confirmed else {
                throw RestoreError.phaseFailed(
                    phase: .restore,
                    message: "The device did not confirm the partial restore landed.")
            }

            onProgress(1.0)
            inFlight = false
            cancelFlag = nil
        } catch {
            inFlight = false
            cancelFlag = nil
            throw error
        }
    }
}

// MARK: - Synthetic backup builder (iOS 26 branch)

/// Builds the minimal backup the sparse restore needs, from nothing:
/// <backupRoot>/<udid>/{Info.plist, Status.plist, Manifest.plist,
/// Manifest.mbdb, <fileID>…}. No device content is pulled, no wipe.
/// Mirrors GoldenNugget-mobile BackupInjector.pruneAndInject(ios27:false)
///
/// - Manifest versions are the legacy branch's (Status 2.4,
///   Manifest 9.1/20.0) — desktop backup.py + GoldenNugget HostManifests.
/// - Manifest.db is deleted if present: the device must read
///   Manifest.mbdb on this branch, never sqlite.
enum PartialBackupSynthesizer {
    struct Payload: Sendable {
        let domain: String
        /// Normalized mbdb filename: no leading "/" (desktop convention;
        /// matches real iTunes backup records).
        let path: String
        let contents: Data
    }

    struct Result: Sendable {
        let backupRoot: URL
        let deviceDir: URL
        let payloadCount: Int
        let mbdbRowCount: Int
    }

    static func synthesize(stagingRoot: URL, udid: String, built: BuiltPayload,
                           isCancelled: @Sendable () -> Bool) throws -> Result {
        let fm = FileManager.default
        let backupRoot = stagingRoot.appendingPathComponent("PartialRestore", isDirectory: true)
        try? fm.removeItem(at: backupRoot)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let deviceDir = backupRoot.appendingPathComponent(udid, isDirectory: true)
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        // Normalize + dedupe (last wins); deterministic order so the
        // mbdb bytes are reproducible for the same input.
        var byKey: [String: Payload] = [:]
        for file in built.files {
            if isCancelled() { throw RestoreError.cancelled }
            let path = normalize(file.restorePath)
            guard !path.isEmpty else { continue }
            let contents = try Data(contentsOf: file.url)
            byKey[file.domain + "\u{1F}" + path] =
                Payload(domain: file.domain, path: path, contents: contents)
        }
        let payloads = byKey.keys.sorted().compactMap { byKey[$0] }
        guard !payloads.isEmpty else { throw RestoreError.nothingStaged }

        // Manifest.mbdb (legacy binary format).
        let rows = PartialMBDB.rows(for: payloads)
        try PartialMBDB.encode(rows).write(
            to: deviceDir.appendingPathComponent("Manifest.mbdb"), options: .atomic)

        // Payloads flat, named by fileID = hex SHA1("domain-path").
        for p in payloads {
            if isCancelled() { throw RestoreError.cancelled }
            try p.contents.write(
                to: deviceDir.appendingPathComponent(
                    PartialMBDB.fileID(domain: p.domain, path: p.path)),
                options: .atomic)
        }

        // Never sqlite on this branch.
        try? fm.removeItem(at: deviceDir.appendingPathComponent("Manifest.db"))

        try writeHostManifests(deviceDir: deviceDir, udid: udid, payloads: payloads)

        return Result(backupRoot: backupRoot, deviceDir: deviceDir,
                      payloadCount: payloads.count, mbdbRowCount: rows.count)
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    // MARK: host manifests

    /// libimobiledevice's public hardcoded backup keybag (1336 bytes
    /// decoded), also shipped by GoldenNugget-mobile's HostManifests.
    /// It carries no device identity — the UUIDs are keybag-entry
    /// identifiers — so one blob serves every device. Without it the
    /// device pulls all payloads, then refuses the restore with
    /// MBErrorDomain/205 "No keybag in manifest" (measured there).
    private static let backupKeyBag = Data(base64Encoded:
        "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"
    )!

    private static func writeHostManifests(deviceDir: URL, udid: String,
                                           payloads: [Payload]) throws {
        let status: [String: Any] = [
            "BackupState": "new",
            "Date": Date(),
            "IsFullBackup": false,
            "Version": "2.4",
            "SnapshotState": "finished",
            "UUID": UUID().uuidString.uppercased(),
        ]
        try PropertyListSerialization.data(fromPropertyList: status, format: .binary, options: 0)
            .write(to: deviceDir.appendingPathComponent("Status.plist"), options: .atomic)

        // AppDomain-* rows are not self-describing: without a matching
        // Applications entry the device answers 205 "Unknown domain name".
        // Compact shape {CFBundleIdentifier} — proven by
        // GoldenNugget-mobile's earlier app-container PoC; the full
        // installation_proxy record is the safer variant if rejected.
        var applications: [String: Any] = [:]
        for p in payloads where p.domain.hasPrefix("AppDomain-") {
            let bundleID = String(p.domain.dropFirst("AppDomain-".count))
            if !bundleID.isEmpty, applications[bundleID] == nil {
                applications[bundleID] = ["CFBundleIdentifier": bundleID]
            }
        }
        let manifest: [String: Any] = [
            "DataProtection": true,
            "BackupKeyBag": backupKeyBag,
            "Lockdown": [String: Any](),
            "SystemDomainsVersion": "20.0",
            "Version": "9.1",
            "Applications": applications,
        ]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: deviceDir.appendingPathComponent("Manifest.plist"), options: .atomic)

        let info: [String: Any] = [
            "Unique Identifier": udid.uppercased(),
            "Target Type": "Device",
            "Target Identifier": udid,
            "Build Version": "",
            "Product Version": "",
            "Product Type": "",
            "Serial Number": "",
            "Applications": [String: Any](),
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: deviceDir.appendingPathComponent("Info.plist"), options: .atomic)
    }
}

// MARK: - Legacy MBDB encoder (iOS 26 branch)
//
// Record layout, verbatim from desktop src/restore/mbdb.py:26-65 and
// backup.py BackupFile.to_record / Directory.to_record:
//
//   u16be len + bytes   domain
//   u16be len + bytes   filename
//   u16be len + bytes   link        (empty)
//   u16be len + bytes   hash        (raw SHA-1 of contents; empty for dirs)
//   u16be len + bytes   key         (empty)
//   u16be               mode        (0o755 | S_IFREG / S_IFDIR)
//   u64be               inode       (0 for dirs, random 8 bytes for files)
//   u32be               user_id
//   u32be               group_id
//   u32be               mtime / atime / ctime
//   u64be               size
//   u8                  flags       (4 — the MBDB flags byte, NOT the
//                                    sqlite flags column)
//   u8                  propertyCount (0)
//
// Header: "mbdb" + 0x05 0x00. No ProtectionClass field exists in this
// format (that lives in the sqlite `file` blob on iOS 27+).
enum PartialMBDB {
    private static let sIFREG: UInt16 = 0o100000
    private static let sIFDIR: UInt16 = 0o040000
    private static let defaultMode: UInt16 = 0o755
    private static let rowFlags: UInt8 = 4

    struct Row {
        let domain: String
        let path: String
        let isDirectory: Bool
        let owner: UInt32
        let group: UInt32
        let contents: Data
    }

    /// The name a payload is stored under: hex SHA1("domain-path").
    /// The device reads the filename out of Manifest.mbdb, derives this
    /// same string, and requests "<udid>/<fileID>".
    static func fileID(domain: String, path: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((domain + "-" + path).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Rows for a payload set: each payload's file, plus the domain root
    /// and every directory component above it. Mirrors desktop
    /// restore.py concat_regular_file — the device's rename step needs
    /// those directory rows (dropping them fails renameatx ENOENT).
    static func rows(for payloads: [PartialBackupSynthesizer.Payload]) -> [Row] {
        var rows: [Row] = []
        var seen = Set<String>()

        func addDirectory(domain: String, path: String) {
            let key = domain + "\u{1F}" + path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            rows.append(Row(domain: domain, path: path, isDirectory: true,
                            owner: 0, group: 0, contents: Data()))
        }

        for p in payloads {
            addDirectory(domain: p.domain, path: "")
            var accumulated = ""
            for component in p.path.split(separator: "/").dropLast() {
                accumulated = accumulated.isEmpty
                    ? String(component) : accumulated + "/" + component
                addDirectory(domain: p.domain, path: accumulated)
            }
        }
        for p in payloads {
            let o = owner(for: p.domain)
            rows.append(Row(domain: p.domain, path: p.path, isDirectory: false,
                            owner: o, group: o, contents: p.contents))
        }
        return rows
    }

    /// Measured in GoldenNugget-mobile (MBDBManifest.rowOwner): the
    /// reference threads owner=501/group=501 through every file row and
    /// only the deliberately root-owned tweak uses 0 — in this catalog
    /// that is exactly the DatabaseDomain set (launchd disabled.plist).
    /// ASSUMED for other DatabaseDomain paths: needs a device to confirm.
    private static func owner(for domain: String) -> UInt32 {
        domain.hasPrefix("DatabaseDomain") ? 0 : 501
    }

    static func encode(_ rows: [Row],
                       now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        var out = Data()
        out.append(contentsOf: [0x6D, 0x62, 0x64, 0x62]) // "mbdb"
        out.append(contentsOf: [0x05, 0x00])
        for row in rows {
            appendField(&out, Data(row.domain.utf8))
            appendField(&out, Data(row.path.utf8))
            appendField(&out, Data()) // link
            appendField(&out, row.isDirectory
                        ? Data()
                        : Data(Insecure.SHA1.hash(data: row.contents)))
            appendField(&out, Data()) // key
            appendBE(&out, defaultMode | (row.isDirectory ? sIFDIR : sIFREG))
            appendBE(&out, row.isDirectory ? 0 : randomInode())
            appendBE(&out, row.owner)
            appendBE(&out, row.group)
            appendBE(&out, now)
            appendBE(&out, now)
            appendBE(&out, now)
            appendBE(&out, UInt64(row.contents.count))
            out.append(rowFlags)
            out.append(0) // propertyCount
        }
        return out
    }

    // MARK: - byte helpers (big-endian throughout)

    private static func appendField(_ data: inout Data, _ value: Data) {
        appendBE(&data, UInt16(value.count))
        data.append(value)
    }

    private static func appendBE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendBE(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    private static func appendBE(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    /// Random 8-byte inode per file row, like desktop backup.py
    /// (int.from_bytes(randbytes(8), "big")); directory rows use 0.
    private static func randomInode() -> UInt64 {
        var out: UInt64 = 0
        for _ in 0..<8 {
            out = (out << 8) | UInt64(UInt8.random(in: 0...255))
        }
        return out
    }
}
