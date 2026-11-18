import SwiftUI
import Charts

struct CaloriesView: View {
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let calories = store.day.calories {
                    totalCard(calories)
                    hourlyCard(calories)
                    sourcesCard(calories)
                } else {
                    EmptyStateCard(
                        symbol: "flame", title: "Calories aren't available yet",
                        message: "Add your profile and wear your band, and today's total appears here.",
                        tint: Palette.calories)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Calories").font(Typo.label(16, weight: .bold)) } }
        
    }

    private func totalCard(_ calories: DisplayCalories) -> some View {
        let denominator = max(calories.goal ?? calories.total, 1)
        let restingShare = calories.resting / denominator
        let activeShare = calories.active / denominator
        return Card(padding: 18) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Palette.track, lineWidth: 9).padding(4.5)
                    Circle().trim(from: 0, to: min(1, restingShare))
                        .stroke(Palette.restingCalories, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                        .rotationEffect(.degrees(-90)).padding(4.5)
                    Circle().trim(from: min(1, restingShare), to: min(1, restingShare + activeShare))
                        .stroke(Palette.calories, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                        .rotationEffect(.degrees(-90)).padding(4.5)
                    Image(systemName: "flame.fill").font(.system(size: 32)).foregroundStyle(Palette.calories)
                }
                .frame(width: 148, height: 148)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Format.kcal(calories.total)) calories: \(Format.kcal(calories.resting)) resting and \(Format.kcal(calories.active)) active")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Total burn").sectionLabel(size: 12, tracking: 1.8)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Format.kcal(calories.total)).font(Typo.number(46))
                        Text("kcal").sectionLabel(size: 12, tracking: 1.4)
                    }
                    if let goal = calories.goal {
                        Text("\(Int((calories.total / goal * 100).rounded()))% of \(Format.kcal(goal)) kcal goal")
                            .font(Typo.body(12)).foregroundStyle(Palette.muted)
                    }
                    VStack(spacing: 6) {
                        legendRow(Palette.calories, "Active", Format.kcal(calories.active))
                        legendRow(Palette.restingCalories, "Resting", Format.kcal(calories.resting))
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func legendRow(_ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title).font(Typo.body(13, weight: .medium))
            Spacer()
            Text(value).font(Typo.body(13, weight: .semibold))
        }
    }

    private func hourlyCard(_ calories: DisplayCalories) -> some View {
        let hours = calories.hourly.enumerated().compactMap { index, value in value.map { (index, $0) } }
        let restingPerHour = calories.resting / Double(max(hours.count, 1))
        let peak = hours.max { $0.1 < $1.1 }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Hourly burn").sectionLabel(size: 12, tracking: 1.8)
                    Spacer()
                    if let peak {
                        Text("Peak \(Format.kcal(peak.1)) kcal at \(hourLabel(peak.0))").font(Typo.body(12)).foregroundStyle(Palette.muted)
                    }
                }
                Chart {
                    ForEach(hours, id: \.0) { hour, kcal in
                        BarMark(x: .value("Hour", hour), y: .value("kcal", kcal), width: .fixed(9))
                            .foregroundStyle(kcal > restingPerHour * 1.5 ? Palette.calories : Palette.restingCalories)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) { Text(hourLabel(hour)).font(Typo.body(11)).foregroundStyle(Palette.muted) }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 110)
                .accessibilityLabel("Calories burned each hour today")
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12a"
        case 12: "12p"
        case 1..<12: "\(hour)a"
        default: "\(hour - 12)p"
        }
    }

    private func sourcesCard(_ calories: DisplayCalories) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Where it came from").sectionLabel(size: 12, tracking: 1.8)
                ForEach(calories.sources) { source in
                    let share = source.kcal / max(calories.total, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            if let symbol = source.symbol { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(source.isResting ? Palette.restingCalories : Palette.calories).frame(width: 20) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(Typo.body(14, weight: .semibold))
                                if let detail = source.detail { Text(detail).font(Typo.body(12)).foregroundStyle(Palette.muted) }
                            }
                            Spacer()
                            Text("\(Format.kcal(source.kcal)) kcal · \(Int((share * 100).rounded()))%")
                                .font(Typo.body(13)).foregroundStyle(Palette.muted)
                        }
                        ProgressTrack(progress: share, color: source.isResting ? Palette.restingCalories : Palette.calories)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
