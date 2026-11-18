import SwiftUI

/// Wording shared by Home, Sleep and Calibration so every "not ready yet" says the same thing.
extension CalibrationPhase {
    var headline: String {
        switch self {
        case .setup: "Setting up"
        case .calibrating(let n): "Getting to know you · Night \(min(n + 1, HealthConstants.recoveryMinimumNights)) of \(HealthConstants.recoveryMinimumNights)"
        case .early(let n): "Personal baseline · \(n) of \(HealthConstants.recoveryEarlyNights) nights"
        case .calibrated: "Calibrated"
        }
    }
    var recoveryCaption: String? {
        switch self {
        case .setup: "After setup"
        case .calibrating(let n): "Calibrating · \(n) of \(HealthConstants.recoveryMinimumNights)"
        case .early, .calibrated: nil
        }
    }
    var explanation: String {
        switch self {
        case .setup: "Finish the steps below so the band's data can be trusted."
        case .calibrating: "Recovery needs four nights of sleep with the band on. Heart rate, Strain and calories already work."
        case .early: "Recovery is live but still settling. Your personal baseline firms up over the next nights."
        case .calibrated: "Your baseline is established."
        }
    }
}

/// Setup checklist: one row per step, the current one highlighted.
struct SetupCard: View {
    let setup: SetupState
    @EnvironmentObject private var router: Router

    var body: some View {
        let current = setup.remaining.first
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Getting set up").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    Text("\(SetupStep.allCases.count - setup.remaining.count) of \(SetupStep.allCases.count)").font(Typo.label(12)).foregroundStyle(Palette.muted)
                }
                ForEach(SetupStep.allCases) { step in
                    let done = setup.isDone(step), isCurrent = step == current
                    let label = HStack(alignment: .top, spacing: 12) {
                            Image(systemName: done ? "checkmark.circle.fill" : (isCurrent ? "circle.dotted" : "circle"))
                                .font(.system(size: 20)).foregroundStyle(done ? Palette.green : (isCurrent ? Palette.strain : Palette.muted))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.rawValue).font(Typo.body(15, weight: .semibold)).foregroundStyle(done ? Palette.muted : Palette.text)
                                if isCurrent { Text(step.detail).font(Typo.body(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    Group {
                        if step == .profile { NavigationLink { ProfileView() } label: { label } }
                        else {
                            Button {
                                if step == .band {
                                    router.tab = .device
                                    if !done { router.showingBandSetup = true }
                                } else {
                                    router.tab = .sleep
                                }
                            } label: { label }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.rawValue), \(done ? "done" : "to do")")
                }
            }
        }
    }
}

/// Home card for the Calibrating and Early phases. Opens the Calibration screen.
struct CalibrationCard: View {
    let state: DisplayCalibration

    var body: some View {
        NavigationLink { CalibrationView() } label: {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(state.phase.headline).font(Typo.body(15, weight: .semibold)).foregroundStyle(Palette.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    ProgressSteps(filled: state.validNights, total: state.phase.isCalibrating ? HealthConstants.recoveryMinimumNights : HealthConstants.recoveryEarlyNights)
                    if let last = state.lastNight { Text(last).font(Typo.body(12)).foregroundStyle(Palette.muted) }
                    else { Text(state.phase.explanation).font(Typo.body(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading) }
                }
            }
        }
        .buttonStyle(CardPressStyle())
    }
}

extension CalibrationPhase {
    var isCalibrating: Bool { if case .calibrating = self { true } else { false } }
}

struct ProgressSteps: View {
    let filled: Int
    let total: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3).fill(index < filled ? Palette.strain : Palette.track).frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filled) of \(total) nights")
    }
}

/// The last 14 nights as dots: filled when the night counted, hollow (tap for the reason) when it did not.
struct NightStrip: View {
    let nights: [NightLog]
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(nights) { night in
                    Button { selected = selected == night.wakeDay ? nil : night.wakeDay } label: {
                        Circle()
                            .strokeBorder(night.verdict.counts ? Palette.strain : Palette.muted, lineWidth: 1.5)
                            .background(Circle().fill(night.verdict.counts ? Palette.strain : .clear))
                            .frame(width: 16, height: 16)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(night.verdict.counts ? "Night counted" : "Night did not count")
                }
            }
            if let selected, let night = nights.first(where: { $0.wakeDay == selected }) {
                switch night.verdict {
                case .counted: Text("This night counted.").font(Typo.body(12)).foregroundStyle(Palette.muted)
                case .missed(let reason): Text(reason.rawValue + ".").font(Typo.body(12)).foregroundStyle(Palette.muted)
                }
            } else {
                Text("Filled dots counted toward your baseline. Tap a hollow one to see why not.").font(Typo.body(12)).foregroundStyle(Palette.muted)
            }
        }
    }
}
