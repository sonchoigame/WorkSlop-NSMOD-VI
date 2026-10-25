import Foundation

// MARK: - Phase identity
//
// The iOS 27 method, exactly as ordered: BACKUP ALL DATA FULL → PAYLOAD FILE
// (dozens of locations, per active tweaks) → MODIF → RESTORE FULL → RESTART
// (with restart notification). One phase = one unit; each phase owns a
// structured result type, honest progress, and honest errors.

enum RestorePhaseID: String, CaseIterable, Sendable {
    case backup
    case payload
    case modify
    case restore
    case restart

    var displayName: String {
        switch self {
        case .backup:  return "Sao lưu (đầy đủ)"
        case .payload: return "Payload"
        case .modify:  return "Chỉnh sửa"
        case .restore: return "Khôi phục (đầy đủ)"
        case .restart: return "Khởi động lại"
        }
    }

    /// Overall-progress weight range for this phase (0...1). Reported
    /// honestly: a phase only advances its own slice.
    var weight: (lo: Double, hi: Double) {
        switch self {
        case .backup:  return (0.00, 0.30)
        case .payload: return (0.30, 0.45)
        case .modify:  return (0.45, 0.60)
        case .restore: return (0.60, 0.95)
        case .restart: return (0.95, 1.00)
        }
    }
}

// MARK: - Device version (never guessed)

/// Parsed from the live lockdown value at run time. An unknown/empty
/// version refuses the run — guessing once bricked a 27.0 device down
/// the iOS 26 branch (MBErrorDomain/205, no keybag in manifest).
struct DeviceVersion: Sendable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, let major = parts.first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    var isIOS27OrLater: Bool { major >= 27 }

    var description: String { "\(major).\(minor).\(patch)" }
}

// MARK: - iOS 27 route support (strict allowlist, desktop parity)

/// Strict eligibility for the iOS 27 full method, mirroring desktop's
/// is_ios27_g1_supported: ProductVersion 27.0 (covers Developer Beta 1–9,
/// RC and stable — all report "27.0") or 27.0.1, or a verified build
/// number. `major >= 27` alone wrongly admitted 27.2+/28.x, which the
/// desktop deliberately refuses.
enum G1Support {
    static let supportedBuilds: Set<String> = [
        "24A5355q", "24A5370h", "24A5380h", "24A5390f",
        "24A5408d", "24A5418b", "24A5424a", "24A5430a",
        "24A435", "24A437",
    ]

    static func isSupported(version: DeviceVersion, build: String?) -> Bool {
        if version.major == 27 && version.minor == 0 && version.patch <= 1 {
            return true
        }
        if let build, !build.isEmpty, supportedBuilds.contains(build) {
            return true
        }
        return false
    }

    /// Pre-apply warning (desktop: IOS27_WARNING_TEXT). The UI must show
    /// this and record riskWarningAccepted before the run starts; the
    /// engine fail-closes without the acceptance.
    static let riskWarningTitle = "iOS 27 — Cảnh báo rủi ro"

    static let riskWarningText = """
        CẢNH BÁO: việc áp dụng tinh chỉnh trên iOS 27 vẫn mang tính thử nghiệm và có rủi ro.

        iOS 27 có thể khiến iPhone bị BOOTLOOP (kẹt ở logo Apple và không khởi động). \
        Ứng dụng sẽ sao lưu đầy đủ TOÀN BỘ dữ liệu trước khi ghi bất cứ thứ gì, nhưng \
        bản sao lưu không thể khắc phục mọi dạng hư hỏng.

        Chủ sở hữu phần mềm này (Adnan.120hz) KHÔNG chịu trách nhiệm cho hư hỏng, \
        bootloop hoặc mất dữ liệu do sử dụng trên iOS 27.

        Bản sao lưu thiết bị KHÔNG được mã hóa (bỏ chọn 'Encrypt local backup'), \
        nếu không quá trình áp dụng sẽ bị từ chối trước khi ghi bất cứ thứ gì.

        Chỉ tiếp tục nếu bạn đã có bản sao lưu và chấp nhận toàn bộ rủi ro.
        """

    static let notSupportedMessage =
        "Not supported: this device runs an iOS version outside the supported " +
        "list (iOS 27.0 Developer Beta 1–9, 27.0 RC, 27.0 official, 27.0.1). " +
        "Nothing was applied."
}

// MARK: - Prerequisites

enum PrerequisiteStatus: Sendable {
    case passed
    case failed(reason: String)
    /// The sandbox cannot verify this; the user attests it. Recorded, not faked.
    case attestedUnverifiable(note: String)
}

struct PrerequisiteCheck: Sendable {
    let name: String
    let status: PrerequisiteStatus

    var isOK: Bool {
        switch status {
        case .passed, .attestedUnverifiable: return true
        case .failed: return false
        }
    }
}

// MARK: - Progress

/// Phase-local progress. The engine maps `fraction` through the phase's
/// weight range for the overall bar; phases never claim another phase's
/// slice.
struct RestoreProgress: Sendable {
    let phase: RestorePhaseID
    /// 0...1 within the phase.
    let fraction: Double
    let message: String
}

// MARK: - Errors (all honest, all typed)

enum RestoreError: Error, LocalizedError, Sendable {
    /// A second run was attempted while one is in flight. FFI-class calls
    /// cannot be interrupted; stacking runs is how use-after-free happens.
    case alreadyInFlight
    case cancelled
    /// Version string empty/unparseable — the run is refused, never guessed.
    case versionUnknown
    /// The run was started with zero staged tweaks — meaningless, refused.
    case nothingStaged
    /// The device failed the strict iOS 27 allowlist (not just major>=27).
    case osVersionNotSupported(version: String, build: String?)
    /// The partial (sparse) engine covers iOS 16–26; iOS 27+ takes the
    /// full engine.
    case versionOutsidePartialRange(major: Int)
    case prerequisitesFailed([PrerequisiteCheck])
    /// Stall-based watchdog: no progress for 10 minutes. No hard deadline —
    /// a healthy backup/restore is never cut off for being slow.
    case stalled(phase: RestorePhaseID)
    /// Inner device-I/O watchdog (desktop: run_with_stall_watchdog, 300s):
    /// the device went quiet mid-transfer. Distinct from .stalled, which
    /// is the 10-minute route-level backstop.
    case ioStalled(phase: RestorePhaseID, operation: String, seconds: Int)
    case diskSpaceInsufficient(neededBytes: Int64, availableBytes: Int64)
    /// Something the app genuinely cannot do yet. Thrown loudly with the
    /// missing piece named — never silently faked as success.
    case unimplemented(what: String, needed: String)
    case modifyFailed(reason: String)
    case phaseFailed(phase: RestorePhaseID, message: String)

    var errorDescription: String? {
        switch self {
        case .alreadyInFlight:
            return "A restore run is already in flight. Wait for it to finish or cancel it first — runs are never stacked."
        case .cancelled:
            return "Restore cancelled by the user."
        case .versionUnknown:
            return "Device version is unknown. The run is refused rather than guessing (a guessed version once sent a 27.0 device down the wrong branch)."
        case .nothingStaged:
            return "No tweaks staged. Stage at least one tweak before running the restore method."
        case .osVersionNotSupported(let version, let build):
            let b = (build?.isEmpty == false) ? " (build \(build!))" : ""
            return "Not supported: device reports iOS \(version)\(b) — outside the supported " +
                "list (iOS 27.0 Developer Beta 1–9, 27.0 RC, 27.0 official, 27.0.1). Nothing was applied."
        case .versionOutsidePartialRange(let major):
            return "Partial (sparse) restore covers iOS 16–26; device reports iOS \(major), which takes the iOS 27 full engine."
        case .prerequisitesFailed(let checks):
            let bad = checks.filter { !$0.isOK }.map { $0.name }.joined(separator: ", ")
            return "Prerequisites failed: \(bad)."
        case .stalled(let phase):
            return "Stalled in \(phase.displayName): no progress for 10 minutes. Aborting rather than hanging forever."
        case .ioStalled(let phase, let operation, let seconds):
            return "Device stopped reporting \(operation) progress for \(seconds)s in \(phase.displayName) — " +
                "the transfer is wedged. Aborted so it cannot hang forever; the device was not left half-written by us."
        case .diskSpaceInsufficient(let needed, let available):
            return "Not enough free space for a full backup: need \(needed) bytes, have \(available)."
        case .unimplemented(let what, let needed):
            return "Not implemented: \(what). Needed: \(needed)."
        case .modifyFailed(let reason):
            return "Modify phase failed: \(reason)."
        case .phaseFailed(let phase, let message):
            return "\(phase.displayName) phase failed: \(message)."
        }
    }
}
