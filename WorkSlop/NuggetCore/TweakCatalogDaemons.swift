import Foundation

// PORT from GoldenNugget-mobile (Nugget/Core/TweakCatalogDaemons.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// Source of truth: GoldenNugget's src/tweaks/daemons_tweak.py + src/gui/ios/daemons.py.

/// One switch on the Daemons page: a named group of launchd labels that
/// are disabled together.
struct DaemonGroup: Sendable {
    let name: String
    let title: String
    let labels: [String]
    let section: DaemonSection
    let isRecommended: Bool
    let showsSwitch: Bool
}

/// The two groups of switches on the Daemons page, in the reference's order.
enum DaemonSection: String, CaseIterable, Identifiable, Sendable {
    case disable = "Daemons to Disable"
    case analytics = "Analytics, Data Tracking & Logging"
    var id: String { rawValue }
}

enum DaemonGroups {
    static let all: [DaemonGroup] = [
        DaemonGroup(name: "thermalmonitord", title: "Disable thermalmonitord",
                    labels: ["com.apple.thermalmonitord"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "OTA", title: "Disable OTA",
                    labels: ["com.apple.mobile.softwareupdated", "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd", "com.apple.mobile.NRDUpdated"],
                    section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "UsageTrackingAgent", title: "Disable UsageTrackingAgent",
                    labels: ["com.apple.UsageTrackingAgent"], section: .disable, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "GameCenter", title: "Disable Game Center",
                    labels: ["com.apple.gamed"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "ATWAKEUP", title: "Disable ATWAKEUP",
                    labels: ["com.apple.atc.atwakeup"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "Tips", title: "Disable Tips Services",
                    labels: ["com.apple.tipsd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "VPN", title: "VPN Icon",
                    labels: ["com.apple.racoon"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "ChineseLAN", title: "Disable Chinese WLAN Service",
                    labels: ["com.apple.wapic", "com.apple.wifi.wapic"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "HealthKit", title: "Disable HealthKit",
                    labels: ["com.apple.healthd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "AirPrint", title: "Disable AirPrint",
                    labels: ["com.apple.printd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "AssistiveTouch", title: "Disable Assistive Touch",
                    labels: ["com.apple.assistivetouchd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "iCloud", title: "Disable iCloud",
                    labels: ["com.apple.itunescloudd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "InternetTethering", title: "Disable Internet Tethering (Hotspot)",
                    labels: ["com.apple.MobileInternetSharing"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "PassBook", title: "Disable Passbook",
                    labels: ["com.apple.passd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "Spotlight", title: "Disable Spotlight",
                    labels: ["com.apple.searchd", "com.apple.corespotlightservice", "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater", "com.apple.spotlight.IndexAgent"],
                    section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "NanoTimeKit", title: "Disable NanoTimeKit (Apple Watch Face Sync)",
                    labels: ["com.apple.nanotimekitcompaniond"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "VoiceControl", title: "Disable Voice Control",
                    labels: ["com.apple.assistant_service", "com.apple.assistantd", "com.apple.voiced"],
                    section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "FollowUp", title: "Follow Up",
                    labels: ["com.apple.followupd"], section: .disable, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "Location", title: "Location Services",
                    labels: ["com.apple.locationd"], section: .disable, isRecommended: false, showsSwitch: true),
        DaemonGroup(name: "WifiAnalytics", title: "Disable Wi-Fi Analytics",
                    labels: ["com.apple.wifianalyticsd"], section: .analytics, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "AnalyticsHelper", title: "Disable System Analytics",
                    labels: ["com.apple.analyticsd", "com.apple.analyticsd.admin", "com.apple.analyticsd.events"],
                    section: .analytics, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "CallAnalytics", title: "Disable Call Analytics (RTC Reporting)",
                    labels: ["com.apple.rtcreportingd"], section: .analytics, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "CoreDuet", title: "Disable CoreDuet (Battery/Usage Statistics)",
                    labels: ["com.apple.coreduetd"], section: .analytics, isRecommended: true, showsSwitch: true),
        DaemonGroup(name: "Insight", title: "Disable Insight",
                    labels: ["com.apple.insightd"], section: .analytics, isRecommended: true, showsSwitch: true),
        // Groups upstream ships without a per-group switch — kept in the
        // catalog so the Recommended set turns them on, but the page must
        // not offer a switch for them (showsSwitch: false), as the reference does.
        DaemonGroup(name: "AppleAds", title: "Apple Ads",
                    labels: ["com.apple.adid", "com.apple.adservicesd"], section: .analytics, isRecommended: true, showsSwitch: false),
        DaemonGroup(name: "CrashReports", title: "Crash Reports",
                    labels: ["com.apple.CrashReporterSupportHelper", "com.apple.apsd.crashreporterhelper"], section: .analytics, isRecommended: true, showsSwitch: false),
        DaemonGroup(name: "Diagnostics", title: "Diagnostics",
                    labels: ["com.apple.diagnosticd"], section: .analytics, isRecommended: true, showsSwitch: false),
        DaemonGroup(name: "Feedback", title: "Feedback",
                    labels: ["com.apple.appleseed.feedd"], section: .analytics, isRecommended: true, showsSwitch: false),
        DaemonGroup(name: "SettingsStats", title: "Settings Statistics",
                    labels: ["com.apple.Settings.Statistics"], section: .analytics, isRecommended: true, showsSwitch: false),
        DaemonGroup(name: "Shazam", title: "Shazam",
                    labels: ["com.apple.shazamd"], section: .analytics, isRecommended: true, showsSwitch: false),
    ]

    /// The launchd disabled.plist spec one AdvancedPlistTweak writes —
    /// every group turned on contributes its labels with value true.
    static var launchdSpec: TweakSpec {
        TweakSpec(
            id: "disabledDaemons",
            section: .daemons,
            title: "Daemons to Disable (launchd disabled.plist)",
            location: .disabledDaemons,
            key: "com.apple.xpc.launchd.disabled",
            value: .bool(true),
            kind: .toggle,
            minValue: 0.0, maxValue: 999.0, step: 1.0,
            minVersion: nil, maxVersion: nil,
            iphoneOnly: false, ipadOnly: false,
            disabled: false,
            detail: "Launchd disabled.plist carrier for every daemon group switch.",
            multiValues: nil)
    }

    /// All labels currently enabled by the selection, for the compiler.
    static func enabledLabels(selection: TweakSelection) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for group in all where group.showsSwitch && selection.isOn(groupName: group.name) {
            for label in group.labels { out[label] = true }
        }
        return out
    }
}

extension TweakSelection {
    /// Daemons are keyed by group name, not TweakSpec id.
    mutating func setDaemonOn(_ group: String, _ on: Bool) {
        setOn("daemon:\(group)", on)
    }
    func isOn(groupName group: String) -> Bool {
        isOn(id: "daemon:\(group)")
    }
    func isOn(id: String) -> Bool {
        enabledIDs.contains(id)
    }
}
