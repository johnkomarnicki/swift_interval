import SwiftData
import SwiftUI

/// The run to do next, pinned above the plan's views so Start is always on the
/// first screen. Says when today is a rest day or today's run is done, and
/// offers a new plan once this one is over.
struct ProgramUpNext: View {
    let programID: UUID
    let progress: ProgramProgress
    let onBuildNewPlan: () -> Void

    @Environment(ProgramStore.self) private var programs
    @Query private var routes: [RunRoute]
    @State private var runningSession: WorkoutSession?
    @State private var pendingStart: PendingSessionStart?
    @AppStorage(AppSettings.programWarmUpKey) private var includeWarmUp = true
    @AppStorage(AppSettings.programCoolDownKey) private var includeCoolDown = true

    var body: some View {
        let doneToday = progress.sessions(on: progress.today).contains { progress.status(of: $0) == .done }
        VStack(spacing: 10) {
            if doneToday {
                Label("Today's run is done. Nice work.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Phase.rest.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Phase.rest.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let next = progress.nextSession {
                let route = route(for: next)
                NextSessionCard(session: next, status: progress.status(of: next), doneToday: doneToday, routeName: route?.displayName) {
                    if let route {
                        start(next, route: route.snapshot)
                    } else {
                        pendingStart = PendingSessionStart(session: next)
                    }
                }
            } else {
                PlanFinishedCard(doneCount: progress.doneCount, totalCount: progress.totalCount, onBuildNewPlan: onBuildNewPlan)
            }
        }
        .routeBeforeStart($pendingStart, programID: programID) { session, route in
            start(session, route: route)
        }
        .fullScreenCover(item: $runningSession) { running in
            PlayerView(session: running) { _ in runningSession = nil }
        }
    }

    private func start(_ session: ProgramSession, route: RoutePath?) {
        runningSession = WorkoutSession(
            name: session.title,
            plan: session.workout.workoutPlan(warmUp: includeWarmUp, coolDown: includeCoolDown),
            programLink: ProgramLink(programID: programID, sessionID: session.id),
            route: route
        )
    }

    private func route(for session: ProgramSession) -> RunRoute? {
        guard let id = programs.routeID(for: session.id, in: programID) else { return nil }
        return routes.first { $0.syncID == id }
    }
}

/// Shown in place of the next run once no runs are left.
private struct PlanFinishedCard: View {
    let doneCount: Int
    let totalCount: Int
    let onBuildNewPlan: () -> Void

    var body: some View {
        let allDone = doneCount == totalCount
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.title)
                .foregroundStyle(Phase.work.color)
            Text(allDone ? "Plan complete" : "Plan finished")
                .font(.title2.bold())
            Text(allDone
                 ? "You did all \(totalCount) runs. Ready for what's next?"
                 : "You did \(doneCount) of \(totalCount) runs. Ready for what's next?")
                .foregroundStyle(.secondary)
            Button(action: onBuildNewPlan) {
                Label("Build a new plan", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Phase.work.color, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// One week of the plan, with arrows to step through the weeks. The next run
/// is marked; it's started from `ProgramUpNext` or its detail screen.
struct ProgramWeekView: View {
    let programID: UUID
    let plan: ProgramPlan
    let progress: ProgramProgress
    @Binding var weekIndex: Int

    @Environment(ProgramStore.self) private var programs
    @Query private var routes: [RunRoute]

    var body: some View {
        let week = plan.weeks[weekIndex]
        VStack(spacing: 12) {
            navigator(week)
            if week.sessions.isEmpty {
                Text("No runs this week. Rest up.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
            ForEach(week.sessions) { session in
                SessionCard(
                    session: session,
                    status: progress.status(of: session),
                    isNext: session.id == progress.nextSession?.id,
                    routeName: route(for: session)?.displayName
                )
            }
        }
    }

    private func route(for session: ProgramSession) -> RunRoute? {
        guard let id = programs.routeID(for: session.id, in: programID) else { return nil }
        return routes.first { $0.syncID == id }
    }

    private func navigator(_ week: ProgramWeek) -> some View {
        let isCurrent = weekIndex == progress.currentWeekIndex
        return HStack {
            arrow("chevron.left", label: "Previous week", disabled: weekIndex == 0) {
                weekIndex -= 1
            }
            Spacer(minLength: 8)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Week \(week.week)").font(.title2.bold())
                    if isCurrent {
                        Text("THIS WEEK")
                            .font(.caption2.weight(.heavy))
                            .tracking(0.5)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Phase.work.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(Phase.work.color)
                    }
                }
                Text(subtitle(week))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !isCurrent {
                    Button("Back to this week") {
                        withAnimation { weekIndex = progress.currentWeekIndex }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Phase.work.color)
                }
            }
            Spacer(minLength: 8)
            arrow("chevron.right", label: "Next week", disabled: weekIndex >= plan.weeks.count - 1) {
                weekIndex += 1
            }
        }
        .padding(.vertical, 4)
    }

    /// "Oct 26 – Nov 1 · Up to 5 minutes"
    private func subtitle(_ week: ProgramWeek) -> String {
        guard let range = progress.dateRange(ofWeekAt: weekIndex) else { return week.focus }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(range.lowerBound.formatted(format)) – \(range.upperBound.formatted(format)) · \(week.focus)"
    }

    private func arrow(_ systemImage: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation { action() }
        } label: {
            CircleIcon(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

/// "26:30 · Neighbor Trail", or "Run/walk · 26:30" without a route.
private func sessionSummary(_ session: ProgramSession, seconds: Int, routeName: String?, alwaysKind: Bool = false) -> String {
    var parts = [TimeFormat.clock(seconds)]
    if alwaysKind || routeName == nil {
        parts.insert(session.kindLabel, at: 0)
    }
    if let routeName {
        parts.append(routeName)
    }
    return parts.joined(separator: " · ")
}

/// A plan session: date, title, length, the shape of the workout and whether
/// it's done. The next run is outlined and marked "Up next".
struct SessionCard: View {
    let session: ProgramSession
    let status: ProgramProgress.Status
    var isNext = false
    var routeName: String?

    @AppStorage(AppSettings.programWarmUpKey) private var includeWarmUp = true
    @AppStorage(AppSettings.programCoolDownKey) private var includeCoolDown = true

    var body: some View {
        let plan = session.workout.workoutPlan(warmUp: includeWarmUp, coolDown: includeCoolDown)
        NavigationLink(value: SessionRoute(sessionID: session.id)) {
            HStack(spacing: 14) {
                dateBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Text(sessionSummary(session, seconds: plan.totalSeconds, routeName: routeName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    WorkoutStripe(segments: plan.segments)
                        .padding(.top, 6)
                }
                Spacer(minLength: 4)
                statusLabel
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if isNext {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Phase.work.color.opacity(0.6), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(status == .missed ? 0.6 : 1)
    }

    private var dateBadge: some View {
        let date = session.calendarDate
        let tint: Color = switch status {
        case .done: Phase.rest.color
        case .today: Phase.work.color
        case .upcoming, .missed: .secondary
        }
        return VStack(spacing: 0) {
            Text(date?.formatted(.dateTime.weekday(.abbreviated)).uppercased() ?? session.day.short.uppercased())
                .font(.caption2.weight(.bold))
            Text(date?.formatted(.dateTime.day()) ?? "")
                .font(.title2.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .frame(width: 54, height: 58)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Phase.rest.color)
                .accessibilityLabel("Done")
        case .today:
            Text("Today")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Phase.work.color, in: Capsule())
                .foregroundStyle(.white)
        case .missed:
            Text("Missed").font(.caption).foregroundStyle(.secondary)
        case .upcoming where isNext:
            Text("Up next")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Phase.work.color.opacity(0.18), in: Capsule())
                .foregroundStyle(Phase.work.color)
        case .upcoming:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The next run, large and in the work color, with a Start button.
struct NextSessionCard: View {
    let session: ProgramSession
    let status: ProgramProgress.Status
    /// Today's run is already done, so this one isn't replacing a rest day.
    var doneToday = false
    var routeName: String?
    let onStart: () -> Void

    @AppStorage(AppSettings.programWarmUpKey) private var includeWarmUp = true
    @AppStorage(AppSettings.programCoolDownKey) private var includeCoolDown = true

    var body: some View {
        let plan = session.workout.workoutPlan(warmUp: includeWarmUp, coolDown: includeCoolDown)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dayLabel)
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Phase.work.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white, in: Capsule())
                Spacer()
                NavigationLink(value: SessionRoute(sessionID: session.id)) {
                    HStack(spacing: 4) {
                        Text("Details")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            Text(session.title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.leading)
                .padding(.top, 18)
            Text(sessionSummary(session, seconds: plan.totalSeconds, routeName: routeName, alwaysKind: true))
                .font(.subheadline)
                .opacity(0.85)
                .padding(.top, 6)

            WorkoutStripe(segments: plan.segments, onTint: true, height: 7)
                .padding(.top, 22)
            legend(plan.segments)
                .padding(.top, 10)

            Button(action: onStart) {
                Label("Start", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Phase.work.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(.white, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Phase.work.color)
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .shadow(color: Phase.work.color.opacity(0.35), radius: 24, y: 12)
        }
    }

    /// "TODAY · FRI 30"; "REST DAY · NEXT RUN TOMORROW" or "… MON 2"; after
    /// today's run, "UP NEXT · TOMORROW" or "… MON 2".
    private var dayLabel: String {
        if status == .today, let date = session.calendarDate {
            return "TODAY · \(Self.day(date))"
        }
        let lead = doneToday ? "UP NEXT" : "REST DAY · NEXT RUN"
        guard let date = session.calendarDate else { return lead }
        return "\(lead) · \(Calendar.current.isDateInTomorrow(date) ? "TOMORROW" : Self.day(date))"
    }

    /// "FRI 30"
    private static func day(_ date: Date) -> String {
        "\(date.formatted(.dateTime.weekday(.abbreviated)).uppercased()) \(date.formatted(.dateTime.day()))"
    }

    /// One entry per kind of stretch the workout has.
    private func legend(_ segments: [Segment]) -> some View {
        let phases = Set(segments.map(\.phase))
        return HStack(spacing: 14) {
            if phases.contains(.work) {
                legendItem("Work", WorkoutStripe.onTintColor(.work))
            }
            if phases.contains(.rest) {
                legendItem("Rest", WorkoutStripe.onTintColor(.rest))
            }
            if phases.contains(.warmUp) || phases.contains(.coolDown) {
                legendItem("Warm-up/down", WorkoutStripe.onTintColor(.warmUp))
            }
        }
        .font(.caption.weight(.medium))
        .accessibilityHidden(true)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).opacity(0.85)
        }
    }
}

/// The shape of a workout: one bar per segment, sized by its length and colored
/// by phase. `onTint` is for drawing over the work color.
struct WorkoutStripe: View {
    let segments: [Segment]
    var onTint = false
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = segments.count > 24 ? 1.5 : 3
            let total = segments.reduce(0) { $0 + $1.duration }
            let available = max(0, proxy.size.width - spacing * CGFloat(max(segments.count - 1, 0)))
            HStack(spacing: spacing) {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    Capsule()
                        .fill(onTint ? Self.onTintColor(segment.phase) : Self.color(segment.phase))
                        .frame(width: total > 0 ? available * segment.duration / total : 0)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .work: Phase.work.color
        case .rest: Phase.rest.color
        case .warmUp, .coolDown: .primary.opacity(0.25)
        }
    }

    static func onTintColor(_ phase: Phase) -> Color {
        switch phase {
        case .work: .white
        case .rest: .black.opacity(0.25)
        case .warmUp, .coolDown: .white.opacity(0.35)
        }
    }
}
