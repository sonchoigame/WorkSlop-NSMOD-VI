import SwiftUI

/// First-launch introduction, shown once. Plain text pages — what
/// WorkSlop Mobile supports, and what it needs before anything is
/// applied. No animation, no cards.
struct IntroView: View {
    @AppStorage("seenIntro") private var seenIntro = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage(
                    title: "WorkSlop",
                    lines: [
                        "Các tinh chỉnh chạy trực tiếp trên iPhone này: Liquid Glass, Thanh trạng thái, Daemon, Apple Internal, SpringBoard, Biểu tượng tùy chỉnh và PosterBoard.",
                        "Thiết bị này: \(DeviceStatus.modelOrDash) \u{2022} iOS \(DeviceInfoEx.fullVersion)",
                    ])
                .tag(0)

                introPage(
                    title: "iOS được hỗ trợ",
                    lines: [
                        "Liquid Glass: iOS 26.0 trở lên.",
                        "Các tùy chọn Thanh trạng thái kiểu cũ: iOS 26.x (iOS 27 chỉ giữ lại tên nhà mạng).",
                        "iOS 26 trở xuống: tinh chỉnh dùng Khôi phục một phần (sparse restore, không xóa dữ liệu). iOS 27: Sao lưu đầy đủ \u{2192} chỉnh sửa \u{2192} khôi phục toàn bộ dữ liệu - phương pháp của WorkSlop Desktop.",
                        "Thiết bị dưới iOS 16.0 hoặc trên iOS 27 sẽ nhận thông báo \"Phiên bản iOS không được hỗ trợ\" thay vì mở ứng dụng.",
                    ])
                .tag(1)

                introPage(
                    title: "Trước khi áp dụng",
                    lines: [
                        "Nhập tệp ghép đôi (.plist) trên màn hình chính.",
                        "Quá trình áp dụng chạy qua đường hầm VPN loopback trên chính điện thoại này - dòng VPN ở màn hình chính phải hiển thị ĐÃ PHÁT HIỆN.",
                        "Find My phải TẮT trước khi áp dụng và BẬT lại sau đó - cùng quy tắc như bản desktop.",
                        "Ứng dụng không thể tự khởi động lại iPhone \u{2014} sau khi áp dụng bạn cần tự khởi động lại máy.",
                        "Áp dụng sẽ gửi các tinh chỉnh đã chọn qua bộ máy khôi phục trên thiết bị. Không thể hủy giữa chừng khi quá trình khôi phục đang chạy.",
                    ])
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(page == 2 ? "Bắt đầu" : "Tiếp tục") {
                if page == 2 {
                    seenIntro = true
                    dismiss()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .accessibilityIdentifier("intro-continue")
        }
    }

    private func introPage(title: String, lines: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title.weight(.bold))
                    .padding(.top, 32)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
        }
    }
}
