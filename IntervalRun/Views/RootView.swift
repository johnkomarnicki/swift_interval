import SwiftData
import SwiftUI

/// Sign-in → onboarding questions → the main tabs.
struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn(let userID, _):
            SignedInView(userID: userID)
                .id(userID)
        }
    }
}

private struct SignedInView: View {
    let userID: UUID

    @Environment(AuthStore.self) private var auth
    @Environment(ProfileStore.self) private var profile
    @Environment(ProgramStore.self) private var programs
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if profile.isLoaded {
                if profile.answers == nil {
                    OnboardingView(mode: .firstRun) {
                        Task { await programs.build() }
                    }
                } else {
                    MainTabView()
                }
            } else if let error = profile.loadError {
                ContentUnavailableView {
                    Label("Can't load your account", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await profile.load(userID: userID) } }
                    Button("Sign Out") { Task { await auth.signOut() } }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            await profile.load(userID: userID)
            await SyncService.shared.syncNow()
            await programs.load()
            await HeartRateRecorder.backfill(modelContext)
        }
        .onChange(of: profile.accountMissing) { _, missing in
            if missing { Task { await auth.signOut() } }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await SyncService.shared.syncNow()
                await programs.load()
                await HeartRateRecorder.backfill(modelContext)
            }
        }
    }
}

enum MainTab: CaseIterable, Identifiable {
    case plan, workouts, freeRun, history, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .workouts: "Workouts"
        case .freeRun: "Free Run"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .plan: "calendar"
        case .workouts: "figure.run"
        case .freeRun: "location"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// The tabs, switched by a floating bar in place of the system tab bar. The bar
/// steps aside while the keyboard is up.
struct MainTabView: View {
    @State private var selection = MainTab.plan
    @State private var isKeyboardShown = false
    @State private var barHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ForEach(MainTab.allCases) { tab in
                    content(tab)
                        .tag(tab)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
            .environment(\.tabBarInset, isKeyboardShown ? 0 : barHeight)

            if !isKeyboardShown {
                MainTabBar(selection: $selection)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
        .background { DailyReminderSync() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardShown = false
        }
        .tint(Phase.work.color)
    }

    @ViewBuilder
    private func content(_ tab: MainTab) -> some View {
        switch tab {
        case .plan: ProgramView()
        case .workouts: WorkoutListView()
        case .freeRun: FreeRunView()
        case .history: HistoryListView()
        case .settings: SettingsView()
        }
    }
}

/// Reschedules the morning reminders whenever the plan, the runs done or the
/// setting change, and each time the app comes back to the front (a new day
/// moves the 14-day window on). Has its own query so a new run doesn't redraw
/// the tabs.
private struct DailyReminderSync: View {
    @Environment(ProgramStore.self) private var programs
    @Environment(\.scenePhase) private var scenePhase
    @Query private var records: [WorkoutRecord]
    @AppStorage(AppSettings.dailyReminderKey) private var isOn = true
    @AppStorage(AppSettings.dailyReminderMinuteKey) private var minuteOfDay = AppSettings.defaultDailyReminderMinute

    private struct Inputs: Equatable {
        var plan: ProgramPlan?
        var doneSessionIDs: Set<String>
        var isOn: Bool
        var minuteOfDay: Int
        var isActive: Bool
        var isLoaded: Bool
    }

    private var inputs: Inputs {
        let program = programs.program
        let done = records.filter { $0.programID == program?.id && $0.completed }.compactMap(\.programSessionID)
        return Inputs(plan: program?.plan, doneSessionIDs: Set(done), isOn: isOn,
                      minuteOfDay: minuteOfDay, isActive: scenePhase == .active, isLoaded: programs.isLoaded)
    }

    var body: some View {
        Color.clear
            .task(id: inputs) {
                let inputs = inputs
                // Wait for the plan to load rather than clearing reminders on launch.
                guard inputs.isActive, inputs.isLoaded else { return }
                guard inputs.isOn, let plan = inputs.plan else {
                    await DailyReminders.clear()
                    return
                }
                await DailyReminders.schedule(DailyReminderPlanner.reminders(
                    plan: plan, doneSessionIDs: inputs.doneSessionIDs, minuteOfDay: inputs.minuteOfDay
                ))
            }
    }
}

extension EnvironmentValues {
    /// Height of the floating tab bar, for `clearsTabBar()`.
    @Entry var tabBarInset: CGFloat = 0
}

extension View {
    /// Leaves room at the bottom for the floating tab bar, so the end of the
    /// screen can scroll clear of it. Goes on every screen shown in a tab,
    /// inside its NavigationStack: an inset on the stack itself doesn't reach
    /// the screens in it.
    func clearsTabBar() -> some View {
        modifier(ClearsTabBar())
    }
}

private struct ClearsTabBar: ViewModifier {
    @Environment(\.tabBarInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: inset)
        }
    }
}

/// A rounded bar of tabs; the chosen one is lit in the work color on a pill.
private struct MainTabBar: View {
    @Binding var selection: MainTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.spring(duration: 0.3)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? Phase.work.color : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
