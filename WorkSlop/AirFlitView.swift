import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

extension UTType {
    /// AirCard passcode theme file (ZIP with per-digit PNGs).
    /// Declared in project.yml UTExportedTypeDeclarations.
    static var passthm: UTType {
        UTType("com.adnan120hz.workslop.passthm") ?? .zip
    }
}

/// AirFlit: custom passcode themes + Apple Wallet card images,
/// using 100% the AirCard method (AirTraffic via AirliftFFI).
/// NOT sparse restore — this menu rides its own delivery channel.
///
/// - Passcode: writes keypad PNGs to /var/mobile/Library/Caches/TelephonyUI-10.
///   Lock the iPhone to see the new keypad (it reloads every lock screen).
/// - Wallet: writes card artwork into the .pkpass folder and corrupts the
///   FrontFace/Preview caches. Force-close the Wallet app to see changes.
///
/// iOS window: 18.0 – 27.2 beta 2 (27.2 beta 3+ patched the vector).
struct AirFlitView: View {
    @StateObject private var vm = AirFlitViewModel()
    @State private var walletItem: PhotosPickerItem?
    @State private var showPassthmImporter = false

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if !vm.iosOK {
                    Section {
                        Label("AirFlit yêu cầu iOS 18.0 – 27.2 beta 2. Thiết bị này đang chạy \(DeviceInfoEx.versionWithBuild).",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if !vm.hasPairingFile {
                    Section {
                        Label("Hãy nhập tệp ghép đôi từ màn hình chính trước.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    // .passthm file import (AirCard's native theme format)
                    Button {
                        showPassthmImporter = true
                    } label: {
                        Label(vm.passthmURL == nil ? "Nhập giao diện .passthm…" : "Đổi giao diện .passthm…",
                              systemImage: "doc.zipper")
                    }
                    if vm.passthmURL != nil {
                        Text("Đã nạp .passthm với \(vm.passthmFileCount) ảnh phím.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button {
                        vm.applyPasscodeTheme()
                    } label: {
                        Label("Áp dụng giao diện mật mã", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.passthmURL == nil || vm.running || !vm.iosOK || !vm.hasPairingFile)
                    Text("Ghi vào bộ nhớ đệm bàn phím TelephonyUI. Khóa iPhone để xem bàn phím mới — không cần khởi động lại.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Giao diện mật mã")
                }

                Section {
                    TextField("ID thẻ (lấy từ quét Wallet)", text: $vm.walletCardID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if let img = vm.walletImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    PhotosPicker(selection: $walletItem, matching: .images) {
                        Label(vm.walletImage == nil ? "Chọn ảnh thẻ…" : "Đổi ảnh thẻ…",
                              systemImage: "photo")
                    }
                    .onChange(of: walletItem) { item in
                        Task {
                            if let raw = try? await item?.loadTransferable(type: Data.self),
                               let img = UIImage(data: raw) {
                                vm.walletImage = img
                            }
                        }
                    }
                    Button {
                        vm.applyWalletSkin()
                    } label: {
                        Label("Áp dụng giao diện Wallet", systemImage: "creditcard.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.walletImage == nil || vm.walletCardID.trimmingCharacters(in: .whitespaces).isEmpty
                              || vm.running || !vm.iosOK || !vm.hasPairingFile)
                    Text("Ghi ảnh vào thư mục .pkpass của thẻ và làm mới bộ nhớ đệm. Buộc đóng ứng dụng Wallet để thấy thay đổi — không cần khởi động lại.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Ảnh Wallet")
                }

                if vm.running {
                    Section("Đang áp dụng") {
                        ProgressView(value: vm.progress)
                        Text("\(Int(vm.progress * 100))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if !vm.logLines.isEmpty {
                    Section("Nhật ký") {
                        ForEach(vm.logLines.indices, id: \.self) { i in
                            Text(vm.logLines[i])
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let result = vm.result {
                    Section("Kết quả") {
                        Label(result, systemImage: vm.resultOK ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(vm.resultOK ? .green : .red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("AirFlit")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showPassthmImporter,
            allowedContentTypes: [.passthm, .zip]
        ) { result in
            switch result {
            case .success(let url):
                vm.loadPassthm(from: url)
            case .failure:
                break
            }
        }
    }
}
