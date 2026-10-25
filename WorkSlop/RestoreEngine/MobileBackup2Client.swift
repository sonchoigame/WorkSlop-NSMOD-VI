import Foundation
import Network

// MARK: - mobilebackup2 wire protocol
//
// Verified against libimobiledevice:
// - Envelope + version exchange: src/device_link_service.c
//   (DLMessageVersionExchange/DLVersionsOk/DLMessageDeviceReady,
//   DLMessageProcessMessage wrapping).
// - Hello + requests + status responses: src/mobilebackup2.c
//   (Hello {SupportedProtocolVersions:[2.0,2.1]} → Response
//   {ErrorCode:0, ProtocolVersion}; send_request {TargetIdentifier,
//   SourceIdentifier, Options, MessageName}; DLMessageStatusResponse).
// - Backup/restore DLMessage loop + raw file transfer: tools/idevicebackup2.c
//   (DLMessageDownloadFiles/DLMessageUploadFiles/GetFreeDiskSpace/
//   PurgeDiskSpace/CreateDirectory/MoveFiles|MoveItems/RemoveFiles|
//   RemoveItems/CopyItem/Disconnect; per-file raw protocol with
//   CODE_* markers; terminating zero dword).
//
// Framing for every plist on this channel: 4-byte big-endian length +
// plist bytes (property_list_service); DL messages are sent BINARY
// (device_link_service_send_process_message → send_binary_plist).

enum MobileBackup2Error: Error, LocalizedError, Sendable {
    case connectFailed(String)
    case ioError(String)
    case plistError(String)
    case versionMismatch(String)
    case deviceError(String)
    case unexpectedMessage(String)
    case fileError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectFailed(let s): return "mobilebackup2: connect failed: \(s)"
        case .ioError(let s): return "mobilebackup2: I/O error: \(s)"
        case .plistError(let s): return "mobilebackup2: plist error: \(s)"
        case .versionMismatch(let s): return "mobilebackup2: version mismatch: \(s)"
        case .deviceError(let s): return "mobilebackup2: device error: \(s)"
        case .unexpectedMessage(let s): return "mobilebackup2: unexpected message: \(s)"
        case .fileError(let s): return "mobilebackup2: file error: \(s)"
        case .cancelled: return "mobilebackup2: cancelled"
        }
    }
}

/// File-transfer markers — idevicebackup2.c
private enum MB2FileCode: UInt8 {
    case success = 0x00
    case errorLocal = 0x06
    case errorRemote = 0x0b
    case fileData = 0x0C
}

// MARK: - Framed NWConnection (4-byte BE length + plist)

/// All NWConnection access is funneled through one serial queue; the
/// class is @unchecked Sendable on that basis.
private final class FramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "workslop.mb2.conn", qos: .userInitiated)

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed else { return }; resumed = true
                    cont.resume()
                case .failed(let e):
                    guard !resumed else { return }; resumed = true
                    cont.resume(throwing: MobileBackup2Error.connectFailed(e.localizedDescription))
                case .cancelled:
                    guard !resumed else { return }; resumed = true
                    cont.resume(throwing: MobileBackup2Error.connectFailed("cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: MobileBackup2Error.ioError("send: \(error.localizedDescription)"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: MobileBackup2Error.ioError("receive: \(error.localizedDescription)"))
                } else if let data = data, data.count == count {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: MobileBackup2Error.ioError("connection closed by peer"))
                } else {
                    cont.resume(throwing: MobileBackup2Error.ioError("short read: \(data?.count ?? 0)/\(count)"))
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

// MARK: - mobilebackup2 client

/// One client = one service connection. Sequential request/response;
/// implemented as an actor so phases can't interleave on the socket.
final actor MobileBackup2Client {
    static let host = "127.0.0.1"
    /// device_link_service version pair (MBACKUP2_VERSION_INT1/INT2).
    private static let dlVersionMajor: UInt64 = 400
    private static let dlVersionMinor: UInt64 = 0
    /// Hello protocol versions (idevicebackup2.c: {2.0, 2.1}).
    private static let helloVersions = [2.0, 2.1]

    private let conn: FramedConnection
    private var isCancelled: @Sendable () -> Bool = { false }

    init(port: UInt16) {
        conn = FramedConnection(host: Self.host, port: port)
    }

    func setCancelled(_ flag: @Sendable @escaping () -> Bool) {
        isCancelled = flag
    }

    // MARK: low-level plist I/O (binary plist on the wire)

    private func sendPlist(_ plist: Any) async throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        } catch {
            throw MobileBackup2Error.plistError("serialize: \(error.localizedDescription)")
        }
        var len = UInt32(data.count).bigEndian
        try await conn.send(Data(bytes: &len, count: 4) + data)
    }

    private func receivePlist() async throws -> Any {
        let lenData = try await conn.receiveExactly(4)
        let len = uint32BE(lenData)
        guard len > 0, len < 256 * 1024 * 1024 else {
            throw MobileBackup2Error.plistError("implausible length prefix: \(len)")
        }
        let body = try await conn.receiveExactly(Int(len))
        do {
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            return try PropertyListSerialization.propertyList(from: body, options: [], format: &fmt)
        } catch {
            throw MobileBackup2Error.plistError("parse: \(error.localizedDescription)")
        }
    }

    /// ["DLMessage<Name>", items...] — device_link_service envelope.
    private func sendDL(_ name: String, _ items: [Any] = []) async throws {
        try await sendPlist([name] + items)
    }

    /// Returns (message name, items after the name).
    private func receiveDL() async throws -> (name: String, items: [Any]) {
        let obj = try await receivePlist()
        guard let arr = obj as? [Any], arr.count >= 1,
              let name = arr[0] as? String, name.hasPrefix("DL")
        else {
            throw MobileBackup2Error.plistError("not a DL* message")
        }
        return (name, Array(arr.dropFirst()))
    }

    private func sendRaw(_ data: Data) async throws {
        try await conn.send(data)
    }

    private func receiveRaw(count: Int) async throws -> Data {
        try await conn.receiveExactly(count)
    }

    // MARK: connect: version exchange + hello

    /// device_link_service_version_exchange + mobilebackup2 Hello.
    /// Returns the negotiated protocol version.
    func connect() async throws -> Double {
        try await conn.start()

        // 1. Device opens with DLMessageVersionExchange.
        let (vname, vitems) = try await receiveDL()
        guard vname == "DLMessageVersionExchange", vitems.count >= 2,
              let major = vitems[0] as? NSNumber, let minor = vitems[1] as? NSNumber
        else { throw MobileBackup2Error.versionMismatch("expected DLMessageVersionExchange") }
        if major.uint64Value > Self.dlVersionMajor ||
            (major.uint64Value == Self.dlVersionMajor && minor.uint64Value > Self.dlVersionMinor) {
            throw MobileBackup2Error.versionMismatch(
                "device=(\(major),\(minor)) > client=(\(Self.dlVersionMajor),\(Self.dlVersionMinor))")
        }

        // 2. Reply DLVersionsOk, then expect DeviceReady.
        try await sendDL("DLMessageVersionExchange", ["DLVersionsOk", NSNumber(value: Self.dlVersionMajor)])
        let (rname, _) = try await receiveDL()
        guard rname == "DLMessageDeviceReady" else {
            throw MobileBackup2Error.versionMismatch("expected DLMessageDeviceReady, got \(rname)")
        }

        // 3. Hello (mobilebackup2_version_exchange).
        try await sendDL("DLMessageProcessMessage", [[
            "MessageName": "Hello",
            "SupportedProtocolVersions": Self.helloVersions,
        ]])
        let (hname, hitems) = try await receiveDL()
        guard hname == "DLMessageProcessMessage",
              let dict = hitems.first as? [String: Any],
              dict["MessageName"] as? String == "Response"
        else { throw MobileBackup2Error.unexpectedMessage("expected Hello/Response, got \(hname)") }
        guard let errCode = dict["ErrorCode"] as? NSNumber, errCode.uint64Value == 0 else {
            throw MobileBackup2Error.deviceError("Hello ErrorCode=\(dict["ErrorCode"] ?? "?")")
        }
        guard let version = dict["ProtocolVersion"] as? NSNumber else {
            throw MobileBackup2Error.plistError("Hello response missing ProtocolVersion")
        }
        return version.doubleValue
    }

    func disconnect() {
        conn.cancel()
    }

    // MARK: requests

    /// mobilebackup2_send_request: {TargetIdentifier, SourceIdentifier?,
    /// Options?, MessageName} as DLMessageProcessMessage.
    func sendRequest(_ request: String, targetID: String, sourceID: String?, options: [String: Any]?) async throws {
        var dict: [String: Any] = ["MessageName": request, "TargetIdentifier": targetID]
        if let sourceID = sourceID { dict["SourceIdentifier"] = sourceID }
        if let options = options { dict["Options"] = options }
        try await sendDL("DLMessageProcessMessage", [dict])
    }

    /// DLMessageStatusResponse — mobilebackup2_send_status_response.
    func sendStatusResponse(status: Int, status1: String?, status2: Any?) async throws {
        try await sendDL("DLMessageStatusResponse", [
            NSNumber(value: status),
            status1 ?? "___EmptyParameterString___",
            status2 ?? "___EmptyParameterString___",
        ])
    }

    // MARK: - backup pull (device → host)

    /// Sends "Backup" (ForceFullBackup) and receives the device's files
    /// into `backupRoot` (flat, named by fileID — like mb2_handle_receive_files:
    /// bname = backup_dir/fname). Returns the received file count.
    func runBackup(targetID: String, sourceID: String, password: String?,
                   to backupRoot: URL,
                   progress: @Sendable (Double, String) -> Void) async throws -> Int {
        var options: [String: Any] = ["ForceFullBackup": true]
        if let password = password {
            // UNVERIFIED for the Backup request specifically: the "Password"
            // key is verified on Unback/Restore requests (idevicebackup2.c);
            // same key name is assumed here. Needs a device to confirm.
            options["Password"] = password
        }
        try await sendRequest("Backup", targetID: targetID, sourceID: sourceID, options: options)

        var fileCount = 0
        var done = false
        while !done {
            if isCancelled() { throw MobileBackup2Error.cancelled }
            let (name, items) = try await receiveDL()
            switch name {
            case "DLMessageUploadFiles":
                // Overall progress lives at index 1 (mb2_set_overall_progress_from_message).
                if items.count > 1, let p = items[1] as? NSNumber {
                    progress(p.doubleValue, "Receiving backup…")
                }
                fileCount += try await receiveFiles(to: backupRoot, progress: progress)
            case "DLMessageDownloadFiles":
                // Not expected during a pull, but handle honestly if asked.
                _ = try await sendFiles(from: backupRoot, list: items, progress: progress)
            case "DLMessageGetFreeDiskSpace":
                let free = (try? FileManager.default.attributesOfFileSystem(forPath: backupRoot.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                try await sendStatusResponse(status: 0, status1: nil, status2: NSNumber(value: free))
            case "DLMessagePurgeDiskSpace":
                // Not supported — exactly what idevicebackup2 answers.
                try await sendStatusResponse(status: -1, status1: "Operation not supported", status2: [String: Any]())
            case "DLMessageCreateDirectory":
                try await handleCreateDirectory(items, base: backupRoot)
            case "DLMessageMoveFiles", "DLMessageMoveItems":
                if items.count > 2, let p = items[2] as? NSNumber { progress(p.doubleValue, "Moving files…") }
                try await handleMove(items, base: backupRoot)
            case "DLMessageRemoveFiles", "DLMessageRemoveItems":
                if items.count > 2, let p = items[2] as? NSNumber { progress(p.doubleValue, "Removing files…") }
                try await handleRemove(items, base: backupRoot)
            case "DLMessageCopyItem":
                try await handleCopyItem(items, base: backupRoot)
            case "DLMessageDisconnect":
                done = true
            case "DLMessageProcessMessage":
                // Final verdict (ErrorCode) or an out-of-band message.
                if let dict = items.first as? [String: Any],
                   let code = dict["ErrorCode"] as? NSNumber {
                    if code.uint64Value != 0 {
                        throw MobileBackup2Error.deviceError(
                            "backup ErrorCode=\(code) (\(dict["ErrorDescription"] as? String ?? "?"))")
                    }
                    done = true
                }
            default:
                throw MobileBackup2Error.unexpectedMessage(name)
            }
        }
        return fileCount
    }

    /// Receives one DLMessageUploadFiles stream: repeated
    /// (domain, filename) + chunked file data. Mirrors
    /// mb2_handle_receive_files exactly:
    /// - a zero-length domain ends the whole stream;
    /// - per file: 4-byte len + 1-byte code header (the code byte is read
    ///   ONLY when len > 0 inside the chunk loop);
    /// - CODE_FILE_DATA chunks, then CODE_SUCCESS / CODE_ERROR_REMOTE;
    ///   ERROR_REMOTE after file data with an empty message is the
    ///   end-of-file marker, not an error.
    private func receiveFiles(to backupRoot: URL,
                              progress: @Sendable (Double, String) -> Void) async throws -> Int {
        var fileCount = 0
        var errcode = 0
        var errdesc: String? = nil

        while true {
            if isCancelled() { throw MobileBackup2Error.cancelled }
            guard let domain = try await receiveSizedString() else { break } // zero length = no more files
            guard let fname = try await receiveSizedString(), !fname.isEmpty else { break }

            let dest = backupRoot.appendingPathComponent(fname)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Remove any stale file first (mirrors remove_file(bname)).
            try? FileManager.default.removeItem(at: dest)
            guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
                errcode = -1; errdesc = "cannot create \(fname)"; break
            }
            guard let handle = try? FileHandle(forWritingTo: dest) else {
                errcode = -1; errdesc = "cannot open \(fname)"; break
            }

            // First chunk header: unconditional 4-byte len + 1-byte code.
            var tlen = try await receiveTlen()
            var lastCode: UInt8 = 0
            var code = try await receiveRaw(count: 1)[0]

            while code == MB2FileCode.fileData.rawValue {
                let blockSize = Int(tlen) - 1
                var received = 0
                while received < blockSize {
                    let chunk = try await receiveRaw(count: min(blockSize - received, 1 << 15))
                    handle.write(chunk)
                    received += chunk.count
                }
                progress(-1, "Receiving \(domain):\(fname)")
                // Next header: length first; the code byte follows ONLY
                // when the length is non-zero.
                tlen = try await receiveTlen()
                if tlen == 0 { break }
                lastCode = code
                code = try await receiveRaw(count: 1)[0]
            }
            try? handle.close()
            fileCount += 1

            if tlen == 0 { break } // zero dword ends the whole stream
            if code == MB2FileCode.errorRemote.rawValue {
                let msgData = try await receiveRaw(count: Int(tlen) - 1)
                let msg = String(data: msgData, encoding: .utf8) ?? ""
                if lastCode != MB2FileCode.fileData.rawValue, !msg.isEmpty {
                    errcode = -1; errdesc = msg
                }
            } else if code != MB2FileCode.success.rawValue {
                errcode = -1; errdesc = "unexpected file code \(code)"
            }
        }

        try await sendStatusResponse(status: errcode, status1: errdesc, status2: [String: Any]())
        if errcode != 0 { throw MobileBackup2Error.deviceError(errdesc ?? "receive failed") }
        return fileCount
    }

    /// 4-byte BE length + bytes; nil when length is 0 (mb2_receive_filename).
    private func receiveSizedString() async throws -> String? {
        let lenData = try await receiveRaw(count: 4)
        let len = uint32BE(lenData)
        if len == 0 { return nil }
        guard len <= 4096 else { throw MobileBackup2Error.plistError("filename length \(len) too large") }
        let bytes = try await receiveRaw(count: Int(len))
        return String(data: bytes, encoding: .utf8)
    }

    /// 4-byte big-endian length, decoded byte-by-byte (never
    /// `load(as:)` — Data bytes are not guaranteed aligned).
    private func uint32BE(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        return (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
    }

    private func receiveTlen() async throws -> UInt32 {
        uint32BE(try await receiveRaw(count: 4))
    }

    // MARK: - restore push (host → device)

    /// Sends "Restore" and serves the device's DLMessageDownloadFiles
    /// requests from `backupRoot`. Returns when the device sends its final
    /// verdict (DLMessageProcessMessage ErrorCode) + Disconnect.
    /// The returned Bool is the DEVICE's confirmation — the caller must
    /// still treat it as the verdict, not as local bookkeeping.
    func runRestore(targetID: String, sourceID: String, password: String?,
                    from backupRoot: URL, fileResolver: @Sendable (String) -> URL?,
                    progress: @Sendable (Double, String) -> Void) async throws -> Bool {
        // Restore options — idevicebackup2.c (CMD_RESTORE).
        // No RestoreShouldReboot: the engine reboots explicitly exactly
        // once after the restore (desktop: reboot=False). Letting the
        // device auto-reboot AND rebooting again was a double reboot.
        // RestoreSystemFiles + DontCopyBackup=false mirror the desktop's
        // protective restore (mb.restore(..., system=True, copy=True)):
        // the device copies the backup locally, then restores system
        // files from that copy.
        var options: [String: Any] = [
            "RestoreDontCopyBackup": false,
            "RestorePreserveSettings": true,
            "RestoreSystemFiles": true,
            "RemoveItemsNotRestored": false,
        ]
        if let password = password { options["Password"] = password }
        try await sendRequest("Restore", targetID: targetID, sourceID: sourceID, options: options)

        var deviceConfirmed = false
        var done = false
        while !done {
            if isCancelled() { throw MobileBackup2Error.cancelled }
            let (name, items) = try await receiveDL()
            switch name {
            case "DLMessageDownloadFiles":
                // Overall progress at index 2 (mb2_set_overall_progress_from_message).
                if items.count > 2, let p = items[2] as? NSNumber {
                    progress(p.doubleValue, "Sending files…")
                }
                _ = try await sendFiles(from: backupRoot, list: items, progress: progress, resolver: fileResolver)
            case "DLMessageUploadFiles":
                // Not expected during a push; drain honestly rather than hanging.
                _ = try await receiveFiles(to: FileManager.default.temporaryDirectory, progress: progress)
            case "DLMessageGetFreeDiskSpace":
                // Answer the REAL free byte count (like the backup path
                // does). Answering 0 made the device refuse the restore
                // for "insufficient space".
                let free = (try? FileManager.default.attributesOfFileSystem(forPath: backupRoot.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                try await sendStatusResponse(status: 0, status1: nil, status2: NSNumber(value: free))
            case "DLMessagePurgeDiskSpace":
                try await sendStatusResponse(status: -1, status1: "Operation not supported", status2: [String: Any]())
            case "DLMessageCreateDirectory":
                try await handleCreateDirectory(items, base: backupRoot)
            case "DLMessageMoveFiles", "DLMessageMoveItems":
                try await handleMove(items, base: backupRoot)
            case "DLMessageRemoveFiles", "DLMessageRemoveItems":
                try await handleRemove(items, base: backupRoot)
            case "DLMessageDisconnect":
                done = true
            case "DLMessageProcessMessage":
                if let dict = items.first as? [String: Any],
                   let code = dict["ErrorCode"] as? NSNumber {
                    // The device's own verdict — this is what the engine's
                    // "device must confirm" rule is built on.
                    deviceConfirmed = (code.uint64Value == 0)
                    if !deviceConfirmed {
                        throw MobileBackup2Error.deviceError(
                            "restore ErrorCode=\(code) (\(dict["ErrorDescription"] as? String ?? "?"))")
                    }
                }
            default:
                throw MobileBackup2Error.unexpectedMessage(name)
            }
        }
        return deviceConfirmed
    }

    // MARK: - partial restore push (host → device, iOS 16–26 sparse method)

    /// Sends "Restore" for a SYNTHESIZED sparse backup (legacy
    /// Manifest.mbdb, payloads flat by fileID). Options mirror
    /// GoldenNugget-mobile's partial path (Rust RestoreOptions with
    /// reboot=false, system_files=true): no wipe, no reboot — the device
    /// writes the listed system files in place.
    ///
    /// Returns (deviceConfirmed, servedFiles). deviceConfirmed is the
    /// device's own DLMessageProcessMessage ErrorCode==0; servedFiles
    /// counts files the device actually pulled, so a confirmed-but-empty
    /// restore can't be mistaken for a delivered one.
    func runPartialRestore(targetID: String, sourceID: String, password: String?,
                           from backupRoot: URL,
                           progress: @Sendable (Double, String) -> Void) async throws
        -> (deviceConfirmed: Bool, servedFiles: Int)
    {
        var options: [String: Any] = [
            "RestoreShouldReboot": false,
            // Desktop sparse restore parity (perform_restore: copy=False
            // → RestoreDontCopyBackup=True): the device streams payloads
            // on demand instead of copying the synthetic backup locally.
            "RestoreDontCopyBackup": true,
            "RestorePreserveSettings": true,
            "RestoreSystemFiles": true,
            "RemoveItemsNotRestored": false,
        ]
        if let password = password { options["Password"] = password }
        try await sendRequest("Restore", targetID: targetID, sourceID: sourceID, options: options)

        var deviceConfirmed = false
        var servedFiles = 0
        var done = false
        while !done {
            if isCancelled() { throw MobileBackup2Error.cancelled }
            let (name, items) = try await receiveDL()
            switch name {
            case "DLMessageDownloadFiles":
                // Overall progress at index 2 of the items (index 3 of the
                // full array — mb2_set_overall_progress_from_message).
                if items.count > 2, let p = items[2] as? NSNumber {
                    progress(p.doubleValue, "Sending files…")
                }
                servedFiles += try await sendFiles(from: backupRoot, list: items, progress: progress)
            case "DLMessageUploadFiles":
                // Not expected during a push; drain honestly rather than hanging.
                _ = try await receiveFiles(to: FileManager.default.temporaryDirectory, progress: progress)
            case "DLContentsOfDirectory":
                try await handleListDirectory(items, base: backupRoot)
            case "DLMessageGetFreeDiskSpace":
                let free = (try? FileManager.default.attributesOfFileSystem(forPath: backupRoot.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                try await sendStatusResponse(status: 0, status1: nil, status2: NSNumber(value: free))
            case "DLMessagePurgeDiskSpace":
                try await sendStatusResponse(status: -1, status1: "Operation not supported", status2: [String: Any]())
            case "DLMessageCreateDirectory":
                try await handleCreateDirectory(items, base: backupRoot)
            case "DLMessageMoveFiles", "DLMessageMoveItems":
                try await handleMove(items, base: backupRoot)
            case "DLMessageRemoveFiles", "DLMessageRemoveItems":
                try await handleRemove(items, base: backupRoot)
            case "DLMessageDisconnect":
                done = true
            case "DLMessageProcessMessage":
                if let dict = items.first as? [String: Any],
                   let code = dict["ErrorCode"] as? NSNumber {
                    // The device's own verdict.
                    deviceConfirmed = (code.uint64Value == 0)
                    if !deviceConfirmed {
                        throw MobileBackup2Error.deviceError(
                            "partial restore ErrorCode=\(code) (\(dict["ErrorDescription"] as? String ?? "?"))")
                    }
                }
            default:
                throw MobileBackup2Error.unexpectedMessage(name)
            }
        }
        return (deviceConfirmed, servedFiles)
    }

    /// Answers DLContentsOfDirectory (idevicebackup2.c
    /// mb2_handle_list_directory reads full-array index 1; receiveDL
    /// strips the message name, so the path is items[0] here): status 0 +
    /// { name: { DLFileType, DLFileSize, DLFileModificationDate } }.
    private func handleListDirectory(_ items: [Any], base: URL) async throws {
        var listing: [String: Any] = [:]
        if let rel = items.first as? String {
            let dirURL = base.appendingPathComponent(rel)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) {
                for name in names {
                    let url = dirURL.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    listing[name] = [
                        "DLFileType": isDir.boolValue ? "DLFileTypeDirectory" : "DLFileTypeRegular",
                        "DLFileSize": attrs?[.size] as? NSNumber ?? NSNumber(value: 0),
                        "DLFileModificationDate": attrs?[.modificationDate] as? Date ?? Date(),
                    ]
                }
            }
        }
        try await sendStatusResponse(status: 0, status1: nil, status2: listing)
    }

    /// Serves one DLMessageDownloadFiles: for each requested path, send
    /// path length + path, then the file in CODE_FILE_DATA chunks +
    /// CODE_SUCCESS terminator (mb2_handle_send_file). Ends with a zero
    /// dword + DLMessageStatusResponse (mb2_handle_send_files).
    ///
    /// Returns the number of files actually sent.
    private func sendFiles(from backupRoot: URL, list items: [Any],
                           progress: @Sendable (Double, String) -> Void,
                           resolver: @Sendable (String) -> URL? = { _ in nil }) async throws -> Int {
        guard let files = items.first as? [String] else {
            throw MobileBackup2Error.plistError("DLMessageDownloadFiles: item[0] is not a string array")
        }
        var errcode = 0
        var errdesc: String? = nil
        var served = 0
        for path in files {
            if isCancelled() { throw MobileBackup2Error.cancelled }
            let localURL: URL? = {
                let direct = backupRoot.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
                return resolver(path)
            }()
            guard let url = localURL else {
                errcode = -1; errdesc = "no local file for requested path: \(path)"
                break // mirrors the C loop breaking on first send error
            }
            do {
                try await sendOneFile(path: path, url: url, progress: progress)
                served += 1
            } catch {
                errcode = -1; errdesc = "send \(path): \(error.localizedDescription)"
                break
            }
        }
        // Terminating zero dword, then the status response.
        var zero = UInt32(0).bigEndian
        try await sendRaw(Data(bytes: &zero, count: 4))
        if errcode == 0 {
            try await sendStatusResponse(status: 0, status1: nil, status2: [String: Any]())
        } else {
            try await sendStatusResponse(status: -13, status1: "Multi status",
                                         status2: ["error": errdesc ?? "unknown"])
        }
        if errcode != 0 { throw MobileBackup2Error.fileError(errdesc ?? "send failed") }
        return served
    }

    private func sendOneFile(path: String, url: URL,
                             progress: @Sendable (Double, String) -> Void) async throws {
        let pathBytes = Data(path.utf8)
        var plen = UInt32(pathBytes.count).bigEndian
        try await sendRaw(Data(bytes: &plen, count: 4) + pathBytes)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if total == 0 {
            // Empty file: path only, then the success terminator below.
            // (mirrors mb2_handle_send_file's total==0 path)
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sent: UInt64 = 0
            while sent < total {
                if isCancelled() { throw MobileBackup2Error.cancelled }
                let chunk = try handle.read(upToCount: 32768) ?? Data()
                if chunk.isEmpty { break }
                // 4-byte BE (len+1) + CODE_FILE_DATA + bytes.
                var hlen = UInt32(chunk.count + 1).bigEndian
                var header = Data(bytes: &hlen, count: 4)
                header.append(MB2FileCode.fileData.rawValue)
                try await sendRaw(header + chunk)
                sent += UInt64(chunk.count)
                progress(-1, "Sending \(path)")
            }
        }
        // Success terminator: 4-byte BE(1) + CODE_SUCCESS.
        var tlen = UInt32(1).bigEndian
        var term = Data(bytes: &tlen, count: 4)
        term.append(MB2FileCode.success.rawValue)
        try await sendRaw(term)
    }

    // MARK: - small DLMessage handlers (idevicebackup2.c patterns)

    private func handleCreateDirectory(_ items: [Any], base: URL) async throws {
        // message[1] is the directory path string (mb2_handle_make_directory).
        var errcode = 0
        var errdesc: String? = nil
        if let rel = items.first as? String {
            do {
                try FileManager.default.createDirectory(at: base.appendingPathComponent(rel),
                                                        withIntermediateDirectories: true)
            } catch {
                errcode = -1; errdesc = error.localizedDescription
            }
        }
        try await sendStatusResponse(status: errcode, status1: errdesc, status2: [String: Any]())
        if errcode != 0 { throw MobileBackup2Error.fileError(errdesc ?? "mkdir failed") }
    }

    private func handleMove(_ items: [Any], base: URL) async throws {
        var errcode = 0
        var errdesc: String? = nil
        if let moves = items.first as? [String: String] {
            for (old, new) in moves {
                let oldURL = base.appendingPathComponent(old)
                let newURL = base.appendingPathComponent(new)
                do {
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        try FileManager.default.removeItem(at: newURL)
                    }
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                } catch {
                    errcode = -1; errdesc = error.localizedDescription
                    break
                }
            }
        }
        try await sendStatusResponse(status: errcode, status1: errdesc, status2: [String: Any]())
        if errcode != 0 { throw MobileBackup2Error.fileError(errdesc ?? "move failed") }
    }

    private func handleRemove(_ items: [Any], base: URL) async throws {
        var errcode = 0
        var errdesc: String? = nil
        if let list = items.first as? [String] {
            for rel in list {
                do {
                    try FileManager.default.removeItem(at: base.appendingPathComponent(rel))
                } catch {
                    errcode = -1; errdesc = error.localizedDescription
                    break
                }
            }
        }
        try await sendStatusResponse(status: errcode, status1: errdesc, status2: [String: Any]())
        if errcode != 0 { throw MobileBackup2Error.fileError(errdesc ?? "remove failed") }
    }

    private func handleCopyItem(_ items: [Any], base: URL) async throws {
        var errcode = 0
        var errdesc: String? = nil
        if items.count > 1, let src = items[0] as? String, let dst = items[1] as? String {
            do {
                let s = base.appendingPathComponent(src)
                let d = base.appendingPathComponent(dst)
                if FileManager.default.fileExists(atPath: d.path) {
                    try FileManager.default.removeItem(at: d)
                }
                try FileManager.default.copyItem(at: s, to: d)
            } catch {
                errcode = -1; errdesc = error.localizedDescription
            }
        }
        try await sendStatusResponse(status: errcode, status1: errdesc, status2: [String: Any]())
        if errcode != 0 { throw MobileBackup2Error.fileError(errdesc ?? "copy failed") }
    }
}
