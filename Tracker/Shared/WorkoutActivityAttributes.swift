import Foundation
import ActivityKit

/// Shared by the app and the widget extension: what the lock screen and Dynamic Island show
/// while a workout runs. Values are `nil` when they are not known; the views show "—".
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var bpm: Int?
        /// 1...5, `nil` below zone 1 or without a reading.
        var zone: Int?
        var calories: Int?
        var strain: Double?
        var pausedAt: Date?
        var pausedSeconds: Double
        /// No heart-rate reading for a while: show the last value dimmed rather than as live.
        var isStale: Bool
        /// The workout is over: show the final numbers with no controls.
        var isEnded: Bool = false
        /// Average heart rate, set only once the workout has ended.
        var avgBPM: Int?
    }
    var workoutID: String
    var workoutType: String
    var startDate: Date
}
