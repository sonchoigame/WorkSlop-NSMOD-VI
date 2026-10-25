import Foundation

// PORT from GoldenNugget-mobile — the GoldenNugget apply pipeline adapted to
// WorkSlop's LoopbackTransport (mobilebackup2 over the loopback tunnel).
//
// Flow (GoldenNuggetEngine._apply_tweak_pass, ported):
//   1. Compile the selection to plists — before the device is touched.
//   2. HostManifests.ensure writes Status/Manifest/Info (with the keybag).
//   3. The compiled payloads ride the existing PartialRestoreEngine /
//      RestoreEngine push (mobilebackup2 sparse restore on iOS 26; the
//      full engine on iOS 27).
//   4. The device's own verdict decides success — never local bookkeeping.

/// Gate: which tweaks a device's iOS version may switch on. THE RULE the
/// owner set:
///   - iOS ≤ 26 (any 16–26): every tweak in the catalog is available.
///   - iOS 27: ONLY these four remain active:
///       1. Disable Liquid Glass (ForceSolariumFallback)
///       2. PosterBoard
///       3. Custom Icons
///       4. AirFlit (AirCard)
///     Everything else is hidden/locked on 27.
enum TweakGate {
    /// The four feature IDs allowed on iOS 27.
    static let ios27Allowed: Set<String> = [
        "ForceSolariumFallback",   // Disable Liquid Glass
        "posterboard",
        "custom-icons",
        "airflit",
    ]

    /// Which catalog IDs are available on this device version.
    static func availableIDs(major: Int) -> Set<String> {
        guard major >= 27 else {
            // 16–26: everything the registry defines.
            return Set(TweakCatalog.all.map { $0.id })
        }
        return ios27Allowed
    }

    /// Registry specs still applicable on this device.
    static func applicableSpecs(major: Int) -> [TweakSpec] {
        TweakCatalog.all.filter { availableIDs(major: major).contains($0.id) }
    }
}

/// The apply pipeline ported from GoldenNuggetEngine._apply_tweak_pass onto
/// WorkSlop's restore machinery.
enum GoldenNuggetPort {
    /// Compile the current selection into payloads, honoring the iOS gate.
    /// Returns nil reason when nothing survived.
    static func compile(selection: TweakSelection,
                        deviceVersion: String,
                        isIPhone: Bool) -> TweakCompiler.Result {
        TweakCompiler.compile(selection: selection,
                              deviceVersion: deviceVersion,
                              isIPhone: isIPhone)
    }

    /// Build a TweakSelection from the app's existing staged feature IDs
    /// (SelectionStore.staged), mapping the old WorkSlop IDs onto the
    /// GoldenNugget registry where they overlap.
    static func selection(fromStagedIDs staged: Set<String>) -> TweakSelection {
        var sel = TweakSelection()
        for spec in TweakCatalog.all where staged.contains(spec.id) {
            sel.setOn(spec.id, true)
            sel.setValue(spec.id, spec.value)
        }
        return sel
    }

    /// Human summary for the log.
    static func logLine(_ result: TweakCompiler.Result) -> String {
        var lines: [String] = []
        lines.append("compiled \(result.payloads.count) payload(s) over \(result.locations.count) location(s)")
        for p in result.payloads {
            lines.append("→ \(p.label) (\(p.contents.count) B)")
        }
        for (label, reason) in result.skipped {
            lines.append("skip \(label): \(reason)")
        }
        return lines.joined(separator: "\n")
    }
}
