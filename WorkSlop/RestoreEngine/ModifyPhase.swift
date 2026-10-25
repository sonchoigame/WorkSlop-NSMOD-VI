import Foundation

// MARK: - Phase 3: MODIF
//
// Real injection into the pulled backup, in Apple layout:
//   - payload bytes → <backupRoot>/<aa>/<fileID>  (aa = first 2 hex of fileID)
//   - Manifest.db rows (fileID, domain, relativePath, flags=1) with
//     hand-built MBFile blobs carrying UNIQUE inodes
//   - parent directory rows (flags=2), also with unique inodes
//   - staged plist keys are deep-merged onto the backup's own copy of
//     the file (original preserved as .bak) — never a whole-file
//     replace from an empty base
//   - verification gate: every payload is re-read byte-identical and
//     its Manifest row checked BEFORE the restore may start
//
// What was removed: the old <domain>/<relativePath> tree this phase
// used to write. Nothing ever read it (the restore serves <aa>/<fileID>
// via the fileID map), so it was dead weight.
//
// SAFETY, non-negotiable on iOS 27: a nulled file MUST be a valid EMPTY
// PLIST. A 0-byte plist on iOS 27 bootloops SpringBoard. This phase
// enforces that by version — it never writes 0 bytes on 27+.

enum ModifyPhase {
    struct Result: Sendable {
        let backupRoot: URL
        let injectedCount: Int
        /// Files that would have been 0 bytes but were written as valid
        /// empty plists because the target is iOS 27+.
        let nulledAsEmptyPlistCount: Int
        /// Loud notes: merges, .bak preserves, skipped merges.
        let warnings: [String]
    }

    static func run(
        request: RestoreRequest,
        backupRoot: URL,
        payloadManifest: URL,
        progress: @Sendable (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Result {
        func report(_ fraction: Double, _ message: String) {
            progress(RestoreProgress(phase: .modify, fraction: fraction, message: message))
        }

        report(0.05, "Reading payload manifest…")
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: payloadManifest)
        } catch {
            throw RestoreError.modifyFailed(reason: "Cannot read payload manifest: \(error.localizedDescription)")
        }
        let entries: [PayloadPhase.ManifestEntry]
        do {
            entries = try JSONDecoder().decode([PayloadPhase.ManifestEntry].self, from: manifestData)
        } catch {
            throw RestoreError.modifyFailed(reason: "Payload manifest is corrupt: \(error.localizedDescription)")
        }
        guard !entries.isEmpty else {
            throw RestoreError.modifyFailed(reason: "Payload manifest is empty — nothing to inject.")
        }

        // Encrypted POST-check (desktop: post-check before injection).
        // The pre-check already ran in BackupPhase; this is defense in
        // depth at the exact point where bytes are about to be written.
        if BackupInjector.isEncryptedBackup(at: backupRoot) {
            throw RestoreError.modifyFailed(
                reason: "Backup is encrypted — refusing to inject. Nothing was written.")
        }

        let payloadDir = payloadManifest.deletingLastPathComponent()
        let stagingRoot = backupRoot.deletingLastPathComponent()
        var targets: [BackupInjector.FileTarget] = []
        var warnings: [String] = []
        var nulled = 0

        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw RestoreError.cancelled }
            // Desktop plan_g1_payloads rules: empty domain / empty path /
            // ".." are never planned; leading slashes are stripped.
            let (domain, relPath) = try validated(
                domain: entry.domain, relativePath: entry.restorePath)
            let src = payloadDir.appendingPathComponent(entry.fileName)
            guard let stagedData = try? Data(contentsOf: src) else {
                throw RestoreError.modifyFailed(
                    reason: "Payload file missing: \(entry.fileName) for \(domain):\(relPath)")
            }

            let finalData: Data
            if stagedData.isEmpty && request.deviceVersion.isIOS27OrLater {
                // Nulled file on iOS 27: valid empty plist, NEVER 0 bytes.
                // It REPLACES the backup's copy, so the original is
                // preserved first (never silently clobbered).
                preserveOriginal(domain: domain, relativePath: relPath,
                                 backupRoot: backupRoot, stagingRoot: stagingRoot,
                                 warnings: &warnings)
                finalData = ModifyPhase.emptyPlistData()
                nulled += 1
            } else {
                // Deep-merge staged keys onto the backup's own copy
                // (desktop: _merge_staged_onto_backup_plist). Whole-file
                // replace from an empty base would delete keys the user
                // (or an earlier apply) already had on the device.
                finalData = mergedContents(
                    staged: stagedData, domain: domain, relativePath: relPath,
                    backupRoot: backupRoot, stagingRoot: stagingRoot,
                    warnings: &warnings)
            }
            targets.append(BackupInjector.FileTarget(
                domain: domain, relativePath: relPath, contents: finalData))
            report(0.05 + 0.55 * Double(index + 1) / Double(entries.count),
                   "Modify \(index + 1)/\(entries.count)")
        }

        report(0.65, "Injecting into backup (Apple layout)…")
        let injectResult = try BackupInjector.inject(backupRoot: backupRoot, files: targets)
        if isCancelled() { throw RestoreError.cancelled }

        // Verification gate (desktop: _verify_injected_files): the restore
        // is REFUSED unless every payload re-reads byte-identical and its
        // Manifest row (domain/relativePath/flags) is correct.
        report(0.85, "Verifying injected payloads…")
        let problems = BackupInjector.verify(backupRoot: backupRoot, files: targets)
        guard problems.isEmpty else {
            throw RestoreError.modifyFailed(
                reason: "Verification failed — restore refused:\n" +
                    problems.joined(separator: "\n"))
        }

        for w in warnings { report(1.0, w) }
        report(1.0, "Modify done: \(injectResult.injectedCount) injected " +
               "(\(injectResult.dirRowsAdded) dir rows), \(nulled) nulled as empty plist.")
        return Result(backupRoot: backupRoot,
                      injectedCount: injectResult.injectedCount,
                      nulledAsEmptyPlistCount: nulled,
                      warnings: warnings)
    }

    // MARK: - entry validation (desktop: plan_g1_payloads)

    /// Empty domain / empty path / ".." segments are never planned.
    /// Leading slashes are stripped (device tolerance unproven).
    private static func validated(domain: String, relativePath: String) throws
    -> (domain: String, relativePath: String) {
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else {
            throw RestoreError.modifyFailed(
                reason: "Refusing to inject a payload with an empty domain.")
        }
        var p = relativePath
        while p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else {
            throw RestoreError.modifyFailed(
                reason: "Refusing to inject \(d) with an empty path.")
        }
        let parts = p.split(separator: "/").map(String.init)
        guard !parts.contains("..") else {
            throw RestoreError.modifyFailed(
                reason: "Refusing to inject \(d)/\(p): '..' would plant a " +
                "manifest row outside the intended tree.")
        }
        return (d, p)
    }

    // MARK: - payload merge (desktop: _merge_staged_onto_backup_plist)

    /// Deep-merge staged plist keys onto the backup's own copy of the file.
    /// The original is preserved as .bak BEFORE any replace decision.
    /// Not in backup → staged bytes as-is. Either side not a plist dict →
    /// staged replaces wholesale, LOUDLY (original already preserved).
    private static func mergedContents(staged: Data, domain: String,
                                       relativePath: String, backupRoot: URL,
                                       stagingRoot: URL,
                                       warnings: inout [String]) -> Data {
        guard let origURL = originalURL(domain: domain, relativePath: relativePath,
                                        backupRoot: backupRoot),
              let origData = try? Data(contentsOf: origURL)
        else { return staged }  // absent from backup: inject new, byte-identical
        preserveBak(originalURL: origURL, domain: domain, relativePath: relativePath,
                    stagingRoot: stagingRoot, warnings: &warnings)
        guard let stagedDict = plistDict(staged),
              let origDict = plistDict(origData)
        else {
            warnings.append(
                "WARNING: \(domain)/\(relativePath) is not a plist dict on one side — " +
                "the staged file REPLACES the backup copy wholesale (original preserved as .bak).")
            return staged
        }
        let merged = deepMerge(base: origDict, staged: stagedDict)
        guard let out = try? PropertyListSerialization.data(
                fromPropertyList: merged, format: .binary, options: 0),
              !out.isEmpty
        else {
            warnings.append(
                "WARNING: merge encode failed for \(domain)/\(relativePath) — " +
                "the staged file replaces wholesale (original preserved as .bak).")
            return staged
        }
        return out
    }

    /// The backup's own copy of a payload file, if present. This transport
    /// pulls flat (backupRoot/<fileID>); Apple layout is also checked.
    private static func originalURL(domain: String, relativePath: String,
                                    backupRoot: URL) -> URL? {
        let fid = BackupInjector.fileID(domain: domain, relativePath: relativePath)
        let candidates = [
            backupRoot.appendingPathComponent(fid),
            BackupInjector.blobURL(backupRoot: backupRoot, fileID: fid),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Preserve the backup's original as .bak next to the staging root
    /// (desktop: g1-merge-fallback-bak), BEFORE any replace decision.
    private static func preserveBak(originalURL: URL, domain: String,
                                    relativePath: String, stagingRoot: URL,
                                    warnings: inout [String]) {
        do {
            let bakDir = stagingRoot.appendingPathComponent(
                "g1-merge-fallback-bak", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bakDir, withIntermediateDirectories: true)
            let rawStem = "\(domain)__\(relativePath)".replacingOccurrences(of: "/", with: "__")
            let stem = String(rawStem
                .filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
                .prefix(120))
            let dest = bakDir.appendingPathComponent(
                "\(Int(Date().timeIntervalSince1970))_\(stem.isEmpty ? "payload" : stem).bak")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: originalURL, to: dest)
            warnings.append(
                "Preserved the backup's original \(domain)/\(relativePath) as \(dest.lastPathComponent).")
        } catch {
            // Desktop proceeds with a loud log when preservation itself
            // fails; the alternative (refusing the whole run over a .bak)
            // is worse. Loud either way.
            warnings.append(
                "WARNING: could not preserve a .bak of the backup's " +
                "\(domain)/\(relativePath) (\(error.localizedDescription)) — proceeding.")
        }
    }

    /// Preserve-before-replace for the nulled-file path (no merge there).
    private static func preserveOriginal(domain: String, relativePath: String,
                                         backupRoot: URL, stagingRoot: URL,
                                         warnings: inout [String]) {
        guard let origURL = originalURL(domain: domain, relativePath: relativePath,
                                        backupRoot: backupRoot)
        else { return }
        preserveBak(originalURL: origURL, domain: domain, relativePath: relativePath,
                    stagingRoot: stagingRoot, warnings: &warnings)
    }

    private static func plistDict(_ data: Data) -> [String: Any]? {
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &fmt),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    /// Recursively merge staged onto base (staged wins on scalars).
    /// Neither input is mutated (desktop: _deep_merge_dict).
    private static func deepMerge(base: [String: Any],
                                  staged: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in staged {
            if let baseSub = out[key] as? [String: Any],
               let stagedSub = value as? [String: Any] {
                out[key] = deepMerge(base: baseSub, staged: stagedSub)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// A valid empty plist. What iOS 27 requires where older systems
    /// tolerated 0 bytes.
    static func emptyPlistData() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>

        """.utf8)
    }
}
