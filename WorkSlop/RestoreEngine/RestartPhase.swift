import Foundation
import UserNotifications

// MARK: - Phase 5: RESTART (with restart notification)
//
// Tries the lockdown reboot first. If a transport ever throws
// `.unimplemented` (none currently does), the phase degrades HONESTLY:
// it schedules a real local notification telling the user to restart
// manually, and reports `.manualRestartNotified` — never
// `.deviceRebooted`.

enum RestartPhase {
    enum Result: Sendable {
        /// The device rebooted over lockdown. bootVerified=false does NOT
        /// mean bricked — only that it hasn't come back on the wire yet
        /// (still booting, or stuck on the Apple logo). Reported honestly.
        case deviceRebooted(bootVerified: Bool)
        /// No transport: a real local notification was scheduled asking
        /// the user to restart manually. `notificationScheduled` is false
        /// when notifications are denied — also reported honestly.
        case manualRestartNotified(notificationScheduled: Bool)
    }

    static func run(
        transport: DeviceTransport,
        progress: @Sendable (RestoreProgress) -> Void
    ) async throws -> Result {
        progress(RestoreProgress(phase: .restart, fraction: 0.10, message: "Restarting device…"))
        do {
            try await transport.rebootDevice()
        } catch let error as RestoreError {
            // Only the missing-transport case degrades to manual.
            // Anything else is a real failure and propagates.
            guard case .unimplemented = error else { throw error }
            progress(RestoreProgress(phase: .restart, fraction: 0.50, message: "Scheduling restart reminder…"))
            let scheduled = await scheduleRestartNotification()
            progress(RestoreProgress(
                phase: .restart,
                fraction: 1.0,
                message: scheduled ? "Restart reminder scheduled — please restart your iPhone."
                                   : "Could not schedule the reminder (notifications denied) — please restart your iPhone manually."
            ))
            return .manualRestartNotified(notificationScheduled: scheduled)
        }

        // The reboot kills this app too — we run ON the device we just
        // rebooted. Post-reboot polling from inside the rebooted device
        // is impossible (the process dies with the reboot), so there is
        // no wait here: the reboot command was accepted (the socket
        // dropped right after Restart), and the user reopens the app
        // after the device boots. bootVerified=false is honest here —
        // never a success claim, never a brick verdict.
        progress(RestoreProgress(
            phase: .restart,
            fraction: 1.0,
            message: "Reboot command sent — the app closes as the device restarts. " +
                     "Reopen WorkSlop after the device boots; the full backup is kept on this device."
        ))
        return .deviceRebooted(bootVerified: false)
    }

    private static func scheduleRestartNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return false }
        case .denied:
            return false
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "Restart your iPhone"
        content.body = "WorkSlop finished applying tweaks. Restart now so the changes take effect."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "workslop-restart-reminder",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
