import Foundation
import SQLite3

// PORT from GoldenNugget-mobile (Nugget/Core/HostManifests.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// The three host-side backup metadata files.

/// `SQLITE_TRANSIENT` is a C macro; the module never sees it. It is `-1`:
/// tell sqlite to copy the bytes rather than keep the pointer.
let SQLITE_TRANSIENT_HOST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Status.plist / Manifest.plist / Info.plist — written before any backup
/// exchange, because the device's first DL message requests them.
enum HostManifests {
    /// The `BackupKeyBag` blob for `Manifest.plist`, byte for byte what the
    /// reference hardcodes (src/restore/backup.py:244). libimobiledevice's
    /// public backup keybag — carries no device identity, so the same blob
    /// serves every device. Omit it and the device pulls all the payloads,
    /// then refuses with MBErrorDomain/205 "No keybag in manifest".
    static let backupKeyBag = Data(base64Encoded: backupKeyBagBase64)!
    static let backupKeyBagBase64 = """
        VkVSUwAAAAQAAAAFVFlQRQAAAAQAAAABVVVJRAAAABDud41d1b9NBICR1BH9JfVtSE1DSwAAACgAAAAAAAAAAAAAAAAAAAAA\
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAV1JBUAAAAAQAAAAAU0FMVAAAABRY5Ne2bthGQ5rf4O3gikep1e6tZUlURVIAAAAE\
        AAAnEFVVSUQAAAAQB7R8awiGR9aba1UuVahGPENMQVMAAAAEAAAAAVdSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAo\
        N3kQAJloFg+ukEUY+v5P+dhc/Welw/oucsyS40UBh67ZHef5ZMk9UVVVSUQAAAAQgd0cg0hSTgaxR3PVUbcEkUNMQVMAAAAE\
        AAAAAldSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAoMiQTXx0SJlyrGJzdKZQ+SfL124w+2Tf/3d1R2i9yNj9zZCHN\
        JhnorVVVSUQAAAAQf7JFQiBOS12JDD7qwKNTSkNMQVMAAAAEAAAAA1dSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAo\
        SEelorROJA46ZUdwDHhMKiRguQyqHukotrxhjIfqiZ5ESBXX9txi51VVSUQAAAAQfF0G/837QLq01xH9+66vx0NMQVMAAAAE\
        AAAABFdSQVAAAAAEAAAAAktUWVAAAAAEAAAAAFdQS1kAAAAol0BvFhd5bu4Hr75XqzNf4g0fMqZAie6OxI+x/pgm6Y95XW17\
        N+ZIDVVVSUQAAAAQimkT2dp1QeadMu1KhJKNTUNMQVMAAAAEAAAABVdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        2N2DZarQ6GPoWRgTiy/tdjKArOqTaH0tPSG9KLbIjGTOcLodhx23xFVVSUQAAAAQQV37JVZHQFiKpoNiGmT6+ENMQVMAAAAE\
        AAAABldSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAofe2QSvDC2cV7Etk4fSBbgqDx5ne/z1VHwmJ6NdVrTyWi80Sy\
        869DM1VVSUQAAAAQFzkdH+VgSOmTj3yEcfWmMUNMQVMAAAAEAAAAB1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        7kLYPQ/DnHBERGpaz37eyntIX/XzovsS0mpHW3SoHvrb9RBgOB+WblVVSUQAAAAQEBpgKOz9Tni8F9kmSXd0sENMQVMAAAAE\
        AAAACFdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo5mxVoyNFgPMzphYhm1VG8Fhsin/xX+r6mCd9gByF5SxeolAI\
        T/ICF1VVSUQAAAAQrfKB2uPSQtWh82yx6w4BoUNMQVMAAAAEAAAACVdSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        5iayZBwcRa1c1MMx7vh6lOYux3oDI/bdxFCW1WHCQR/Ub1MOv+QaYFVVSUQAAAAQiLXvK3qvQza/mea5inss/0NMQVMAAAAE\
        AAAACldSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAoD2wHX7KriEe1E31z7SQ7/+AVymcpARMYnQgegtZD0Mq2U55u\
        xwNr2FVVSUQAAAAQ/Q9feZxLS++qSe/a4emRRENMQVMAAAAEAAAAC1dSQVAAAAAEAAAAA0tUWVAAAAAEAAAAAFdQS1kAAAAo\
        cYda2jyYzzSKggRPw/qgh6QPESlkZedgDUKpTr4ZZ8FDgd7YoALY1g==
        """

    /// Write Status.plist / Manifest.plist / Info.plist if missing.
    /// - isFullBackup: false = sparse (injector's restore), true = protective pull.
    /// - applications: App records under `Applications` — what makes the device
    ///   upload app containers; nil leaves the empty dict a protective backup wants.
    static func ensure(deviceDir: URL,
                       udid: String,
                       ios27: Bool = true,
                       isFullBackup: Bool = false,
                       applications: [String: [String: Any]]? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)

        // The version split is the reference's: backup.py:113 manifest_ios27,
        // set from restore.py:1065-1074. iOS 26 speaks the legacy MBDB format
        // and declares Status 2.4 / Manifest 9.1+20.0; iOS 27+ uses the sqlite
        // Manifest.db and 3.3 / 10.0+24.0.
        let statusURL = deviceDir.appendingPathComponent("Status.plist")
        if !fm.fileExists(atPath: statusURL.path) || isFullBackup {
            let status: [String: Any] = [
                "BackupState": "new",
                "Date": Date(),
                "IsFullBackup": isFullBackup,
                "Version": ios27 ? "3.3" : "2.4",
                "SnapshotState": "finished",
                "UUID": UUID().uuidString.uppercased(),
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: status,
                                                              format: .binary, options: 0) {
                try? data.write(to: statusURL)
            }
        }

        // Manifest.plist — the keybag is not optional. AppDomain payloads also
        // have to be registered here: without a matching Applications entry,
        // mobilebackup2 rejects the file row with MBErrorDomain/205
        // "Unknown domain name in file record".
        let manifestURL = deviceDir.appendingPathComponent("Manifest.plist")
        if !fm.fileExists(atPath: manifestURL.path) || applications != nil {
            var manifest: [String: Any]
            if fm.fileExists(atPath: manifestURL.path),
               let data = try? Data(contentsOf: manifestURL),
               let existing = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any] {
                manifest = existing
            } else {
                manifest = [
                    "DataProtection": true,
                    "BackupKeyBag": backupKeyBag,
                    "IsEncrypted": false,
                    "ManifestKey": Data(),
                    "Version": ios27 ? "10.0" : "9.1",
                    "SystemDomainsVersion": ios27 ? "24.0" : "20.0",
                ]
            }
            var apps: [String: [String: Any]] =
                (manifest["Applications"] as? [String: [String: Any]]) ?? [:]
            for (bundleID, record) in (applications ?? [:]) {
                apps[bundleID] = record
            }
            manifest["Applications"] = apps
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: manifest, format: .binary, options: 0) {
                try? data.write(to: manifestURL)
            }
        }

        // Info.plist — the device lists it in its DL exchange as well.
        let infoURL = deviceDir.appendingPathComponent("Info.plist")
        if !fm.fileExists(atPath: infoURL.path) || applications != nil {
            let info: [String: Any] = [
                "TargetIdentifier": udid,
                "Unique Identifier": udid,
                "Device Name": "iPhone",
                "Display Name": "iPhone",
                "Product Type": "iPhone",
                "Last Backup Date": Date(),
                "IsEncrypted": false,
                "System Build Version": "24A5430a",
            ]
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: info, format: .binary, options: 0) {
                try? data.write(to: infoURL)
            }
        }
    }
}
