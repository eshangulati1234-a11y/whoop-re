import SwiftUI
import Charts

// MARK: - Shared pieces

struct SheetTopBar: View {
    var title: String
    var closeSymbol = "xmark"
    var closeLabel = "Close"
    var onClose: () -> Void
    var trailing: AnyView = AnyView(Color.clear.frame(width: 44, height: 44))

    var body: some View {
        Color.clear.frame(height: 0)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(action: onClose) { Label(closeLabel,systemImage: closeSymbol) } }
                ToolbarItem(placement: .principal) { Text(title).font(.headline) }
                ToolbarItem(placement: .topBarTrailing) { trailing }
            }
    }
}

struct HeartRateTrace: View {
    var points: [HRPoint]
    var maxHR: Int
    var average: Int?
    var height: CGFloat = 110

    var body: some View {
        let values = points.map(\.bpm)
        let lo = max(30, (values.min() ?? 60) - 10)
        let hi = (values.max() ?? 160) + 10
        let xs = (points.first?.date ?? Date())...(points.last?.date ?? Date())
        let bands = ZoneBand.allCases.filter { $0.ceilingBPM(maxHR: maxHR) > lo && $0.floorBPM(maxHR: maxHR) < hi }
        Chart {
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Start", xs.lowerBound), xEnd: .value("End", xs.upperBound),
                    yStart: .value("Low", max(lo, band.floorBPM(maxHR: maxHR))),
                    yEnd: .value("High", min(hi, band.ceilingBPM(maxHR: maxHR))))
                .foregroundStyle(band.color.opacity(0.10))
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), yStart: .value("Base", lo), yEnd: .value("BPM", point.bpm))
                    .foregroundStyle(LinearGradient(colors: [Palette.heart.opacity(0.3), Palette.heart.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("BPM", point.bpm))
                    .foregroundStyle(Palette.heart)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: xs)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityLabel("Heart rate during the workout")
    }

    /// Thin a dense series so the chart stays fast: at most `limit` points.
    static func thinned(_ points: [HRPoint], limit: Int = 240) -> [HRPoint] {
        guard points.count > limit else { return points }
        let stride = Double(points.count) / Double(limit)
        return (0..<limit).map { points[min(points.count - 1, Int(Double($0) * stride))] }
    }
}

// MARK: - Start

struct StartWorkoutView: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router
    @AppStorage("liveActivityEnabled") private var showOnLockScreen = true
    @AppStorage("zoneHaptics") private var zoneHaptics = true
    @AppStorage("lastActivityType") private var lastType = ActivityKind.running.rawValue
    @State private var selection: ActivityKind = .running
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
            VStack(spacing: 16) {
                SheetTopBar(title: "Start workout", onClose: { router.presented = nil }, trailing: AnyView(hrChip))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose an activity").sectionLabel(size: 12, tracking: 1.8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(ActivityKind.allCases) { kind in tile(kind) }
                    }
                }
                .padding(.top, 4)
                Card(padding: 4, radius: 20) {
                    VStack(spacing: 0) {
                        SettingToggleRow(title: "Show on lock screen", subtitle: "Time, heart rate and zone at a glance", isOn: $showOnLockScreen)
                            .padding(.horizontal, 12)
                        Hairline().padding(.horizontal, 12)
                        SettingToggleRow(title: "Zone haptics", subtitle: "Buzz when you move into a new zone", isOn: $zoneHaptics)
                            .padding(.horizontal, 12)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button { begin() } label: { Text("Start \(selection.rawValue)") }
                        .buttonStyle(PillButtonStyle(height: 64))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(readyText(store.linkState(at: context.date)))
                            .font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            }
            .contentMargins(.bottom, 24, for: .scrollContent)

            if let countdown { countdownOverlay(countdown) }
        }
        .onAppear { selection = ActivityKind(rawValue: lastType) ?? .running }
        .onDisappear { countdownTask?.cancel() }
    }

    private var hrChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = store.linkState(at: context.date)
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 8, height: 8)
                if state.isLive, let bpm = store.current?.bpm {
                    Text("\(bpm)").font(Typo.number(20))
                } else {
                    Text("—").font(Typo.number(20)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Palette.raised, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.isLive ? "Heart rate \(store.current?.bpm ?? 0)" : "No heart rate")
        }
    }

    private func tile(_ kind: ActivityKind) -> some View {
        let selected = kind == selection
        return Button {
            Haptics.select(); withAnimation(.snappy(duration: 0.2)) { selection = kind }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: kind.symbol).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(selected ? Palette.strain : Palette.text)
                Spacer(minLength: 6)
                Text(kind.rawValue).font(Typo.number(20))
                Text(lastLine(kind)).font(Typo.body(11, weight: .medium)).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(14)
            .background(selected ? Palette.strain.opacity(0.14) : Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? Palette.strain : Palette.hairline, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func lastLine(_ kind: ActivityKind) -> String {
        guard let last = band.workouts.filter({ $0.type == kind.rawValue }).max(by: { $0.start < $1.start }) else {
            return kind == .other ? "Anything else" : "No workouts yet"
        }
        if Calendar.current.isDateInToday(last.start) { return "Last: today, \(Format.time(last.start))" }
        return "Last: " + last.start.formatted(.dateTime.month(.abbreviated).day())
    }

    private func readyText(_ state: LinkState) -> String {
        state.isLive ? state.detail : "\(state.detail) · The workout will record time until heart rate arrives"
    }

    private func begin() {
        lastType = selection.rawValue
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for number in [3, 2, 1] {
                countdown = number
                Haptics.medium()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { countdown = nil; return }
            }
            Haptics.success()
            countdown = nil
            band.startWorkout(type: selection.rawValue)
            router.presented = .active
        }
    }

    private func countdownOverlay(_ number: Int) -> some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Get ready").sectionLabel(size: 14, tracking: 4)
                Text("\(number)").font(Typo.number(220)).foregroundStyle(Palette.strain)
                    .contentTransition(.numericText())
                Text(selection.rawValue).font(Typo.label(22, weight: .bold))
                Button("Cancel") { countdownTask?.cancel(); countdown = nil }
                    .font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(minWidth: 88, minHeight: 48)
                    .padding(.top, 28)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Starting in \(number)")
    }
}

// MARK: - Active

struct ActiveWorkoutView: View {
    @AppStorage("zoneHaptics") private var zoneHaptics = true
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let workout = band.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(workout, now: context.date)
                }
            } else {
                ProgressView().tint(Palette.muted).onAppear {
                    // Only dismiss if nothing else (e.g. the summary) has taken over.
                    DispatchQueue.main.async { if router.presented == .active { router.presented = nil } }
                }
            }
        }
    }

    private func content(_ workout: Workout, now: Date) -> some View {
        let paused = workout.pausedAt != nil
        let fresh = store.current.map { now.timeIntervalSince($0.date) < 15 } ?? false
        let bpm = fresh && !paused ? store.current?.bpm : nil
        let zone = bpm.flatMap { ZoneBand.band(for: $0, maxHR: ZoneConfig.maxHR) }
        let average = HRMath.stats(workout.readings.map(\.point))?.avg
        let metrics = store.activeMetrics
        return ScrollView {
        VStack(spacing: 14) {
            SheetTopBar(
                title: workout.type, closeSymbol: "chevron.down", closeLabel: "Minimise workout",
                onClose: { router.presented = nil },
                trailing: AnyView(Image(systemName: "lock.fill").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44).accessibilityHidden(true)))
            Text(paused ? "Paused" : "In progress")
                .font(Typo.label(11, weight: .semibold))
                .foregroundStyle(paused ? Palette.calories : Palette.strain)
                .offset(y: -8)

            VStack(spacing: 0) {
                Text("Elapsed").sectionLabel(size: 11, tracking: 3)
                Text(Format.clock(workout.elapsed(at: now))).font(Typo.number(84))
                    .foregroundStyle(paused ? Palette.muted : Palette.text)
            }

            ZoneRing(zone: zone, size: 244, lineWidth: 8) {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill").font(.system(size: 14))
                        Text(bpm != nil ? "Live" : (paused ? "Paused" : "No signal")).font(Typo.label(11))
                    }
                    .foregroundStyle(bpm != nil ? Palette.heart : Palette.muted)
                    Text(bpm.map(String.init) ?? "—").font(Typo.number(92))
                        .foregroundStyle(bpm != nil ? Palette.text : Palette.muted)
                    Text("BPM").sectionLabel(size: 12, tracking: 2.4)
                    Text(zone.map { "\($0.title) · \($0.intensity)" } ?? (bpm != nil ? "Below Zone 1" : " "))
                        .font(Typo.label(15, weight: .bold))
                        .foregroundStyle(zone?.color ?? Palette.muted).padding(.top, 6)
                }
            }
            .opacity(paused ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bpm.map { "Heart rate \($0) beats per minute" + (zone.map { ", \($0.title)" } ?? "") } ?? "No heart rate")

            Card(padding: 14, radius: 20) {
                HStack {
                    metric("Calories", metrics?.calories.map { Format.kcal($0) }, Palette.calories)
                    Rectangle().fill(Palette.track).frame(width: 1, height: 40)
                    metric("Strain", metrics?.strain.map { $0.formatted(.number.precision(.fractionLength(1))) }, Palette.strain)
                    Rectangle().fill(Palette.track).frame(width: 1, height: 40)
                    metric("Avg HR", average.map(String.init), Palette.text)
                }
            }
            Spacer(minLength: 0)
            controls(workout, paused: paused)
        }
        .animation(.smooth(duration: 0.3), value: paused)
        .onChange(of: zone?.title) { old, new in
            // A buzz when you move into a new zone (not when the signal drops out).
            if zoneHaptics, old != nil, new != nil { Haptics.medium() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
        }
        .contentMargins(.bottom, 24, for: .scrollContent)
    }

    private func metric(_ title: String, _ value: String?, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).sectionLabel(size: 11, tracking: 1.5)
            Text(value ?? "—").font(Typo.number(30)).foregroundStyle(value == nil ? Palette.muted : color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func controls(_ workout: Workout, paused: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                Button {
                    Haptics.tap(); band.pauseWorkout()
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26)).foregroundStyle(Palette.text)
                        .frame(width: 72, height: 72)
                        .overlay { Circle().stroke(Palette.text, lineWidth: 2) }
                }
                .accessibilityLabel(paused ? "Resume workout" : "Pause workout")
                Text(paused ? "Resume" : "Pause").sectionLabel(size: 11, tracking: 2)
            }
            HoldToFinishButton {
                let id = workout.id
                band.finishWorkout()
                router.presented = .summary(id)
            }
        }
    }
}

struct HoldToFinishButton: View {
    var onComplete: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Capsule().fill(Palette.red.opacity(0.12))
            GeometryReader { geo in
                Capsule().fill(Palette.red.opacity(0.38)).frame(width: geo.size.width * progress)
            }
            HStack(spacing: 10) {
                Image(systemName: "stop.fill").font(.system(size: 16))
                Text("Hold to finish").font(Typo.label(17, weight: .bold))
            }
            .foregroundStyle(Palette.red)
        }
        .frame(height: 72)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Palette.red, lineWidth: 2) }
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 80, perform: {
            Haptics.success(); onComplete()
        }, onPressingChanged: { pressing in
            if pressing { Haptics.medium() }
            withAnimation(.linear(duration: pressing ? 1.2 : 0.25)) { progress = pressing ? 1 : 0 }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finish workout")
        .accessibilityHint("Press and hold to finish")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onComplete() }
    }
}

// MARK: - Summary

struct WorkoutSummaryView: View {
    var workoutID: UUID
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router
    @State private var editing = false

    private var workout: Workout? { band.workouts.first { $0.id == workoutID } }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let workout {
                ScrollView {
                    VStack(spacing: 16) {
                        SheetTopBar(title: "Workout", onClose: { router.presented = nil },
                                    trailing: AnyView(Button("Edit") { editing = true }.font(Typo.body(15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)))
                        WorkoutDetailSections(workout: workout)
                        Button("Done") { router.presented = nil }
                            .buttonStyle(PillButtonStyle())
                            .padding(.top, 4)
                        if let strain = store.workoutMetrics[workout.id]?.strain {
                            Text("Adds \(strain.formatted(.number.precision(.fractionLength(1)))) strain to today")
                                .font(Typo.body(12)).foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .sheet(isPresented: $editing) {
                    EditWorkoutSheet(workout: workout) { router.presented = nil }
                        .environmentObject(band)
                }
            } else {
                EmptyStateCard(symbol: "questionmark.circle", title: "Workout not found", message: "This workout is no longer saved.",
                               actionTitle: "Close") { router.presented = nil }
                    .padding(20)
            }
        }
    }
}

/// Header, stats, heart-rate trace and zones for one saved workout. Shared by the summary and the day history.
struct WorkoutDetailSections: View {
    let workout: Workout
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        VStack(spacing: 16) {
            titleRow(workout)
            heroCard(workout)
            chartCard(workout)
            zonesCard(workout)
        }
    }

    private func titleRow(_ workout: Workout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ActivityKind.symbol(for: workout.type))
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.strain)
                .frame(width: 48, height: 48).background(Palette.strain.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.type).font(Typo.number(30))
                Text("\(workout.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(Format.time(workout.start)) – \(workout.end.map(Format.time) ?? "now")")
                    .font(Typo.body(13)).foregroundStyle(Palette.muted)
            }
            Spacer()
        }
    }

    private func heroCard(_ workout: Workout) -> some View {
        let stats = HRMath.stats(workout.readings.map(\.point))
        let metrics = store.workoutMetrics[workout.id]
        return Card(padding: 18) {
            HStack(spacing: 16) {
                RingView(progress: metrics?.strain.map { $0 / 21 }, color: Palette.strain, size: 140) {
                    VStack(spacing: 2) {
                        Text(metrics?.strain.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                            .font(Typo.number(44)).foregroundStyle(metrics?.strain == nil ? Palette.muted : Palette.text)
                        Text("Strain").sectionLabel(size: 11, color: Palette.strain, tracking: 2)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    StatColumn(title: "Duration", value: Format.clock(workout.elapsed(at: Date())), size: 28)
                    StatColumn(title: "Calories", value: metrics?.calories.map { Format.kcal($0) } ?? "—", color: Palette.calories, size: 28)
                    StatColumn(title: "Avg HR", value: stats.map { String($0.avg) } ?? "—", size: 28)
                    StatColumn(title: "Max HR", value: stats.map { String($0.max) } ?? "—", color: Palette.heart, size: 28)
                }
            }
        }
    }

    @ViewBuilder private func chartCard(_ workout: Workout) -> some View {
        let points = workout.readings.map(\.point)
        let stats = HRMath.stats(points)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Heart rate").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    if let stats { Text("Average \(stats.avg) BPM").font(Typo.body(12)).foregroundStyle(Palette.muted) }
                }
                if points.count > 2 {
                    HeartRateTrace(points: HeartRateTrace.thinned(points), maxHR: ZoneConfig.maxHR, average: stats?.avg, height: 110)
                    HStack {
                        Text(Format.time(workout.start)); Spacer(); Text(workout.end.map(Format.time) ?? "")
                    }
                    .font(Typo.body(11, weight: .medium)).foregroundStyle(Palette.muted)
                } else {
                    Text("No heart rate was recorded. Keep your band connected during workouts to see your trace and zones.")
                        .font(Typo.body(13)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    @ViewBuilder private func zonesCard(_ workout: Workout) -> some View {
        let zones = HRMath.timeInZones(workout.readings.map(\.point), maxHR: ZoneConfig.maxHR)
        if !zones.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Time in zones").sectionLabel(size: 12, tracking: 1.8)
                    let total = max(zones.values.reduce(0, +), 1)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(ZoneBand.allCases) { band in
                                if let seconds = zones[band], seconds > 0 {
                                    RoundedRectangle(cornerRadius: 4).fill(band.color)
                                        .frame(width: max(3, (geo.size.width - 8) * seconds / total))
                                }
                            }
                        }
                    }
                    .frame(height: 14)
                    .accessibilityHidden(true)
                    ZoneTimeList(zones: zones, maxHR: ZoneConfig.maxHR)
                }
            }
        }
    }
}

// MARK: - Detected

struct DetectedWorkoutView: View {
    var detectionID: String
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router
    @State private var chosen: String?

    private var detection: DisplayDetection? { store.detections.first { $0.id == detectionID } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.strain.opacity(0.22), Palette.background], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
                .background(Palette.background).ignoresSafeArea()
            if let detection {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            CircleIconButton(symbol: "xmark", label: "Close") { router.presented = nil }
                            Spacer()
                            Text("Auto-detected").font(Typo.label(12, weight: .semibold))
                                .foregroundStyle(Palette.strain)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .overlay { Capsule().stroke(Palette.strain, lineWidth: 1) }
                        }
                        header(detection)
                        Text(blurb(detection)).font(Typo.body(14)).foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statsCard(detection)
                        typePicker(detection)
                        VStack(spacing: 4) {
                            Button("Save workout") {
                                Haptics.success()
                                store.confirmDetection?(detection, chosen ?? detection.guessedType)
                                router.presented = nil
                            }
                            .buttonStyle(PillButtonStyle())
                            Button("Not a workout") {
                                Haptics.tap()
                                store.dismissDetection?(detection)
                                router.presented = nil
                            }
                            .font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.muted)
                            .frame(minHeight: 48)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            } else {
                EmptyStateCard(symbol: "checkmark.circle", title: "Already handled", message: "This activity was saved or dismissed.",
                               actionTitle: "Close") { router.presented = nil }
                    .padding(20)
            }
        }
    }

    private func header(_ detection: DisplayDetection) -> some View {
        let type = chosen ?? detection.guessedType
        return HStack(spacing: 16) {
            Image(systemName: ActivityKind.symbol(for: type)).font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.strain)
                .frame(width: 72, height: 72)
                .background(Palette.strain.opacity(0.18), in: Circle())
                .overlay { Circle().stroke(Palette.strain, lineWidth: 2) }
            VStack(alignment: .leading, spacing: 6) {
                Text(chosen == nil ? "Looks like \(noun(type))" : type)
                    .font(Typo.number(34)).minimumScaleFactor(0.7)
                Text("Today · \(Format.time(detection.start)) – \(Format.time(detection.end))")
                    .font(Typo.body(13)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func noun(_ type: String) -> String {
        switch type {
        case "Running": "a run"
        case "Cycling": "a ride"
        case "Walking": "a walk"
        case "Strength": "strength work"
        default: "a workout"
        }
    }

    private func blurb(_ detection: DisplayDetection) -> String {
        "Your heart rate stayed elevated for \(Int(detection.duration / 60)) minutes. Save it to count toward today's strain."
    }

    private func statsCard(_ detection: DisplayDetection) -> some View {
        let inHighZones = detection.zones.filter { $0.key.rawValue >= 3 }.values.reduce(0, +)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Heart rate").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    Text("\(Int(detection.duration / 60)) min").font(Typo.body(12)).foregroundStyle(Palette.muted)
                }
                if detection.trace.count > 2 {
                    HeartRateTrace(points: HeartRateTrace.thinned(detection.trace), maxHR: ZoneConfig.maxHR, average: nil, height: 90)
                }
                Hairline()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 14) {
                    StatColumn(title: "Duration", value: Format.clock(detection.duration))
                    StatColumn(title: "Avg HR", value: String(detection.avgHR))
                    StatColumn(title: "Max HR", value: String(detection.maxHR), color: Palette.heart)
                    StatColumn(title: "Calories", value: detection.calories.map { Format.kcal($0) } ?? "—", color: Palette.calories)
                    StatColumn(title: "Strain", value: detection.strain.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", color: Palette.strain)
                    StatColumn(title: "Time Z3–Z5", value: inHighZones > 0 ? "\(Int((inHighZones / 60).rounded())) min" : "—")
                }
            }
        }
    }

    private func typePicker(_ detection: DisplayDetection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not \(detection.guessedType.lowercased())? Change activity").sectionLabel(size: 12, tracking: 1.6)
            FlowLayout(spacing: 8) {
                ForEach(ActivityKind.allCases) { kind in
                    let selected = (chosen ?? detection.guessedType) == kind.rawValue
                    Button { Haptics.select(); chosen = kind.rawValue } label: {
                        Text(kind.rawValue).font(Typo.body(14, weight: selected ? .semibold : .medium))
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(selected ? Palette.strain.opacity(0.18) : Palette.card, in: Capsule())
                            .overlay { Capsule().stroke(selected ? Palette.strain : Palette.border, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
