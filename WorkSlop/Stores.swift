import SwiftUI

/// Device + gate state for the whole app, in ONE place.
///
/// The old UI probed the VPN tunnel and the pairing file from
/// several views (and once per row per render, before the perf
/// fixes). Every row now reads this single object from the
/// environment — no per-row probing, no per-row @AppStorage.
final class StatusStore: ObservableObject {
    @Published private(set) var vpnDetected: Bool
    @Published private(set) var pairingImported: Bool
    @Published private(set) var probing = false

    /// The activation gate: no tweak toggles on before BOTH the
    /// pairing file is imported AND a VPN tunnel is up.
    var unlocked: Bool { vpnDetected && pairingImported }

    init() {
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
    }

    /// Re-probe tunnel + pairing file, then ask lockdownd whether it
    /// answers on the tunnel (the real two-phase check).
    func refresh() {
        guard !probing else { return }
        probing = true
        vpnDetected = DeviceStatus.vpnTunnelActive()
        pairingImported = PairingStore.isImported
        LockdownProbe.probe { [weak self] _ in
            DispatchQueue.main.async {
                self?.probing = false
            }
        }
    }

    /// Called after import/delete so the rows update without a refresh.
    func pairingChanged() {
        pairingImported = PairingStore.isImported
    }
}

/// Staged custom icons, shared by the Your Icons table and all
/// three gallery tables so every row sees the same staged set.
/// Single writer to CustomIconStore.
final class IconStage: ObservableObject {
    @Published var entries: [CustomIconEntry] = CustomIconStore.load()

    func isStaged(bundleID: String) -> Bool {
        entries.contains { $0.bundleID == bundleID }
    }

    func stage(_ entry: CustomIconEntry) {
        if let i = entries.firstIndex(where: { $0.bundleID == entry.bundleID }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        CustomIconStore.save(entries)
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        CustomIconStore.save(entries)
    }

    /// Appends a blank entry for the editor; returns its index.
    func addBlank() -> Int {
        entries.append(CustomIconEntry())
        CustomIconStore.save(entries)
        return entries.count - 1
    }

    /// Writes back an edited draft, matched by stable UUID (never by
    /// index). Falls back to append if the entry vanished mid-edit.
    func update(_ entry: CustomIconEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        CustomIconStore.save(entries)
    }

    func save() {
        CustomIconStore.save(entries)
    }
}
