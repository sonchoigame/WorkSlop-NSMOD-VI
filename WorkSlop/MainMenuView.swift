import SwiftUI

/// Home: the WorkSlop hero, device gates, the Apply button, and the
/// two menus (All Tweaks, Settings). SkyBackground behind everything.
///
/// Screenshot runs deep-link with `-DemoScreen <name>`:
/// home | alltweaks | settings | apply.
enum HomeRoute: Hashable {
    case allTweaks
    case settings
    case apply
}

struct MainMenuView: View {
    let demoScreen: String?
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var iconStage: IconStage
    @State private var path: [HomeRoute] = []
    @State private var importing = false
    @State private var pairingNote: String?
    @State private var showTunnelInfo = false
    @State private var showAbout = false

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        hero
                        deviceCard
                        applyButton
                        menusCard
                        LockBanner()
                    }
                    .padding()
                }
                .onChange(of: pairingNote) { new in
                    // Transient notes only: clear after 6s so a stale
                    // message never sits on screen.
                    guard let current = new else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if pairingNote == current {
                            pairingNote = nil
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allTweaks: AllTweaksView()
                case .settings: SettingsView()
                case .apply: ApplyView()
                }
            }
        }
        .onAppear {
            guard path.isEmpty, let s = demoScreen else { return }
            switch s {
            case "alltweaks": path = [.allTweaks]
            case "settings": path = [.settings]
            case "apply": path = [.apply]
            default: break
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item]
        ) { result in
            switch result {
            case .success(let url): flashNote(importPairing(from: url) ?? "Đã lưu tệp ghép đôi.")
            case .failure: flashNote("Đã hủy nhập.")
            }
        }
        .sheet(isPresented: $showTunnelInfo) { TunnelInfoView() }
        .sheet(isPresented: $showAbout) { AboutInfoView() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            Image("BrandBlue")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            HStack(spacing: 6) {
                Text("WorkSlop")
                    .font(.title.weight(.bold))
                Button {
                    showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-info")
            }
            Text("\(DeviceStatus.modelOrDash) • \(DeviceInfoEx.versionWithBuild)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Device gates

    /// One status card: pairing file and VPN tunnel share a card with a
    /// divider between them. Secondary actions are plain text links
    /// (never gray pills) so the Apply button keeps its visual hierarchy.
    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label {
                    Text("Tệp ghép đôi")
                } icon: {
                    RowIcon(name: "key.fill")
                }
                Spacer()
                Text(status.pairingImported ? "Đã nhập" : "Chưa nhập")
                    .foregroundStyle(status.pairingImported ? Color.green : .secondary)
                    .fontWeight(status.pairingImported ? .semibold : .regular)
            }
            .padding(.vertical, 12)

            HStack {
                Button(status.pairingImported ? "Nhập lại tệp ghép đôi" : "Nhập tệp ghép đôi (.plist)") {
                    importing = true
                }
                .accessibilityIdentifier("import-pairing")
                Spacer()
                if status.pairingImported {
                    Button("Xóa", role: .destructive) {
                        do {
                            try FileManager.default.removeItem(at: PairingStore.fileURL)
                            status.pairingChanged()
                            flashNote("Đã xóa tệp ghép đôi khỏi ứng dụng.")
                        } catch {
                            flashNote("Không thể xóa tệp ghép đôi: \(error.localizedDescription)")
                        }
                    }
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            if let pairingNote {
                Text(pairingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Label {
                    Text("Đường hầm VPN")
                } icon: {
                    RowIcon(name: "network")
                }
                Spacer()
                Text(status.vpnDetected ? "ĐÃ PHÁT HIỆN" : "-")
                    .foregroundStyle(status.vpnDetected ? Color.green : .secondary)
                    .fontWeight(status.vpnDetected ? .semibold : .regular)
            }
            .padding(.vertical, 12)
            .accessibilityIdentifier("status-vpn")

            HStack {
                Button {
                    showTunnelInfo = true
                } label: {
                    Label("Đường hầm VPN là gì?", systemImage: "info.circle")
                }
                Spacer()
                Button("Làm mới") { status.refresh() }
                    .disabled(status.probing)
                    .accessibilityIdentifier("refresh-status")
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    /// Shows a transient note under the pairing row, then clears it so a
    /// stale message never lingers on screen (the "deleted" note in the
    /// screenshot was from an old action).
    private func flashNote(_ note: String) {
        pairingNote = note
    }

    // MARK: - Apply

    private var applyButton: some View {
        Button {
            path.append(.apply)
        } label: {
            Text(applyLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canApply)
        .accessibilityIdentifier("apply-button")
    }

    private var canApply: Bool {
        status.unlocked && (!selection.staged.isEmpty || hasStagedIcons)
    }

    /// True when at least one custom icon has a bundle ID (matches
    /// ApplyView's gate so the Home button and the Apply screen agree).
    private var hasStagedIcons: Bool {
        iconStage.entries.contains { !$0.bundleID.isEmpty }
    }

    private var applyLabel: String {
        let total = selection.staged.count + (hasStagedIcons ? 1 : 0)
        if total == 0 { return "Áp dụng (hãy chọn tinh chỉnh trước)" }
        if !status.pairingImported { return "Áp dụng (hãy nhập tệp ghép đôi trước)" }
        if !status.vpnDetected { return "Áp dụng (chưa phát hiện đường hầm VPN)" }
        return "Áp dụng (\(total) tinh chỉnh)"
    }

    // MARK: - Menus

    /// Native-style navigation rows: representative SF Symbols, a
    /// disclosure chevron, clean dividers. Plain Buttons pushing onto
    /// the NavigationStack path (not NavigationLink) so the whole row
    /// is always tappable - contentShape makes even the empty Spacer
    /// area hit-testable.
    private var menusCard: some View {
        VStack(spacing: 0) {
            Button {
                path.append(.allTweaks)
            } label: {
                HStack {
                    Label {
                        Text("Tất Cả Tinh Chỉnh")
                    } icon: {
                        RowIcon(name: "sparkles")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-all-tweaks")
            Divider()
                .padding(.leading, 46)
            Button {
                path.append(.settings)
            } label: {
                HStack {
                    Label {
                        Text("Cài Đặt")
                    } icon: {
                        RowIcon(name: "gear")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-settings")
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    /// Blue-tinted reflective glass card: ultra-thin material keeps the
    /// blur over the animated sky, a translucent blue wash pulls it into
    /// the WorkSlop blue UI family, and a white top sheen gives the
    /// glass reflection. Kept light (never opaque) so text stays
    /// readable. (All ShapeStyles are iOS 15/16-safe.)
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.32),
                                .blue.opacity(0.08),
                                .blue.opacity(0.22),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: .blue.opacity(0.14), radius: 8, y: 3)
    }

    // MARK: - Pairing import

    private func importPairing(from url: URL) -> String? {
        // Accept any Files/iCloud item here. The actual security check is the
        // pairing-record structure below, not the filename extension or UTType.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinatedError: NSError?
        var importedData: Data?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatedError) { readableURL in
            importedData = try? Data(contentsOf: readableURL, options: [.mappedIfSafe])
        }

        guard let data = importedData else {
            if let coordinatedError {
                return "Không thể đọc tệp pairing: \(coordinatedError.localizedDescription)"
            }
            return "Không thể đọc tệp pairing. Hãy lưu tệp vào Tệp hoặc Trên iPhone rồi thử lại."
        }

        guard let format = PairingStore.format(of: data) else {
            return PairingStore.diagnose(data) + " Không có dữ liệu nào được lưu."
        }

        do {
            try PairingStore.save(data)
            status.pairingChanged()
            switch format {
            case .legacy:
                return "Đã nhập pairing file (định dạng lockdown)."
            case .remotePairing:
                return "Đã nhập pairing file (RemotePairing iOS 17+)."
            }
        } catch {
            return "Không thể lưu pairing file: \(error.localizedDescription)"
        }
    }
}

// MARK: - About / risks / how-to

/// What the (i) button next to the WorkSlop title opens: the honest
/// risks, the steps to use the app, and how the iOS 26 and iOS 27
/// methods differ. English only - translations live in
/// Localizable.xcstrings and are handled separately.
struct AboutInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Việc áp dụng tinh chỉnh trên iOS 27 vẫn mang tính thử nghiệm và có rủi ro. iOS 27 có thể khiến iPhone bị BOOTLOOP (kẹt ở logo Apple và không khởi động được).")
                    Text("Ứng dụng sẽ sao lưu đầy đủ TOÀN BỘ dữ liệu trước khi ghi bất cứ thứ gì, nhưng bản sao lưu không thể khắc phục mọi dạng hư hỏng. Chủ sở hữu phần mềm này (adnan.120hz) KHÔNG chịu trách nhiệm cho hư hỏng, bootloop hoặc mất dữ liệu.")
                    Text("Bản sao lưu thiết bị KHÔNG được mã hóa; nếu có mã hóa, quá trình áp dụng sẽ bị từ chối trước khi ghi bất cứ thứ gì.")
                    Text("Find My phải TẮT trước khi áp dụng và BẬT lại sau đó. Không thể hủy giữa chừng khi quá trình khôi phục đang chạy - không được buộc đóng ứng dụng lúc đang thực hiện.")
                } header: {
                    Text("Rủi Ro")
                }

                Section {
                    Text("1. Nhập tệp ghép đôi (.plist) trên màn hình này. Trên iOS 26, tệp được tạo từ máy tính (iDevice Pair / Apple Configurator); không có tệp này thì không thể gửi dữ liệu.")
                    Text("2. Khởi động đường hầm VPN loopback bằng LocalDevVPN cho đến khi dòng VPN phía trên hiển thị ĐÃ PHÁT HIỆN. Đây không phải VPN Internet - không có lưu lượng nào rời khỏi iPhone.")
                    Text("3. Mở Tất cả tinh chỉnh, chọn một danh mục và bật các tinh chỉnh bạn muốn áp dụng.")
                    Text("4. Quay lại màn hình chính và bấm Áp dụng. Xác nhận Find My đã TẮT rồi theo dõi tiến trình. Khi hoàn tất, tự khởi động lại iPhone và kiểm tra các tinh chỉnh.")
                } header: {
                    Text("Cách sử dụng")
                }

                Section {
                    Text("iOS 16 - 26: khôi phục một phần (sparse). Chỉ các tệp đã chọn được gửi đi - không sao lưu toàn bộ, không xóa dữ liệu và ứng dụng không tự khởi động lại máy.")
                    Text("iOS 27: sao lưu đầy đủ → payload → chỉnh sửa → khôi phục toàn bộ dữ liệu (phương pháp WorkSlop Desktop). Điện thoại sẽ được khởi động lại trong quá trình này; nếu máy không lên, hãy ép khởi động lại (Tăng âm lượng, Giảm âm lượng, giữ nút Sườn).")
                } header: {
                    Text("iOS 26 so với iOS 27")
                }
            }
            .navigationTitle("Giới thiệu WorkSlop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }
}
