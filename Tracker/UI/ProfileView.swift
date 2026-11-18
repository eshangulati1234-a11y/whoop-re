import SwiftUI

/// Age and body measurements used for zones, calories and strain. Stored only on this iPhone.
struct ProfileView: View {
    @AppStorage(HealthEngine.profileKey) private var profileData = Data()
    @EnvironmentObject private var personal: Personalization
    @Environment(\.dismiss) private var dismiss
    @State private var age = ""
    @State private var weight = ""
    @State private var height = ""
    @State private var sex = UserProfile.Sex.male
    @State private var maximum = ""
    @State private var resting = ""
    @State private var goal = ""
    @State private var sleepNeed = ""
    @State private var message: String?
    @State private var confirmRemove = false
    @AppStorage(UnitSystem.key) private var unitRaw = UnitSystem.metric.rawValue
    @State private var feet = ""
    @State private var inches = ""
    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About you").sectionLabel(size: 12, tracking: 1.8)
                        Text("Used for your heart rate zones, calories and strain. Everything stays on this iPhone.")
                            .font(Typo.body(12)).foregroundStyle(Palette.muted)
                        Hairline().padding(.vertical, 6)
                        field("Age", "yrs", $age, .numberPad)
                        Hairline()
                        field("Weight", units.weightUnit, $weight, .decimalPad)
                        Hairline()
                        if units == .metric { field("Height", "cm", $height, .decimalPad) }
                        else {
                            HStack(spacing: 8) {
                                Text("Height").font(Typo.body(15))
                                Spacer()
                                TextField("—", text: $feet).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.number(22)).frame(width: 44)
                                Text("ft").font(Typo.body(12)).foregroundStyle(Palette.muted)
                                TextField("—", text: $inches).keyboardType(.numberPad).multilineTextAlignment(.trailing).font(Typo.number(22)).frame(width: 44)
                                Text("in").font(Typo.body(12)).foregroundStyle(Palette.muted)
                            }
                            .frame(minHeight: 52)
                        }
                        Hairline()
                        HStack {
                            Text("Sex for energy formula").font(Typo.body(15))
                            Spacer()
                            HStack(spacing: 6) {
                                ForEach(UserProfile.Sex.allCases, id: \.self) { option in
                                    Button { Haptics.select(); sex = option } label: {
                                        Text(option.rawValue.capitalized).font(Typo.body(13, weight: .semibold))
                                            .padding(.horizontal, 14).frame(height: 34)
                                            .background(sex == option ? Palette.text : Palette.raised, in: Capsule())
                                            .foregroundStyle(sex == option ? Palette.onAccent : Palette.text)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(minHeight: 52)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional").sectionLabel(size: 12, tracking: 1.8)
                        Text("Leave blank to use a value based on your age.").font(Typo.body(12)).foregroundStyle(Palette.muted)
                        Hairline().padding(.vertical, 6)
                        field("Max heart rate", "bpm", $maximum, .numberPad, optional: true)
                        Hairline()
                        field("Resting heart rate", "bpm", $resting, .numberPad, optional: true)
                        Hairline()
                        field("Daily calorie goal", "kcal", $goal, .numberPad, optional: true)
                        Hairline()
                        field("Sleep need", "hrs", $sleepNeed, .decimalPad, optional: true)
                    }
                }
                if let message {
                    Text(message).font(Typo.body(13)).foregroundStyle(Palette.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Save profile", action: save).buttonStyle(PillButtonStyle(height: 56))
                if !profileData.isEmpty {
                    Button("Remove profile") { confirmRemove = true }
                        .font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.red).frame(minHeight: 44)
                }
                Text("Used for your calories, strain and zones.")
                    .font(Typo.body(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Profile").font(Typo.label(16, weight: .bold)) } }
        
        .confirmationDialog("Remove your profile?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove profile", role: .destructive) { profileData = Data(); dismiss() }
        } message: { Text("Calories and strain will stop showing until you add it again.") }
        .onAppear(perform: load)
    }

    private func field(_ title: String, _ unit: String, _ text: Binding<String>, _ keyboard: UIKeyboardType, optional: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Typo.body(15))
            Spacer()
            TextField(optional ? "Auto" : "—", text: text)
                .keyboardType(keyboard).multilineTextAlignment(.trailing)
                .font(Typo.number(22)).frame(width: 96)
            Text(unit).font(Typo.body(12)).foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading)
        }
        .frame(minHeight: 52)
    }

    private func load() {
        guard let profile = try? JSONDecoder().decode(UserProfile.self, from: profileData) else { return }
        age = String(profile.ageYears); sex = profile.sex
        weight = Self.text((units.weight(fromKg: profile.weightKg) * 10).rounded() / 10); height = Self.text(profile.heightCm)
        let parts = UnitSystem.feetInches(fromCm: profile.heightCm); feet = String(parts.feet); inches = String(parts.inches)
        maximum = profile.maxHROverride.map(String.init) ?? ""; resting = profile.restingHROverride.map(String.init) ?? ""
        goal = profile.dailyCalorieGoal.map { String(Int($0)) } ?? ""; sleepNeed = profile.sleepNeedHours.map(Self.text) ?? ""
    }

    private static func text(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
    private func number(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    private func save() {
        let heightCm: Double? = units == .metric ? number(height) : Int(feet.trimmingCharacters(in: .whitespaces)).map { UnitSystem.centimetres(feet: $0, inches: Int(inches.trimmingCharacters(in: .whitespaces)) ?? 0) }
        guard let age = Int(age.trimmingCharacters(in: .whitespaces)), let shownWeight = number(weight), let height = heightCm else {
            message = "Enter your age, weight and height."; return
        }
        let weight = units.kilograms(fromDisplay: shownWeight)
        func optional<T>(_ text: String, _ parse: (String) -> T?) -> T?? {
            text.trimmingCharacters(in: .whitespaces).isEmpty ? .some(nil) : parse(text).map { .some($0) }
        }
        guard let max = optional(maximum, { Int($0.trimmingCharacters(in: .whitespaces)) }), let rest = optional(resting, { Int($0.trimmingCharacters(in: .whitespaces)) }),
              let calories = optional(goal, { number($0) }), let sleepHours = optional(sleepNeed, { number($0) }) else {
            message = "Optional fields must be numbers or blank."; return
        }
        var profile = UserProfile(ageYears: age, weightKg: weight, heightCm: height, sex: sex)
        profile.maxHROverride = max; profile.restingHROverride = rest; profile.dailyCalorieGoal = calories; profile.sleepNeedHours = sleepHours
        if let error = profile.validationError { message = error; return }
        if let hours = sleepHours, !(4...12).contains(hours) { message = "Sleep need must be between 4 and 12 hours."; return }
        if let calories, !(500...10000).contains(calories) { message = "Calorie goal must be between 500 and 10,000."; return }
        do {
            if let prior = HealthEngine.loadProfile(), personal.feedback.weights.isEmpty { personal.feedback.weights.append(WeightEntry(date: Date(timeIntervalSince1970: 0),kg: prior.weightKg)) }
            personal.feedback.weights.append(WeightEntry(date: Date(),kg: profile.weightKg)); personal.saveFeedback()
            profileData = try JSONEncoder().encode(profile); Haptics.success(); dismiss() } catch { message = error.localizedDescription }
    }
}
