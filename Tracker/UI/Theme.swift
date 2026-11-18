import SwiftUI
import UIKit

// Adaptive native design tokens shared by all Pulse screens.
// A colour keeps one meaning everywhere: strain blue, recovery green/yellow/red,
// sleep violet, heart rate red, calories amber.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Palette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let track = Color(uiColor: .quaternarySystemFill)
    static let hairline = Color(uiColor: .separator).opacity(0.35)
    static let border = Color(uiColor: .separator)

    static let text = Color.primary
    static let secondary = Color.secondary
    static let muted = Color.secondary
    static let onAccent = Color.white

    static let strain = Color(uiColor: .systemBlue)
    static let green = Color(uiColor: .systemGreen)
    static let yellow = Color(uiColor: .systemYellow)
    static let orange = Color(uiColor: .systemOrange)
    static let red = Color(uiColor: .systemRed)
    static let heart = Color(uiColor: .systemRed)
    static let calories = Color(uiColor: .systemOrange)
    static let restingCalories = Color(uiColor: .systemOrange).opacity(0.45)

    static let sleep = Color(uiColor: .systemIndigo)
    static let rem = Color(uiColor: .systemPurple)
    static let deep = Color(uiColor: .systemIndigo)
    static let awake = Color.secondary

    static let zone1 = Color(uiColor: .systemBlue)
    static let zone2 = Color(uiColor: .systemGreen)
    static let zone3 = Color(uiColor: .systemYellow)
    static let zone4 = Color(uiColor: .systemOrange)
    static let zone5 = Color(uiColor: .systemRed)
}

enum Typo {
    /// Scalable system numerals for health metrics and durations.
    static func number(_ size: CGFloat) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .title1).scaledValue(for: size), weight: .semibold).monospacedDigit()
    }
    /// Scalable section and control labels.
    static func label(_ size: CGFloat = 12, weight: Font.Weight = .semibold) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: size), weight: weight)
    }
    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: size), weight: weight)
    }
}

extension View {
    /// Semantic section heading. Tracking is retained in the API for source compatibility.
    func sectionLabel(size: CGFloat = 12, color: Color = Palette.muted, tracking: CGFloat = 1.6) -> some View {
        self.font(Typo.label(max(size, 13),weight: .semibold)).foregroundStyle(color)
    }
}

enum Format {
    /// 1450 -> "24:10"; 3725 -> "1:02:05"
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    /// 27720 -> "7h 42m"
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return String(format: "%dh %02dm", h, m)
    }
    /// 27720 -> "7:42"
    static func hoursColonMinutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    /// Short minutes text for time in zone: "1h 12m", "38 min", "2 min", "<1 min"
    static func zoneTime(_ seconds: TimeInterval) -> String {
        if seconds < 30 { return seconds <= 0 ? "0 min" : "<1 min" }
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes) min"
    }
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    static func kcal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
}
