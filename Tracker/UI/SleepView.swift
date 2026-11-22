import SwiftUI

struct SleepView: View {
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let sleep = store.lastSleep {
                    SleepDetailSections(sleep: sleep)
                } else {
                    emptyHero
                }
                napsCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.lastSleep.map { $0.end.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } ?? "Last night")
                    .sectionLabel(size: 12, tracking: 2)

            }
            Spacer()
            if store.lastSleep != nil {
                Text("Last night").font(Typo.label(12, weight: .bold))
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Palette.raised, in: Capsule())
            }
        }
    }

    // MARK: Empty

    private var emptyHero: some View {
        VStack(spacing: 16) {
            Card {
                VStack(spacing: 16) {
                    RingView(progress: nil, color: Palette.sleep, size: 184, lineWidth: 7) {
                        VStack(spacing: 2) {
                            Text("—").font(Typo.number(68)).foregroundStyle(Palette.muted)
                            Text("Performance").sectionLabel(size: 11, tracking: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
            }
            EmptyStateCard(
                symbol: "moon.stars", title: "No sleep recorded yet",
                message: "Wear your band overnight. In the morning, open the app and sync to see how you slept: time asleep, stages and how close you got to what you needed.",
                tint: Palette.sleep, actionTitle: "Sync your band") { router.tab = .device }
        }
    }

    // MARK: Naps

    @ViewBuilder private var napsCard: some View {
        if !store.naps.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Naps today").sectionLabel(size: 12, tracking: 1.8)
                    ForEach(store.naps) { nap in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(Format.time(nap.start)) – \(Format.time(nap.end))").font(Typo.body(15, weight: .semibold))
                                Spacer()
                                Text(Format.hoursMinutes(nap.asleep)).font(Typo.number(20))
                            }
                            if nap.needsReview {
                                Text("Was this a nap? It counts toward tonight's sleep need once you confirm.").font(Typo.body(12)).foregroundStyle(Palette.muted)
                                HStack(spacing: 10) {
                                    Button("Yes, a nap") { store.decideNap?(nap.id, true) }.buttonStyle(PillButtonStyle())
                                    Button("No") { store.decideNap?(nap.id, false) }.foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Every sleep card for one night. Shared by the Sleep tab and the day history.
struct SleepDetailSections: View {
    let sleep: DisplaySleep
    var historical = false
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        VStack(spacing: 16) {
            heroCard(sleep)
            stagesCard(sleep)
            needCard(sleep)
            detailTiles(sleep)
            vitals(sleep)
            overnight(sleep)
        }
    }

    // MARK: Hero

    private func heroCard(_ sleep: DisplaySleep) -> some View {
        Card(padding: 20) {
            VStack(spacing: 20) {
                RingView(progress: sleep.performance, color: Palette.sleep, size: 184, lineWidth: 7) {
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int((sleep.performance * 100).rounded()))").font(Typo.number(68))
                            Text("%").font(Typo.number(26))
                        }
                        Text("Performance").sectionLabel(size: 11, tracking: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                Hairline()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hours vs. needed").sectionLabel(size: 11, tracking: 1.5)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Format.hoursColonMinutes(sleep.asleep)).font(Typo.number(26))
                            Text("/ \(Format.hoursColonMinutes(sleep.need))").font(Typo.number(18)).foregroundStyle(Palette.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    StatColumn(title: "Efficiency", value: sleep.efficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .frame(width: 92)
                    StatColumn(title: "Consistency", value: sleep.consistency.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .frame(width: 92)
                }
            }
        }
    }

    // MARK: Stages

    private func stagesCard(_ sleep: DisplaySleep) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sleep stages").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    Text("In bed \(Format.hoursMinutes(sleep.inBed))").font(Typo.body(12)).foregroundStyle(Palette.muted)
                }
                if let segments = sleep.segments, !segments.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach([SleepStage.awake, .rem, .light, .deep], id: \.row) { stage in
                                Text(stage.title).font(Typo.label(10))
                                    .foregroundStyle(Palette.muted)
                                    .frame(height: 18, alignment: .leading)
                            }
                        }
                        .frame(width: 40, alignment: .leading)
                        HypnogramView(segments: segments)
                    }
                    HStack {
                        Text(Format.time(sleep.start))
                        Spacer()
                        Text(Format.time(sleep.start.addingTimeInterval(sleep.inBed / 2)))
                        Spacer()
                        Text(Format.time(sleep.end))
                    }
                    .font(Typo.body(11, weight: .medium)).foregroundStyle(Palette.muted)
                    .padding(.leading, 50)

                    VStack(spacing: 0) {
                        Hairline()
                        ForEach([SleepStage.awake, .light, .rem, .deep], id: \.row) { stage in
                            let seconds = sleep.total(for: stage)
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(stage.color).frame(width: 10, height: 10)
                                Text(stage.title).font(Typo.body(14, weight: .medium))
                                Spacer()
                                Text(Format.hoursColonMinutes(seconds)).font(Typo.number(20))
                                Text("\(Int((seconds / max(sleep.inBed, 1) * 100).rounded()))%")
                                    .font(Typo.body(12)).foregroundStyle(Palette.muted).frame(width: 40, alignment: .trailing)
                            }
                            .frame(height: 44)
                            .accessibilityElement(children: .combine)
                            Hairline().opacity(0.5)
                        }
                    }
                } else {
                    Text("Sleep stages are unavailable. Heart rate alone has not been validated for REM or deep sleep in this app.")
                        .font(Typo.body(13)).foregroundStyle(Palette.muted)
                }
                Text("You can adjust sleep times in Calibration → More options.").font(Typo.body(11)).foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Need

    @ViewBuilder private func needCard(_ sleep: DisplaySleep) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(historical ? "Sleep need" : "Tonight's sleep need").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    Text(Format.hoursColonMinutes(sleep.need)).font(Typo.number(22)).foregroundStyle(Palette.sleep)
                }
                if let base = sleep.needBaseline, let strain = sleep.needStrain, let debt = sleep.needDebt {
                    GeometryReader { geo in
                        let total = max(base + strain + debt, 1)
                        let gap: CGFloat = 3
                        let width = geo.size.width - gap * 2
                        HStack(spacing: gap) {
                            RoundedRectangle(cornerRadius: 5).fill(Palette.sleep).frame(width: width * base / total)
                            RoundedRectangle(cornerRadius: 5).fill(Palette.rem).frame(width: width * strain / total)
                            RoundedRectangle(cornerRadius: 5).fill(Palette.calories).frame(width: width * debt / total)
                        }
                    }
                    .frame(height: 10)
                    HStack {
                        legend(Palette.sleep, "Baseline \(Format.hoursColonMinutes(base))")
                        Spacer()
                        legend(Palette.rem, "Strain \(Format.hoursColonMinutes(strain))")
                        Spacer()
                        legend(Palette.calories, "Debt \(Format.hoursColonMinutes(debt))")
                    }
                    if let nap = sleep.needNap, nap > 0 {
                        legend(Palette.green, "Naps yesterday lowered tonight's need by \(Format.hoursColonMinutes(nap))")
                    }
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: Details

    private func detailTiles(_ sleep: DisplaySleep) -> some View {
        let items: [(String, String)] = [
            ("Efficiency", sleep.efficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not enough data"),
            ("Consistency", sleep.consistency.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not enough data"),
            ("Disturbances", sleep.disturbances.map(String.init) ?? "Not enough data"),
            ("Restorative", sleep.restorative.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not enough data"),
            ("Sleep cycles", sleep.cycles.map(String.init) ?? "Not enough data"),
            ("Latency", "Not available"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items, id: \.0) { item in
                Card(padding: 14, radius: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0).sectionLabel(size: 11, tracking: 1.4)
                        Text(item.1).font(item.1.contains("Not") ? Typo.body(13) : Typo.number(26)).foregroundStyle(item.1.contains("Not") ? Palette.muted : Palette.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Overnight measures. Each shows what the band can and cannot supply rather than a made-up number.
    private func overnight(_ sleep: DisplaySleep) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Overnight").sectionLabel(size: 12, tracking: 1.8)
                row("Resting heart rate", sleep.sleepingHR.map { "\($0) BPM" } ?? "Not enough data")
                row("HRV", sleep.hrv.map { "\(Int($0.rounded())) ms" } ?? "Not enough data")
                row("Skin temperature", sleep.skinState ?? (store.calibration.nights.contains { $0.verdict.counts } ? "Typical range builds over 7 nights" : "Calibrating"))
                Text("HRV is measured from the beat-to-beat data your band records overnight.")
                    .font(Typo.body(11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Typo.body(14, weight: .medium))
            Spacer()
            Text(value).font(Typo.body(14)).foregroundStyle(value.hasPrefix("Not") || value == "Calibrating" ? Palette.muted : Palette.text)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Vitals

    @ViewBuilder private func vitals(_ sleep: DisplaySleep) -> some View {
        let tiles: [(String, String, String, Color)] = [
            sleep.sleepingHR.map { ("Sleeping HR", String($0), "BPM", Palette.heart) },
            sleep.hrv.map { ("HRV", String(Int($0.rounded())), "MS", Palette.text) },
            sleep.respiratoryRate.map { ("Resp. rate", $0.formatted(.number.precision(.fractionLength(1))), "RPM", Palette.text) },
        ].compactMap { $0 }
        if !tiles.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    Card(padding: 14, radius: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tile.0).sectionLabel(size: 11, tracking: 1.4)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(tile.1).font(Typo.number(30)).foregroundStyle(tile.3)
                                Text(tile.2).sectionLabel(size: 11, tracking: 1.4)
                            }
                        }
                    }
                }
            }
        }
    }
}
