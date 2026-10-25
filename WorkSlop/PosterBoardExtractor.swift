import Foundation
import ZIPFoundation

/// Extracts imported .tendies zips into PosterBoard restore files.
///
/// Routing note: this uses the legacy *descriptors* route — descriptor
/// folders land in .../Extensions/{ext}/descriptors/<random-UUID>/. That is
/// the apply method upstream GoldenNugget DROPPED (commit 2f2fab7, "drop
/// descriptors apply method"): current desktop always delivers new tendies
/// as *configurations* (.../Extensions/{ext}/configurations/) AND registers
/// them in the PosterBoard SQLite database. This port does neither — the
/// database is never touched — so delivered wallpapers may be ignored by
/// PosterBoard even after the force-refresh below. PayloadBuilder warns
/// about this at build time; do not claim desktop parity for the routing.
///
/// Desktop rules still mirrored here:
/// - Structure version 59 on iOS 16, 61 on iOS 17+ (PayloadSpecCatalog.pbStructure).
/// - Descriptor folders (name contains "descriptor", case-insensitive) are
///   renamed to a random uppercase UUID (desktop randomizeUUID) to avoid
///   collisions with existing descriptors on the device.
/// - The 3 identifier plists are rewritten to the randomized ID
///   (desktop update_plist_id); MercuryPoster identifiers are preserved
///   byte-for-byte (desktop is_mercury).
/// - The provider extension is derived from the descriptor's parent folder
///   or name keywords (video/photos -> PhotosPosterProvider, mercury ->
///   MercuryPoster, else WallpaperKit.CollectionsPoster).
/// - Domain is always AppDomain-com.apple.PosterBoard.
/// - Zip-slip protection: entries with ".." or absolute paths are skipped;
///   symlink entries are skipped outright (a symlink inside the temp dir
///   could otherwise stage files from outside the zip).
///
/// Honest simplifications vs desktop:
/// - No configurations/database mode (descriptors mode only).
/// - Video tendies (.batter templates, freeze-frame/loop builders) are
///   out of scope — only plain .tendies descriptor zips.
enum PosterBoardExtractor {
    static let maxTendiesPerRestore = 5
    static let domain = "AppDomain-com.apple.PosterBoard"

    /// One extracted file ready for the restore payload.
    struct ExtractedFile {
        let restorePath: String
        let localURL: URL
    }

    /// Extracts a .tendies zip and maps its descriptor files to restore
    /// paths. Returns the files, the number of descriptor folders found
    /// (for the desktop's 10-descriptor total cap), plus any warnings
    /// (skipped entries, etc.).
    static func extract(
        tendiesURL: URL,
        structureVersion: Int,
        stagingDir: URL
    ) -> (files: [ExtractedFile], warnings: [String], descriptorCount: Int) {
        var files: [ExtractedFile] = []
        var warnings: [String] = []
        var descriptorCount = 0

        guard let archive = Archive(url: tendiesURL, accessMode: .read) else {
            return ([], ["\(tendiesURL.lastPathComponent): not a readable zip - skipped."], 0)
        }

        // Extract to a unique temp dir with zip-slip protection.
        let extractDir = stagingDir
            .appendingPathComponent("tendies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        for entry in archive {
            let name = entry.path
            // Zip-slip guard: skip absolute paths and parent traversals.
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                warnings.append("\(tendiesURL.lastPathComponent): skipped unsafe entry '\(name)'.")
                continue
            }
            // Symlinks are never materialized: a crafted link could point
            // the descriptor walk at files outside the zip.
            if entry.type == .symlink {
                warnings.append("\(tendiesURL.lastPathComponent): skipped symlink entry '\(name)'.")
                continue
            }
            if name.hasPrefix("__MACOSX/") || name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let dest = extractDir.appendingPathComponent(name)
            do {
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try archive.extract(entry, to: dest)
                }
            } catch {
                warnings.append("\(tendiesURL.lastPathComponent): failed to extract '\(name)' (\(error.localizedDescription)).")
            }
        }

        // Walk for descriptor folders and route their contents.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([], ["\(tendiesURL.lastPathComponent): could not walk extracted contents."], 0)
        }
        for case let dirURL as URL in enumerator {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folderName = dirURL.lastPathComponent
            guard folderName.lowercased().contains("descriptor") else { continue }
            enumerator.skipDescendants()
            descriptorCount += 1

            let ext = extensionFor(descriptorURL: dirURL)
            let isMercury = (ext == "com.apple.MercuryPoster")
            // Desktop randomizeUUID: rename the descriptor folder to a random
            // uppercase UUID so it never collides with an existing descriptor
            // on the device (which would overwrite instead of adding).
            let newFolderName = UUID().uuidString.uppercased()
            let randomizedID = Int.random(in: 9999...99999)
            let base = "/Library/Application Support/PRBPosterExtensionDataStore/\(structureVersion)/Extensions/\(ext)/descriptors/\(newFolderName)"

            guard let inner = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let fileURL as URL in inner {
                guard (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else { continue }
                let rel = fileURL.path.replacingOccurrences(of: dirURL.path + "/", with: "")
                // Copy into staging so BuiltFile.url points at a stable location.
                let staged = stagingDir
                    .appendingPathComponent("pb-\(UUID().uuidString)-\(fileURL.lastPathComponent)")
                do {
                    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                    // Desktop update_plist_id(): rewrite the 3 identifier
                    // files to the randomized ID. Mercury identifiers are
                    // preserved (desktop is_mercury).
                    if !isMercury,
                       let newData = rewrittenIdentifier(
                           fileName: fileURL.lastPathComponent,
                           sourceURL: fileURL,
                           randomizedID: randomizedID) {
                        try newData.write(to: staged, options: .atomic)
                    } else {
                        try fm.copyItem(at: fileURL, to: staged)
                    }
                    files.append(ExtractedFile(restorePath: "\(base)/\(rel)", localURL: staged))
                } catch {
                    warnings.append("\(tendiesURL.lastPathComponent): could not stage '\(rel)' (\(error.localizedDescription)).")
                }
            }
        }

        if files.isEmpty {
            warnings.append("\(tendiesURL.lastPathComponent): no descriptor folders found - nothing to deliver.")
        }
        return (files, warnings, descriptorCount)
    }

    /// Desktop extension heuristic (posterboard_tweak.py): the provider
    /// extension is the descriptor's parent folder when it looks like a
    /// bundle ID; otherwise keyword-matched.
    private static func extensionFor(descriptorURL: URL) -> String {
        let parent = descriptorURL.deletingLastPathComponent().lastPathComponent
        if parent.hasPrefix("com.apple.") { return parent }
        let name = descriptorURL.lastPathComponent.lowercased()
        if name.contains("video") || name.contains("photos") {
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        }
        if name.contains("mercury") { return "com.apple.MercuryPoster" }
        return "com.apple.WallpaperKit.CollectionsPoster"
    }

    /// Port of desktop posterboard_tweak.py update_plist_id(): rewrites the
    /// 3 identifier files to the randomized ID. Returns the modified data,
    /// or nil when the file is not an identifier file or could not be read.
    private static func rewrittenIdentifier(
        fileName: String,
        sourceURL: URL,
        randomizedID: Int
    ) -> Data? {
        if fileName == "com.apple.posterkit.provider.descriptor.identifier" {
            // Plain-text file holding the numeric ID.
            return String(randomizedID).data(using: .utf8)
        }
        if fileName == "com.apple.posterkit.provider.contents.userInfo" {
            guard var plist = readPlist(at: sourceURL) else { return nil }
            plist["wallpaperRepresentingIdentifier"] = randomizedID
            return try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
        }
        if fileName.hasSuffix("Wallpaper.plist") {
            guard var plist = readPlist(at: sourceURL) else { return nil }
            plist["identifier"] = randomizedID
            return try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
        }
        return nil
    }

    private static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// Force-refresh plist (desktop posterboard_tweak.py force_pb_refresh):
    /// PosterBoard resets file protections and re-scans descriptors on next
    /// launch when this is present. Without it, delivered wallpapers are
    /// silently ignored even after reboot. Written once per restore (not per
    /// .tendies file) — callers add the result to the payload.
    static func forceRefreshFile(stagingDir: URL) -> ExtractedFile? {
        var plist: [String: Any] = [
            "PBF_LOCALE_DID_CHANGE": false,
            "PBF_RESET_FILE_PROTECTIONS": true,
        ]
        // Desktop: iOS 26.4+ needs the migration keys too.
        let v = DeviceInfo.iosVersion
        if v.major > 26 || (v.major == 26 && v.minor >= 4) {
            plist["PersistedPosterContainerBundleIdentifiers"] = [
                "com.apple.Posters.CollectionsPosterApp"
            ]
            plist["CompletedPosterBundleIdentifierMigrations"] = [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ]
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0) else { return nil }
        let url = stagingDir.appendingPathComponent("pb-force-refresh.plist")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return ExtractedFile(
            restorePath: "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist",
            localURL: url)
    }
}
