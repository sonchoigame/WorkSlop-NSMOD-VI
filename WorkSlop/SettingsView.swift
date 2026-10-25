import SwiftUI

/// Cài đặt: thông tin phiên bản/thiết bị, credit gốc, bảng NSMOD và giấy phép.
struct SettingsView: View {
    private let nsmodTelegramURL = URL(string: "https://t.me/sonchoigame23")!
    private let nsmodTikTokURL = URL(string: "https://www.tiktok.com/@sonchoigame23")!

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                Section {
                    NavigationLink {
                        SetupGuideView()
                    } label: {
                        Label("Hướng dẫn thiết lập: ứng dụng VPN + tệp ghép đôi", systemImage: "book.fill")
                    }
                    Text("Nếu áp dụng thất bại, mục Kết quả sẽ ghi rõ giai đoạn lỗi (sao lưu / khôi phục / bắt tay / đường hầm) cùng lỗi cụ thể — hãy gửi nguyên văn lỗi đó khi cần hỗ trợ, không chỉ nói \"backend mati\".")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Trợ Giúp")
                }

                Section {
                    LabeledContent("Phiên Bản", value: "15.0")
                    LabeledContent("iOS Của Thiết Bị", value: DeviceInfoEx.fullVersion)
                    Text("iOS 26 trở xuống: khôi phục một phần (sparse restore, không xóa dữ liệu). iOS 27: sao lưu đầy đủ → chỉnh sửa → khôi phục toàn bộ dữ liệu — cùng phương pháp với WorkSlop Desktop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Find My phải được tắt trước khi áp dụng và bật lại sau khi hoàn tất — giống quy tắc trên bản desktop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Không thể hủy giữa chừng khi quá trình khôi phục đang chạy. Nếu bị kẹt, hãy tắt đường hầm VPN rồi ép khởi động lại (Tăng âm lượng, Giảm âm lượng, giữ nút Sườn).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Ứng dụng không thể tự khởi động lại iPhone. Sau khi áp dụng, bạn cần tự khởi động lại máy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Thông Tin")
                }

                // Credit/tác giả gốc được giữ nguyên.
                Section {
                    LabeledContent("Nhà Phát Triển", value: "adnan.120hz")
                    Link("TikTok @adnan.120hz", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                    Text("Gói biểu tượng iOS 18: catwithabaloon (v2.0)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Tác Giả Gốc")
                }

                // Một bảng duy nhất của NSMOD: credit Việt hóa + Telegram + TikTok.
                Section {
                    LabeledContent("Việt Hóa Bởi") {
                        Text("@NSMOD")
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                    nsmodSocialRow(
                        iconName: "TelegramIcon",
                        title: "Kênh Telegram",
                        handle: "@sonchoigame23",
                        subtitle: "t.me/sonchoigame23",
                        url: nsmodTelegramURL
                    )

                    nsmodSocialRow(
                        iconName: "TikTokIcon",
                        title: "Kênh TikTok",
                        handle: "@sonchoigame23",
                        subtitle: "tiktok.com/@sonchoigame23",
                        url: nsmodTikTokURL
                    )
                } header: {
                    Text("NSMOD")
                }

                Section {
                    Text("WorkSlop Mobile là phần mềm tự do, được cấp phép theo GNU General Public License v3.0 hoặc mới hơn.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Đọc Toàn Bộ Giấy Phép (GPL-3.0)",
                         destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                } header: {
                    Text("Giấy Phép")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Cài Đặt")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func nsmodSocialRow(
        iconName: String,
        title: String,
        handle: String,
        subtitle: String,
        url: URL
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(handle)
                        .font(.callout)
                        .foregroundStyle(.blue)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
