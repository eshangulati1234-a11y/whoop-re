import Foundation
import UserNotifications

/// Local notifications for detected workouts, saved workouts and sleep. Permission is requested
/// the first time the user turns a notification setting on, never at launch.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let detectedCategory = "WORKOUT_DETECTED"
    static let confirmAction = "CONFIRM_WORKOUT"
    static let dismissAction = "DISMISS_WORKOUT"

    /// Called with (detection id, confirmed?). Set by `HealthEngine`; actions that arrive earlier are queued.
    var onAction: ((String, Bool) -> Void)? {
        didSet { if let onAction { for item in queued { onAction(item.0, item.1) }; queued = [] } }
    }
    private var queued: [(String, Bool)] = []
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let confirm = UNNotificationAction(identifier: Self.confirmAction, title: "Save workout", options: [])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Not a workout", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.detectedCategory, actions: [confirm, dismiss], intentIdentifiers: [])])
    }

    enum Setting: String {
        case detections = "notifyDetections", workoutSaved = "notifyWorkoutSaved", sleep = "notifySleep", recovery = "notifyRecovery"
        var isOn: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
    }

    /// Ask the system for permission. Returns whether notifications are allowed.
    @discardableResult func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func isAllowed() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    private func post(id: String, thread: String, title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        Task {
            guard await isAllowed() else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.threadIdentifier = thread; content.userInfo = userInfo
            if let category { content.categoryIdentifier = category }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func postDetected(id: String, type: String, minutes: Int, avgHR: Int?) {
        guard Setting.detections.isOn else { return }
        let noun = type == "Running" ? "a run" : type == "Walking" ? "a walk" : type == "Cycling" ? "a ride" : type == "Strength" ? "a strength session" : "a workout"
        let detail = avgHR.map { " · avg \($0) BPM" } ?? ""
        post(id: "detected-\(id)", thread: id, title: "Workout detected", body: "Looks like \(noun), \(minutes) min\(detail). Save it?",
             category: Self.detectedCategory, userInfo: ["detection": id])
    }

    func postSaved(id: String, type: String, minutes: Int, strain: Double?, calories: Double?) {
        guard Setting.workoutSaved.isOn else { return }
        var parts = ["\(minutes) min"]
        if let strain { parts.append(String(format: "Strain %.1f", strain)) }
        if let calories { parts.append("\(Int(calories.rounded())) kcal") }
        post(id: "saved-\(id)", thread: id, title: "\(type) saved", body: parts.joined(separator: " · "))
    }

    func postSleep(day: Int, asleep: TimeInterval, performance: Double?) {
        guard Setting.sleep.isOn else { return }
        let total = Int(asleep / 60)
        var body = "\(total / 60)h \(total % 60)m asleep"
        if let performance { body += " · \(Int((performance * 100).rounded()))% of your sleep need" }
        post(id: "sleep-\(day)", thread: "sleep", title: "Sleep recorded", body: body)
    }

    func postRecovery(day: Int, score: Int, band: RecoveryBandKind, early: Bool) {
        guard Setting.recovery.isOn else { return }
        let word: String
        switch band {
        case .green: word = "You're well recovered"
        case .yellow: word = "A moderate day, listen to your body"
        case .red: word = "Take it easy today"
        }
        post(id: "recovery-\(day)", thread: "sleep", title: "Recovery \(score)%", body: word + (early ? " · still learning your baseline" : ""))
    }

    func clearDetected(id: String) { center.removeDeliveredNotifications(withIdentifiers: ["detected-\(id)"]) }

    // MARK: UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["detection"] as? String else { return }
        let confirmed: Bool
        switch response.actionIdentifier {
        case Self.confirmAction: confirmed = true
        case Self.dismissAction: confirmed = false
        default: return   // a plain tap just opens the app
        }
        await MainActor.run {
            if let onAction { onAction(id, confirmed) } else { queued.append((id, confirmed)) }
        }
    }
}
