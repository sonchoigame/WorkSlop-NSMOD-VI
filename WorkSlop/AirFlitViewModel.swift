import SwiftUI
import PhotosUI
import ZIPFoundation

/// AirFlit view model: owns the passcode/wallet apply flow.
/// @MainActor like AirCard's AppViewModel — the blocking FFI calls
/// run on detached tasks, UI state stays on the main actor.
@MainActor
final class AirFlitViewModel: ObservableObject {
    @Published var passthmURL: URL?
    @Published var passthmFileCount: Int = 0
    @Published var walletCardID: String = ""
    @Published var walletImage: UIImage?
    @Published var running = false
    @Published var progress: Double = 0
    @Published var logLines: [String] = []
    @Published var result: String?
    @Published var resultOK = false
    @Published var hasPairingFile = PairingStore.isImported

    var iosOK: Bool {
        let v = DeviceInfo.iosVersion
        return AirFlitEngine.isSupported(major: v.major, minor: v.minor,
                                         build: DeviceInfoEx.buildNumber)
    }

    // MARK: - Passcode theme (.passthm)

    /// Imports a .passthm theme file (zip with keypad PNGs).
    /// Validates it contains PNG entries, stores a copy in Documents.
    func loadPassthm(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = docs.appendingPathComponent("airflit_theme.passthm")
            let data = try Data(contentsOf: url)
            // Validate: must be a zip with PNG entries
            guard let archive = Archive(data: data, accessMode: .read) else {
                resultOK = false
                result = "Invalid .passthm file (not a zip)."
                return
            }
            var pngCount = 0
            for entry in archive {
                if entry.path.hasSuffix(".png") { pngCount += 1 }
            }
            guard pngCount > 0 else {
                resultOK = false
                result = "Invalid .passthm file (no PNGs found)."
                return
            }
            try data.write(to: dest, options: .atomic)
            passthmURL = dest
            passthmFileCount = pngCount
            resultOK = true
            result = "Loaded .passthm with \(pngCount) key images."
        } catch {
            resultOK = false
            result = "Could not load .passthm: \(error.localizedDescription)"
        }
    }

    func applyPasscodeTheme() {
        guard !running else { return }
        // AirCard method: .passthm file only. No single-image mode.
        guard let themeURL = passthmURL else {
            resultOK = false
            result = "Import a .passthm theme file first."
            return
        }
        let themeCount = passthmFileCount
        running = true
        progress = 0
        result = nil
        logLines = ["[AirFlit] Staging passcode theme…"]
        Task { @MainActor in
            do {
                // Blocking FFI work runs on a background thread with
                // Sendable data only. It returns log lines;
                // all UI state is touched here on the main actor.
                let bgLog: [String] = try await Task.detached(
                    priority: .userInitiated
                ) { () -> [String] in
                    var log: [String] = []
                    // .passthm mode: extract the theme zip directly,
                    // preserving per-digit PNGs and their names.
                    let stage = try AirFlitEngine.makeStagingDir(prefix: "airflit_passthm") { dir in
                        guard let archive = Archive(url: themeURL, accessMode: .read) else {
                            throw AirFlitEngine.AirFlitError.writeFailed("Cannot read .passthm")
                        }
                        var n = 0
                        for entry in archive {
                            let destURL = dir.appendingPathComponent(entry.path)
                            // Create subdirectories as needed
                            let parent = destURL.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                            _ = try archive.extract(entry, to: destURL)
                            n += 1
                        }
                        log.append("[AirFlit] Extracted \(n) files from .passthm (\(themeCount) PNGs)")
                    }
                    defer { try? FileManager.default.removeItem(at: stage) }
                    // Write to all TelephonyUI versions (same as AirCard)
                    for target in ["/var/mobile/Library/Caches/TelephonyUI-10",
                                   "/var/mobile/Library/Caches/TelephonyUI-9",
                                   "/var/mobile/Library/Caches/TelephonyUI-8"] {
                        log.append("[AirFlit] Writing to \((target as NSString).lastPathComponent)…")
                        try AirFlitEngine.writeDirectory(
                            sourceDir: stage,
                            targetDir: target
                        ) { line in log.append("  " + line) }
                    }
                    return log
                }.value
                progress = 1.0
                logLines.append(contentsOf: bgLog)
                logLines.append("[AirFlit] Done.")
                resultOK = true
                result = "Passcode theme applied. Lock your iPhone to see it."
                running = false
            } catch {
                let msg = error.localizedDescription
                resultOK = false
                result = msg
                logLines.append("[AirFlit] Failed: \(msg)")
                running = false
            }
        }
    }

    // MARK: - Wallet skin

    func applyWalletSkin() {
        guard let image = walletImage, !running else { return }
        let cardID = walletCardID.trimmingCharacters(in: .whitespaces)
        guard !cardID.isEmpty else { return }
        // All UIImage work (resizing) happens here on the main actor.
        // The result [String: Data] is Sendable and safe to ferry
        // into the detached task.
        let skins = AirFlitImages.prepareCardSkins(from: image)
        guard !skins.isEmpty else {
            resultOK = false
            result = "Could not generate card skins."
            return
        }
        running = true
        progress = 0
        result = nil
        logLines = ["[AirFlit] Generating card skins…"]
        Task { @MainActor in
            do {
                let bgLog: [String] = try await Task.detached(
                    priority: .userInitiated
                ) { () -> [String] in
                    var log: [String] = []
                    let stage = try AirFlitEngine.makeStagingDir(prefix: "airflit_card") { dir in
                        for (name, data) in skins {
                            try? data.write(to: dir.appendingPathComponent(name))
                        }
                        log.append("[AirFlit] Staged \(skins.count) skin files")
                    }
                    defer { try? FileManager.default.removeItem(at: stage) }
                    let target = "/var/mobile/Library/Passes/Cards/\(cardID).pkpass"
                    log.append("[AirFlit] Injecting skins into \(cardID.prefix(12))…")
                    try AirFlitEngine.writeDirectory(sourceDir: stage, targetDir: target) { line in
                        log.append("  " + line)
                    }
                    log.append("[AirFlit] Invalidating pass cache…")
                    let invStage = try AirFlitEngine.makeStagingDir(prefix: "airflit_inv") { dir in
                        AirFlitImages.stageCacheInvalidation(into: dir)
                    }
                    defer { try? FileManager.default.removeItem(at: invStage) }
                    for ext in [".cache", ".pkcache"] {
                        let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cardID)\(ext)"
                        try AirFlitEngine.writeDirectory(sourceDir: invStage, targetDir: cacheTarget)
                    }
                    return log
                }.value
                progress = 1.0
                logLines.append(contentsOf: bgLog)
                logLines.append("[AirFlit] Done.")
                resultOK = true
                result = "Wallet skin applied. Force-close the Wallet app to see it."
                running = false
            } catch {
                let msg = error.localizedDescription
                resultOK = false
                result = msg
                logLines.append("[AirFlit] Failed: \(msg)")
                running = false
            }
        }
    }
}
