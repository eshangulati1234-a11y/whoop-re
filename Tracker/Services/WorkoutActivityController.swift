import Foundation
import ActivityKit

/// Starts, updates and ends the workout Live Activity. Updates are throttled by the caller (every 5 s);
/// this type adds a heartbeat so a missing heart-rate signal is shown as stale.
@MainActor final class WorkoutActivityController {
    private var activity: Activity<WorkoutActivityAttributes>?
    private var heartbeat: Task<Void, Never>?
    private var workout: Workout?
    private var metrics: DisplayWorkoutMetrics?
    private var reading: LiveReading?
    private var lastState: WorkoutActivityAttributes.ContentState?

    static let staleAfter: TimeInterval = 15

    private var enabled: Bool {
        (UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true) && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// End activities left over from a workout that no longer exists (app killed mid-workout).
    func endOrphans(activeWorkoutID: UUID?) {
        for existing in Activity<WorkoutActivityAttributes>.activities where existing.attributes.workoutID != activeWorkoutID?.uuidString {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
        }
        if let activeWorkoutID, activity == nil {
            activity = Activity<WorkoutActivityAttributes>.activities.first { $0.attributes.workoutID == activeWorkoutID.uuidString }
        }
    }

    func update(workout: Workout?, metrics: DisplayWorkoutMetrics?, reading: LiveReading?) {
        self.workout = workout; self.metrics = metrics; self.reading = reading
        guard let workout else { return }
        if activity == nil {
            guard enabled else { return }
            let attributes = WorkoutActivityAttributes(workoutID: workout.id.uuidString, workoutType: workout.type, startDate: workout.start)
            activity = try? Activity.request(attributes: attributes, content: .init(state: state(workout), staleDate: nil), pushType: nil)
            startHeartbeat()
        }
        push(force: false)
    }

    func end(finalWorkout: Workout, metrics final: WorkoutMetrics) {
        heartbeat?.cancel(); heartbeat = nil
        workout = nil
        guard let activity else { return }
        self.activity = nil
        let summary = WorkoutActivityAttributes.ContentState(
            bpm: nil, zone: nil, calories: final.calories.map { Int($0.rounded()) }, strain: final.strain,
            pausedAt: finalWorkout.end ?? Date(), pausedSeconds: finalWorkout.pausedSeconds, isStale: false, isEnded: true, avgBPM: final.avgHR)
        Task { await activity.end(.init(state: summary, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }

    private func state(_ workout: Workout) -> WorkoutActivityAttributes.ContentState {
        let now = Date()
        let fresh = reading.map { now.timeIntervalSince($0.date) <= Self.staleAfter } ?? false
        return .init(bpm: reading?.bpm, zone: reading.flatMap { ZoneBand.band(for: $0.bpm, maxHR: ZoneConfig.maxHR)?.rawValue },
                     calories: metrics?.calories.map { Int($0.rounded()) }, strain: metrics?.strain,
                     pausedAt: workout.pausedAt, pausedSeconds: workout.pausedSeconds, isStale: !fresh)
    }

    private func push(force: Bool) {
        guard let activity, let workout else { return }
        let next = state(workout)
        guard force || next != lastState else { return }
        lastState = next
        Task { await activity.update(.init(state: next, staleDate: Date().addingTimeInterval(60))) }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.push(force: false)
            }
        }
    }
}
