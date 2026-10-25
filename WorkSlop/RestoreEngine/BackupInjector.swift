import Foundation
import CryptoKit
import SQLite3

// MARK: - Minimal bplist00 writer
//
// Hand-rolled (not PropertyListSerialization) because Swift has no public
// UID type: decoding a donor blob's UID references and re-encoding them
// would silently corrupt the archive (a UID decoded as Int re-encodes as
// a plain integer, not a UID). The emitted archive layout is validated
// field-for-field against desktop's _build_mbfile_blob/_build_mbdir_blob:
//   $objects == ["$null", info, path, digest, extattrs, classdict]
//   cross-references as UID objects (RelativePath -> UID(2), ...)
// Only the object types the MBFile blobs need are supported.

enum BPlist {
    /// One object-table entry. Containers hold child INDICES — bplist
    /// stores every nested value by reference (objectRefSize = 1).
    enum Object {
        case string(String)
        case data(Data)
        case int(Int)
        /// A UID *object* in the table (0x80...), for cross-references
        /// between archive objects. NOT the same as a raw index.
        case uid(Int)
        case array([Int])
        case dict([(key: Int, value: Int)])
    }

    struct Encoder {
        private(set) var objects: [Object] = []

        mutating func add(_ o: Object) -> Int {
            objects.append(o)
            return objects.count - 1
        }

        mutating func addString(_ s: String) -> Int { add(.string(s)) }
        mutating func addInt(_ v: Int) -> Int { add(.int(v)) }
        mutating func addData(_ d: Data) -> Int { add(.data(d)) }
        /// Adds a UID object pointing at `index`.
        mutating func addUID(to index: Int) -> Int { add(.uid(index)) }
        mutating func set(_ o: Object, at index: Int) { objects[index] = o }

        func encode(topIndex: Int) -> Data {
            precondition(objects.count < 256, "objectRefSize=1 supports <256 objects")
            var buf = Data("bplist00".utf8)
            var offsets: [Int] = []
            offsets.reserveCapacity(objects.count)
            for o in objects {
                offsets.append(buf.count)
                encodeObject(o, into: &buf)
            }
            let tableOffset = buf.count
            let maxOff = offsets.max() ?? 0
            let offSize = maxOff < 256 ? 1 : (maxOff < 65536 ? 2 : 4)
            for off in offsets {
                for i in stride(from: offSize - 1, through: 0, by: -1) {
                    buf.append(UInt8((off >> (i * 8)) & 0xFF))
                }
            }
            // Trailer: 6 unused bytes, offsetIntSize, objectRefSize,
            // numObjects, topObject, offsetTableOffset (all 8-byte BE).
            buf.append(contentsOf: [UInt8](repeating: 0, count: 6))
            buf.append(UInt8(offSize))
            buf.append(1)
            append64(UInt64(objects.count), into: &buf)
            append64(UInt64(topIndex), into: &buf)
            append64(UInt64(tableOffset), into: &buf)
            return buf
        }

        private func encodeObject(_ o: Object, into buf: inout Data) {
            switch o {
            case .int(let v):
                precondition(v >= 0, "bplist writer: negative int unsupported")
                encodeIntValue(v, into: &buf)
            case .string(let s):
                if let ascii = s.data(using: .ascii) {
                    encodeLength(base: 0x50, count: ascii.count, into: &buf)
                    buf.append(ascii)
                } else {
                    // Unicode string: count is UTF-16 code units.
                    var u16 = Data()
                    u16.reserveCapacity(s.utf16.count * 2)
                    for unit in s.utf16 {
                        append16(unit, into: &u16)
                    }
                    encodeLength(base: 0x60, count: s.utf16.count, into: &buf)
                    buf.append(u16)
                }
            case .data(let d):
                encodeLength(base: 0x40, count: d.count, into: &buf)
                buf.append(d)
            case .uid(let i):
                precondition(i >= 0)
                if i < 0x100 {
                    buf.append(0x80); buf.append(UInt8(i))
                } else {
                    buf.append(0x81); append16(UInt16(i), into: &buf)
                }
            case .array(let idx):
                encodeLength(base: 0xA0, count: idx.count, into: &buf)
                for i in idx {
                    precondition(i < 256)
                    buf.append(UInt8(i))
                }
            case .dict(let pairs):
                encodeLength(base: 0xD0, count: pairs.count, into: &buf)
                for (k, _) in pairs {
                    precondition(k < 256)
                    buf.append(UInt8(k))
                }
                for (_, v) in pairs {
                    precondition(v < 256)
                    buf.append(UInt8(v))
                }
            }
        }

        private func encodeIntValue(_ v: Int, into buf: inout Data) {
            if v < 0x100 { buf.append(0x10); buf.append(UInt8(v)) }
            else if v < 0x10000 { buf.append(0x11); append16(UInt16(v), into: &buf) }
            else if v < 0x1_0000_0000 { buf.append(0x12); append32(UInt32(v), into: &buf) }
            else { buf.append(0x13); append64(UInt64(v), into: &buf) }
        }

        private func encodeLength(base: UInt8, count: Int, into buf: inout Data) {
            if count < 15 {
                buf.append(base | UInt8(count))
            } else {
                buf.append(base | 0x0F)
                encodeIntValue(count, into: &buf)
            }
        }

        private func append16(_ v: UInt16, into buf: inout Data) {
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }

        private func append32(_ v: UInt32, into buf: inout Data) {
            for i in stride(from: 3, through: 0, by: -1) {
                buf.append(UInt8((v >> UInt32(i * 8)) & 0xFF))
            }
        }

        private func append64(_ v: UInt64, into buf: inout Data) {
            for i in stride(from: 7, through: 0, by: -1) {
                buf.append(UInt8((v >> UInt64(i * 8)) & 0xFF))
            }
        }
    }
}

// MARK: - MBFile archive blobs

/// NSKeyedArchiver MBFile blobs for Manifest.db `file` column rows.
/// Field layout mirrors desktop's _build_mbfile_blob/_build_mbdir_blob
/// (validated field-for-field against them). The inode is stamped by the
/// caller and MUST be unique per row: the iOS 27 restore agent
/// deduplicates by inode — a row sharing its donor's inode gets restored
/// with the DONOR's content, and a blob without an inode is skipped
/// outright (desktop inject.py).
enum MBFileBlob {
    /// Data-protection exception extended attributes, same as
    /// IconState.plist and friends. A plain dict — no UID references —
    /// so PropertyListSerialization is safe here.
    private static func extAttrs() -> Data {
        let dict = ["com.apple.dataprotection.policy.exception-applied-by":
                        Data("com.apple.springboard".utf8)]
        return (try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
    }

    /// Regular-file blob for a flags=1 row.
    static func file(relativePath: String, contents: Data,
                     mode: Int, owner: Int, group: Int, inode: Int64) -> Data {
        var e = BPlist.Encoder()
        let now = Int(Date().timeIntervalSince1970)
        let digest = Data(Insecure.SHA1.hash(data: contents))
        e.add(.string("$null"))                       // 0
        let infoSlot = e.add(.dict([]))               // 1
        let pathI = e.addString(relativePath)         // 2
        let digestI = e.addData(digest)                // 3
        let extI = e.addData(extAttrs())               // 4
        let classSlot = e.add(.dict([]))              // 5
        // Class descriptor: fully inline (desktop: plain strings/array).
        let mb1 = e.addString("MBFile"), ns1 = e.addString("NSObject")
        e.set(.dict([
            (key: e.addString("$classname"), value: e.addString("MBFile")),
            (key: e.addString("$classes"), value: e.add(.array([mb1, ns1]))),
        ]), at: classSlot)
        e.set(.dict([
            (key: e.addString("Birth"), value: e.addInt(now)),
            (key: e.addString("LastModified"), value: e.addInt(now)),
            (key: e.addString("LastStatusChange"), value: e.addInt(now)),
            (key: e.addString("Flags"), value: e.addInt(0)),
            (key: e.addString("GroupID"), value: e.addInt(group)),
            (key: e.addString("UserID"), value: e.addInt(owner)),
            (key: e.addString("Mode"), value: e.addInt(mode)),
            (key: e.addString("ProtectionClass"), value: e.addInt(4)),
            (key: e.addString("Size"), value: e.addInt(contents.count)),
            (key: e.addString("RelativePath"), value: e.addUID(to: pathI)),
            (key: e.addString("Digest"), value: e.addUID(to: digestI)),
            (key: e.addString("ExtendedAttributes"), value: e.addUID(to: extI)),
            (key: e.addString("InodeNumber"), value: e.addInt(Int(inode))),
            (key: e.addString("$class"), value: e.addUID(to: classSlot)),
        ]), at: infoSlot)
        let objsArr = e.add(.array([0, 1, 2, 3, 4, 5]))
        let top = e.add(.dict([
            (key: e.addString("$version"), value: e.addInt(100000)),
            (key: e.addString("$archiver"), value: e.addString("NSKeyedArchiver")),
            (key: e.addString("$top"), value: e.add(.dict([
                (key: e.addString("root"), value: e.addUID(to: infoSlot)),
            ]))),
            (key: e.addString("$objects"), value: e.addUID(to: objsArr)),
        ]))
        return e.encode(topIndex: top)
    }

    /// Directory blob for a flags=2 row (desktop _build_mbdir_blob).
    static func dir(relativePath: String, inode: Int64) -> Data {
        var e = BPlist.Encoder()
        let now = Int(Date().timeIntervalSince1970)
        e.add(.string("$null"))                       // 0
        let infoSlot = e.add(.dict([]))               // 1
        let pathI = e.addString(relativePath)         // 2
        let classSlot = e.add(.dict([]))              // 3
        let mb1 = e.addString("MBFile"), ns1 = e.addString("NSObject")
        e.set(.dict([
            (key: e.addString("$classname"), value: e.addString("MBFile")),
            (key: e.addString("$classes"), value: e.add(.array([mb1, ns1]))),
        ]), at: classSlot)
        e.set(.dict([
            (key: e.addString("Birth"), value: e.addInt(now)),
            (key: e.addString("LastModified"), value: e.addInt(now)),
            (key: e.addString("LastStatusChange"), value: e.addInt(now)),
            (key: e.addString("Flags"), value: e.addInt(0)),
            (key: e.addString("GroupID"), value: e.addInt(501)),
            (key: e.addString("UserID"), value: e.addInt(501)),
            (key: e.addString("Mode"), value: e.addInt(0o40755)),
            (key: e.addString("ProtectionClass"), value: e.addInt(4)),
            (key: e.addString("Size"), value: e.addInt(0)),
            (key: e.addString("RelativePath"), value: e.addUID(to: pathI)),
            (key: e.addString("InodeNumber"), value: e.addInt(Int(inode))),
            (key: e.addString("$class"), value: e.addUID(to: classSlot)),
        ]), at: infoSlot)
        let objsArr = e.add(.array([0, 1, 2, 3]))
        let top = e.add(.dict([
            (key: e.addString("$version"), value: e.addInt(100000)),
            (key: e.addString("$archiver"), value: e.addString("NSKeyedArchiver")),
            (key: e.addString("$top"), value: e.add(.dict([
                (key: e.addString("root"), value: e.addUID(to: infoSlot)),
            ]))),
            (key: e.addString("$objects"), value: e.addUID(to: objsArr)),
        ]))
        return e.encode(topIndex: top)
    }
}

// MARK: - Backup injector (the real MODIF)

/// Injects payload files into the PULLED backup, in Apple layout:
///   - bytes at <backupRoot>/<aa>/<fileID>  (aa = first 2 hex of fileID)
///   - Manifest.db row (fileID, domain, relativePath, flags=1) with a
///     hand-built MBFile blob carrying a UNIQUE inode
///   - parent directory rows (flags=2), also with unique inodes —
///     the agent skips a file whose parent dirs have no rows
///     (desktop: inject_files_into_backup / _ensure_directory_rows).
///
/// What was wrong before (now fixed): ModifyPhase wrote a
/// <domain>/<relativePath> tree nobody read, and ManifestDBPatcher
/// copied the donor blob VERBATIM — shared inode, so the agent would
/// restore the donor's content, not the payload.
struct BackupInjector {
    struct FileTarget: Sendable {
        let domain: String
        let relativePath: String
        let contents: Data
    }

    struct Result: Sendable {
        /// fileID → on-disk blob URL (<aa>/<fileID>), for the restore resolver.
        let fileIDMap: [String: URL]
        let injectedCount: Int
        let dirRowsAdded: Int
    }

    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Standard fileID: hex SHA1("domain-relativePath").
    static func fileID(domain: String, relativePath: String) -> String {
        sha1Hex("\(domain)-\(relativePath)")
    }

    /// Apple-layout blob URL: <backupRoot>/<aa>/<fileID>.
    static func blobURL(backupRoot: URL, fileID: String) -> URL {
        backupRoot
            .appendingPathComponent(String(fileID.prefix(2)), isDirectory: true)
            .appendingPathComponent(fileID)
    }

    // MARK: encrypted-backup refusal

    /// Plaintext injection into an encrypted backup has no matching
    /// wrapped key — the restore agent fails it with MBErrorDomain/205
    /// (desktop: _is_encrypted_backup / inject.py:317). Refuse loudly.
    static func isEncryptedBackup(at backupRoot: URL) -> Bool {
        let url = backupRoot.appendingPathComponent("Manifest.plist")
        guard let data = try? Data(contentsOf: url) else { return false }
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &fmt) as? [String: Any]
        else { return false }
        return (plist["IsEncrypted"] as? Bool) == true
    }

    // MARK: inject

    static func inject(backupRoot: URL, files: [FileTarget]) throws -> Result {
        guard !isEncryptedBackup(at: backupRoot) else {
            throw RestoreError.phaseFailed(
                phase: .modify,
                message: "Backup is encrypted (Manifest.plist IsEncrypted). Plaintext injection " +
                "has no matching key — refusing. Turn off backup encryption and pull a fresh backup.")
        }
        let dbURL = backupRoot.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw RestoreError.phaseFailed(
                phase: .modify, message: "Manifest.db missing in pulled backup — cannot register payload rows.")
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db else {
            throw RestoreError.phaseFailed(phase: .modify, message: "Cannot open Manifest.db.")
        }
        defer { sqlite3_close(db) }
        guard tableExists(db, "Files") else {
            throw RestoreError.phaseFailed(
                phase: .modify, message: "Manifest.db has no Files table — refusing to guess the schema.")
        }

        // Unique inode counter, seeded above every inode the backup
        // already claims (desktop: _max_inode_in_manifest).
        var nextInode = maxInode(in: db) + 1
        var knownDirs = Set<String>()
        var fileIDMap: [String: URL] = [:]
        var dirRowsAdded = 0

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw RestoreError.phaseFailed(phase: .modify, message: "Manifest.db: cannot begin transaction.")
        }
        do {
            for f in files {
                let fid = fileID(domain: f.domain, relativePath: f.relativePath)
                // Parent directory rows FIRST (agent skips files whose
                // parent dirs have no rows).
                let advanced = try ensureDirRows(
                    db: db, domain: f.domain, relativePath: f.relativePath,
                    nextInode: nextInode, knownDirs: &knownDirs)
                nextInode = advanced.nextInode
                dirRowsAdded += advanced.added

                // Mode normalize (desktop): regular file, 0644-style.
                let mode = 0o100644

                // The inode MUST be unique per row — never the donor's.
                let blob = MBFileBlob.file(
                    relativePath: f.relativePath, contents: f.contents,
                    mode: mode, owner: 501, group: 501, inode: nextInode)
                nextInode += 1

                let url = blobURL(backupRoot: backupRoot, fileID: fid)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Bytes already match: leave the file alone, just make sure
                // the row exists (desktop: unchanged).
                if (try? Data(contentsOf: url)) != f.contents {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try f.contents.write(to: url, options: .atomic)
                }
                try insertRow(db: db, fileID: fid, domain: f.domain,
                              relativePath: f.relativePath, flags: 1, blob: blob)
                fileIDMap[fid] = url
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw RestoreError.phaseFailed(
                    phase: .modify, message: "Manifest.db: commit failed: \(sqliteError(db))")
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return Result(fileIDMap: fileIDMap, injectedCount: files.count, dirRowsAdded: dirRowsAdded)
    }

    // MARK: verification gate

    /// Re-read every injected payload and confirm it is deliverable
    /// (desktop: _verify_injected_files). Returns problem strings —
    /// empty = all good. The restore is REFUSED unless this is clean.
    static func verify(backupRoot: URL, files: [FileTarget]) -> [String] {
        var problems: [String] = []
        var rows: [String: (domain: String, rel: String, flags: Int64)] = [:]
        let dbURL = backupRoot.appendingPathComponent("Manifest.db")
        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db = db {
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db,
                    "SELECT fileID, domain, relativePath, flags FROM Files",
                    -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let fid = columnString(stmt, 0),
                          let dom = columnString(stmt, 1),
                          let rel = columnString(stmt, 2)
                    else { continue }
                    rows[fid] = (dom, rel, sqlite3_column_int64(stmt, 3))
                }
            } else {
                problems.append("Manifest.db unreadable for verification.")
            }
        } else {
            problems.append("Manifest.db missing from the backup — manifest rows cannot be verified.")
        }

        for f in files {
            let fid = fileID(domain: f.domain, relativePath: f.relativePath)
            let url = blobURL(backupRoot: backupRoot, fileID: fid)
            guard let onDisk = try? Data(contentsOf: url) else {
                problems.append("\(f.domain)/\(f.relativePath): payload not found in backup after injection (<aa>/<fileID>)")
                continue
            }
            if onDisk != f.contents {
                problems.append("\(f.domain)/\(f.relativePath): content mismatch after injection " +
                                "(expected \(f.contents.count) bytes, found \(onDisk.count))")
            }
            guard let row = rows[fid] else {
                problems.append("\(f.domain)/\(f.relativePath): no Manifest.db row — the restore agent would skip it")
                continue
            }
            if row.domain != f.domain || row.rel != f.relativePath {
                problems.append("\(f.domain)/\(f.relativePath): Manifest.db row mismatch " +
                                "(row says \(row.domain)/\(row.rel)) — the agent would not deliver this file")
            }
            if row.flags != 1 {
                problems.append("\(f.domain)/\(f.relativePath): Manifest.db flags=\(row.flags) (expected 1 for a regular file)")
            }
        }
        return problems
    }

    // MARK: - internals

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                -1, &stmt, nil) == SQLITE_OK, let stmt = stmt
        else { return false }
        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient())
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func sqliteTransient() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// sqlite3_column_text returns UInt8 bytes owned by SQLite — copy them
    /// out as a Swift String before the next step invalidates the pointer.
    private static func columnString(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return ptr.withMemoryRebound(to: CChar.self, capacity: n + 1) {
            String(cString: $0)
        }
    }

    private static func sqliteError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    /// Largest InodeNumber claimed by any regular/directory row (0 when
    /// none has one). Blobs are decoded read-only; only the plain-int
    /// InodeNumber is read — UID objects are never touched.
    private static func maxInode(in db: OpaquePointer) -> Int64 {
        var maxIno: Int64 = 0
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
                "SELECT file FROM Files WHERE flags IN (1,2) AND file IS NOT NULL",
                -1, &stmt, nil) == SQLITE_OK, let stmt = stmt
        else { return 0 }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0 else { continue }
            let blob = Data(bytes: bytes, count: count)
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            guard let plist = try? PropertyListSerialization.propertyList(
                    from: blob, options: [], format: &fmt) as? [String: Any],
                  let objects = plist["$objects"] as? [Any],
                  objects.count > 1,
                  let info = objects[1] as? [String: Any]
            else { continue }
            if let ino = info["InodeNumber"] as? NSNumber {
                maxIno = max(maxIno, ino.int64Value)
            } else if let ino = info["InodeNumber"] as? Int {
                maxIno = max(maxIno, Int64(ino))
            }
        }
        return maxIno
    }

    /// Insert flags=2 directory rows for the domain root and every missing
    /// path component (desktop: _ensure_directory_rows). Each new row gets
    /// a unique inode from the shared counter.
    private static func ensureDirRows(db: OpaquePointer, domain: String,
                                      relativePath: String, nextInode: Int64,
                                      knownDirs: inout Set<String>)
    throws -> (nextInode: Int64, added: Int) {
        var inode = nextInode
        var added = 0
        // Chain: "" (domain root) + each intermediate component.
        var chain: [String] = [""]
        let dirPath = (relativePath as NSString).deletingLastPathComponent
        var acc = ""
        for comp in dirPath.split(separator: "/") {
            acc = acc.isEmpty ? String(comp) : acc + "/" + comp
            chain.append(acc)
        }
        for rel in chain {
            let key = domain + "\u{0}" + rel
            if knownDirs.contains(key) { continue }
            if dirRowExists(db: db, domain: domain, relativePath: rel) {
                knownDirs.insert(key)
                continue
            }
            let blob = MBFileBlob.dir(relativePath: rel, inode: inode)
            inode += 1
            let fid = fileID(domain: domain, relativePath: rel)
            try insertRow(db: db, fileID: fid, domain: domain,
                          relativePath: rel, flags: 2, blob: blob)
            knownDirs.insert(key)
            added += 1
        }
        return (inode, added)
    }

    private static func dirRowExists(db: OpaquePointer, domain: String,
                                     relativePath: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
                "SELECT 1 FROM Files WHERE domain=? AND relativePath=? AND flags=2",
                -1, &stmt, nil) == SQLITE_OK, let stmt = stmt
        else { return false }
        sqlite3_bind_text(stmt, 1, domain, -1, sqliteTransient())
        sqlite3_bind_text(stmt, 2, relativePath, -1, sqliteTransient())
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func insertRow(db: OpaquePointer, fileID: String,
                                  domain: String, relativePath: String,
                                  flags: Int64, blob: Data) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) " +
                  "VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else {
            throw RestoreError.phaseFailed(
                phase: .modify, message: "Manifest.db prepare failed: \(sqliteError(db))")
        }
        sqlite3_bind_text(stmt, 1, fileID, -1, sqliteTransient())
        sqlite3_bind_text(stmt, 2, domain, -1, sqliteTransient())
        sqlite3_bind_text(stmt, 3, relativePath, -1, sqliteTransient())
        sqlite3_bind_int64(stmt, 4, flags)
        blob.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress,
                                  Int32(blob.count), sqliteTransient())
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RestoreError.phaseFailed(
                phase: .modify,
                message: "Manifest.db insert failed for \(domain):\(relativePath): \(sqliteError(db))")
        }
    }
}
