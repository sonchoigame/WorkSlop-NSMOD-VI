import Foundation

#if canImport(AirliftFFI)
import AirliftFFI

/// Box to ferry a Swift log closure through the C `void *ctx`.
private final class AirFlitLogBox {
    let log: (String) -> Void
    init(_ log: @escaping (String) -> Void) { self.log = log }
}

/// C-compatible log callback. Must be a global function with no
/// captures — a capturing Swift closure cannot convert to a C
/// function pointer.
private func airFlitLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let ctx = ctx, let msg = msg else { return }
    let box = Unmanaged<AirFlitLogBox>.fromOpaque(ctx).takeUnretainedValue()
    box.log(String(cString: msg))
}
#endif

/// AirFlit engine: writes files to the device using 100% the AirCard
/// method (AirTraffic via AirliftFFI), NOT sparse restore.
///
/// The core primitive is `al_exploit_write_dir` from AirliftFFI:
/// it stages a local directory and writes every file into the
/// target directory on the device through the AirTraffic sync
/// channel, authenticated with the pairing file.
///
/// iOS support window: 18.0 – 27.2 beta 2. iOS 27.2 beta 3+ patched
/// the underlying AirTraffic vector, so this menu is locked there.
enum AirFlitEngine {
    // MARK: - Pairing

    /// AirFlit keeps its own copy of the pairing file, in the same
    /// Documents folder the user already imports into. AirliftFFI
    /// accepts standard pairing files (.plist / .mobiledevicepairing /
    /// .mobilepair from SideStore, AltStore, etc.) — the same kind
    /// WorkSlop's restore engine uses. If AirFlit reports an auth
    /// Uses the shared pairing file from Home (PairingStore).
    /// No separate AirFlit pairing — one pairing file for the whole app.
    static var pairingFileURL: URL {
        PairingStore.fileURL
    }

    static var hasPairingFile: Bool {
        PairingStore.isImported
    }

    // MARK: - iOS gating

    /// True on iOS 18.0 – 27.2 beta 2. Excludes 27.2 beta 3+ where
    /// Apple patched the AirTraffic vector.
    static func isSupported(major: Int, minor: Int, build: String) -> Bool {
        if major < 18 { return false }
        if major > 27 { return false }
        if major == 27 {
            // 27.2 beta 3+ is patched, and stable 27.2+ carries the
            // patch too. Fail closed: only allow 27.2 when we can
            // positively identify beta 1 or beta 2 from the build
            // string. Stable 27.0–27.1 are fine.
            if minor > 2 { return false }
            if minor == 2 {
                let b = build.lowercased()
                let isBeta1or2 = b.contains("b1") || b.contains("b2")
                    || b.contains("beta1") || b.contains("beta2")
                // A "b1"/"b2" marker could theoretically appear inside
                // "b12" etc.; the b3/beta3 exclusion below guards the
                // known-bad case explicitly.
                if b.contains("b3") || b.contains("beta3") { return false }
                return isBeta1or2
            }
        }
        return true
    }

    // MARK: - Core write

    enum AirFlitError: LocalizedError {
        case ffiUnavailable
        case noPairingFile
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffiUnavailable:
                return "AirliftFFI is not linked. See AIRFLIT-SETUP.md to embed the framework."
            case .noPairingFile:
                return "No AirFlit pairing file. Import a pairing file first."
            case .writeFailed(let msg):
                return "AirFlit write failed: \(msg)"
            }
        }
    }

    /// Writes every file in `sourceDir` into `targetDir` on the device.
    /// Blocks the calling thread — always call off the main thread.
    static func writeDirectory(
        sourceDir: URL,
        targetDir: String,
        log: ((String) -> Void)? = nil
    ) throws {
        #if canImport(AirliftFFI)
        guard hasPairingFile else { throw AirFlitError.noPairingFile }
        let pairingPath = pairingFileURL.path
        // The log closure rides the C `void *ctx`; al_exploit_write_dir
        // BLOCKS, so the box is guaranteed alive for the whole call.
        let box = AirFlitLogBox(log ?? { _ in })
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc: Int32 = pairingPath.withCString { pairC in
            sourceDir.path.withCString { srcC in
                targetDir.withCString { tgtC in
                    al_exploit_write_dir(pairC, srcC, tgtC, airFlitLogCallback, ctx, &outError)
                }
            }
        }
        // Keep the box alive until the C call has returned.
        let writeError: String? = withExtendedLifetime(box) { () -> String? in
            if let p = outError {
                let msg = String(validatingUTF8: p) ?? "unknown error"
                al_string_free(p)
                return rc != 0 ? msg : nil
            }
            return rc != 0 ? "exploit returned \(rc)" : nil
        }
        if let msg = writeError {
            throw AirFlitError.writeFailed(msg)
        }
        #else
        throw AirFlitError.ffiUnavailable
        #endif
    }

    // MARK: - Staging helper

    /// Creates a fresh staging directory, runs `fill`, and returns it.
    /// Caller must delete it when done.
    static func makeStagingDir(prefix: String, fill: (URL) throws -> Void) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try fill(dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }
}
