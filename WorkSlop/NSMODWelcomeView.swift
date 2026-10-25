import SwiftUI

/// Bảng NSMOD hiện một lần cho mỗi lần process ứng dụng khởi động.
/// Lần đầu chưa từng bấm Telegram sẽ không có nút Đóng.
struct NSMODWelcomeView: View {
    @Binding var isPresented: Bool
    @AppStorage("NSMOD_TELEGRAM_JOINED") private var telegramJoined = false

    let onDismiss: () -> Void

    private let telegramURL = URL(string: "https://t.me/sonchoigame23")!
    private let tiktokURL = URL(string: "https://www.tiktok.com/@sonchoigame23")!

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NSMOD")
                            .font(.title2.weight(.heavy))
                        Text("Việt Hóa Bởi @NSMOD")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if telegramJoined {
                        Button("Đóng") {
                            closePanel()
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                Text("Theo dõi kênh để nhận thông tin và các bản cập nhật mới nhất.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                socialButton(
                    iconName: "TelegramIcon",
                    title: "Kênh Telegram",
                    handle: "@sonchoigame23",
                    action: openTelegram
                )

                socialButton(
                    iconName: "TikTokIcon",
                    title: "Kênh TikTok",
                    handle: "@sonchoigame23",
                    action: openTikTok
                )

                if !telegramJoined {
                    Text("Lần đầu, hãy vào kênh Telegram để tiếp tục.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(20)
            .frame(maxWidth: 390)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
            .padding(.horizontal, 20)
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                appeared = true
            }
        }
    }

    private func socialButton(
        iconName: String,
        title: String,
        handle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(handle)
                        .font(.callout)
                        .foregroundStyle(.blue)
                }

                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openTelegram() {
        telegramJoined = true
        UIApplication.shared.open(telegramURL)
        closePanel()
    }

    private func openTikTok() {
        UIApplication.shared.open(tiktokURL)
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.18)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            isPresented = false
            onDismiss()
        }
    }
}
