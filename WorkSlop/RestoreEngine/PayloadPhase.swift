import Foundation

// MARK: - Phase 2: PAYLOAD FILE
//
// Builds the real tweak payload for every staged feature — the "dozens of
// locations" are the PayloadSpec catalog targets, grouped per target file by
// PayloadBuilder. Files land in engine staging with a manifest mapping each
// file → domain + restorePath, which ModifyPhase consumes. Fully real,
// fully local; no device needed.

enum PayloadPhase {
    struct ManifestEntry: Codable, Sendable {
        let fileName: String
        let domain: String
        let restorePath: String
    }

    struct Result: Sendable {
        let stagingDir: URL
        let manifestURL: URL
        let entries: [ManifestEntry]
        let warnings: [String]
    }

    static let manifestFileName = "payload-manifest.json"

    static func run(
        request: RestoreRequest,
        stagingRoot: URL,
        progress: @Sendable (RestoreProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Result {
        func report(_ fraction: Double, _ message: String) {
            progress(RestoreProgress(phase: .payload, fraction: fraction, message: message))
        }

        report(0.05, "Building tweak payload…")
        let built = PayloadBuilder.build(staged: request.stagedFeatureIDs)
        if isCancelled() { throw RestoreError.cancelled }
        guard !built.files.isEmpty else { throw RestoreError.nothingStaged }

        let dir = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [ManifestEntry] = []
        for (index, file) in built.files.enumerated() {
            if isCancelled() { throw RestoreError.cancelled }
            let safeDomain = file.domain.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            let fileName = String(format: "%03d-%@.plist", index, safeDomain)
            let dest = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file.url, to: dest)
            entries.append(ManifestEntry(fileName: fileName, domain: file.domain, restorePath: file.restorePath))
            report(0.05 + 0.80 * Double(index + 1) / Double(built.files.count),
                   "Payload \(index + 1)/\(built.files.count): \(file.domain)")
        }

        let manifestURL = dir.appendingPathComponent(manifestFileName)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: manifestURL)

        report(1.0, "Payload ready: \(entries.count) files.")
        return Result(stagingDir: dir, manifestURL: manifestURL, entries: entries, warnings: built.warnings)
    }
}
