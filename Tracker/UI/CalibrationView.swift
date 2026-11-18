import SwiftUI
import UserNotifications

struct CalibrationView: View {
    @EnvironmentObject private var personal: Personalization
    @EnvironmentObject private var store: DisplayStore
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.calibration.phase.headline).font(Typo.body(17, weight: .semibold))
                    ProgressSteps(filled: store.calibration.validNights, total: store.calibration.phase.isCalibrating || store.calibration.phase == .setup ? HealthConstants.recoveryMinimumNights : HealthConstants.recoveryEarlyNights)
                    Text(store.calibration.phase.explanation).font(Typo.body(13)).foregroundStyle(Palette.muted)
                    if let last = store.calibration.lastNight { Text(last).font(Typo.body(13, weight: .medium)) }
                }
                .padding(.vertical, 4)
            }
                        Section("Last 14 nights") { NightStrip(nights: store.calibration.nights).padding(.vertical, 4) }
            Section("Your baselines") {
                baseline("Resting heart rate", store.calibration.restingHR.map { "\(Int($0.rounded())) BPM" }, nights: personal.baseline.resting.count, ready: personal.baseline.resting.established)
                baseline("HRV", nil, nights: personal.baseline.hrv.count, ready: personal.baseline.hrv.established)
                Text("A night counts with 4 hours of sleep and most of it measured. Missing a night pauses progress.").font(.caption)
            }
            if let profile = HealthEngine.loadProfile() {
                let zones = personal.zones(profile)
                Section {
                  DisclosureGroup("Heart-rate zones") {
                    Text("Maximum: \(Int(zones.maximum)) BPM · \(zones.maximumSource)")
                    Text(zones.resting.map { "Resting: \(Int($0.rounded())) BPM" } ?? "Using 70 BPM until your resting heart rate is measured")
                    ForEach(0..<5,id: \.self) { index in
                        let upper = index < 4 ? " to \(Int(zones.boundaries[index + 1].rounded()) - 1)" : "+"
                        Text("Zone \(index + 1): \(Int(zones.boundaries[index].rounded()))\(upper) BPM")
                    }
                    Text("Zones follow your resting heart rate slowly, by at most 2 BPM a week.").font(.caption)
                  }
                }
            }
            Section { NavigationLink("More options") { CalibrationOptionsView() } }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Calibration")
    }
    private func baseline(_ title: String, _ value: String?, nights: Int, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(value ?? "—").foregroundStyle(.secondary) }
            Text(ready ? "\(nights) nights counted · ready" : "\(min(nights, HealthConstants.recoveryMinimumNights)) of \(HealthConstants.recoveryMinimumNights) nights counted").font(.caption).foregroundStyle(.secondary)
        }
    }
}

import UserNotifications

struct CalibrationOptionsView: View {
    @EnvironmentObject private var personal: Personalization
    @EnvironmentObject private var band: BandManager
    @State private var weight = ""
    @State private var date = Date()
    @State private var excludedDate = Date()
    @EnvironmentObject private var store: DisplayStore
    @State private var excluded = false
    @State private var effort = 5
    @State private var workoutID = ""
    @State private var notes = ""
    @State private var sleepStart = Date().addingTimeInterval(-8 * 3600)
    @State private var sleepEnd = Date()
    @State private var error: String?
    @State private var reminder = false
    var body: some View {
        Form {
            Section("Weight history") {
                DatePicker("Effective date",selection: $date,in: ...Date(),displayedComponents: .date)
                TextField("Weight in \(UnitSystem.current.weightUnit)",text: $weight).keyboardType(.decimalPad)
                Button("Save weight") {
                    let units = UnitSystem.current
                    guard let shown = Double(weight.replacingOccurrences(of: ",", with: ".")), shown.isFinite, units.weightRange.contains(shown) else { error = "Enter a weight from \(Int(units.weightRange.lowerBound)) to \(Int(units.weightRange.upperBound)) \(units.weightUnit)."; return }
                    let kg = units.kilograms(fromDisplay: shown)
                    personal.feedback.weights.append(WeightEntry(date: date,kg: kg)); personal.saveFeedback(); weight = ""
                }
                ForEach(personal.feedback.weights.sorted { $0.date > $1.date }) { entry in Text("\(entry.date.formatted(date: .abbreviated,time: .omitted)) · \(UnitSystem.current.weightText(entry.kg))") }
                Toggle("Weekly weight reminder",isOn: $reminder).onChange(of: reminder) { _, enabled in
                    UserDefaults.standard.set(enabled,forKey: "weightReminder")
                    let center = UNUserNotificationCenter.current(); center.removePendingNotificationRequests(withIdentifiers: ["weight-reminder"])
                    if enabled { Task {
                        guard (try? await center.requestAuthorization(options: [.alert,.sound])) == true else { reminder = false; return }
                        let content = UNMutableNotificationContent(); content.title = "Update your weight"; content.body = "A current weight keeps your calorie numbers accurate."
                        try? await center.add(UNNotificationRequest(identifier: "weight-reminder",content: content,trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9,weekday: 2),repeats: true)))
                    } }
                }
            }
            Section("Illness or unreliable day") {
                DatePicker("Day",selection: $excludedDate,in: ...Date(),displayedComponents: .date)
                Button("Exclude selected day from learning") {
                    if !personal.feedback.excludedDays.contains(where: { Calendar.current.isDate($0,inSameDayAs: excludedDate) }) { personal.feedback.excludedDays.append(excludedDate); personal.saveFeedback() }
                }
                ForEach(personal.feedback.excludedDays,id: \.self) { day in
                    Button("Restore \(day.formatted(date: .abbreviated,time: .omitted))") { personal.feedback.excludedDays.removeAll { $0 == day }; personal.saveFeedback() }
                }
            }
            Section("Workout feedback") {
                Picker("Workout",selection: $workoutID) {
                    Text("Choose workout").tag("")
                    ForEach(band.workouts) { workout in Text("\(workout.type) · \(workout.start.formatted(date: .abbreviated,time: .shortened))").tag(workout.id.uuidString) }
                }
                Stepper("Perceived effort: \(effort)/10",value: $effort,in: 1...10)
                TextField("Optional sets and load",text: $notes)
                Button("Save feedback") { personal.feedback.efforts[workoutID] = effort; personal.feedback.strengthNotes[workoutID] = notes; personal.saveFeedback() }.disabled(workoutID.isEmpty)
            }
            Section("Sleep correction") {
                DatePicker("Sleep start",selection: $sleepStart,in: ...Date())
                DatePicker("Wake time",selection: $sleepEnd,in: ...Date())
                Button("Save corrected sleep window") {
                    guard sleepEnd > sleepStart, sleepEnd.timeIntervalSince(sleepStart) <= 24 * 3600 else { error = "Choose a sleep window shorter than 24 hours."; return }
                    let today = Int((Calendar.current.startOfDay(for: sleepEnd).timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: sleepEnd))) / 86400)
                    guard let sleep = try? band.storage?.sleeps(fromDay: today - 1,toDay: today + 1).min(by: { abs($0.session.end.timeIntervalSince(sleepEnd)) < abs($1.session.end.timeIntervalSince(sleepEnd)) }) else { error = "Sync a sleep session first."; return }
                    personal.feedback.sleepCorrections[String(sleep.session.start.timeIntervalSince1970)] = DateInterval(start: sleepStart,end: sleepEnd); personal.saveFeedback()
                }
            }
            Section("Unconfirmed activity") {
                Text("Sustained heart rate can reflect exercise, stress or heat.").font(.caption)
                ForEach(personal.activities) { activity in
                    VStack(alignment: .leading) {
                        Text("\(activity.start.formatted(date: .omitted,time: .shortened)) · \(activity.minutes.count) measured minutes")
                        Menu("Confirm as…") {
                            ForEach(ActivityKind.allCases) { kind in
                                Button(kind.rawValue) { var workout = Workout(type: kind.rawValue); workout.start = activity.start; workout.end = activity.end; workout.source = .detected; band.addWorkout(workout); personal.changed?() }
                            }
                        }
                        Button("Not activity") { personal.feedback.dismissedActivity.append(DateInterval(start: activity.start,end: activity.end)); personal.saveFeedback() }
                    }
                }
            }
            Section("Validation") { ShareLink("Export calibration and feedback",item: personal.export()); Text("Export contains personal health data. Share only with recipients you choose.").font(.caption) }
            if let message = personal.message { Section { Text(message) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("More options")
        .onAppear { reminder = UserDefaults.standard.bool(forKey: "weightReminder") }
    }
}
