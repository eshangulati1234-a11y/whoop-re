import SwiftUI

enum AppTab: Hashable {
    case home, sleep, heart, device
}

enum Presentation: Identifiable, Hashable {
    case workouts
    case start
    case active
    case summary(UUID)
    case detected(String)

    var id: String {
        switch self {
        case .workouts: "workouts"
        case .start: "start"
        case .active: "active"
        case .summary(let id): "summary-\(id.uuidString)"
        case .detected(let id): "detected-\(id)"
        }
    }
}

@MainActor final class Router: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var presented: Presentation?
    @Published var showingBandSetup = false
}

struct RootView: View {
    @EnvironmentObject private var band: BandManager
    @Environment(\.scenePhase) private var scenePhase
    // Plain @State: the root must not re-render on every heart-rate tick; child views observe the store.
    @State private var store = DisplayStore()
    @State private var health = HealthEngine()
    @StateObject private var router = Router()
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var checkedOnboarding = false

    var body: some View {
        TabView(selection: $router.tab) {
            NativeTabRoot(title: "Home") { HomeView() }
                .tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
            NativeTabRoot(title: "Sleep") { SleepView() }
                .tabItem { Label("Sleep", systemImage: "moon") }.tag(AppTab.sleep)
            NativeTabRoot(title: "Heart") { HeartHealthView() }
                .tabItem { Label("Heart", systemImage: "heart") }.tag(AppTab.heart)
            NativeTabRoot(title: "Device") { DeviceView() }
                .tabItem { Label("Device", systemImage: "applewatch") }.tag(AppTab.device)
        }
        .modifier(WorkoutAccessory())
        .tint(Palette.strain)
        .environmentObject(store)
        .environmentObject(health.personalization)
        .environmentObject(router)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingDone = true
                showOnboarding = false
            }
            .environmentObject(band)
            .environmentObject(health.personalization)
        }
        .sheet(isPresented: $router.showingBandSetup) {
            BandSetupSheet().environmentObject(band)
        }
        .tint(Palette.strain)
        .fullScreenCover(item: $router.presented) { presentation in
            NavigationStack {
            Group {
                switch presentation {
                case .workouts: WorkoutsHubView()
                case .start: StartWorkoutView()
                case .active: ActiveWorkoutView()
                case .summary(let id): WorkoutSummaryView(workoutID: id)
                case .detected(let id): DetectedWorkoutView(detectionID: id)
                }
            }
            }
            .environmentObject(band)
            .environmentObject(store)
            .environmentObject(health.personalization)
            .environmentObject(router)
            
        }
        .onAppear {
            store.attach(band)
            #if DEBUG
            if DemoData.isEnabled { DemoData.seed(band: band, store: store) }
            #endif
            health.attach(band: band, display: store)
            presentOnboardingIfNeeded()
        }
        .onChange(of: router.tab, initial: true) { _, _ in syncStreaming() }
        .onChange(of: router.presented) { old, new in
            syncStreaming()
            if new != nil && old == nil { Haptics.soft() }
        }
        .onChange(of: scenePhase) { _, phase in band.setAppActive(phase == .active); if phase == .active { store.steps.start() } }
    }

    private func presentOnboardingIfNeeded() {
        guard !checkedOnboarding else { return }
        checkedOnboarding = true
        #if DEBUG
        if CommandLine.arguments.contains("-testOnboarding") { showOnboarding = true; return }
        if CommandLine.arguments.contains("-previewData") || CommandLine.arguments.contains("-demoHistory") { return }
        #endif
        guard !onboardingDone else { return }
        if band.hasSavedBand || HealthEngine.loadProfile() != nil {
            onboardingDone = true
        } else {
            showOnboarding = true
        }
    }

    /// Live streaming drains the band, so it only runs where live heart rate is on screen.
    private func syncStreaming() {
        let onLiveScreen = router.tab == .home || router.tab == .heart || router.presented != nil
        band.setTodayVisible(onLiveScreen)
    }
}

// MARK: Native navigation

private struct NativeTabRoot<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @EnvironmentObject private var router: Router
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { router.presented = .workouts } label: { Label("Workouts", systemImage: "figure.run") }
                            .accessibilityIdentifier("open-workouts")
                    }
                }
        }
    }
}
private struct WorkoutAccessory: ViewModifier {
    @EnvironmentObject private var band: BandManager
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: band.activeWorkout != nil) {
                if let workout = band.activeWorkout { ActiveWorkoutBanner(workout: workout) }
            }
        } else if #available(iOS 26.0, *) {
            if let workout = band.activeWorkout {
                content.tabViewBottomAccessory { ActiveWorkoutBanner(workout: workout) }
            } else { content }
        } else {
            content.safeAreaInset(edge: .bottom,spacing: 0) {
                if let workout = band.activeWorkout {
                    ActiveWorkoutBanner(workout: workout).background(.regularMaterial)
                }
            }
        }
    }
}

// MARK: - Active workout banner

struct ActiveWorkoutBanner: View {
    var workout: Workout
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var store: DisplayStore

    var body: some View {
        Button {
            router.presented = .active
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    Image(systemName: ActivityKind.symbol(for: workout.type))
                        .foregroundStyle(Palette.strain)
                    Text(workout.type).font(Typo.label(14, weight: .bold))
                    Text(workout.pausedAt == nil ? "In progress" : "Paused")
                        .font(Typo.label(11))
                        .foregroundStyle(workout.pausedAt == nil ? Palette.muted : Palette.calories)
                    Spacer(minLength: 0)
                    if let bpm = store.current?.bpm, context.date.timeIntervalSince(store.current?.date ?? .distantPast) < 15 {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Palette.heart)
                            Text("\(bpm)").font(Typo.number(18))
                        }
                    }
                    Text(Format.clock(workout.elapsed(at: context.date))).font(Typo.number(20))
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text)
        .accessibilityLabel("\(workout.type) workout in progress. Open.")
    }
}
