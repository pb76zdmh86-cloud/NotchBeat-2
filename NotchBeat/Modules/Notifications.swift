import Foundation
import UserNotifications

@MainActor enum LocalNotifications {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func schedule(id: String, title: String, body: String, at date: Date) {
        guard date.timeIntervalSinceNow > 0 else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    static func cancel(_ ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
}
