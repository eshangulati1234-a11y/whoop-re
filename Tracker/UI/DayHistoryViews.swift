import SwiftUI

/// Days with recorded data, shared by the week pager and the month calendar.
@MainActor final class DayHistory: ObservableObject {
    @Published private(set) var days: Set<Date> = []
    @Published private(set) var earliest: Date?
    private let calendar = Calendar.current

    func refresh(_ store: DisplayStore) {
        let today = calendar.startOfDay(for: Date())
        let first = store.earliestDay?().map { calendar.startOfDay(for: $0) }
        earliest = first
        let from = first ?? (calendar.date(byAdding: .day, value: -60, to: today) ?? today)
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        days = store.daysWithData?(from, to) ?? []
    }
    func hasData(_ day: Date) -> Bool { days.contains(calendar.startOfDay(for: day)) }
}

/// Swipe back through every past week. A dot marks days with data; the calendar button opens the month view.
struct WeekPager: View {
    @EnvironmentObject private var store: DisplayStore
    @ObservedObject var history: DayHistory
    var onPick: (Date) -> Void
    var onCalendar: () -> Void
    @State private var weekID: Date?

    private let calendar = Calendar.current

    private var weeks: [Date] {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let floor = history.earliest ?? (calendar.date(byAdding: .weekOfYear, value: -7, to: thisWeek) ?? thisWeek)
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: min(floor, thisWeek))?.start ?? thisWeek
        var result: [Date] = []; var week = firstWeek
        while week <= thisWeek, result.count < 520 {
            result.append(week)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
            week = next
        }
        return result
    }

    var body: some View {
        let today = calendar.startOfDay(for: Date())
        let weeks = weeks
        VStack(spacing: 6) {
            HStack {
                Text(title(for: weekID ?? weeks.last ?? today)).sectionLabel(size: 12, tracking: 1.6)
                Spacer()
                if weekID != nil, weekID != weeks.last {
                    Button("Today") { Haptics.select(); withAnimation { weekID = weeks.last } }
                        .font(Typo.label(12, weight: .semibold)).foregroundStyle(Palette.strain).frame(minHeight: 32)
                }
                Button { Haptics.select(); onCalendar() } label: {
                    Image(systemName: "calendar").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 32)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.text).accessibilityLabel("Open calendar")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(weeks, id: \.self) { start in
                        weekRow(start, today: today).containerRelativeFrame(.horizontal).id(start)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $weekID, anchor: .leading)
            .frame(height: 70)
            .onAppear { if weekID == nil { weekID = weeks.last } }
        }
    }

    private func title(for week: Date) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: week) ?? week
        if calendar.isDate(week, equalTo: end, toGranularity: .month) {
            return week.formatted(.dateTime.month(.wide).year())
        }
        return week.formatted(.dateTime.month(.abbreviated)) + " – " + end.formatted(.dateTime.month(.abbreviated).year())
    }

    private func weekRow(_ start: Date, today: Date) -> some View {
        HStack {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                let isToday = calendar.isDate(day, inSameDayAs: today)
                let isFuture = day > today
                let hasData = history.hasData(day)
                Button { if !isToday && !isFuture { Haptics.select(); onPick(day) } } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(Typo.label(12))
                        Text(day.formatted(.dateTime.day())).font(Typo.number(20))
                        Circle().fill(hasData ? (isToday ? Palette.background : Palette.strain) : .clear).frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isToday ? Palette.background : (isFuture ? Palette.muted.opacity(0.5) : Palette.text))
                .frame(width: 44, height: 66)
                .background(isToday ? Palette.text : .clear, in: Capsule())
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()) + (isToday ? ", today" : "") + (hasData ? ", has data" : ""))
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Month grid for jumping to any past day. Days with data carry a dot.
struct CalendarSheet: View {
    @ObservedObject var history: DayHistory
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date
    private let calendar = Calendar.current

    init(history: DayHistory, onPick: @escaping (Date) -> Void) {
        self.history = history; self.onPick = onPick
        let c = Calendar.current
        _month = State(initialValue: c.dateInterval(of: .month, for: Date())?.start ?? Date())
    }

    private var thisMonth: Date { calendar.dateInterval(of: .month, for: Date())?.start ?? Date() }
    private var firstMonth: Date? { history.earliest.flatMap { calendar.dateInterval(of: .month, for: $0)?.start } }
    private var canGoBack: Bool { firstMonth.map { month > $0 } ?? true }
    private var canGoForward: Bool { month < thisMonth }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(!canGoBack).accessibilityLabel("Previous month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(Typo.number(22))
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(!canGoForward).accessibilityLabel("Next month")
                    Button("Done") { dismiss() }.font(Typo.body(15, weight: .semibold)).frame(minHeight: 44).padding(.leading, 8)
                }
                .foregroundStyle(Palette.text)
                grid
                HStack(spacing: 6) {
                    Circle().fill(Palette.strain).frame(width: 6, height: 6)
                    Text("Recorded data").font(Typo.body(12)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                Spacer()
            }
            .padding(20)
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width > 60, canGoBack { step(-1) } else if value.translation.width < -60, canGoForward { step(1) }
        })
        .presentationDetents([.medium, .large])
    }

    private func step(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        Haptics.select(); withAnimation(.snappy) { month = next }
    }

    private var grid: some View {
        let today = calendar.startOfDay(for: Date())
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(spacing: 8) {
            HStack { ForEach(ordered.indices, id: \.self) { Text(ordered[$0]).font(Typo.label(12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(-lead..<0, id: \.self) { _ in Color.clear.frame(height: 48) }
                ForEach(0..<count, id: \.self) { index in
                    let day = calendar.date(byAdding: .day, value: index, to: first) ?? first
                    let isToday = calendar.isDate(day, inSameDayAs: today)
                    let isFuture = day > today
                    let hasData = history.hasData(day)
                    Button {
                        guard !isToday, !isFuture else { return }
                        Haptics.select(); onPick(day)
                    } label: {
                        VStack(spacing: 3) {
                            Text(day.formatted(.dateTime.day())).font(Typo.number(18))
                            Circle().fill(hasData ? (isToday ? Palette.background : Palette.strain) : .clear).frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(isToday ? Palette.text : (hasData ? Palette.card : .clear), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isToday ? Palette.background : (isFuture ? Color(uiColor: .quaternaryLabel) : (hasData ? Palette.text : Color(uiColor: .tertiaryLabel))))
                    .disabled(isFuture || isToday)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()) + (hasData ? ", has data" : ", no data"))
                }
            }
        }
    }
}
