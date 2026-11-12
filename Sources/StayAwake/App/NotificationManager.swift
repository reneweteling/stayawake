import AppKit
import Foundation
import UserNotifications
import StayAwakeCore

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// UNUserNotificationCenter needs a real app bundle; a bare `swift run`
    /// binary would crash on first use.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var asked = false

    func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked on the first arm, when the user has a reason to expect a notification.
    func requestAuthorizationIfNeeded() {
        guard available, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(id: String, title: String, body: String, sound: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func notifyTrip(_ trip: TripInfo, at date: Date, timeZone: TimeZone) {
        post(id: "trip", title: "Sleep restored at \(Readout.clock(date, in: timeZone))", body: trip.message)
    }

    func notifyUnplugged() {
        post(id: "unplugged", title: "Unplugged", body: "Unplugged. StayAwake keeps this Mac awake on battery.")
    }

    func notifyHeadsUp(_ margin: RuleMargin) {
        post(id: "headsup-\(margin.rule.rawValue)", title: "StayAwake will stop soon", body: Readout.marginLine(margin))
    }

    func notifyArmed(_ text: String) {
        post(id: "armed", title: "StayAwake", body: text)
    }

    func playTripSound(named name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
