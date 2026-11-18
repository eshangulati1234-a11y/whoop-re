import SwiftUI
import Charts

struct HeartHealthView: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore

    private var maxHR: Int { ZoneConfig.maxHR }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = store.linkState(at: context.date)
            ScrollView {
                VStack(spacing: 16) {
                    header(state)
                    metricsGrid(state)
                    traceCard
                    statsCard
                    zonesCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .screenBackground()
        
    }

    // MARK: Header and hero

    private func header(_ state: LinkState) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heart").sectionLabel(size: 12, tracking: 2)
                Text("Heart health").font(.headline)
            }
            Spacer()
            ConnectionChip(state: state)
        }
    }

    private func metricsGrid(_ state: LinkState) -> some View {
        let bpm = store.current?.bpm
        let zone = bpm.flatMap { ZoneBand.band(for: $0, maxHR: maxHR) }
        let resting = store.calibration.restingHR.map { Int($0.rounded()) } ?? store.lastSleep?.sleepingHR
        let hrv = store.lastSleep?.hrv
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            metricTile(title: "Heart rate", value: bpm.map(String.init), unit: "BPM", tint: Palette.heart, live: state.isLive,
                       caption: state.isLive ? (zone.map { "\($0.title) · \($0.intensity)" } ?? "Resting") : state.detail)
            metricTile(title: "Resting heart rate", value: resting.map(String.init), unit: "BPM", tint: Palette.heart, live: true,
                       caption: resting == nil ? "Measured while you sleep" : "Lowest while asleep")
            metricTile(title: "HRV", value: hrv.map { String(Int($0.rounded())) }, unit: "ms", tint: Palette.sleep, live: true,
                       caption: hrv == nil ? "Measured while you sleep" : "Last night")
            metricTile(title: "Blood oxygen", value: nil, unit: "%", tint: Palette.strain, live: true, caption: "No reading yet")
        }
    }

    private func metricTile(title: String, value: String?, unit: String, tint: Color, live: Bool, caption: String) -> some View {
        Card(radius: 20, stretch: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(title).sectionLabel(size: 12, tracking: 1.4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value ?? "—").font(Typo.number(40)).foregroundStyle(value != nil && live ? Palette.text : Palette.muted)
                        .contentTransition(.numericText())
                    Text(unit).sectionLabel(size: 12, tracking: 1.2)
                }
                Text(caption).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.map { $0 + " " + unit } ?? "no reading"). \(caption)")
    }

    // MARK: Trace

    private var traceCard: some View {
        let points = store.trace
        let minutes = points.count > 1 ? max(1, Int((points.last!.date.timeIntervalSince(points.first!.date) / 60).rounded())) : 0
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(minutes > 0 ? "Last \(minutes) min" : "Live trace").sectionLabel(size: 12, tracking: 1.8)
                }
                if points.count > 1 {
                    traceChart(points)
                        .frame(height: 150)
                } else {
                    Text("Your heart rate appears here once your band is connected.")
                        .font(Typo.body(13)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func traceChart(_ points: [HRPoint]) -> some View {
        let values = points.map(\.bpm)
        let lo = max(30, (values.min() ?? 60) - 8)
        let hi = max((values.max() ?? 100) + 10, lo + 40)
        let xs = (points.first?.date ?? Date())...(points.last?.date ?? Date())
        let bands = ZoneBand.allCases.filter { $0.ceilingBPM(maxHR: maxHR) > lo && $0.floorBPM(maxHR: maxHR) < hi }
        let floors = bands.map { $0.floorBPM(maxHR: maxHR) }.filter { $0 > lo && $0 < hi }
        return Chart {
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Start", xs.lowerBound), xEnd: .value("End", xs.upperBound),
                    yStart: .value("Low", max(lo, band.floorBPM(maxHR: maxHR))),
                    yEnd: .value("High", min(hi, band.ceilingBPM(maxHR: maxHR))))
                .foregroundStyle(band.color.opacity(0.10))
            }
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), yStart: .value("Base", lo), yEnd: .value("BPM", point.bpm))
                    .foregroundStyle(LinearGradient(colors: [Palette.heart.opacity(0.28), Palette.heart.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.date), y: .value("BPM", point.bpm))
                    .foregroundStyle(Palette.heart)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let last = points.last {
                PointMark(x: .value("Time", last.date), y: .value("BPM", last.bpm))
                    .foregroundStyle(Palette.heart).symbolSize(70)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: xs)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: floors) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(Palette.border)
                AxisValueLabel {
                    if let bpm = value.as(Int.self), let band = ZoneBand.allCases.first(where: { $0.floorBPM(maxHR: maxHR) == bpm }) {
                        Text(band.shortTitle).font(Typo.label(11)).foregroundStyle(band.color)
                    }
                }
            }
        }
        .accessibilityLabel("Heart rate trace, currently \(points.last?.bpm ?? 0) beats per minute")
    }

    // MARK: Today

    private var todayPoints: [HRPoint] { store.historyToday(band) }

    private var statsCard: some View {
        let history = todayPoints
        let source = history.isEmpty ? store.trace : history
        let stats = HRMath.stats(source)
        let since = source.first.map { Format.time($0.date) }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let coversDay = (source.first?.date ?? Date()) < startOfDay.addingTimeInterval(3600)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(coversDay || since == nil ? "Today" : "Since \(since!)").sectionLabel(size: 12, tracking: 1.8)
                }
                HStack {
                    StatColumn(title: "Min", value: stats.map { String($0.min) } ?? "—")
                    StatColumn(title: "Average", value: stats.map { String($0.avg) } ?? "—")
                    StatColumn(title: "Max", value: stats.map { String($0.max) } ?? "—")
                }
            }
        }
    }

    private var zonesCard: some View {
        let zones = HRMath.timeInZones(todayPoints, maxHR: maxHR)
        let total = zones.values.reduce(0, +)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("HR zones").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    if total > 0 { Text(Format.hoursMinutes(total)).font(Typo.body(12)).foregroundStyle(Palette.muted) }
                }
                if total > 0 {
                    ZoneTimeList(zones: zones, maxHR: maxHR)
                } else {
                    Text("Time in each zone appears here once your band has recorded today.")
                        .font(Typo.body(13)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
