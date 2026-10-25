import Foundation

// PORT from GoldenNugget-mobile (Nugget/Core/TweakCompiler.swift)
// https://github.com/goldennugget-team/goldennugget-mobile
// The compile half of device_manager._apply_tweak_pass.

/// One file to deliver into the backup: the payload and where it belongs.
/// Swift counterpart of the reference's FileToRestore.
struct TweakPayload: Equatable {
    let domain: String
    let relativePath: String
    let contents: Data

    init(domain: String, relativePath: String, contents: Data) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = contents
    }

    /// A manifest row's relativePath, with no leading slash.
    /// (restore.py: `rel = f.restore_path.lstrip("/")` — a row that keeps the
    /// slash is what the device rejects with MBErrorDomain/205.)
    static func manifestPath(_ relativePath: String) -> String {
        var path = Substring(relativePath)
        while path.first == "/" { path = path.dropFirst() }
        return String(path)
    }

    var label: String { "\(domain)/\(relativePath)" }
}

/// Turns a tweak selection into the files a restore should carry.
enum TweakCompiler {
    struct Result {
        let payloads: [TweakPayload]
        let locations: [TweakFileLocation]
        let skipped: [(label: String, reason: String)]
    }

    /// Compile the selection to plists, merging per location. deviceVersion is
    /// the device's ProductVersion; isIPhone is ProductType.hasPrefix("iPhone").
    static func compile(
        selection: TweakSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) -> Result {
        var order: [TweakFileLocation] = []
        var plists: [TweakFileLocation: [String: Any]] = [:]
        var skipped: [(label: String, reason: String)] = []

        // allWithDaemons, not all: the daemon group specs are not registry
        // rows, and compiling only the registry would drop the launchd
        // disabled.plist entirely.
        for spec in TweakCatalog.allWithDaemons where !spec.disabled {
            let isOn: Bool
            if spec.id == DaemonGroups.launchdSpec.id {
                isOn = !DaemonGroups.enabledLabels(selection: selection).isEmpty
            } else {
                isOn = selection.isOn(spec)
            }
            guard isOn else { continue }
            guard spec.isCompatible(deviceVersion: deviceVersion, isIPhone: isIPhone) else {
                skipped.append((label: spec.title,
                                reason: "incompatible with iOS \(deviceVersion)"))
                continue
            }

            guard let dest = TweakDomainMap.split(path: spec.location.rawValue) else {
                skipped.append((label: spec.title,
                                reason: "no domain mapping for \(spec.location.rawValue)"))
                continue
            }

            // Map the absolute path to the file location this registry uses.
            guard let location = TweakFileLocation(rawValue: spec.location.rawValue) else {
                skipped.append((label: spec.title, reason: "unknown location"))
                continue
            }

            if plists[location] == nil {
                plists[location] = [:]
                order.append(location)
            }

            // Daemon carrier: merge every enabled group's labels as keys.
            if spec.id == DaemonGroups.launchdSpec.id {
                let labels = DaemonGroups.enabledLabels(selection: selection)
                for (label, value) in labels {
                    plists[location]?[label] = value
                }
                continue
            }

            let value = selection.value(for: spec) ?? spec.value
            plists[location]?[spec.key] = value.plistObject
        }

        // Serialise each location once — the merge is the whole point: all
        // Liquid Glass tweaks write into the same .GlobalPreferences.plist,
        // so emitting one file per tweak would leave only the last standing.
        var payloads: [TweakPayload] = []
        for location in order {
            guard let dict = plists[location], !dict.isEmpty else { continue }
            guard let dest = TweakDomainMap.split(path: location.rawValue) else { continue }
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: dict, format: .binary, options: 0) else {
                skipped.append((label: location.rawValue, reason: "plist serialization failed"))
                continue
            }
            payloads.append(TweakPayload(
                domain: dest.domain,
                relativePath: dest.relativePath,
                contents: data))
        }

        return Result(payloads: payloads, locations: order, skipped: skipped)
    }
}
