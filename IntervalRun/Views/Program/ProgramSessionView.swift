import SwiftData
import SwiftUI

/// One session from the plan: what it is, the coach's note, its route, the
/// intervals as a timeline, and Start.
struct ProgramSessionView: View {
    let programID: UUID
    let session: ProgramSession
    let isDone: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ProgramStore.self) private var programs
    @Query private var routes: [RunRoute]
    @Query private var records: [WorkoutRecord]
    @State private var runningSession: WorkoutSession?
    @State private var returnAfterPlayer = false
    @State private var savedToWorkouts = false
    @State private var choosingRoute = false
    @State private var pendingStart: PendingSessionStart?
    @State private var routeError: String?
    @AppStorage(AppSettings.programWarmUpKey) private var includeWarmUp = true
    @AppStorage(AppSettings.programCoolDownKey) private var includeCoolDown = true
    /// Once the large title has scrolled away, it shows in the navigation bar.
    @State private var showsInlineTitle = false

    private let cardColor = Color(.secondarySystemGroupedBackground)

    var body: some View {
        let plan = self.plan
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                intro
                summaryCard(plan: plan)
                    .padding(.top, 20)

                sectionHeader("Route")
                routeCard(plan: plan)

                if session.workout.hasWarmUp || session.workout.hasCoolDown {
                    sectionHeader("Warm-up & cool-down")
                    warmUpCard
                    Text("Your choice is remembered for your next plan runs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                }

                sectionHeader("Intervals", detail: plan.segments.count == 1 ? "1 interval" : "\(plan.segments.count) intervals")
                intervalsCard(plan: plan)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(showsInlineTitle ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showsInlineTitle)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(savedToWorkouts ? "Saved to Workouts" : "Save to Workouts", systemImage: "square.and.arrow.down") {
                        modelContext.insert(Workout(name: session.title, plan: plan))
                        SyncService.shared.scheduleSync()
                        savedToWorkouts = true
                    }
                    .disabled(savedToWorkouts)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            startButton(plan: plan)
        }
        // After the Start button's inset, so the button sits above the tab bar.
        .clearsTabBar()
        .sheet(isPresented: $choosingRoute) {
            RoutePickerView(
                targetMeters: targetMeters(plan: plan),
                selectedID: route?.syncID
            ) { picked in
                setRoute(picked?.syncID)
            }
        }
        .routeBeforeStart($pendingStart, programID: programID) { _, route in
            start(route: route)
        }
        .alert("Couldn't save the route", isPresented: Binding(
            get: { routeError != nil },
            set: { if !$0 { routeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(routeError ?? "")
        }
        .fullScreenCover(item: $runningSession, onDismiss: {
            if returnAfterPlayer {
                returnAfterPlayer = false
                dismiss()
            }
        }) { running in
            PlayerView(session: running) { completed in
                returnAfterPlayer = completed
                runningSession = nil
            }
        }
    }

    /// The session's workout with the warm-up and cool-down the runner chose.
    private var plan: WorkoutPlan {
        session.workout.workoutPlan(warmUp: includeWarmUp, coolDown: includeCoolDown)
    }

    private func start(route: RoutePath?) {
        runningSession = WorkoutSession(
            name: session.title,
            plan: plan,
            programLink: ProgramLink(programID: programID, sessionID: session.id),
            route: route
        )
    }

    // MARK: Route

    private var route: RunRoute? {
        guard let id = programs.routeID(for: session.id, in: programID) else { return nil }
        return routes.first { $0.syncID == id }
    }

    private func targetMeters(plan: WorkoutPlan) -> Double {
        RouteFit.targetMeters(seconds: plan.totalSeconds, pace: RouteFit.usualPace(records: records))
    }

    // MARK: Layout

    /// Where the run sits in the plan, its title and the coach's note.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(eyebrow)
                    .font(.footnote.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isDone {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Phase.rest.color)
                }
            }
            Text(session.title)
                .font(.system(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: Bool.self) { proxy in
                    // Roughly where the navigation bar ends.
                    proxy.frame(in: .global).maxY < 100
                } action: { hidden in
                    showsInlineTitle = hidden
                }
            if !session.description.isEmpty {
                Text(session.description)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    /// "WEEK 4 · RUN 3 OF 3 · FRI, OCT 30"
    private var eyebrow: String {
        var parts: [String] = []
        if let program = programs.program, program.id == programID, let plan = program.plan,
           let week = plan.weeks.first(where: { $0.sessions.contains { $0.id == session.id } }),
           let index = week.sessions.firstIndex(where: { $0.id == session.id }) {
            parts.append("WEEK \(week.week)")
            parts.append("RUN \(index + 1) OF \(week.sessions.count)")
        }
        if let date = session.calendarDate {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(cardColor)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Total, work and rest time, and the workout's shape. Rest counts the
    /// warm-up and cool-down too.
    private func summaryCard(plan: WorkoutPlan) -> some View {
        let work = plan.segments.filter { $0.phase == .work }.reduce(0) { $0 + $1.seconds }
        return card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    summaryStat("TOTAL", seconds: plan.totalSeconds)
                    summaryStat("WORK", seconds: work, dot: Phase.work.color)
                    summaryStat("REST", seconds: plan.totalSeconds - work, dot: Phase.rest.color)
                }
                WorkoutStripe(segments: plan.segments, height: 8)
            }
            .padding(20)
        }
    }

    private func summaryStat(_ title: String, seconds: Int, dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(title)
                    .tracking(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(TimeFormat.clock(seconds))
                .font(.title2.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func routeCard(plan: WorkoutPlan) -> some View {
        let target = targetMeters(plan: plan)
        return card {
            VStack(spacing: 0) {
                if let route {
                    RouteMapView(path: route.path, interactive: false)
                        .frame(height: 170)
                        .allowsHitTesting(false)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [cardColor.opacity(0), cardColor], startPoint: .top, endPoint: .bottom)
                                .frame(height: 48)
                        }
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.displayName).font(.headline)
                            fitLabel(RouteFit.match(routeMeters: route.meters, targetMeters: target))
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.2f", DistanceFormat.miles(route.meters)))
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Text("mi")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    Divider()
                    cardButton("Change route", systemImage: "arrow.up.arrow.down") { choosingRoute = true }
                } else {
                    Text(paceNote(target: target))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    Divider()
                    cardButton("Choose a route", systemImage: "map") { choosingRoute = true }
                }
            }
        }
    }

    @ViewBuilder
    private func fitLabel(_ match: RouteFit.Match) -> some View {
        switch match {
        case .fits:
            Label("Good fit for this workout", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Phase.rest.color)
        case .short:
            Label("Shorter than this workout", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .long:
            Label("Longer than this workout", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func cardButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Phase.work.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var warmUpCard: some View {
        card {
            VStack(spacing: 0) {
                if session.workout.hasWarmUp {
                    toggleRow("Warm-up", seconds: session.workout.warmUpSeconds, isOn: $includeWarmUp)
                }
                if session.workout.hasWarmUp && session.workout.hasCoolDown {
                    Divider().padding(.leading, 20)
                }
                if session.workout.hasCoolDown {
                    toggleRow("Cool-down", seconds: session.workout.coolDownSeconds, isOn: $includeCoolDown)
                }
            }
        }
    }

    private func toggleRow(_ title: String, seconds: Int, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn.animation()) {
            Text("\(title) \(Text("· \(TimeFormat.clock(seconds))").foregroundStyle(.secondary))")
        }
        .tint(Phase.work.color)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Each segment with the time it starts, joined by a line like a timeline.
    private func intervalsCard(plan: WorkoutPlan) -> some View {
        let segments = plan.segments
        let starts = segments.indices.map { index in segments[..<index].reduce(0) { $0 + $1.seconds } }
        // Counted per phase, since a round can hold more than one work step.
        let numbers = segments.indices.map { index in segments[...index].filter { $0.phase == segments[index].phase }.count }
        return card {
            VStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let isLast = index == segments.count - 1
                    HStack(spacing: 12) {
                        Text(TimeFormat.clock(starts[index]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Circle()
                            .fill(WorkoutStripe.color(segment.phase))
                            .frame(width: 10, height: 10)
                            .frame(width: 12)
                            .frame(maxHeight: .infinity)
                            .background {
                                VStack(spacing: 0) {
                                    Rectangle().fill(index == 0 ? .clear : Color.primary.opacity(0.15))
                                    Rectangle().fill(isLast ? .clear : Color.primary.opacity(0.15))
                                }
                                .frame(width: 1.5)
                            }
                        HStack {
                            Text(label(for: segment, number: numbers[index]))
                            Spacer()
                            Text(TimeFormat.clock(segment.seconds))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            if !isLast { Divider() }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(label(for: segment, number: numbers[index])), \(TimeFormat.clock(segment.seconds)), starts at \(TimeFormat.clock(starts[index]))")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func startButton(plan: WorkoutPlan) -> some View {
        Button {
            if let route {
                start(route: route.snapshot)
            } else {
                pendingStart = PendingSessionStart(session: session)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(isDone ? "Run it again" : "Start")
                    .font(.title3.weight(.bold))
                Text("· \(TimeFormat.clock(plan.totalSeconds))")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background {
                Capsule()
                    .fill(Phase.work.color)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                            .clipShape(Capsule())
                    }
                    .shadow(color: Phase.work.color.opacity(0.4), radius: 16, y: 6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            // Content fades out behind the button rather than ending abruptly.
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .center)
        }
    }

    /// "About 1.85 mi at your usual 12:30 /mi pace."
    private func paceNote(target: Double) -> String {
        let pace = RouteFit.usualPace(records: records)
        let paceText = "\(TimeFormat.clock(pace.secondsPerMile)) /mi"
        return pace.fromHistory
            ? "About \(DistanceFormat.short(target)) at your usual \(paceText) pace."
            : "About \(DistanceFormat.short(target)) at a \(paceText) pace. This gets more accurate as you log runs."
    }

    private func setRoute(_ routeID: UUID?) {
        Task {
            do {
                try await programs.setRoute(routeID, for: session.id, in: programID)
            } catch {
                routeError = "Check your connection and try again."
            }
        }
    }

    private func label(for segment: Segment, number: Int) -> String {
        switch segment.phase {
        case .warmUp: "Warm-up"
        case .coolDown: "Cool-down"
        case .work: "Work \(number)"
        case .rest: "Rest \(number)"
        }
    }
}
