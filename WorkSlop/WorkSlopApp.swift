import SwiftUI

@main
struct WorkSlopApp: App {
    @AppStorage("seenIntro") private var seenIntro = false
    @State private var showIntro = false
    @State private var showNSMODWelcome = true

    init() {
        // Bản Việt hóa: ép ngôn ngữ ứng dụng sang Tiếng Việt.
        UserDefaults.standard.set(["vi"], forKey: "AppleLanguages")
    }

    /// iOS line this build supports: iOS 16 through 27. Up to the
    /// latest iOS 26 the tweaks ride the partial restore; on iOS 27
    /// everything rides the full backup -> modify -> restore flow,
    /// like the desktop. Anything outside the line gets the
    /// full-screen notice instead of an app that cannot serve it.
    private var iosSupported: Bool {
        let v = DeviceInfo.iosVersion
        return (16...27).contains(v.major)
    }

    /// `-DemoScreen <name>` deep-links screenshot runs straight to a
    /// menu (home|settings|statusbar|posterboard). Nil on normal launches.
    private var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DemoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var isDemoLaunch: Bool {
        demoScreen != nil || ProcessInfo.processInfo.arguments.contains("-DemoIOS26")
    }

    var body: some Scene {
        WindowGroup {
            if iosSupported {
                ZStack {
                    ContentView(demoScreen: demoScreen)
                        .environment(\.locale, Locale(identifier: "vi"))

                    if showNSMODWelcome && !isDemoLaunch {
                        NSMODWelcomeView(isPresented: $showNSMODWelcome) {
                            if !seenIntro {
                                showIntro = true
                            }
                        }
                        .zIndex(100)
                    }
                }
                .sheet(isPresented: $showIntro) {
                    IntroView()
                }
                .onAppear {
                    // Demo/screenshot runs đi thẳng vào giao diện ứng dụng.
                    if isDemoLaunch {
                        showNSMODWelcome = false
                    }
                }
            } else {
                UnsupportedIOSView()
                    .environment(\.locale, Locale(identifier: "vi"))
            }
        }
    }
}

/// Full-screen block for devices outside the supported iOS line.
/// Honest and final: no app UI behind it, just the facts.
struct UnsupportedIOSView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.octagon")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                Text("Phiên bản iOS không được hỗ trợ")
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Thiết bị này đang chạy iOS \(DeviceInfoEx.fullVersion). WorkSlop 15.0 hỗ trợ iOS 16.0 đến 27.x.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("Ứng dụng sẽ không mở trên phiên bản iOS này. Không có thay đổi nào được thực hiện trên thiết bị của bạn.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding()
        }
    }
}
