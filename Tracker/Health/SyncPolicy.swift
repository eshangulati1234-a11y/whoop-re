import Foundation

/// When an automatic history transfer is worth starting. Pure: the caller supplies the clock and state.
enum SyncPolicy {
    enum Trigger { case manual, foreground, reconnect, background }

    static func shouldSync(_ trigger: Trigger, now: Date, lastSuccess: Date?, lastAttempt: Date?, isSyncing: Bool, lowPower: Bool) -> Bool {
        guard !isSyncing else { return false }
        if trigger == .manual { return true }
        // Several triggers in quick succession (foreground + reconnect) start one transfer, not several.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < HealthConstants.syncCoalesce { return false }
        let age = lastSuccess.map { now.timeIntervalSince($0) } ?? .infinity
        switch trigger {
        case .manual: return true
        case .foreground: return age > HealthConstants.foregroundSyncAge
        case .reconnect, .background:
            // Not user-visible work: skip it when the phone is conserving energy.
            return !lowPower && age >= HealthConstants.backgroundSyncAge
        }
    }
}
