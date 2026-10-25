import Foundation
import SQLite3

// PORT from GoldenNugget-mobile (Nugget/Core/TweakInjector.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// The row shape the device writes for one backup domain — filled in from the
// device's own rows (MobileSync/Backup ground truth), same rule as MBFileBlob.

/// Protection classes, measured from the device's own backup rows.
enum TweakProtectionClass {
    static let file = 4
    static let dir = 4
    static let systemFile = 4
}

/// The row shape the device writes for one backup domain. Where GoldenNugget
/// stamps every plist tweak with owner=501/group=501, the device disagrees per
/// domain (footnote row is -2/-2, DatabaseDomain is 0/0) — the device wins.
struct TweakRowProfile {
    let fileOwner: Int
    let fileGroup: Int
    let fileProtectionClass: Int
    let fileExceptionPublisher: String?
    let dirOwner: Int
    let dirGroup: Int
    let dirProtectionClass: Int
    let rootOwner: Int
    let rootGroup: Int
    let rootProtectionClass: Int
    /// Whether this domain's file rows carry a Digest (SHA-1 of the payload).
    let carriesDigest: Bool
    let verified: Bool
    let note: String

    static func forDomain(_ domain: String) -> TweakRowProfile {
        if domain.hasPrefix("AppDomain") { return .appContainer }
        if domain.hasPrefix("SysSharedContainerDomain") || domain.hasPrefix("SysContainerDomain") {
            return .systemContainer
        }
        switch domain {
        case "ManagedPreferencesDomain": return .managedPreferences
        case "HomeDomain": return .homeDomain
        case "SystemPreferencesDomain": return .systemPreferences
        case "DatabaseDomain": return .database
        default: return .unmeasured
        }
    }
}

extension TweakRowProfile {
    /// AppDomain-*: delivered by BackupInjector.inject, production evidence.
    static let appContainer = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: TweakProtectionClass.file,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: TweakProtectionClass.dir,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: TweakProtectionClass.dir,
        carriesDigest: false, verified: true,
        note: "AppDomain-* rows, as delivered by BackupInjector.inject")

    /// SysSharedContainerDomain-*: delivered by injectSystemPlist (footnote),
    /// production evidence.
    static let systemContainer = TweakRowProfile(
        fileOwner: -2, fileGroup: -2, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: -2, dirGroup: -2, dirProtectionClass: TweakProtectionClass.systemFile,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: TweakProtectionClass.dir,
        carriesDigest: false, verified: true,
        note: "SysSharedContainerDomain rows, as delivered by injectSystemPlist")

    /// Measured: mobile/*.plist are mode 0o100755, 501/501, class 4, EA
    /// com.apple.BackupAgent2; the mobile dir row is 501/501 class 4, root 0/0.
    static let managedPreferences = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: TweakProtectionClass.systemFile,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: TweakProtectionClass.systemFile,
        carriesDigest: true, verified: false,
        note: "ManagedPreferencesDomain rows")

    /// Measured: Library/Preferences/.GlobalPreferences.plist is 0o100600
    /// 501/501 class 4 (EA com.apple.cfprefsd); ScreenTimeAgent class 4.
    static let homeDomain = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: TweakProtectionClass.dir,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: TweakProtectionClass.dir,
        carriesDigest: true, verified: false,
        note: "HomeDomain rows")

    /// Measured: SystemConfiguration/*.plist are 0o100644, 0/0, class 4, no EA.
    static let systemPreferences = TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: nil,
        dirOwner: 0, dirGroup: 0, dirProtectionClass: TweakProtectionClass.systemFile,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: TweakProtectionClass.systemFile,
        carriesDigest: true, verified: false,
        note: "SystemPreferencesDomain rows")

    /// Measured: com.apple.xpc.launchd/disabled.plist is 0/0 class 4, EA
    /// com.apple.BackupAgent2.
    static let database = TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 0, dirGroup: 0, dirProtectionClass: TweakProtectionClass.systemFile,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: TweakProtectionClass.systemFile,
        carriesDigest: true, verified: false,
        note: "DatabaseDomain rows")

    /// A domain this port has never measured a device row for. The injector
    /// refuses to guess a row shape it has no evidence for.
    static let unmeasured = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: TweakProtectionClass.systemFile,
        fileExceptionPublisher: nil,
        dirOwner: 501, dirGroup: 501, dirProtectionClass: TweakProtectionClass.dir,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: TweakProtectionClass.dir,
        carriesDigest: true, verified: false,
        note: "Unmeasured domain — using the most conservative shape")
}
