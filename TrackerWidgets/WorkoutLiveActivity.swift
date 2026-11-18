import SwiftUI
import UIKit
import WidgetKit
import ActivityKit
import AppIntents

// Same colours as the app (Tracker/UI/Theme.swift); the extension cannot import the app's UI files.
private enum Tone {
    static let background = Color(uiColor: .secondarySystemBackground)
    static let raised = Color(uiColor: .tertiarySystemFill)
    static let heart = Color(red: 1, green: 0.302, blue: 0.369)
    static let calories = Color(red: 1, green: 0.690, blue: 0.125)
    static let strain = Color(red: 0.231, green: 0.620, blue: 1)
    static let muted = Color.secondary
    static func zone(_ zone: Int?) -> Color {
        switch zone {
        case 1: Color(red: 0.31, green: 0.70, blue: 1)
        case 2: Color(red: 0.18, green: 0.90, blue: 0.42)
        case 3: Color(red: 1, green: 0.87, blue: 0)
        case 4: Color(red: 1, green: 0.60, blue: 0.24)
        case 5: Color(red: 1, green: 0.30, blue: 0.37)
        default: muted
        }
    }
}

private func symbol(for type: String) -> String {
    switch type {
    case "Running": "figure.run"
    case "Cycling": "figure.outdoor.cycle"
    case "Walking": "figure.walk"
    case "Strength": "dumbbell.fill"
    default: "figure.mixed.cardio"
    }
}

/// A timer that ticks on its own while running and holds still when paused.
private struct Elapsed: View {
    var start: Date
    var state: WorkoutActivityAttributes.ContentState
    var size: CGFloat
    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds), h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    var body: some View {
        Group {
            if let pausedAt = state.pausedAt {
                Text(Self.clock(max(0, pausedAt.timeIntervalSince(start) - state.pausedSeconds)))
            } else {
                Text(timerInterval: start.addingTimeInterval(state.pausedSeconds)...start.addingTimeInterval(86400 * 2), countsDown: false, showsHours: true)
            }
        }
        .font(.system(size: size, weight: .bold)).monospacedDigit()
        .minimumScaleFactor(0.7).lineLimit(1)
    }
}

private struct Stat: View {
    var label: String, value: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Tone.muted)
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(color)
        }
    }
}

private struct LockScreen: View {
    var attributes: WorkoutActivityAttributes
    var state: WorkoutActivityAttributes.ContentState
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: symbol(for: attributes.workoutType)).foregroundStyle(Tone.strain)
                Text(attributes.workoutType.uppercased()).font(.system(size: 13, weight: .bold))
                Text(state.isEnded ? "COMPLETED" : state.pausedAt == nil ? "IN PROGRESS" : "PAUSED").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(state.isEnded ? Tone.strain : state.pausedAt == nil ? Tone.muted : Tone.calories)
                Spacer()
                Elapsed(start: attributes.startDate, state: state, size: 30)
            }
            HStack(alignment: .bottom, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 16)).foregroundStyle(Tone.heart.opacity(state.isStale ? 0.4 : 1))
                    Text((state.isEnded ? state.avgBPM : state.bpm).map(String.init) ?? "—").font(.system(size: 46, weight: .bold))
                        .foregroundStyle(state.isStale ? Tone.muted : .primary)
                    Text(state.isEnded ? "AVG BPM" : state.isStale ? "NO SIGNAL" : "BPM").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tone.muted)
                }
                Spacer(minLength: 0)
                if !state.isEnded { Stat(label: "ZONE", value: state.zone.map { "Z\($0)" } ?? "—", color: Tone.zone(state.zone)) }
                Stat(label: "KCAL", value: state.calories.map(String.init) ?? "—", color: Tone.calories)
                Stat(label: "STRAIN", value: state.strain.map { String(format: "%.1f", $0) } ?? "—", color: Tone.strain)
            }
            if !state.isEnded { HStack(spacing: 10) {
                Button(intent: PauseWorkoutIntent()) {
                    Label(state.pausedAt == nil ? "Pause" : "Resume", systemImage: state.pausedAt == nil ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain).background(Tone.raised, in: Capsule())
                Button(intent: EndWorkoutIntent()) {
                    Label("End", systemImage: "stop.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tone.heart)
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain).background(Tone.heart.opacity(0.16), in: Capsule())
            } }
        }
        .foregroundStyle(.primary)
        .padding(16)
        .activityBackgroundTint(Tone.background)
    }
}

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreen(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: context.attributes.workoutType)).foregroundStyle(Tone.strain)
                        Text(context.attributes.workoutType.uppercased()).font(.system(size: 12, weight: .bold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) { Elapsed(start: context.attributes.startDate, state: context.state, size: 24) }
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "heart.fill").foregroundStyle(Tone.heart.opacity(context.state.isStale ? 0.4 : 1))
                        Text((context.state.isEnded ? context.state.avgBPM : context.state.bpm).map(String.init) ?? "—").font(.system(size: 38, weight: .bold))
                            .foregroundStyle(context.state.isStale ? Tone.muted : .white)
                        Text(context.state.isEnded ? "AVG BPM" : "BPM").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tone.muted)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 22) {
                        if !context.state.isEnded { Stat(label: "ZONE", value: context.state.zone.map { "Z\($0)" } ?? "—", color: Tone.zone(context.state.zone)) }
                        Stat(label: "KCAL", value: context.state.calories.map(String.init) ?? "—", color: Tone.calories)
                        Stat(label: "STRAIN", value: context.state.strain.map { String(format: "%.1f", $0) } ?? "—", color: Tone.strain)
                        Spacer(minLength: 0)
                        if !context.state.isEnded {
                            Button(intent: PauseWorkoutIntent()) { Image(systemName: context.state.pausedAt == nil ? "pause.fill" : "play.fill").frame(width: 36, height: 36) }
                                .buttonStyle(.plain).background(Tone.raised, in: Circle())
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(for: context.attributes.workoutType)).foregroundStyle(Tone.strain)
            } compactTrailing: {
                Text(context.state.bpm.map(String.init) ?? "—").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(context.state.isStale ? Tone.muted : Tone.heart)
            } minimal: {
                Text(context.state.bpm.map(String.init) ?? "—").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(context.state.isStale ? Tone.muted : Tone.heart)
            }
            .keylineTint(Tone.heart)
        }
    }
}
