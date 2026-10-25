import Foundation

/// Delivery route a tweak rides. Everything stages through the
/// partial (sparse) restore on iOS 26; on iOS 27 everything rides
/// a full backup -> modify -> restore with all data, exactly
/// like the desktop. (The desktop's old Beta 1 tweaks were removed by
/// the maintainer and do not exist here.)
enum DeliveryRoute: String {
    case partialRestore = "Khôi phục một phần"
    case fullBackup = "Sao lưu đầy đủ → chỉnh sửa → khôi phục"
    /// The desktop's targeted container backup exists only for the
    /// PosterBoard Configurations (database) mode, which mobile does
    /// not offer; mobile PosterBoard is Descriptors = partial restore.
}

/// iOS version window a feature supports. A feature is locked ONLY when
/// the device's iOS is outside its window — when the iOS supports it, the
/// feature is open, exactly like the desktop app. (The app runs on the
/// device it tweaks, so "the device" is this phone.)
struct IOSWindow {
    let min: (major: Int, minor: Int)
    let maxExclusive: (major: Int, minor: Int)?

    func contains(_ v: (major: Int, minor: Int)) -> Bool {
        // Lexicographic (major, minor) against BOTH bounds. The
        // old major-first shortcut returned true for iOS 27 in a
        // 16.0-<27.0 window - the max was never reached.
        if (v.major, v.minor) < (min.major, min.minor) { return false }
        if let max = maxExclusive,
           (v.major, v.minor) >= (max.major, max.minor) { return false }
        return true
    }

    var label: String {
        if let max = maxExclusive {
            return "iOS \(min.major).\(min.minor)–<\(max.major).\(max.minor)"
        }
        return "iOS \(min.major).\(min.minor)+"
    }
}

enum Availability: Equatable {
    case supported
    case unsupported(reason: String)

    var isEnabled: Bool {
        if case .supported = self { return true }
        return false
    }

    var chipText: String? {
        switch self {
        case .supported: return nil
        case .unsupported(let reason): return reason
        }
    }
}

struct Feature: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let section: String
    let route: DeliveryRoute

    /// True when this feature can be used on iOS 27 at all - in
    /// which case a partial-restore feature must say out loud that
    /// Partial restore itself is iOS 26 only.
    var reachesIOS27: Bool {
        guard let max = window.maxExclusive else { return true }
        return max.major > 27 || (max.major == 27 && max.minor > 0)
    }

    /// Full route sentence for the info sheet. Standing wording:
    /// Partial restore tops out at iOS 26; iOS 27 is the Full
    /// backup route.
    var routeSummary: String {
        if route == .partialRestore && reachesIOS27 {
            return "Khôi phục một phần - tối đa iOS 26. Trên iOS 27 sẽ dùng Sao lưu đầy đủ \u{2192} chỉnh sửa \u{2192} khôi phục."
        }
        if route == .partialRestore {
            return "Khôi phục một phần - tối đa iOS 26."
        }
        return "Sao lưu đầy đủ \u{2192} chỉnh sửa \u{2192} khôi phục - phương pháp WorkSlop Desktop; đây là phương thức cho iOS 27."
    }
    let window: IOSWindow

    func availability(for ios: (major: Int, minor: Int)) -> Availability {
        return window.contains(ios)
            ? .supported
            : .unsupported(reason: "Yêu cầu \(window.label)")
    }
}

/// Full iOS version of THIS device, patch included ("26.6.1").
/// Device facts never change while the app runs, so each is read
/// from the system exactly once per launch instead of on every
/// view render (these were syscalls/reflection per row before).
enum DeviceInfoEx {
    static let fullVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Build number of this device ("23G82") via kern.osversion.
    static let buildNumber: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "-" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        let b = String(cString: buf)
        return b.isEmpty ? "-" : b
    }()

    /// "iOS 26.6.1 (23G82)" for display.
    static var versionWithBuild: String {
        "iOS \(fullVersion) (\(buildNumber))"
    }
}

/// Activation gate (rule set by the user): no tweak can be switched
/// on before BOTH the pairing file is imported AND a VPN tunnel is up
/// on this device — the engine route needs both.
enum ActivationGate {
    /// The probe behind the gate is two syscalls (a getifaddrs walk
    /// plus a file stat). Feature rows used to re-run it on every
    /// render of every row, so a short-lived snapshot is shared
    /// instead: one probe serves a whole render pass and the next
    /// second's. Gate state in this app only ever refreshed when a
    /// view re-rendered anyway, so a 1s snapshot changes nothing
    /// the user can see - it just stops the repeated probing.
    /// (Main-thread UI use only, like the probes themselves.)
    private struct Snapshot {
        let pairing: Bool
        let tunnel: Bool
        let takenAt: Date
    }

    private static var snapshot: Snapshot?

    private static func probe() -> Snapshot {
        if let snap = snapshot, Date().timeIntervalSince(snap.takenAt) < 1 {
            return snap
        }
        let snap = Snapshot(pairing: PairingStore.isImported,
                            tunnel: DeviceStatus.vpnTunnelActive(),
                            takenAt: Date())
        snapshot = snap
        return snap
    }

    static var pairingReady: Bool { probe().pairing }
    static var tunnelReady: Bool { probe().tunnel }
    static var unlocked: Bool { let s = probe(); return s.pairing && s.tunnel }

    static var message: String {
        if !pairingReady && !tunnelReady {
            return "Đã khóa: hãy nhập tệp ghép đôi và khởi động đường hầm VPN trước."
        }
        if !pairingReady {
            return "Đã khóa: hãy nhập tệp ghép đôi (.plist) trong Cài đặt trước."
        }
        return "Đã khóa: hãy khởi động đường hầm VPN (LocalDevVPN loopback) trước."
    }
}

enum DeviceStatus {
    /// Hardware model identifier (e.g. "iPhone15,3") from utsname.
    /// Returns "-" when the identifier cannot be read, so the UI shows
    /// a dash instead of a made-up value.
    static var modelOrDash: String {
        let m = model
        return m.isEmpty ? "-" : m
    }

    static let model: String = {
        var sys = utsname()
        uname(&sys)
        let bytes = Mirror(reflecting: sys.machine).children
            .compactMap { $0.value as? Int8 }
            .filter { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }()

    /// Phase 1 of the two-phase tunnel check (ala GoldenNugget's
    /// Tunnel.isInterfaceUp): true while a utun* interface carries a
    /// tunnel address. Deliberately NO IFF_UP|IFF_RUNNING gate — that
    /// flag check was the "VPN tunnel ga kedeteksi" bug: a tunnel
    /// can be up without both flags set, and the gate rejected it.
    /// Like GoldenNugget, this matches on the address actually
    /// configured, not on flags.
    ///
    /// Loopback (127.0.0.1/::1) on a utun interface COUNTS as a tunnel:
    /// WorkSlop's whole method is a loopback tunnel back into the same
    /// iPhone, and a LocalDevVPN loopback configuration assigns 127.0.0.1
    /// to its utun. lo0 is already excluded by the utun-prefix check, so
    /// 127.0.0.1 here can only mean a deliberate loopback tunnel —
    /// exactly what this app needs. (The old code skipped loopback with
    /// "never a VPN tunnel" — domain-wrong for this app, and the reason
    /// LocalDevVPN loopback tunnels showed "-" while 10.x tunnels worked.)
    /// Link-local (fe80::/10) is still skipped: idle system utun
    /// interfaces carry only auto-assigned link-local, and accepting
    /// those would false-positive on phones with no real tunnel.
    /// Phase 2 — does lockdownd actually answer on the tunnel? — is
    /// LockdownProbe.probe, run by "Refresh device status".
    static func vpnTunnelActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = family == UInt8(AF_INET) ? socklen_t(MemoryLayout<sockaddr_in>.size)
                                              : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            // Link-local (fe80::/10) is never a usable tunnel by itself:
            // idle system utun interfaces carry only auto-assigned
            // link-local, so accepting it would false-positive.
            // Loopback (127.0.0.1/::1) IS accepted here — on a utun
            // interface it means a deliberate loopback tunnel (LocalDevVPN
            // loopback configuration), which is exactly this app's method.
            // lo0 can't reach this point (utun-prefix check above).
            if addr.hasPrefix("fe80") || addr.hasPrefix("FE80") { continue }
            return true
        }
        return false
    }
}

enum DeviceInfo {
    /// This device's iOS version. The UI tests pass -DemoIOS26 so the
    /// recorded tour demonstrates the supported (open) state; real runs
    /// always read the actual system version.
    static var iosVersion: (major: Int, minor: Int) {
        if ProcessInfo.processInfo.arguments.contains("-DemoIOS26") {
            return (26, 6)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion)
    }
}

/// Staged (toggled-on) selections, persisted like the desktop's tweak
/// staging. Staging is selection only: nothing is delivered until the
/// on-device restore engine is verified.
final class SelectionStore: ObservableObject {
    @Published private(set) var staged: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(staged), forKey: "stagedFeatures")
        }
    }

    init() {
        staged = Set(UserDefaults.standard.stringArray(forKey: "stagedFeatures") ?? [])
    }

    func isOn(_ id: String) -> Bool { staged.contains(id) }

    /// Cancel: unstage everything. Nothing is sent anywhere — this is
    /// the pre-apply cancel the Apply menu offers.
    func clear() {
        staged = []
    }

    func set(_ id: String, _ on: Bool) {
        // Build the next set and assign once: one publish and one
        // UserDefaults write per tap, instead of one per mutation
        // (plus the manual objectWillChange sends that used to
        // double every invalidation - @Published already sends).
        var next = staged
        if on {
            next.insert(id)
            // RTL and LTR layout forces exclude each other, as on desktop.
            if id == "in-rtl" { next.remove("in-ltr") }
            if id == "in-ltr" { next.remove("in-rtl") }
        } else {
            next.remove(id)
        }
        if next != staged { staged = next }
    }
}

enum FeatureCatalog {
    /// Solarium exists only on iOS 26; the desktop registry gives the
    /// Liquid Glass set min 26.0 and no max, so the window has none.
    private static let ios26 = IOSWindow(min: (26, 0), maxExclusive: nil)
    /// Desktop overall support line (is_version_supported): 16.0–<27.0.
    private static let ios16to26 = IOSWindow(min: (16, 0), maxExclusive: (27, 0))
    private static let ios26_0 = IOSWindow(min: (26, 0), maxExclusive: nil) // registry min only
    /// Classic binary statusBarOverrides is dead on iOS 27 (desktop-verified:
    /// "the classic binary statusBarOverrides file is dead" — only carrier
    /// text survives via StatusBarOverrides.archive). Gate the classic
    /// overrides to iOS 26.x so iOS 27 shows an honest "unsupported" chip.
    private static let ios26xOnly = IOSWindow(min: (26, 0), maxExclusive: (27, 0))

    /// Draws tweak titles and the keys actually written from the desktop
    /// registry (sections Liquid Glass, SpringBoard, Internal Options)
    /// plus the desktop Status Bar and Custom Icons pages. It is a
    /// subset of the desktop catalog, not a full mirror: rows the
    /// maintainer removed are absent. Subtitles name the plist key (or
    /// file target) each toggle stages. The desktop "Feature Flags"
    /// section still exists on desktop as a placeholder, but its
    /// delivery channel is proven closed on retail iOS 26.6.1, so it is
    /// not offered here.
    static let all: [Feature] = [
        // --- Liquid Glass (regular set, partial restore) ---
        Feature(id: "lg-legibility-2", title: "Giá trị độ rõ kính 2",
                subtitle: "UIViewGlassLegibilitySetting = 2", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disallow-clock", title: "Tắt hiệu ứng kính trên đồng hồ màn hình khóa",
                subtitle: "SBDisallowGlassTime", section: "Liquid Glass",
                route: .partialRestore, window: ios26),
        Feature(id: "lg-disable-dock", title: "Tắt hiệu ứng kính trên Dock",
                subtitle: "SBDisableGlassDock", section: "Liquid Glass",
                route: .partialRestore, window: ios26),
        Feature(id: "lg-flat-icons", title: "Biểu tượng phẳng ở mọi nơi",
                subtitle: "SBUseFlatIconsEverywhere", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-widget-specular", title: "Tắt phản sáng trên Widget",
                subtitle: "SBDisableWidgetSpecular", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-dock-specular", title: "Tắt phản sáng trên Dock",
                subtitle: "SBDisableDockSpecular", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-folder-specular", title: "Tắt phản sáng trên thư mục",
                subtitle: "SBDisableFolderSpecular", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-exclude-clear-shadows", title: "Loại bỏ bóng của kính trong suốt",
                subtitle: "SBExcludeAllClearGlassShadows", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-refraction", title: "Tắt khúc xạ bên ngoài",
                subtitle: "SolariumDisableOuterRefraction", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-hdr", title: "Tắt HDR của Solarium",
                subtitle: "SolariumAllowHDR = false", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-specular-motion", title: "Tắt chuyển động phản sáng",
                subtitle: "SBDisableSpecularEverywhereUsingLSSAssertion", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-disable-specular-everywhere", title: "Tắt phản sáng ở mọi nơi",
                subtitle: "SBDisableSpecularEverywhere", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),
        Feature(id: "lg-blurr-motion", title: "Làm mờ chuyển động",
                subtitle: "SolariumIncreasedDiffusion", section: "Liquid Glass",
                route: .partialRestore, window: ios26xOnly),

        // --- SpringBoard (desktop SpringBoard section) ---
        Feature(id: "sb-watchos-pairing", title: "Cho phép ghép đôi với mọi phiên bản watchOS",
                subtitle: "Cờ ghép đôi NanoRegistry (không có khóa plist)", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-dont-lock-crash", title: "Không khóa máy sau Respring",
                subtitle: "SBDontLockAfterCrash", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-dont-dim-ac", title: "Không làm tối màn hình khi đang sạc",
                subtitle: "SBDontDimOrLockOnAC", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-hide-low-power", title: "Tắt cảnh báo pin yếu",
                subtitle: "SBHideLowPowerAlerts", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-hide-ac-power", title: "Ẩn nguồn AC trên màn hình khóa",
                subtitle: "SBHideACPower", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-never-breadcrumb", title: "Tắt Breadcrumbs",
                subtitle: "SBNeverBreadcrumb", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-supervision-text", title: "Hiện dòng giám sát trên màn hình khóa",
                subtitle: "SBShowSupervisionTextOnLockScreen", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        Feature(id: "sb-icon-parallax", title: "Tắt hiệu ứng Parallax của biểu tượng",
                subtitle: "SBDisableParallax", section: "SpringBoard",
                route: .partialRestore, window: ios16to26),
        // --- Daemons (disabled.plist, partial restore) ---
        Feature(id: "dm-recommended",
                title: "Đề xuất (phân tích, theo dõi & ghi log)",
                subtitle: "Một công tắc trên desktop: bộ vô hiệu hóa phân tích/telemetry an toàn - 23 nhóm daemon, 63 nhãn.",
                section: "Recommended", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-clear-screentime",
                title: "Xóa nội dung tệp ScreenTimeAgent.plist",
                subtitle: "Làm rỗng com.apple.ScreenTimeAgent.plist; ScreenTimeAgent sẽ tạo lại tệp.",
                section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-thermalmonitord", title: "Tắt thermalmonitord", subtitle: "com.apple.thermalmonitord", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-ota", title: "Tắt OTA", subtitle: "com.apple.mobile.softwareupdated + 3 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-usagetrackingagent", title: "Tắt UsageTrackingAgent", subtitle: "com.apple.UsageTrackingAgent", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-gamecenter", title: "Tắt Game Center", subtitle: "com.apple.gamed", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-atwakeup", title: "Tắt ATWAKEUP", subtitle: "com.apple.atc.atwakeup", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-tips", title: "Tắt dịch vụ Tips", subtitle: "com.apple.tipsd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-vpn", title: "Biểu tượng VPN", subtitle: "com.apple.racoon", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-chineselan", title: "Tắt dịch vụ WLAN Trung Quốc", subtitle: "com.apple.wapic + 1 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-healthkit", title: "Tắt HealthKit", subtitle: "com.apple.healthd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-airprint", title: "Tắt AirPrint", subtitle: "com.apple.printd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-assistivetouch", title: "Tắt AssistiveTouch", subtitle: "com.apple.assistivetouchd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-icloud", title: "Tắt iCloud", subtitle: "com.apple.itunescloudd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-passbook", title: "Tắt Passbook", subtitle: "com.apple.passd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-spotlight", title: "Tắt Spotlight", subtitle: "com.apple.searchd + 4 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-nanotimekit", title: "Tắt NanoTimeKit (đồng bộ mặt Apple Watch)", subtitle: "com.apple.nanotimekitcompaniond", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-voicecontrol", title: "Tắt Điều khiển bằng giọng nói", subtitle: "com.apple.assistant_service + 2 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-followup", title: "Follow Up", subtitle: "com.apple.followupd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-wifianalytics", title: "Tắt phân tích Wi‑Fi", subtitle: "com.apple.wifianalyticsd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-analyticshelper", title: "Tắt phân tích hệ thống", subtitle: "com.apple.analyticsd + 2 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-callanalytics", title: "Tắt phân tích cuộc gọi (RTC Reporting)", subtitle: "com.apple.rtcreportingd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-coreduet", title: "Tắt CoreDuet (thống kê pin/sử dụng)", subtitle: "com.apple.coreduetd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-insight", title: "Tắt Insight", subtitle: "com.apple.insightd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-metrics", title: "Tắt Metrics", subtitle: "com.apple.metricsd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-mediaexperience", title: "Tắt phân tích trải nghiệm media", subtitle: "com.apple.mediaremoted", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-symptomsd", title: "Tắt chẩn đoán Symptom", subtitle: "com.apple.symptomsd + 1 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-statisticaldiagnostic", title: "Tắt chẩn đoán thống kê", subtitle: "com.apple.StatisticalDiagnosticService", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-wirelessdiagnostics", title: "Tắt chẩn đoán không dây", subtitle: "com.apple.wirelessdiagnostics", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-duetheuristic", title: "Tắt Duet Heuristic", subtitle: "com.apple.DuetHeuristic-BM + 1 more", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-duetexpert", title: "Tắt Duet Expert", subtitle: "com.apple.duetexpertd", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-decisiond", title: "Tắt Decisiond", subtitle: "com.apple.decisiond", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-triald", title: "Tắt Triald (telemetry thử nghiệm A/B)", subtitle: "com.apple.triald", section: "Daemons", route: .partialRestore, window: ios16to26),
        Feature(id: "dm-sociald", title: "Tắt Sociald", subtitle: "com.apple.sociald", section: "Daemons", route: .partialRestore, window: ios16to26),

        // --- Internal Options (desktop Internal section) ---
        Feature(id: "in-build-version", title: "Hiện phiên bản build trên thanh trạng thái",
                subtitle: "UIStatusBarShowBuildVersion", section: "Internal Options",
                route: .partialRestore, window: ios16to26),
        Feature(id: "in-rtl", title: "Buộc bố cục từ phải sang trái",
                subtitle: "NSForceRightToLeftWritingDirection", section: "Internal Options",
                route: .partialRestore, window: ios16to26),
        Feature(id: "in-ltr", title: "Buộc bố cục từ trái sang phải",
                subtitle: "NSForceLeftToRightWritingDirection", section: "Internal Options",
                route: .partialRestore, window: ios16to26),
        Feature(id: "in-disable-thermal", title: "Tắt Thermal",
                subtitle: "com.apple.thermalmonitord (disabled.plist)", section: "Internal Options",
                route: .partialRestore, window: ios16to26),
        Feature(id: "in-hidden-icons", title: "Hiện biểu tượng ẩn trên Màn hình chính",
                subtitle: "SBIconVisibility", section: "Internal Options",
                route: .partialRestore, window: ios16to26),

        // --- PosterBoard (desktop PosterBoard page) ---
        Feature(id: "pb-tendies", title: "Hình nền Tendies (.tendies)", subtitle: "AppDomain-com.apple.PosterBoard / PRBPosterExtensionDataStore (max 5 files per restore, 10 descriptors)", section: "PosterBoard", route: .partialRestore, window: ios16to26),
        Feature(id: "pb-reset", title: "Đặt lại PosterBoard", subtitle: "Xóa các descriptor đã gửi; PosterBoard sẽ tự tạo lại", section: "PosterBoard", route: .partialRestore, window: ios16to26),

        // --- Custom Icons (desktop Custom Icons page) ---
        Feature(
            id: "custom-icons",
            title: "Biểu tượng tùy chỉnh",
            subtitle: "Chủ đề biểu tượng & biểu tượng ứng dụng tùy chỉnh",
            section: "Custom Icons",
            route: .partialRestore,
            window: ios16to26),
    ]

    /// Features grouped once at first use (order within each
    /// section preserved); page bodies ask for their section on
    /// every render, and re-filtering the whole catalog each time
    /// was pure waste.
    private static let bySection: [String: [Feature]] =
        Dictionary(grouping: all, by: \.section)

    static func features(in section: String) -> [Feature] {
        bySection[section] ?? []
    }
}
