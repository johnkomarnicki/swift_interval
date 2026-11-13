import SwiftData
import SwiftUI

/// Opens a plan session's detail screen.
struct SessionRoute: Hashable {
    let sessionID: String
}

enum ProgramViewMode: String, CaseIterable, Identifiable {
    case week, plan, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .plan: "Plan"
        case .calendar: "Calendar"
        }
    }
}

/// The AI training plan, shown one week at a time, as a whole-plan overview,
/// or as a calendar.
struct ProgramView: View {
    @Environment(ProgramStore.self) private var programs
    @Environment(ReviewStore.self) private var reviews
    @Environment(\.scenePhase) private var scenePhase
    @Query private var records: [WorkoutRecord]
    @AppStorage("programViewMode") private var mode: ProgramViewMode = .week
    /// Week shown in Week view; nil means the current week.
    @State private var selectedWeek: Int?
    @State private var askingForNewPlan = false
    @State private var showingAbout = false
    @State private var showingLibrary = false
    @State private var shownProposal: ProgramReview?
    @State private var showingCoach = false

    /// The library only appears once there's more than one plan.
    private var hasMultiplePlans: Bool { programs.library.count > 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if let program = programs.program, let plan = program.plan {
                        planContent(program, plan)
                    } else if programs.isBuilding {
                        BuildingPlanView()
                    } else if !programs.isLoaded {
                        ProgressView()
                            .padding(.top, 60)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await programs.load()
                await reviews.load(programID: programs.program?.id)
            }
            // The plan itself loads in RootView; its coach reviews load here,
            // again when the plan changes or the app comes back.
            .task(id: programs.program?.id) { await reviews.load(programID: programs.program?.id) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await reviews.load(programID: programs.program?.id) }
            }
            .clearsTabBar()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAbout) {
                if let program = programs.program, let plan = program.plan {
                    AboutPlanSheet(title: program.displayTitle, plan: plan)
                }
            }
            .sheet(isPresented: $showingLibrary) {
                PlansLibraryView()
            }
            .sheet(item: $shownProposal) { review in
                ReviewProposalSheet(review: review)
            }
            .sheet(isPresented: $showingCoach) {
                CoachChatView()
            }
            .navigationDestination(for: SessionRoute.self) { route in
                if let program = programs.program, let plan = program.plan,
                   let session = plan.sessions.first(where: { $0.id == route.sessionID }) {
                    ProgramSessionView(
                        programID: program.id,
                        session: session,
                        isDone: completedSessionIDs(for: program).contains(session.id)
                    )
                }
            }
            .sheet(isPresented: $askingForNewPlan) {
                // Every question again, so the new plan starts fresh. This plan
                // keeps its own answers and progress in My plans.
                OnboardingView(mode: .newPlan) { Task { await programs.build() } }
            }
        }
    }

    // MARK: Plan

    /// Routes, the coach chat and plan options as round buttons, then today's date
/// over a large title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NavigationLink {
                    RoutesListView()
                } label: {
                    CircleIcon(systemImage: "map")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Routes")
                Spacer()
                Button { showingCoach = true } label: {
                    CircleIcon(systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chat with your coach")
                if programs.program?.plan != nil {
                    Menu {
                        if hasMultiplePlans {
                            Button("My plans (\(programs.library.count))", systemImage: "square.stack") { showingLibrary = true }
                        }
                        Button("About this plan", systemImage: "info.circle") { showingAbout = true }
                        Button("Build a new plan", systemImage: "sparkles") { askingForNewPlan = true }
                            .disabled(programs.isBuilding)
                    } label: {
                        CircleIcon(systemImage: "ellipsis")
                    }
                    .accessibilityLabel("Plan options")
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 20)

            ScreenTitle(eyebrow: TodayEyebrow.text, title: "Plan")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planContent(_ program: TrainingProgram, _ plan: ProgramPlan) -> some View {
        let progress = ProgramProgress(plan: plan, doneSessionIDs: completedSessionIDs(for: program))
        let weekIndex = Binding(
            get: { min(selectedWeek ?? progress.currentWeekIndex, max(plan.weeks.count - 1, 0)) },
            set: { selectedWeek = $0 }
        )
        return VStack(spacing: 16) {
            if programs.isBuilding {
                Label("Building your new plan… this takes about a minute.", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = programs.buildError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CoachPlanCards(programID: program.id, progress: progress) { shownProposal = $0 }

            PlanHeader(title: program.displayTitle, plan: plan, progress: progress,
                       onSwitchPlan: hasMultiplePlans ? { showingLibrary = true } : nil)

            ProgramUpNext(programID: program.id, progress: progress) { askingForNewPlan = true }

            PillPicker(options: ProgramViewMode.allCases, title: \.title, selection: $mode)

            switch mode {
            case .week:
                ProgramWeekView(programID: program.id, plan: plan, progress: progress, weekIndex: weekIndex)
            case .plan:
                ProgramOverviewView(plan: plan, progress: progress) { index in
                    selectedWeek = index
                    withAnimation { mode = .week }
                }
            case .calendar:
                ProgramCalendarView(plan: plan, progress: progress)
            }
        }
    }

    private func completedSessionIDs(for program: TrainingProgram) -> Set<String> {
        Set(records.filter { $0.programID == program.id && $0.completed }.compactMap(\.programSessionID))
    }

    // MARK: No plan yet

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(Phase.work.color)
            Text("Your personal training plan")
                .font(.title2.bold())
            Text("Your AI coach builds a week-by-week plan from your goal, your schedule and your recent runs. Every session plays right in the timer.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let error = programs.buildError {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button {
                Task { await programs.build() }
            } label: {
                Label("Build my plan", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Phase.work.color)
            .controlSize(.large)
        }
        .padding(32)
    }
}

/// A round icon button face, for the Plan screen's header.
struct CircleIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(Color(.secondarySystemGroupedBackground), in: Circle())
            .contentShape(Circle())
    }
}

/// Plan name, current week and overall progress, with a dot per run grouped
/// by week. With more than one plan, the name doubles as a button to switch plans.
private struct PlanHeader: View {
    let title: String
    let plan: ProgramPlan
    let progress: ProgramProgress
    var onSwitchPlan: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let onSwitchPlan {
                Button(action: onSwitchPlan) {
                    HStack(spacing: 6) {
                        Text(title).multilineTextAlignment(.leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Phase.work.color)
                    }
                    .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Switch plan")
            } else {
                Text(title).font(.title3.weight(.semibold))
            }
            VStack(spacing: 10) {
                HStack {
                    Text("Week \(Text("\(progress.currentWeekIndex + 1)").fontWeight(.bold).foregroundStyle(.primary)) of \(plan.weeks.count)")
                    Spacer()
                    Text("\(Text("\(progress.doneCount)").fontWeight(.bold).foregroundStyle(.primary)) of \(progress.totalCount) runs")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                sessionDots
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Done in green, the next run in orange, the rest grey; a gap between weeks.
    private var sessionDots: some View {
        let nextID = progress.nextSession?.id
        return HStack(spacing: 3) {
            ForEach(Array(plan.weeks.enumerated()), id: \.offset) { index, week in
                if index > 0 {
                    Color.clear.frame(width: 5, height: 1)
                }
                ForEach(week.sessions) { session in
                    Capsule()
                        .fill(progress.doneSessionIDs.contains(session.id) ? Phase.rest.color
                              : session.id == nextID ? Phase.work.color
                              : Color.primary.opacity(0.15))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// The plan's summary and basic facts.
private struct AboutPlanSheet: View {
    let title: String
    let plan: ProgramPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { Text(plan.summary) }
                Section {
                    if let start = ProgramDate.date(from: plan.startDate) {
                        LabeledContent("Starts", value: start.formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledContent("Length", value: "\(plan.weeks.count) weeks")
                    LabeledContent("Runs", value: "\(plan.sessions.count)")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shown while the first plan is being built.
private struct BuildingPlanView: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Building your plan…").font(.title3.bold())
            Text("Your coach is working out your weeks. This takes about a minute; you can leave this screen and come back.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

enum SessionDateText {
    /// "Today", "Tomorrow" or "Tue, Oct 27".
    static func label(for session: ProgramSession) -> String {
        guard let date = session.calendarDate else { return session.day.short }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
