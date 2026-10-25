import Foundation
import Security

// MARK: - Lockdown wire protocol
//
// Verified against libimobiledevice src/lockdown.c (per-message function
// references below). Framing (property_list_service.c): 4-byte big-endian
// length prefix followed by the XML plist bytes. Every request is a dict
// with "Request" (+ "Label"); the device echoes "Request" and reports via
// the "Error" string key, or "Result" == "Success" (lockdown_check_result;
// on iOS 5+ a missing "Result" with no "Error" also counts as success).
//
// CFStream is used instead of Network.framework because the session
// requires a mid-connection TLS upgrade (STARTTLS): after StartSession
// returns EnableSessionSSL=true the client must handshake TLS on the SAME
// socket (idevice.c: idevice_connection_enable_ssl). CFStream supports
// this via kCFStreamPropertySSLSettings on a live stream; NWConnection
// has no supported mid-connection upgrade path.

enum LockdownError: Error, LocalizedError, Sendable {
    case notConnected
    case connectFailed(String)
    case ioError(String)
    case plistError(String)
    case deviceError(String)
    case unexpectedResponse(String)
    case tlsFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Lockdown: not connected."
        case .connectFailed(let s): return "Lockdown: connect failed: \(s)"
        case .ioError(let s): return "Lockdown: I/O error: \(s)"
        case .plistError(let s): return "Lockdown: plist error: \(s)"
        case .deviceError(let s): return "Lockdown: device reported error: \(s)"
        case .unexpectedResponse(let s): return "Lockdown: unexpected response: \(s)"
        case .tlsFailed(let s): return "Lockdown: TLS failed: \(s)"
        }
    }
}

// MARK: - Minimal DER writer (for the PKCS#12 identity container)

/// Deterministic ASN.1 DER encoding — container format only (RFC 7292),
/// no crypto invented here.
private enum DER {
    static func lengthPrefix(_ n: Int) -> Data {
        precondition(n >= 0)
        if n < 128 { return Data([UInt8(n)]) }
        var v = n
        var bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + lengthPrefix(content.count) + content
    }

    static func sequence(_ parts: [Data]) -> Data {
        tlv(0x30, parts.reduce(Data(), +))
    }

    static func set(_ parts: [Data]) -> Data {
        tlv(0x31, parts.reduce(Data(), +))
    }

    static func integer(_ value: Int) -> Data {
        var v = value
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func null() -> Data { Data([0x05, 0x00]) }

    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }

    static func oid(_ arcs: [Int]) -> Data {
        precondition(arcs.count >= 2)
        var body = Data([UInt8(40 * arcs[0] + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var v = arc
            var tmp: [UInt8] = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 {
                tmp.insert(UInt8((v & 0x7F) | 0x80), at: 0)
                v >>= 7
            }
            body += Data(tmp)
        }
        return tlv(0x06, body)
    }

    /// [n] EXPLICIT content
    static func explicit(_ n: UInt8, _ content: Data) -> Data {
        tlv(0xA0 | n, content)
    }
}

// MARK: - PKCS#12 identity container

private enum PKCS12 {
    static let oidData = [1, 2, 840, 113549, 1, 7, 1]
    static let oidSignedData = [1, 2, 840, 113549, 1, 7, 2]
    static let oidKeyBag = [1, 2, 840, 113549, 1, 12, 10, 1, 1]
    static let oidCertBag = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    static let oidX509Certificate = [1, 2, 840, 113549, 1, 9, 22, 1]
    static let oidRSAEncryption = [1, 2, 840, 113549, 1, 1, 1]

    /// Builds an unencrypted, MAC-less PFX holding one private key
    /// (PKCS#8) and one certificate. SecPKCS12Import accepts this shape.
    static func build(keyPKCS8: Data, certDER: Data) -> Data {
        let keyBag = DER.sequence([
            DER.oid(oidKeyBag),
            DER.explicit(0, keyPKCS8),
        ])
        let certBag = DER.sequence([
            DER.oid(oidCertBag),
            DER.explicit(0, DER.sequence([
                DER.oid(oidX509Certificate),
                DER.explicit(0, DER.octetString(certDER)),
            ])),
        ])
        let safeContents = DER.sequence([keyBag, certBag])
        let signedData = DER.sequence([
            DER.integer(3),
            DER.set([]),
            DER.sequence([
                DER.oid(oidData),
                DER.explicit(0, DER.octetString(safeContents)),
            ]),
            DER.set([]),
        ])
        let authSafe = DER.sequence([
            DER.oid(oidSignedData),
            DER.explicit(0, signedData),
        ])
        return DER.sequence([DER.integer(3), authSafe])
    }

    /// Wraps a PKCS#1 RSAPrivateKey DER in a PKCS#8 PrivateKeyInfo.
    static func pkcs1ToPKCS8(_ pkcs1: Data) -> Data {
        DER.sequence([
            DER.integer(0),
            DER.sequence([DER.oid(oidRSAEncryption), DER.null()]),
            DER.octetString(pkcs1),
        ])
    }

    /// Peek heuristic: PKCS#8 is SEQUENCE { INTEGER 0, SEQUENCE … }.
    /// Enough to distinguish from PKCS#1 (SEQUENCE { INTEGER, INTEGER … }).
    static func isPKCS8(_ der: Data) -> Bool {
        guard der.count > 6, der[0] == 0x30 else { return false }
        var idx = 1
        let b = der[idx]
        idx += (b & 0x80 == 0) ? 1 : 1 + Int(b & 0x7F)
        guard idx + 3 < der.count,
              der[idx] == 0x02, der[idx + 1] == 0x01, der[idx + 2] == 0x00
        else { return false }
        return der[idx + 3] == 0x30
    }
}

private enum PEM {
    /// PEM armor → DER. Falls back to raw base64, then raw bytes
    /// (some records already store DER).
    static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN")
        else {
            let t = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Data(base64Encoded: t) ?? data
        }
        let b64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: b64)
    }
}

// MARK: - CFStream socket (blocking I/O on a dedicated queue)

/// Blocking CFStream I/O bridged to async/await. All socket access happens
/// on one serial queue; callers never touch the streams directly.
private final class StreamSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "workslop.lockdown.io", qos: .userInitiated)
    private var readStream: CFReadStream?
    private var writeStream: CFWriteStream?

    private func onIO<T: Sendable>(
        _ body: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    func connect(host: String, port: Int) async throws {
        try await onIO {
            var rs: Unmanaged<CFReadStream>?
            var ws: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &rs, &ws)
            guard let rs = rs, let ws = ws else {
                throw LockdownError.connectFailed("CFStreamCreatePairWithSocketToHost returned nil")
            }
            let r = rs.takeRetainedValue()
            let w = ws.takeRetainedValue()
            // Unscheduled streams do blocking I/O; Open connects synchronously here.
            guard CFReadStreamOpen(r), CFWriteStreamOpen(w) else {
                throw LockdownError.connectFailed(
                    "stream open failed (read:\(CFReadStreamGetStatus(r).rawValue) write:\(CFWriteStreamGetStatus(w).rawValue))")
            }
            self.readStream = r
            self.writeStream = w
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await onIO {
            guard let w = self.writeStream else { throw LockdownError.notConnected }
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { throw LockdownError.ioError("empty buffer") }
                var sent = 0
                while sent < data.count {
                    let n = CFWriteStreamWrite(w, base.advanced(by: sent).assumingMemoryBound(to: UInt8.self), data.count - sent)
                    if n < 0 {
                        let e = CFWriteStreamCopyError(w) as Error?
                        throw LockdownError.ioError("write: \(e?.localizedDescription ?? "unknown")")
                    }
                    if n == 0 { throw LockdownError.ioError("connection closed by peer") }
                    sent += n
                }
            }
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        try await onIO {
            guard let r = self.readStream else { throw LockdownError.notConnected }
            var out = Data()
            out.reserveCapacity(count)
            var buf = [UInt8](repeating: 0, count: min(count, 32768))
            while out.count < count {
                let want = min(buf.count, count - out.count)
                let n = CFReadStreamRead(r, &buf, want)
                if n < 0 {
                    let e = CFReadStreamCopyError(r) as Error?
                    throw LockdownError.ioError("read: \(e?.localizedDescription ?? "unknown")")
                }
                if n == 0 { throw LockdownError.ioError("connection closed by peer") }
                out.append(buf, count: n)
            }
            return out
        }
    }

    /// STARTTLS on the live connection (Apple-documented upgrade path).
    /// No device-certificate validation — matches libimobiledevice's
    /// ssl_verify_callback which unconditionally returns 1 (idevice.c).
    func upgradeToTLS(identity: SecIdentity) async throws {
        try await onIO {
            guard let r = self.readStream, let w = self.writeStream else {
                throw LockdownError.notConnected
            }
            let settings: [CFString: Any] = [
                kCFStreamSSLPeerName: kCFNull,
                // UNVERIFIED: client identity delivery via the CFStream
                // certificate array. libimobiledevice presents
                // RootCertificate+RootPrivateKey through OpenSSL
                // (idevice_connection_enable_ssl); whether lockdownd on
                // iOS 17+ accepts the identity delivered this way is not
                // verifiable without a device.
                kCFStreamSSLCertificates: [identity] as CFArray,
            ]
            guard CFReadStreamSetProperty(r, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary),
                  CFWriteStreamSetProperty(w, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
            else { throw LockdownError.tlsFailed("could not set kCFStreamPropertySSLSettings") }
            // The handshake is driven by the next read/write (the following
            // lockdown message). Failures surface there as I/O errors.
        }
    }

    func close() {
        queue.async {
            if let r = self.readStream { CFReadStreamClose(r) }
            if let w = self.writeStream { CFWriteStreamClose(w) }
            self.readStream = nil
            self.writeStream = nil
        }
    }
}

// MARK: - Pairing identity (from PairingStore's record)

/// The pairing record as stored by the app — format-agnostic (classic
/// idevicepair lockdown records AND iOS 17+ RemotePairing records).
/// @unchecked Sendable: all properties are `let` (immutable after init);
/// the record dict is only ever read, never mutated in place.
struct PairingIdentity: @unchecked Sendable {
    /// Verbatim record dict, for the PairRecord request field.
    let record: [String: Any]
    /// "HostID" (classic) or "identifier" (RemotePairing).
    let hostID: String
    let systemBUID: String?
    let escrowBag: Data?
    let rootCertDER: Data?
    let rootKeyDER: Data?
    /// True when the record carries no certificate material
    /// (RemotePairing shape: identifier/private_key/public_key/alt_irk).
    var isRemotePairing: Bool { rootCertDER == nil }

    init?(record: [String: Any]) {
        self.record = record
        if let h = record["HostID"] as? String, !h.isEmpty {
            hostID = h
        } else if let h = record["identifier"] as? String, !h.isEmpty {
            // UNVERIFIED: for RemotePairing records the "identifier" is
            // assumed to play the HostID role in ValidatePair/StartSession.
            // Not verifiable from libimobiledevice (no RemotePairing code);
            // needs device testing.
            hostID = h
        } else {
            return nil
        }
        systemBUID = record["SystemBUID"] as? String
        escrowBag = record["EscrowBag"] as? Data
        if let certPEM = record["RootCertificate"] as? Data {
            rootCertDER = PEM.der(from: certPEM)
        } else { rootCertDER = nil }
        if let keyPEM = record["RootPrivateKey"] as? Data,
           let der = PEM.der(from: keyPEM) {
            rootKeyDER = PKCS12.isPKCS8(der) ? der : PKCS12.pkcs1ToPKCS8(der)
        } else { rootKeyDER = nil }
    }

    /// Public parts for ValidatePair/Pair. Mirrors lockdownd_do_pair
    /// stripping RootPrivateKey/HostPrivateKey — and extends the same
    /// principle to the RemotePairing "private_key": private key material
    /// is never sent to the device.
    var publicRecord: [String: Any] {
        var r = record
        r.removeValue(forKey: "RootPrivateKey")
        r.removeValue(forKey: "HostPrivateKey")
        r.removeValue(forKey: "private_key")
        return r
    }

    static func load() -> PairingIdentity? {
        guard let data = try? Data(contentsOf: PairingStore.fileURL) else { return nil }
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt),
              let dict = obj as? [String: Any]
        else { return nil }
        return PairingIdentity(record: dict)
    }
}

// MARK: - Lockdown client

/// Speaks the lockdown protocol to 127.0.0.1:62078 through the loopback
/// tunnel. One client = one TCP connection = one session.
actor LockdownClient {
    static let host = "127.0.0.1"
    static let port = 62078
    private static let label = "WorkSlop"

    private let socket = StreamSocket()

    func connect() async throws {
        try await socket.connect(host: Self.host, port: Self.port)
    }

    /// Non-isolated: safe to call from anywhere (the socket serializes
    /// internally); used in `defer` blocks across actors.
    nonisolated func close() {
        socket.close()
    }

    // MARK: plist framing (property_list_service.c: htobe32(len) + plist)

    private func sendPlist(_ dict: [String: Any]) async throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw LockdownError.plistError("serialize: \(error.localizedDescription)")
        }
        var len = UInt32(data.count).bigEndian
        try await socket.write(Data(bytes: &len, count: 4) + data)
    }

    private func receivePlistDict() async throws -> [String: Any] {
        let lenData = try await socket.readExactly(4)
        // Byte-by-byte big-endian decode (Data bytes aren't aligned for load(as:)).
        let len = (UInt32(lenData[0]) << 24) | (UInt32(lenData[1]) << 16) | (UInt32(lenData[2]) << 8) | UInt32(lenData[3])
        guard len > 0, len < 32 * 1024 * 1024 else {
            throw LockdownError.plistError("implausible length prefix: \(len)")
        }
        let body = try await socket.readExactly(Int(len))
        let obj: Any
        do {
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            obj = try PropertyListSerialization.propertyList(from: body, options: [], format: &fmt)
        } catch {
            throw LockdownError.plistError("parse: \(error.localizedDescription)")
        }
        guard let dict = obj as? [String: Any] else {
            throw LockdownError.plistError("top-level is not a dict")
        }
        return dict
    }

    /// One request/response round trip with lockdown_check_result semantics
    /// (lockdown.c): the device must echo "Request"; an "Error" key fails;
    /// "Result"=="Success" (or missing Result with no Error on iOS 5+) passes.
    func transact(_ dict: [String: Any], expect verb: String) async throws -> [String: Any] {
        var d = dict
        d["Label"] = Self.label
        try await sendPlist(d)
        let resp = try await receivePlistDict()
        guard let req = resp["Request"] as? String, req == verb else {
            throw LockdownError.unexpectedResponse("expected Request=\(verb), got \(resp["Request"] ?? "nil")")
        }
        if let err = resp["Error"] as? String {
            throw LockdownError.deviceError(err)
        }
        if let result = resp["Result"] as? String, result != "Success" {
            throw LockdownError.deviceError("Result=\(result)")
        }
        return resp
    }

    // MARK: messages (lockdown.c)

    /// lockdownd_query_type — first message of the handshake.
    func queryType() async throws {
        _ = try await transact(["Request": "QueryType"], expect: "QueryType")
    }

    /// lockdownd_get_value.
    func getValue(domain: String?, key: String?) async throws -> Any? {
        var d: [String: Any] = ["Request": "GetValue"]
        if let domain = domain { d["Domain"] = domain }
        if let key = key { d["Key"] = key }
        return try await transact(d, expect: "GetValue")["Value"]
    }

    /// lockdownd_do_pair(verb:"ValidatePair").
    func validatePair(identity: PairingIdentity) async throws {
        _ = try await transact([
            "Request": "ValidatePair",
            "PairRecord": identity.publicRecord,
            "ProtocolVersion": "2", // LOCKDOWN_PROTOCOL_VERSION (lockdown.h)
        ], expect: "ValidatePair")
    }

    /// lockdownd_do_pair(verb:"Pair") — device shows the trust dialog.
    func pair(identity: PairingIdentity) async throws {
        _ = try await transact([
            "Request": "Pair",
            "PairRecord": identity.publicRecord,
            "ProtocolVersion": "2",
        ], expect: "Pair")
    }

    /// lockdownd_start_session → (SessionID, EnableSessionSSL).
    func startSession(identity: PairingIdentity) async throws -> (sessionID: String, sslEnabled: Bool) {
        var d: [String: Any] = ["Request": "StartSession", "HostID": identity.hostID]
        if let buid = identity.systemBUID { d["SystemBUID"] = buid }
        let r = try await transact(d, expect: "StartSession")
        return (r["SessionID"] as? String ?? "", r["EnableSessionSSL"] as? Bool ?? false)
    }

    /// lockdownd_do_start_service → (Port, EnableServiceSSL).
    /// EscrowBag is attached when the record carries one
    /// (lockdownd_build_start_service_request, send_escrow_bag=1 as used
    /// by idevicebackup2 for com.apple.mobilebackup2).
    func startService(_ name: String, escrowBag: Data?) async throws -> (port: UInt16, sslEnabled: Bool) {
        var d: [String: Any] = ["Request": "StartService", "Service": name]
        if let bag = escrowBag { d["EscrowBag"] = bag }
        let r = try await transact(d, expect: "StartService")
        guard let port = (r["Port"] as? NSNumber)?.uint16Value, port != 0 else {
            throw LockdownError.unexpectedResponse("StartService(\(name)): missing Port")
        }
        return (port, r["EnableServiceSSL"] as? Bool ?? false)
    }

    // MARK: full handshake (lockdownd_client_new_with_handshake order)

    /// QueryType → ValidatePair (→ Pair on InvalidHostID → ValidatePair) →
    /// StartSession → TLS upgrade when the device asks for it.
    func handshake(identity: PairingIdentity) async throws {
        try await queryType()
        do {
            try await validatePair(identity: identity)
        } catch LockdownError.deviceError(let code) where code == "InvalidHostID" {
            try await pair(identity: identity)
            try await validatePair(identity: identity)
        }
        let (_, sslEnabled) = try await startSession(identity: identity)
        if sslEnabled {
            let secID = try makeTLSIdentity(from: identity)
            try await socket.upgradeToTLS(identity: secID)
        }
    }

    /// Builds the TLS client identity (RootCertificate+RootPrivateKey, as
    /// idevice_connection_enable_ssl does with OpenSSL).
    private func makeTLSIdentity(from identity: PairingIdentity) throws -> SecIdentity {
        // RemotePairing records carry no certificate material, so there is
        // no TLS client identity to build from them. libimobiledevice has no
        // RemotePairing TLS code to verify against; the correct client-auth
        // mechanism for such records on iOS 17+ needs device testing.
        // Refusing loudly instead of guessing — and telling the user the
        // concrete workaround (a legacy lockdown pairing file, exportable
        // with idevicepair/Jitterbug on a computer).
        guard let certDER = identity.rootCertDER, let keyPKCS8 = identity.rootKeyDER else {
            throw LockdownError.tlsFailed(
                "The imported pairing file is an iOS 17+ RemotePairing record " +
                "(identifier/private_key/public_key), which carries no certificate " +
                "for the TLS session upgrade — and that upgrade path is unverified. " +
                "Workaround: export a legacy lockdown pairing file instead " +
                "(pair with idevicepair or Jitterbug on a computer, then import " +
                "the .plist here) and re-run Apply.")
        }
        let pfx = PKCS12.build(keyPKCS8: keyPKCS8, certDER: certDER)
        var items: CFArray?
        // Unencrypted PFX: empty options (no passphrase needed).
        let status = SecPKCS12Import(pfx as CFData, [:] as CFDictionary, &items)
        guard status == errSecSuccess,
              let cfItems = items, CFArrayGetCount(cfItems) > 0
        else {
            throw LockdownError.tlsFailed("SecPKCS12Import failed: \(status)")
        }
        // Read the identity out at the CF level (no Swift downcast): the
        // import dictionary is documented to hold a SecIdentity under
        // kSecImportItemIdentity, and the type ID is verified before use.
        let rawDict = CFArrayGetValueAtIndex(cfItems, 0)!
        let dict = Unmanaged<CFDictionary>.fromOpaque(rawDict).takeUnretainedValue()
        let keyPtr = Unmanaged.passUnretained(kSecImportItemIdentity).toOpaque()
        guard let rawValue = CFDictionaryGetValue(dict, keyPtr) else {
            throw LockdownError.tlsFailed("SecPKCS12Import returned no identity")
        }
        let value = Unmanaged<AnyObject>.fromOpaque(rawValue).takeUnretainedValue()
        guard CFGetTypeID(value) == SecIdentityGetTypeID() else {
            throw LockdownError.tlsFailed("SecPKCS12Import returned a non-identity value")
        }
        return Unmanaged<SecIdentity>.fromOpaque(rawValue).takeUnretainedValue()
    }

    // MARK: reboot (diagnostics_relay "Restart" — diagnostics_relay.c)

    /// Reboots the device. The lockdown session on `self` must already be
    /// handshaked; the Restart goes over a fresh service connection, like
    /// libimobiledevice's diagnostics_relay client.
    func reboot() async throws {
        let (port, serviceSSL) = try await startService("com.apple.mobile.diagnostics_relay", escrowBag: nil)
        if serviceSSL {
            // UNVERIFIED: service-level SSL beyond the session upgrade is
            // not covered by the examined sources. Fail loudly.
            throw LockdownError.tlsFailed("diagnostics_relay asked for service-level SSL; no verified flow")
        }
        let svc = LockdownClient()
        try await svc.connect(toPort: port)
        do {
            // A dropped connection right after Restart means the reboot
            // started — accept it as success (documented, not assumed blindly:
            // only the immediate post-send drop counts).
            _ = try await svc.transact(["Request": "Restart"], expect: "Restart")
        } catch LockdownError.ioError(let s) where s.contains("closed by peer") {
            // Device is rebooting; the socket died with it.
        } catch {
            // A received response is checked for Error by transact already.
            throw error
        }
        svc.close()
    }

    /// Connect to a non-lockdown service port (same plist framing).
    func connect(toPort port: UInt16) async throws {
        try await socket.connect(host: Self.host, port: Int(port))
    }
}
