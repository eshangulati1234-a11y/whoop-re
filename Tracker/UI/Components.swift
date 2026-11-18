import SwiftUI
import UIKit

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = 24
    var fill: Color = Palette.card
    var stroke: Color? = nil
    /// Stretch to the height offered by the parent (equal-height tiles side by side).
    var stretch = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke, lineWidth: 1)
                }
            }
    }
}

struct ScreenBackground: ViewModifier {

    func body(content: Content) -> some View {
        content
            // Native navigation owns the safe area; retain only content breathing room.
            .contentMargins(.bottom, 24, for: .scrollContent)
.scrollDismissesKeyboard(.interactively)
            .background(Palette.background.ignoresSafeArea())
    }
}
extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

/// One place for all feedback so it can be switched off (Device → Haptics) and kept consistent.
enum Haptics {
    static let key = "hapticsEnabled"
    private static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Button press.
    static func tap() { if enabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    /// Lighter touch for cards and links.
    static func soft() { if enabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() } }
    /// Weightier moments: starting to hold, zone changes.
    static func medium() { if enabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    /// Choosing an option, switching tabs, flipping a toggle.
    static func select() { if enabled { UISelectionFeedbackGenerator().selectionChanged() } }
    static func success() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
}

/// Card and row links: a small spring press and a soft tick.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in if pressed { Haptics.soft() } }
    }
}

// MARK: - Rings

struct RingView<Center: View>: View {
    var progress: Double?
    var color: Color
    var size: CGFloat
    var lineWidth: CGFloat = 8
    /// Dashed grey track and no fill: the score exists but is not available yet.
    var calibrating = false
    @ViewBuilder var center: Center
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if calibrating {
                Circle().stroke(Palette.muted.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth / 2, lineCap: .round, dash: [2, 9])).padding(lineWidth / 2)
            } else {
                Circle().stroke(Palette.track, lineWidth: lineWidth).padding(lineWidth / 2)
            }
            if let progress, !calibrating {
                Circle()
                    .trim(from: 0, to: appeared || reduceMotion ? max(0.002, min(1, progress)) : 0.002)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            }
            center
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: progress)
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: appeared)
        .onAppear { appeared = true }
    }
}

/// Five-segment ring: segments up to and including `zone` are lit in their zone colour.
struct ZoneRing<Center: View>: View {
    var zone: ZoneBand?
    var size: CGFloat
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            ForEach(ZoneBand.allCases) { band in
                let start = Double(band.rawValue - 1) / 5 + 0.008
                let end = Double(band.rawValue) / 5 - 0.008
                let lit = zone.map { band.rawValue <= $0.rawValue } ?? false
                Circle()
                    .trim(from: start, to: end)
                    .stroke(lit ? band.color : Color(hex: 0x2A353D), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            }
            center
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

struct PillButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var height: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                if kind == .primary {
                    Button { configuration.trigger() } label: { configuration.label.frame(maxWidth: .infinity,minHeight: height).font(.headline) }.buttonStyle(.glassProminent)
                } else {
                    Button { configuration.trigger() } label: { configuration.label.frame(maxWidth: .infinity,minHeight: height).font(.headline) }.buttonStyle(.glass)
                }
            } else {
                if kind == .primary {
                    Button { configuration.trigger() } label: { configuration.label.frame(maxWidth: .infinity,minHeight: height).font(.headline) }.buttonStyle(.borderedProminent)
                } else {
                    Button { configuration.trigger() } label: { configuration.label.frame(maxWidth: .infinity,minHeight: height).font(.headline) }.buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.large)
        .tint(kind == .destructive ? Palette.red : Palette.strain)
        .frame(maxWidth: .infinity,minHeight: height)
    }
}

struct CircleIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

// MARK: - Labels and stats

struct StatColumn: View {
    var title: String
    var value: String
    var unit: String? = nil
    var color: Color = Palette.text
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).sectionLabel(size: 11, tracking: 1.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Typo.number(size)).foregroundStyle(color)
                if let unit { Text(unit).sectionLabel(size: 11, tracking: 1.4) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionChip: View {
    var state: LinkState
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text(state.title).font(Typo.label(12, weight: .bold))
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(state.color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(state.title)")
    }
}

struct EmptyStateCard: View {
    var symbol: String
    var title: String
    var message: String
    var tint: Color = Palette.muted
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.bottom, 2)
                Text(title).font(Typo.number(20))
                Text(message)
                    .font(Typo.body(13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Charts

struct Sparkline: View {
    var values: [Int]
    var color: Color = Palette.heart

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let span = Double(max(hi - lo, 8))
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * Double(index) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (Double(value - lo) / span))
                        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                Rectangle().fill(Palette.track).frame(height: 2).frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .accessibilityHidden(true)
    }
}

struct HypnogramView: View {
    var segments: [DisplaySleepSegment]
    var rowHeight: CGFloat = 18
    var rowGap: CGFloat = 6

    var body: some View {
        let start = segments.first?.start ?? Date()
        let end = segments.last?.end ?? Date()
        let span = max(end.timeIntervalSince(start), 1)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { row in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.track)
                        .frame(width: geo.size.width, height: rowHeight)
                        .offset(y: CGFloat(row) * (rowHeight + rowGap))
                }
                ForEach(segments) { segment in
                    let x = segment.start.timeIntervalSince(start) / span * geo.size.width
                    let w = max(segment.duration / span * geo.size.width - 1, 2)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(segment.stage.color)
                        .frame(width: w, height: rowHeight)
                        .offset(x: x, y: CGFloat(segment.stage.row) * (rowHeight + rowGap))
                }
            }
        }
        .frame(height: 4 * rowHeight + 3 * rowGap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages across the night")
    }
}

/// Zone rows with a bar scaled to the longest zone. Highest zone on top.
struct ZoneTimeList: View {
    var zones: [ZoneBand: TimeInterval]
    var maxHR: Int

    var body: some View {
        let longest = max(zones.values.max() ?? 0, 1)
        VStack(spacing: 10) {
            ForEach(ZoneBand.allCases.reversed()) { band in
                let seconds = zones[band] ?? 0
                HStack(spacing: 12) {
                    Text(band.title).font(Typo.label(12, weight: .semibold))
                        .foregroundStyle(band.color)
                        .frame(width: 58, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule().fill(band.color).frame(width: max(seconds > 0 ? 6 : 0, geo.size.width * seconds / longest))
                        }
                    }
                    .frame(height: 8)
                    Text(Format.zoneTime(seconds)).font(Typo.body(12, weight: .medium))
                        .foregroundStyle(seconds > 0 ? Palette.text : Palette.muted)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(band.title), \(band.floorBPM(maxHR: maxHR)) to \(band.ceilingBPM(maxHR: maxHR)) beats per minute, \(Format.zoneTime(seconds))")
            }
        }
    }
}

// MARK: - Activity row

struct ActivityStat: Identifiable {
    var id = UUID()
    var label: String
    var value: String
    var valueFirst = false

    static func avgHR(_ bpm: Int) -> ActivityStat { ActivityStat(label: "Avg HR", value: String(bpm)) }
    static func maxHR(_ bpm: Int) -> ActivityStat { ActivityStat(label: "Max", value: String(bpm)) }
    static func kcal(_ value: Double) -> ActivityStat { ActivityStat(label: "kcal", value: Format.kcal(value), valueFirst: true) }
    static func note(_ text: String) -> ActivityStat { ActivityStat(label: text, value: "") }
}

struct ActivityRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var strain: Double?
    var stats: [ActivityStat]
    var badge: String? = nil
    var highlight: Bool = false
    var trailingHint: String? = nil

    var body: some View {
        Card(radius: 20, stroke: highlight ? Palette.strain.opacity(0.5) : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(highlight ? Palette.strain : Palette.text)
                        .frame(width: 44, height: 44)
                        .background(highlight ? Palette.strain.opacity(0.16) : Palette.raised, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(title).font(Typo.number(20))
                            if let badge {
                                Text(badge).font(Typo.label(10, weight: .semibold))
                                    .foregroundStyle(Palette.strain)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .overlay { Capsule().stroke(Palette.strain, lineWidth: 1) }
                            }
                        }
                        Text(subtitle).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                    if let strain {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(strain.formatted(.number.precision(.fractionLength(1)))).font(Typo.number(26)).foregroundStyle(Palette.strain)
                            Text("Strain").sectionLabel(size: 10, tracking: 1.4)
                        }
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.muted)
                    }
                }
                HStack(spacing: 18) {
                    ForEach(stats) { stat in
                        HStack(spacing: 4) {
                            if stat.valueFirst {
                                Text(stat.value).font(Typo.body(12, weight: .semibold)).foregroundStyle(Palette.text)
                                Text(stat.label).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                            } else {
                                Text(stat.label).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
                                if !stat.value.isEmpty {
                                    Text(stat.value).font(Typo.body(12, weight: .semibold)).foregroundStyle(Palette.text)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let trailingHint {
                        HStack(spacing: 2) {
                            Text(trailingHint).font(Typo.body(12, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Palette.strain)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings rows

struct SettingToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body(14, weight: .semibold))
                Text(subtitle).font(Typo.body(12)).foregroundStyle(Palette.muted)
            }
        }
        .tint(Palette.strain)
        .frame(minHeight: 60)
        .onChange(of: isOn) { _, _ in Haptics.select() }
    }
}

struct SettingLinkLabel: View {
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.text)
                if let subtitle { Text(subtitle).font(Typo.body(12)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
            if let value { Text(value).font(Typo.number(20)).foregroundStyle(Palette.text) }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.muted)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.track).frame(height: 1) }
}


/// A strap with a sensor pod, drawn so the Device tab reads as a band rather than a watch. Takes the foreground colour.
struct BandGlyph: View {
    var filled = false
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let strap = Path(roundedRect: CGRect(x: 0, y: h * 0.40, width: w, height: h * 0.20), cornerRadius: h * 0.08)
            let pod = Path(roundedRect: CGRect(x: w * 0.33, y: h * 0.16, width: w * 0.34, height: h * 0.68), cornerRadius: h * 0.12)
            let shading = GraphicsContext.Shading.foreground
            if filled {
                context.fill(strap, with: shading)
                context.fill(pod, with: shading)
                context.blendMode = .destinationOut
                context.fill(Path(ellipseIn: CGRect(x: w * 0.5 - h * 0.12, y: h * 0.5 - h * 0.12, width: h * 0.24, height: h * 0.24)), with: .color(.black))
            } else {
                context.stroke(strap, with: shading, lineWidth: 1.8)
                context.blendMode = .destinationOut
                context.fill(pod, with: .color(.black))
                context.blendMode = .normal
                context.stroke(pod, with: shading, lineWidth: 1.8)
                context.fill(Path(ellipseIn: CGRect(x: w * 0.5 - h * 0.1, y: h * 0.5 - h * 0.1, width: h * 0.2, height: h * 0.2)), with: shading)
            }
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
