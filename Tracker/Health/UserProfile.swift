import Foundation

struct UserProfile: Codable, Equatable {
    enum Sex: String, Codable, CaseIterable { case male, female }
    var ageYears: Int
    var weightKg: Double
    var heightCm: Double
    var sex: Sex
    var maxHROverride: Int?
    var restingHROverride: Int?
    var dailyCalorieGoal: Double?
    var sleepNeedHours: Double?
    var validationError: String? {
        guard (18...100).contains(ageYears) else { return "Enter an age from 18 to 100 for the adult estimation models." }
        guard weightKg.isFinite, (25...350).contains(weightKg) else { return "Enter a weight from 25 to 350 kg." }
        guard heightCm.isFinite, (100...250).contains(heightCm) else { return "Enter a height from 100 to 250 cm." }
        if let maxHROverride, !(100...240).contains(maxHROverride) { return "Maximum HR must be from 100 to 240 BPM." }
        if let restingHROverride, !(30...120).contains(restingHROverride) { return "Resting HR must be from 30 to 120 BPM." }
        if let maxHROverride, let restingHROverride, maxHROverride <= restingHROverride { return "Maximum HR must exceed resting HR." }
        return nil
    }
}
