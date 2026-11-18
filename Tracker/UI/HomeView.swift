import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router
    @State private var editingActivities = false
    @State private var pickedDay: DayPick?

    private var todaysWorkouts: [Workout] {
        let calendar = Calendar.current
        return band.workouts.filter { calendar.isDateInToday($0.start) }.sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                bandConnectionStatus
                weekStrip
                ringsCard
                calibrationSection
                HStack(spacing: 12) {
                    heartRateTile
                    caloriesTile
                }
                .fixedSize(horizontal: false, vertical: true)
                stepsCard
                activities
                sleepCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        
        .sheet(item: $pickedDay) { pick in
            DayDetailSheet(date: pick.date)
                .environmentObject(store).environmentObject(band).environmentObject(router)
                .presentationDetents([.large])
        }
    }

    @ViewBuilder private var calibrationSection: some View {
        switch store.calibration.phase {
        case .setup: SetupCard(setup: store.calibration.setup)
        case .calibrating, .early: CalibrationCard(state: store.calibration)
        case .calibrated:
            EmptyView()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .sectionLabel(size: 12, tracking: 2)

            }
            Spacer()
            batteryChip
        }
    }

    @ViewBuilder private var bandConnectionStatus: some View {
        if band.syncing || (band.hasSavedBand && !band.ready) {
            Button { router.tab = .device } label: {
                HStack(alignment: .top, spacing: 8) {
                    if band.syncing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "dot.radiowaves.left.and.right") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(band.status).font(.subheadline)
                        if !band.ready, let lastSync = band.lastSync {
                            Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Device")
        }
    }

    @ViewBuilder private var batteryChip: some View {
        if let percent = band.batteryPercent, band.ready || band.batteryDate.map({ Date().timeIntervalSince($0) < 3600 }) ?? false {
            let charging = band.charging == true
            let symbol = charging ? "battery.100.bolt" : percent < 20 ? "battery.25" : percent < 60 ? "battery.50" : "battery.100"
            Button { router.tab = .device } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(percent < 20 && !charging ? Palette.red : Palette.green)
                    Text("\(Int(percent.rounded()))%").font(Typo.number(22)).contentTransition(.numericText())
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Palette.raised, in: Capsule())
            }
            .buttonStyle(CardPressStyle())
            .accessibilityLabel("Band battery \(Int(percent.rounded())) percent" + (charging ? ", charging" : ""))
        }
    }

    // MARK: Week strip

    private var weekStrip: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        return HStack {
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                let isFuture = day > today
                Button { if !isToday && !isFuture { Haptics.select(); pickedDay = DayPick(date: day) } } label: {
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.narrow))).font(Typo.label(12))
                    Text(day.formatted(.dateTime.day())).font(Typo.number(20))
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isToday ? Palette.background : (isFuture ? Palette.muted : Palette.text))
                .frame(width: 44, height: 62)
                .background(isToday ? Palette.text : .clear, in: Capsule())
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day()) + (isToday ? ", today" : ""))
            }
        }
    }

    // MARK: Rings

    private var ringsCard: some View {
        let day = store.day
        let sleepLabel = day.sleepPerformance == nil ? "No data" : (store.lastSleep.map { Format.hoursMinutes($0.asleep) } ?? "No data")
        return Card(padding: 20) {
            HStack(alignment: .top) {
                Button { router.tab = .sleep } label: {
                    ringColumn(
                        title: "Sleep", color: Palette.sleep,
                        progress: day.sleepPerformance,
                        value: day.sleepPerformance.map { String(Int(($0 * 100).rounded())) },
                        suffix: "%", caption: sleepLabel, captionColor: day.sleepPerformance == nil ? Palette.muted : Palette.sleep)
                }
                .buttonStyle(CardPressStyle())
                ringColumn(
                    title: "Recovery", color: day.recovery?.band.color ?? Palette.green,
                    progress: day.recovery.map { Double($0.score) / 100 },
                    value: day.recovery.map { String($0.score) }, suffix: "%",
                    caption: day.recovery.map { ($0.band.word) + (day.recoveryEarly ? " · Early" : "") } ?? (store.calibration.phase.recoveryCaption ?? "No data"),
                    captionColor: day.recovery?.band.color ?? Palette.muted,
                    calibrating: day.recovery == nil && store.calibration.phase.recoveryCaption != nil)
                ringColumn(
                    title: "Strain", color: Palette.strain,
                    progress: day.strain.map { $0 / 21 },
                    value: day.strain.map { $0.formatted(.number.precision(.fractionLength(1))) }, suffix: nil,
                    caption: day.strain == nil ? (store.calibration.phase == .setup ? "After setup" : "No data") : (day.strainProvisional ? ((day.strain ?? 0) < 2 ? "Light" : "of 21") : (day.loadContext ?? "of 21")),
                    captionColor: day.strain == nil ? Palette.muted : Palette.strain)
            }
        }
    }

    private func ringColumn(title: String, color: Color, progress: Double?, value: String?, suffix: String?, caption: String, captionColor: Color, calibrating: Bool = false) -> some View {
        VStack(spacing: 10) {
            RingView(progress: progress, color: color, size: 96, calibrating: calibrating) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value ?? "—").font(Typo.number(30)).foregroundStyle(value == nil ? Palette.muted : Palette.text)
                    if value != nil, let suffix { Text(suffix).font(Typo.number(14)).foregroundStyle(Palette.text) }
                }
            }
            VStack(spacing: 2) {
                Text(title).sectionLabel(size: 12, tracking: 1.8)
                Text(caption).font(Typo.body(13, weight: .semibold)).foregroundStyle(captionColor)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.map { $0 + (suffix ?? "") } ?? "no data"), \(caption)")
    }

    // MARK: Tiles

    private var heartRateTile: some View {
        Button { router.tab = .heart } label: {
            Card(radius: 20, stretch: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.heart).frame(width: 6, height: 6)
                        Text("Heart rate").sectionLabel(size: 12, tracking: 1.4)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let state = store.linkState(at: context.date)
                        let bpm = store.current?.bpm
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(bpm.map(String.init) ?? "—").font(Typo.number(48))
                                    .foregroundStyle(state.isLive ? Palette.text : Palette.muted)
                                Text("BPM").sectionLabel(size: 12, tracking: 1.4)
                            }
                            Sparkline(values: store.trace.suffix(60).map(\.bpm)).frame(height: 36)
                            Text(zoneCaption(bpm: bpm, state: state)).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
        .buttonStyle(CardPressStyle())
    }

    private func zoneCaption(bpm: Int?, state: LinkState) -> String {
        guard state.isLive, let bpm else { return state.title }
        if let zone = ZoneBand.band(for: bpm, maxHR: ZoneConfig.maxHR) { return "\(zone.title) · \(zone.intensity)" }
        return "Resting"
    }

    private var caloriesTile: some View {
        NavigationLink { CaloriesView() } label: {
            Card(radius: 20, stretch: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.calories).frame(width: 6, height: 6)
                        Text("Calories today").sectionLabel(size: 12, tracking: 1.4)
                    }
                    if let calories = store.day.calories {
                        Text(Format.kcal(calories.total)).font(Typo.number(48))
                        ProgressTrack(progress: calories.goal.map { calories.total / $0 } ?? 0, color: Palette.calories)
                            .opacity(calories.goal == nil ? 0 : 1)
                            .padding(.top, 10)
                        Text("Active \(Format.kcal(calories.active)) · Resting \(Format.kcal(calories.resting))")
                            .font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                    } else {
                        Text("—").font(Typo.number(48)).foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                        Text("Add your profile to see calories").font(Typo.body(12, weight: .medium))
                            .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(CardPressStyle())
    }

    @ViewBuilder private var stepsCard: some View {
        if StepService.isAvailable {
            Card(radius: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "figure.walk").font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.green).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steps today").sectionLabel(size: 12, tracking: 1.4)
                        Text(store.stepsToday.map { $0.formatted() } ?? "—").font(Typo.number(32)).contentTransition(.numericText())
                            .foregroundStyle(store.stepsToday == nil ? Palette.muted : Palette.text)
                    }
                    Spacer()
                    if store.stepsToday == nil { Text("Allow Motion & Fitness in Settings").font(Typo.body(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.trailing) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Steps today: \(store.stepsToday.map(String.init) ?? "not available")")
        }
    }

    // MARK: Activities

    private var todaysDetections: [DisplayDetection] { store.detections.filter { Calendar.current.isDateInToday($0.start) } }

    private var activities: some View {
        let detections = todaysDetections
        let count = todaysWorkouts.count + detections.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today's activity").font(Typo.label(16, weight: .bold))
                Spacer()
                if count > 0 {
                    Button(editingActivities ? "Done" : "Edit") { withAnimation(.snappy) { editingActivities.toggle() } }
                        .font(Typo.body(14, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                }
            }
            ForEach(detections) { detection in
                HStack(spacing: 10) {
                    if editingActivities { removeButton("Remove detected \(detection.guessedType)") { store.dismissDetection?(detection) } }
                    Button { router.presented = .detected(detection.id) } label: {
                        ActivityRow(
                            symbol: ActivityKind.symbol(for: detection.guessedType),
                            title: detection.guessedType,
                            subtitle: "\(Format.time(detection.start)) – \(Format.time(detection.end)) · \(Int(detection.duration / 60)) min",
                            strain: detection.strain,
                            stats: [.avgHR(detection.avgHR), .maxHR(detection.maxHR)]
                                + (detection.calories.map { [ActivityStat.kcal($0)] } ?? []),
                            badge: "Auto-detected", highlight: true, trailingHint: "Review")
                    }
                    .buttonStyle(CardPressStyle())
                }
                .contextMenu { Button(role: .destructive) { store.dismissDetection?(detection) } label: { Label("Not a workout", systemImage: "xmark") } }
            }
            ForEach(todaysWorkouts) { workout in
                HStack(spacing: 10) {
                    if editingActivities, workout.end != nil { removeButton("Remove \(workout.type) workout") { band.removeWorkout(id: workout.id) } }
                    Button { router.presented = .summary(workout.id) } label: { WorkoutListRow(workout: workout) }
                        .buttonStyle(CardPressStyle())
                }
                .contextMenu { if workout.end != nil { Button(role: .destructive) { band.removeWorkout(id: workout.id) } label: { Label("Remove", systemImage: "trash") } } }
            }
            if count == 0 {
                EmptyStateCard(
                    symbol: "figure.run", title: "No activity yet today",
                    message: "Start a workout, or we'll spot one from your heart rate.",
                    tint: Palette.strain, actionTitle: "Workouts") { router.presented = .workouts }
            }
        }
        .onChange(of: count) { _, new in if new == 0 { editingActivities = false } }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); withAnimation(.snappy) { action() } } label: {
            Image(systemName: "minus.circle.fill").font(.system(size: 24)).foregroundStyle(Palette.heart).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    // MARK: Sleep

    @ViewBuilder private var sleepCard: some View {
        if let sleep = store.lastSleep {
            Button { router.tab = .sleep } label: {
                Card(radius: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last night").sectionLabel(size: 12, tracking: 1.8)
                                Text(Format.hoursMinutes(sleep.asleep)).font(Typo.number(36))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int((sleep.performance * 100).rounded()))%").font(Typo.number(26)).foregroundStyle(Palette.sleep)
                                Text("Performance").sectionLabel(size: 10, tracking: 1.4)
                            }
                        }
                        if let segments = sleep.segments, !segments.isEmpty {
                            HypnogramView(segments: segments)
                            HStack {
                                Text(Format.time(sleep.start)); Spacer(); Text(Format.time(sleep.end))
                            }
                            .font(Typo.body(11, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .buttonStyle(CardPressStyle())
        } else {
            EmptyStateCard(
                symbol: "moon.stars", title: "No sleep recorded yet",
                message: "Wear your band overnight, then open the app in the morning to sync.",
                tint: Palette.sleep, actionTitle: "See sleep") { router.tab = .sleep }
        }
    }
}

struct ProgressTrack: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}


struct DayPick: Identifiable { let date: Date; var id: Date { date } }

/// One earlier day: strain, calories, sleep and workouts.
struct DayDetailSheet: View {
    let date: Date
    @EnvironmentObject private var store: DisplayStore
    @Environment(\.dismiss) private var dismiss
    @State private var summary: DisplayDaySummary?
    @State private var steps: Int?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(Typo.number(30))
                        Spacer()
                        Button("Done") { dismiss() }.font(Typo.body(15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                    }
                    if let summary {
                        if !summary.hasHeartRate && summary.asleep == nil && summary.workouts.isEmpty {
                            EmptyStateCard(symbol: "calendar", title: "No data for this day", message: "Your band didn't record anything, or it hasn't synced that day yet.")
                        } else {
                            Card {
                                HStack(alignment: .top) {
                                    stat("Strain", summary.strain.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", Palette.strain)
                                    stat("Calories", summary.calories.map { Format.kcal($0) } ?? "—", Palette.calories)
                                    stat("Sleep", summary.asleep.map { Format.hoursMinutes($0) } ?? "—", Palette.sleep)
                                }
                            }
                            if let steps {
                                Text("\(steps.formatted()) steps").font(Typo.body(13)).foregroundStyle(Palette.muted)
                            }
                            if let performance = summary.sleepPerformance {
                                Text("Sleep performance \(Int((performance * 100).rounded()))%").font(Typo.body(13)).foregroundStyle(Palette.muted)
                            }
                            Text("Workouts").sectionLabel(size: 12, tracking: 1.8)
                            if summary.workouts.isEmpty {
                                Text("No workouts this day.").font(Typo.body(13)).foregroundStyle(Palette.muted)
                            }
                            ForEach(summary.workouts) { WorkoutListRow(workout: $0) }
                        }
                    } else { ProgressView().tint(Palette.text).frame(maxWidth: .infinity).padding(.top, 40) }
                }
                .padding(20)
            }
        }
        
        .task { summary = store.loadDay?(date); steps = await store.steps.steps(on: date) }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value).font(Typo.number(30)).foregroundStyle(color)
            Text(title).sectionLabel(size: 11, tracking: 1.4)
        }
        .frame(maxWidth: .infinity)
    }
}
