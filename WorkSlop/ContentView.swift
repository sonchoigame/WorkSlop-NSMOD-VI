import SwiftUI

/// App root: one menu, one gear. Shared state lives here and is
/// passed down through the environment — rows never own storage.
struct ContentView: View {
    let demoScreen: String?
    @StateObject private var selection = SelectionStore()
    @StateObject private var status = StatusStore()
    @StateObject private var updater = UpdateChecker()
    // Single app-wide owner of the staged custom icons: ApplyView needs
    // to count them toward the apply gate (icons alone must be enough
    // to enable Apply), so the stage lives at the root, not inside the
    // tweak list.
    @StateObject private var iconStage = IconStage()

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        MainMenuView(demoScreen: demoScreen)
            .environmentObject(selection)
            .environmentObject(status)
            .environmentObject(iconStage)
            .task {
                await updater.check()
            }
            .alert(item: $updater.available) { update in
                Alert(
                    title: Text("Có bản cập nhật mới"),
                    message: Text("WorkSlop \(update.version) đã phát hành. Bạn đang dùng \(UpdateChecker.currentVersion).\n\n\(update.notes)"),
                    primaryButton: .default(Text("Xem bản phát hành")) {
                        UIApplication.shared.open(update.url)
                    },
                    secondaryButton: .cancel(Text("Để sau"))
                )
            }
    }
}
