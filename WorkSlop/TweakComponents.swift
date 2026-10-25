import SwiftUI
import PhotosUI

// MARK: - Aligned row icon

/// Fixed-width SF Symbol for menu rows. Different symbols have
/// different optical widths, which makes the label text start at
/// ragged x positions ("mencong"). A fixed frame keeps every row's
/// text in one straight column.
struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .frame(width: 30, alignment: .center)
    }
}

// MARK: - Lock banner

/// Shown at the top while the pairing-file + VPN gate is closed.
struct LockBanner: View {
    @EnvironmentObject private var status: StatusStore

    var body: some View {
        if !status.unlocked {
            Text(ActivationGate.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One flat tweak row: toggle, never a slider

struct FeatureToggleRow: View {
    let feature: Feature
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var status: StatusStore
    @State private var showInfo = false

    private var availability: Availability {
        feature.availability(for: DeviceInfo.iosVersion)
    }

    /// Toggle is live only when the iOS supports the tweak AND the
    /// pairing-file + VPN gate is open.
    private var toggleEnabled: Bool {
        availability.isEnabled && status.unlocked
    }

    /// What the tweak writes, where, and through which route — from
    /// the payload spec itself.
    private var explanation: String {
        var lines: [String] = []
        lines.append(feature.subtitle)
        if let spec = PayloadSpecCatalog.all.first(where: { $0.featureID == feature.id }) {
            for w in spec.writes {
                if let key = w.key {
                    lines.append("Ghi \(key) vào \(w.filePath) (\(w.domain.rawValue)).")
                } else if let target = w.fileTarget {
                    lines.append("Mục tiêu: \(target) tại \(w.filePath) (\(w.domain.rawValue)).")
                }
                if let condition = w.condition {
                    lines.append(condition)
                }
            }
            if let note = spec.note {
                lines.append(note)
            }
        }
        lines.append("Phương thức: \(feature.routeSummary). Hỗ trợ: \(feature.window.label).")
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selection.isOn(feature.id) },
                set: { selection.set(feature.id, $0) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .lineLimit(2)
                    Text(feature.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !availability.isEnabled, let chip = availability.chipText {
                        Text(chip)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!toggleEnabled)
            .accessibilityIdentifier("toggle-\(feature.id)")
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("info-\(feature.id)")
        }
        .opacity(availability.isEnabled ? 1 : 0.6)
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                ScrollView {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(feature.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Xong") { showInfo = false }
                }
            }
        }
    }
}

// MARK: - Your icons + gallery

/// The user's own staged icons. Editing is keyed by the entry's
/// stable UUID (never by row index): indices shift when entries are
/// added or deleted, which used to open the wrong entry or a blank
/// sheet. Deletion is an explicit trailing swipe action (swipe
/// right-to-left) so it always works, with or without edit mode.
///
/// The editor is presented with `.sheet(item:)` over a draft copy of
/// the entry captured at tap time. The sheet content is therefore
/// never empty: an empty sheet is auto-dismissed by iOS on
/// presentation, which was the "editor closes by itself" bug (the
/// previous `.sheet(isPresented:)` + conditional `if let` content
/// could evaluate empty on a state-update race).
struct YourIconsSection: View {
    @EnvironmentObject private var stage: IconStage
    @State private var editingDraft: CustomIconEntry?

    var body: some View {
        Section {
            ForEach(stage.entries) { entry in
                HStack(spacing: 12) {
                    if let data = entry.imageData,
                       let img = EntryImageCache.thumbnail(data) {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "app").foregroundStyle(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.appName.isEmpty ? "Ứng dụng chưa đặt tên" : entry.appName)
                        Text(entry.bundleID.isEmpty ? "Chưa đặt Bundle ID" : entry.bundleID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sửa") { editingDraft = entry }
                        .font(.footnote)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        if let i = stage.entries.firstIndex(where: { $0.id == entry.id }) {
                            stage.remove(at: IndexSet(integer: i))
                        }
                    } label: {
                        Label("Xóa", systemImage: "trash")
                    }
                }
            }
            Button("Thêm biểu tượng ứng dụng") {
                let idx = stage.addBlank()
                editingDraft = stage.entries[idx]
            }
            .accessibilityIdentifier("icons-add")
        } header: {
            Text("Biểu tượng của bạn")
        } footer: {
            Text("Chọn một ảnh, điền tên ứng dụng và Bundle ID (ví dụ com.apple.mobilesafari). Các biểu tượng đã chọn sẽ được ghi dưới dạng web clip trên Màn hình chính bằng cùng payload khôi phục như chủ đề biểu tượng của bản desktop.")
        }
        .sheet(item: $editingDraft) { draft in
            IconEditorView(
                draft: draft,
                onSave: { updated in
                    stage.update(updated)
                    editingDraft = nil
                },
                onCancel: { editingDraft = nil }
            )
        }
    }
}

/// The per-icon editor. Works on a private draft captured at
/// presentation time (never a live binding into the array): the
/// form can't be invalidated by list mutations mid-edit, and Done
/// writes the draft back explicitly via `IconStage.update(_:)`.
struct IconEditorView: View {
    @State private var draft: CustomIconEntry
    var onSave: (CustomIconEntry) -> Void
    var onCancel: () -> Void
    @State private var picked: PhotosPickerItem?

    init(draft: CustomIconEntry,
         onSave: @escaping (CustomIconEntry) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ứng dụng") {
                    TextField("Tên ứng dụng", text: $draft.appName)
                    TextField("Bundle ID", text: $draft.bundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Ảnh biểu tượng") {
                    if let data = draft.imageData, let img = EntryImageCache.full(data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Nhập ảnh (JPEG / PNG / RAW)", systemImage: "photo")
                    }
                    Text("Cần có Bundle ID trước khi có thể chọn biểu tượng này. Tên ứng dụng có thể để trống (ẩn nhãn, giống bản desktop).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Biểu tượng")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { onSave(draft) }
                }
            }
            .onChange(of: picked) { item in
                Task {
                    if let raw = try? await item?.loadTransferable(type: Data.self),
                       let image = UIImage(data: raw),
                       let png = image.pngData() {
                        draft.imageData = png
                    }
                }
            }
        }
    }
}

/// One row of the iOS 18 gallery tables (Dark / Light / Tinted).
struct GalleryRow: View {
    let icon: IOS18Icon
    let variant: IconVariant
    @EnvironmentObject private var stage: IconStage

    var body: some View {
        Button {
            guard let data = galleryData() else { return }
            stage.stage(CustomIconEntry(bundleID: icon.bundleID, appName: icon.name, imageData: data))
        } label: {
            HStack(spacing: 12) {
                if let img = galleryImage() {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(icon.name)
                        .foregroundStyle(.primary)
                    Text(icon.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: stage.isStaged(bundleID: icon.bundleID) ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(stage.isStaged(bundleID: icon.bundleID) ? Color.green : Color.accentColor)
            }
        }
        .accessibilityIdentifier("ios18-\(variantLabel)-\(icon.slug)")
    }

    private var variantLabel: String {
        variant.label
    }

    private func galleryData() -> Data? {
        switch variant {
        case .light: return IOS18IconCatalog.imageData(slug: icon.slug, dark: false)
        case .dark: return IOS18IconCatalog.imageData(slug: icon.slug, dark: true)
        case .tinted: return IOS18IconCatalog.tintedImageData(slug: icon.slug)
        default: return IOS18IconCatalog.variantImageData(variant, slug: icon.slug)
        }
    }

    private func galleryImage() -> UIImage? {
        switch variant {
        case .light: return IOS18IconCatalog.image(slug: icon.slug, dark: false)
        case .dark: return IOS18IconCatalog.image(slug: icon.slug, dark: true)
        case .tinted: return IOS18IconCatalog.tintedImage(slug: icon.slug)
        default: return IOS18IconCatalog.variantImage(variant, slug: icon.slug)
        }
    }
}

// MARK: - VPN tunnel explainer

/// What the loopback VPN tunnel is (and is not), and App Store apps
/// that can open one.
struct TunnelInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Đường hầm là gì") {
                    Text("WorkSlop chạy trên chính chiếc iPhone mà nó tinh chỉnh. Để gửi payload, ứng dụng phải giao tiếp với dịch vụ lockdownd của máy và iOS không cho phép ứng dụng mở kết nối đó trực tiếp - lưu lượng phải đi qua đường hầm VPN cục bộ (giao diện utun) vòng trở lại thiết bị.")
                    Text("Đây KHÔNG phải VPN Internet: không có lưu lượng nào rời khỏi iPhone, không có dữ liệu nào đi qua máy chủ và việc duyệt web của bạn không bị ảnh hưởng. Đường hầm chỉ là cầu loopback tới thiết bị này và tệp ghép đôi dùng để xác thực phiên.")
                }
                Section("Ứng dụng có thể mở đường hầm") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LocalDevVPN").font(.body.weight(.semibold))
                        Text("Mở đường hầm loopback mà WorkSlop có thể phát hiện.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("WorkSlop chỉ phát hiện đường hầm; ứng dụng không xem hoặc định tuyến lưu lượng Internet của bạn.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Đường hầm VPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }
}
