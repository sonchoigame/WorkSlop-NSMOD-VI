import SwiftUI

/// Apply: the real thing. Preflight checks, the user's Find My
/// attestation, then the on-device restore engine:
///
/// - iOS 27+: full backup → payload → modify → restore → restart.
/// - iOS 26 and below: partial (sparse) restore, no wipe.
///
/// Nothing here is a preview: progress comes from the engine's
/// RestoreProgress ticks, and success is only reported when the
/// device confirms.
///
/// Cancel is REAL, not UI-only: the Cancel button cancels the Swift
/// Task running the engine AND sets the engine's cancel flag. The
/// transport disconnects the device socket on cancellation, unblocking
/// hung reads — after cancel, no background work survives (this is the
/// fix for runs that kept going after the user asked them to stop).
struct ApplyView: View {
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var iconStage: IconStage

    @State private var findMyOff = false
    @State private var riskAccepted = false
    @State private var backupPassword = ""
    @State private var running = false
    @State private var cancelling = false
    @State private var progress: RestoreProgress?
    @State private var logLines: [String] = []
    @State private var lastLoggedPercent = -1
    @State private var result: ApplyResult?
    @State private var showRestartSheet = false
    /// The live run's task — stored so Cancel can REALLY stop it.
    @State private var applyTask: Task<Void, Never>?

    private enum ApplyResult {
        case succeeded
        case failed(String)
        /// Cancelled before the device was written: nothing changed.
        case cancelled(phaseName: String)
        /// Cancelled while the restore push was in flight: the device
        /// may hold partial changes — re-running Apply completes them.
        case cancelledDuringRestore(phaseName: String)
    }

    /// The iOS 27 full method needs the explicit bootloop-risk acceptance;
    /// the engine fail-closes without it.
    private var needsRiskAcceptance: Bool {
        DeviceInfo.iosVersion.major >= 27
    }

    var body: some View {
        List {
            Section {
                preflightRow("Tinh chỉnh đã chọn", ok: !effectiveStaged.isEmpty,
                             detail: "\(selection.staged.count + (hasStagedIcons ? 1 : 0))")
                preflightRow("Đã nhập tệp ghép đôi", ok: status.pairingImported, detail: nil)
                preflightRow("Đã phát hiện đường hầm VPN", ok: status.vpnDetected, detail: nil)
                Toggle("Find My đã TẮT trên iPhone này", isOn: $findMyOff)
                    .accessibilityIdentifier("findmy-attest")
                if needsRiskAcceptance {
                    Text(G1Support.riskWarningText)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                    Toggle("Tôi chấp nhận toàn bộ rủi ro (iOS 27)", isOn: $riskAccepted)
                        .accessibilityIdentifier("risk-accept")
                }
                SecureField("Mật khẩu bản sao lưu (chỉ khi bản sao lưu được mã hóa)", text: $backupPassword)
                    .accessibilityIdentifier("backup-password")
                    .disabled(running)
            } header: {
                Text("Kiểm tra trước")
            } footer: {
                Text(routeText)
            }

            if running, let progress {
                Section(cancelling ? "Đang hủy…" : "Đang chạy") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Int(progress.fraction * 100))%")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Spacer()
                            Text(cancelling ? "Đang dừng…" : progress.phase.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress.fraction)
                        Text(cancelling
                             ? "Đã yêu cầu hủy — đang đóng các kết nối tới thiết bị…"
                             : progress.message)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }

                Section("Nhật ký") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(logLines.indices, id: \.self) { i in
                                    Text(logLines[i])
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .id(i)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .onChange(of: logLines.count) { _ in
                            if let last = logLines.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let result {
                Section("Kết quả") {
                    switch result {
                    case .succeeded:
                        Label("Đã gửi - hãy tự khởi động lại iPhone", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.green)
                        Text("Thiết bị đã xác nhận quá trình khôi phục. Hãy khởi động lại từ Cài đặt → Cài đặt chung → Tắt máy, sau đó kiểm tra các tinh chỉnh.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Label("Thất bại", systemImage: "xmark.circle")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            SetupGuideView()
                        } label: {
                            Label("Mở hướng dẫn thiết lập", systemImage: "book.fill")
                                .font(.footnote)
                        }
                    case .cancelled(let phaseName):
                        Label("Đã hủy", systemImage: "stop.circle")
                            .foregroundStyle(Color.orange)
                        Text("Đã dừng ở giai đoạn \(phaseName) trước khi có dữ liệu nào được ghi vào thiết bị. Tất cả kết nối đã đóng — không có gì tiếp tục chạy nền.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .cancelledDuringRestore(let phaseName):
                        Label("Đã hủy trong khi khôi phục", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                        Text("Đã dừng ở giai đoạn \(phaseName). Thiết bị có thể đang giữ thay đổi chưa hoàn tất — hãy chạy Áp dụng lại để hoàn thành. Tất cả kết nối đã đóng — không có gì tiếp tục chạy nền.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(running ? "Đang áp dụng…" : "Áp dụng ngay") {
                    startApply()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!canStart || running)
                .accessibilityIdentifier("apply-now")

                if running {
                    Button(cancelling ? "Đang hủy…" : "Hủy", role: .destructive) {
                        cancelApply()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(cancelling)
                    .accessibilityIdentifier("apply-cancel")
                }

                NavigationLink {
                    SetupGuideView()
                } label: {
                    Label("Hướng dẫn thiết lập: ứng dụng VPN + tệp ghép đôi", systemImage: "book.fill")
                }
                .accessibilityIdentifier("setup-guide")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nút Hủy sẽ dừng tiến trình thực sự: tác vụ bị hủy, các kết nối tới thiết bị được đóng và không có công việc nào tiếp tục chạy nền. Nếu hủy trong lúc Khôi phục, hãy chạy Áp dụng lại để hoàn tất thay đổi.")
                    Text("QUAN TRỌNG: nếu nút Hủy không phản hồi hoặc ứng dụng bị treo, bạn PHẢI đóng hoàn toàn WorkSlop (vuốt ứng dụng khỏi đa nhiệm). Nếu vẫn còn lỗi, hãy tự khởi động lại iPhone (Cài đặt → Cài đặt chung → Tắt máy). Điều này cần thiết để giữ thiết bị an toàn.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Áp dụng")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRestartSheet) {
            NavigationStack {
                List {
                    Section {
                        Label("Áp dụng hoàn tất", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                            .font(.headline)
                        Text("Thiết bị đã xác nhận mọi giai đoạn. Bây giờ hãy khởi động lại iPhone để SpringBoard nạp các tệp mới.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("Cách khởi động lại") {
                        Label("Mở Cài đặt → Cài đặt chung → Tắt máy", systemImage: "1.circle")
                        Label("Trượt để tắt nguồn, chờ 10 giây", systemImage: "2.circle")
                        Label("Giữ nút Sườn cho đến khi logo Apple xuất hiện", systemImage: "3.circle")
                        Label("Sau khi khởi động lại, kiểm tra các tinh chỉnh đã hoạt động", systemImage: "4.circle")
                    }
                    Section {
                        Text("Nếu một tinh chỉnh chưa có hiệu lực, hãy chạy Áp dụng lại — bộ máy chỉ gửi lại những gì cần thiết.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Khởi động lại iPhone")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Xong") { showRestartSheet = false }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - State

    /// Custom icons with a bundle ID count as staged: they are
    /// delivered by the same restore payload, so icons alone (no
    /// other tweak toggled) are enough to enable Apply.
    private var hasStagedIcons: Bool {
        iconStage.entries.contains { !$0.bundleID.isEmpty }
    }

    /// The feature IDs actually sent to the engine: the toggled
    /// tweaks plus "custom-icons" when icons are staged. The ID is
    /// injected into the request only (never persisted into
    /// SelectionStore) so the payload builder's custom-icons gate
    /// fires and the engine's nothing-staged guard passes.
    private var effectiveStaged: Set<String> {
        var ids = selection.staged
        if hasStagedIcons { ids.insert("custom-icons") }
        return ids
    }

    private var canStart: Bool {
        status.unlocked && !effectiveStaged.isEmpty && findMyOff
            && (!needsRiskAcceptance || riskAccepted)
    }

    private var routeText: String {
        let major = DeviceInfo.iosVersion.major
        if major >= 27 {
            return "Thiết bị này chạy iOS \(major): sao lưu đầy đủ → payload → chỉnh sửa → khôi phục, sau đó khởi động lại."
        }
        return "Thiết bị này chạy iOS \(major): khôi phục một phần (sparse), không xóa dữ liệu."
    }

    private func preflightRow(_ title: String, ok: Bool, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? Color.green : Color.red)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Run

    private func startApply() {
        guard canStart, !running else { return }
        guard let version = DeviceVersion(DeviceInfoEx.fullVersion) else {
            result = .failed("Không thể đọc phiên bản iOS của thiết bị - ứng dụng sẽ không tự đoán.")
            return
        }
        running = true
        cancelling = false
        result = nil
        progress = nil
        lastLoggedPercent = -1
        logLines = ["[WorkSlop] Apply started — iOS \(DeviceInfoEx.fullVersion) (\(DeviceInfoEx.buildNumber))"]
        let request = RestoreRequest(
            deviceVersion: version,
            stagedFeatureIDs: effectiveStaged,
            findMyDisabledAttested: findMyOff,
            deviceLabel: "device",
            backupPassword: backupPassword.isEmpty ? nil : backupPassword,
            deviceBuild: DeviceInfoEx.buildNumber,
            riskWarningAccepted: riskAccepted
        )
        // The task handle is stored so Cancel can REALLY stop it:
        // applyTask.cancel() trips Task.isCancelled inside every phase
        // and transport loop, and the transport disconnects the device
        // socket on cancellation. Nothing survives in the background.
        applyTask = Task {
            do {
                // The engine's progress closure is @Sendable; marking ours
                // @MainActor makes it Sendable (global-actor-isolated
                // closures are always safe to share) and keeps the @State
                // write on the main thread.
                try await RestoreEngine.shared.start(
                    request: request,
                    onProgress: { @MainActor p in
                        self.progress = p
                        let pct = Int(p.fraction * 100)
                        // Throttle the log: one line per percent point, not
                        // per tick — a full backup emits thousands of ticks
                        // and the log must not grow without bound.
                        if pct != self.lastLoggedPercent {
                            self.lastLoggedPercent = pct
                            self.logLines.append("[\(pct)%] [\(p.phase.displayName)] \(p.message)")
                        }
                    }
                )
                await MainActor.run {
                    self.applyTask = nil
                    self.running = false
                    self.cancelling = false
                    self.logLines.append("[100%] Done — all phases confirmed by the device.")
                    self.result = .succeeded
                    self.showRestartSheet = true
                }
            } catch is CancellationError {
                await MainActor.run { self.finishCancelled() }
            } catch let error as RestoreError {
                await MainActor.run {
                    if case .cancelled = error {
                        self.finishCancelled()
                    } else {
                        self.applyTask = nil
                        self.running = false
                        self.cancelling = false
                        self.result = .failed(error.localizedDescription)
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.applyTask = nil
                    self.running = false
                    self.cancelling = false
                    self.result = .failed(message)
                }
            }
        }
    }

    /// REAL cancel — not UI-only. Cancels the Swift Task (trips
    /// Task.isCancelled in every phase and transport loop, and the
    /// transport disconnects the device socket so hung reads unblock)
    /// and sets the engine's cancel flag as a backstop. The run stops;
    /// nothing keeps going in the background.
    private func cancelApply() {
        guard running, !cancelling else { return }
        cancelling = true
        logLines.append("[WorkSlop] Cancel requested — stopping the run and closing device connections…")
        applyTask?.cancel()
        Task { await RestoreEngine.shared.cancel() }
    }

    /// Honest cancel report: names the phase that was active and whether
    /// the device may have been written, so the user knows exactly what
    /// to do next.
    private func finishCancelled() {
        let phaseName = progress?.phase.displayName ?? "startup"
        let wasRestore = progress?.phase == .restore
        applyTask = nil
        running = false
        cancelling = false
        logLines.append("[WorkSlop] Cancelled during \(phaseName) — all connections closed, no background work remains.")
        result = wasRestore ? .cancelledDuringRestore(phaseName: phaseName) : .cancelled(phaseName: phaseName)
    }
}

// MARK: - Setup guide

/// Step-by-step: tunnel app + pairing file. This is the missing manual
/// that "backend mati" reports kept asking for: most failures are not
/// code bugs but a missing tunnel app or a bad pairing file, and the
/// preflight rows only say WHAT is red, never HOW to fix it.
struct SetupGuideView: View {
    var body: some View {
        List {
            Section("1 — Cài ứng dụng đường hầm") {
                Text("WorkSlop giao tiếp với dịch vụ lockdownd của chính iPhone này qua đường hầm VPN loopback (giao diện utun trỏ tới 127.0.0.1). Ứng dụng iOS không thể tự mở đường hầm đó — cần một ứng dụng đường hầm riêng.")
                Label("Cài LocalDevVPN (ứng dụng đường hầm mà WorkSlop phát hiện)", systemImage: "1.circle")
                Text("Mở LocalDevVPN và bật cấu hình loopback (IP đường hầm 127.0.0.1). Giữ ứng dụng này chạy khi sử dụng WorkSlop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("2 — Xuất tệp ghép đôi") {
                Text("Phiên đường hầm được xác thực bằng tệp ghép đôi. Hãy xuất một tệp trên máy tính:")
                Label("Cách A: chạy \"idevicepair pair\" trên Mac/PC, sau đó chép tệp .plist được tạo sang iPhone này (AirDrop / Tệp).", systemImage: "2.circle")
                Label("Cách B: dùng ứng dụng Jitterbug để ghép đôi và xuất tệp ghép đôi.", systemImage: "2.circle")
                Text("Mẹo: trên iOS 17+, tệp xuất có thể là RemotePairing (identifier/private_key/public_key). WorkSlop chấp nhận nhập tệp này, nhưng việc nâng cấp phiên TLS cho định dạng đó chưa được xác minh hoàn toàn — nếu Áp dụng lỗi ở bước bắt tay, hãy xuất lại tệp ghép đôi lockdown kiểu cũ.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("3 — Nhập tệp tại đây") {
                Label("Menu chính → \"Nhập tệp ghép đôi (.plist)\" rồi chọn tệp.", systemImage: "3.circle")
                Text("Tệp không hợp lệ sẽ bị từ chối ngay khi nhập với lý do cụ thể (không phải plist, rỗng, thiếu khóa) — không có gì được lưu cho đến khi tệp được nhận diện là bản ghi ghép đôi hợp lệ.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("4 — Kiểm tra rồi Áp dụng") {
                Label("Quay lại menu chính và làm mới trạng thái thiết bị: cả \"Tệp ghép đôi\" và \"Đã phát hiện đường hầm VPN\" phải màu xanh.", systemImage: "4.circle")
                Label("Mở Áp dụng: mọi dòng kiểm tra trước phải màu xanh thì nút \"Áp dụng ngay\" mới được bật.", systemImage: "5.circle")
                Text("Nếu tiến trình thất bại, mục Kết quả sẽ ghi giai đoạn lỗi (sao lưu / khôi phục / bắt tay / đường hầm) cùng lỗi từ thiết bị — khi cần hỗ trợ hãy gửi nguyên văn lỗi đó, không chỉ nói \"backend mati\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Hướng dẫn thiết lập")
        .navigationBarTitleDisplayMode(.inline)
    }
}
