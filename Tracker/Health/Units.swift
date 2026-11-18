import Foundation

/// Display units only. Everything stored and calculated stays in kilograms and centimetres.
enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, imperial
    static let key = "unitSystem"
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric (kg, cm)" : "Imperial (lb, ft, in)" }
    var weightUnit: String { self == .metric ? "kg" : "lb" }

    static var current: UnitSystem { UnitSystem(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .metric }

    static let poundsPerKilogram = 2.2046226218
    func weight(fromKg kg: Double) -> Double { self == .metric ? kg : kg * Self.poundsPerKilogram }
    func kilograms(fromDisplay value: Double) -> Double { self == .metric ? value : value / Self.poundsPerKilogram }
    func weightText(_ kg: Double) -> String { String(format: "%.1f", weight(fromKg: kg)).replacingOccurrences(of: ".0", with: "") + " " + weightUnit }
    /// Valid entry range in the displayed unit.
    var weightRange: ClosedRange<Double> { self == .metric ? 25...350 : 55...770 }

    static func feetInches(fromCm cm: Double) -> (feet: Int, inches: Int) {
        let total = Int((cm / 2.54).rounded())
        return (total / 12, total % 12)
    }
    static func centimetres(feet: Int, inches: Int) -> Double { Double(feet * 12 + inches) * 2.54 }
    func heightText(_ cm: Double) -> String {
        if self == .metric { return "\(Int(cm.rounded())) cm" }
        let parts = Self.feetInches(fromCm: cm); return "\(parts.feet) ft \(parts.inches) in"
    }
}
