import SwiftUI

/// One saved workout as a row. Shared by Home (today) and the Workouts hub (history).
struct WorkoutListRow: View {
    let workout: Workout
    var showDay = false
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        let stats = HRMath.stats(workout.readings.map(\.point))
        let metrics = store.workoutMetrics[workout.id]
        var rowStats: [ActivityStat] = []
        if let stats { rowStats += [.avgHR(stats.avg), .maxHR(stats.max)] }
        if let kcal = metrics?.calories { rowStats.append(.kcal(kcal)) }
        if rowStats.isEmpty { rowStats = [.note("No heart rate recorded")] }
        let day = showDay ? workout.start.formatted(.dateTime.month(.abbreviated).day()) + ", " : ""
        return ActivityRow(
            symbol: ActivityKind.symbol(for: workout.type),
            title: workout.type,
            subtitle: "\(day)\(Format.time(workout.start)) – \(workout.end.map(Format.time) ?? "now") · \(Int(workout.elapsed(at: Date()) / 60)) min",
            strain: metrics?.strain,
            stats: rowStats)
    }
}

/// Start a workout, or look back at (and edit) earlier ones.
struct WorkoutsHubView: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var router: Router
    @AppStorage("lastActivityType") private var lastType = ActivityKind.running.rawValue
    @State private var editing = false
    @State private var pendingDelete: Workout?

    private var finished: [Workout] { band.workouts.filter { $0.end != nil }.sorted { $0.start > $1.start } }
    private var days: [(day: Date, items: [Workout])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: finished) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    startSection
                    historySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { router.presented = nil } }
                ToolbarItem(placement: .topBarTrailing) { editButton }
            }
        }
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete workout", role: .destructive) {
                if let workout = pendingDelete { band.removeWorkout(id: workout.id); Haptics.tap() }
                pendingDelete = nil
            }
        } message: { Text("It is removed from your history and from today's strain and calories.") }
    }

    private var editButton: some View {
        Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }
            .font(Typo.body(15, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .opacity(finished.isEmpty ? 0.35 : 1)
            .disabled(finished.isEmpty)
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a workout").sectionLabel(size: 12, tracking: 1.8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(ActivityKind.allCases) { kind in
                    Button {
                        Haptics.select(); lastType = kind.rawValue; router.presented = .start
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.strain)
                            Text(kind.rawValue).font(Typo.label(12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.hairline, lineWidth: 1) }
                    }
                    .buttonStyle(CardPressStyle())
                    .accessibilityLabel("Start \(kind.rawValue)")
                }
            }
            Text("Workouts also appear on their own when your heart rate looks like exercise.").font(Typo.body(12)).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Previous workouts").sectionLabel(size: 12, tracking: 1.8)
            if finished.isEmpty {
                EmptyStateCard(symbol: "figure.run", title: "No workouts yet", message: "Finished workouts are listed here, and you can edit or remove them.", tint: Palette.strain)
            }
            ForEach(days, id: \.day) { group in
                Text(dayTitle(group.day)).font(Typo.body(13, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 4)
                ForEach(group.items) { workout in
                    HStack(spacing: 10) {
                        if editing {
                            Button { pendingDelete = workout } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 24)).foregroundStyle(Palette.heart)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Delete \(workout.type) workout")
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        Button { router.presented = .summary(workout.id) } label: { WorkoutListRow(workout: workout) }
                            .buttonStyle(CardPressStyle())
                    }
                    .contextMenu {
                        Button { router.presented = .summary(workout.id) } label: { Label("Open and edit", systemImage: "pencil") }
                        Button(role: .destructive) { pendingDelete = workout } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// Change a saved workout's type or times, or delete it.
struct EditWorkoutSheet: View {
    let workout: Workout
    var onDeleted: () -> Void
    @EnvironmentObject private var band: BandManager
    @Environment(\.dismiss) private var dismiss
    @State private var type: String
    @State private var start: Date
    @State private var end: Date
    @State private var confirmDelete = false

    init(workout: Workout, onDeleted: @escaping () -> Void) {
        self.workout = workout; self.onDeleted = onDeleted
        _type = State(initialValue: workout.type)
        _start = State(initialValue: workout.start)
        _end = State(initialValue: workout.end ?? Date())
    }

    private var error: String? {
        if end <= start { return "The end must be after the start." }
        if end.timeIntervalSince(start) > 24 * 3600 { return "A workout can be at most 24 hours." }
        if end > Date() { return "The end can't be in the future." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Activity", selection: $type) { ForEach(ActivityKind.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                }
                Section("Time") {
                    DatePicker("Start", selection: $start, in: ...Date())
                    DatePicker("End", selection: $end, in: ...Date())
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Button("Delete workout", role: .destructive) { confirmDelete = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = workout
                        updated.type = type; updated.start = start; updated.end = end
                        updated.pauses = nil; updated.pausedSeconds = 0
                        band.updateWorkout(updated); Haptics.success(); dismiss()
                    }
                    .disabled(error != nil)
                }
            }
            .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete workout", role: .destructive) { band.removeWorkout(id: workout.id); dismiss(); onDeleted() }
            }
        }
        
    }
}
