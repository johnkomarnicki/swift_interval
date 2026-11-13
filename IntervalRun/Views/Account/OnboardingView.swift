import SwiftUI

/// The questions asked after sign-up, from Settings to update them, and from
/// the Plan screen to build a new plan. The answers are what the AI coach
/// builds the training plan from.
struct OnboardingView: View {
    /// `newPlan` asks every question again from scratch rather than starting
    /// from the saved answers, so the new plan isn't a copy of the last one.
    enum Mode { case firstRun, edit, newPlan }

    let mode: Mode
    /// Called after the answers are saved.
    var onFinished: () -> Void = {}

    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var answers = OnboardingAnswers()
    @State private var step: Step
    /// Which way the last step change went, so the next screen slides in from that side.
    @State private var isGoingBack = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasRaceDate = false
    @State private var raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: .now) ?? .now
    @State private var knowsRecent5K = false
    /// Permission to send the answers to the AI coach (App Store guideline 5.1.2(i)).
    /// Asked on first run; editing answers later means it was already given.
    @State private var sharesWithAI = false

    init(mode: Mode, onFinished: @escaping () -> Void = {}) {
        self.mode = mode
        self.onFinished = onFinished
        _step = State(initialValue: mode == .firstRun ? .welcome : .goal)
    }

    private enum Step: Int, CaseIterable {
        case welcome, goal, fitness, currentRunning, schedule, aboutYou, health

        /// Every step but the welcome, which only shows on first run.
        static let questions = allCases.filter { $0 != .welcome }

        var title: String {
            switch self {
            case .welcome: "Let's build your plan"
            case .goal: "Your goal"
            case .fitness: "Your fitness"
            case .currentRunning: "Your running"
            case .schedule: "Your week"
            case .aboutYou: "About you"
            case .health: "Last few things"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "Answer a few questions and your coach builds a training plan around your goal, your fitness and your week."
            case .goal: "What are you training for? Your whole plan is built around it."
            case .fitness: "How long can you run right now without stopping? Your plan starts from here."
            case .currentRunning: "How much are you running at the moment?"
            case .schedule: "Which days can you train, and for how long?"
            case .aboutYou: "How long have you been running?"
            case .health: "Anything your coach should work around."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ScreenTitle(eyebrow: eyebrow, title: step.title, subtitle: step.subtitle)
                            .padding(.top, 8)
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(step)
                .transition(.asymmetric(
                    insertion: .offset(x: isGoingBack ? -40 : 40).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .tint(Phase.work.color)
        .onAppear(perform: loadExisting)
    }

    // MARK: Header

    private var eyebrow: String {
        guard let index = Step.questions.firstIndex(of: step) else { return "WELCOME" }
        return "QUESTION \(index + 1) OF \(Step.questions.count)"
    }

    /// Back, a bar per question, and Cancel unless this is the first run.
    private var topBar: some View {
        HStack(spacing: 14) {
            if step != firstStep {
                Button { go(back: true) } label: {
                    CircleIcon(systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .transition(.opacity)
            }
            if let index = Step.questions.firstIndex(of: step) {
                StepProgress(current: index, count: Step.questions.count)
            } else {
                Spacer()
            }
            if mode != .firstRun {
                Button { dismiss() } label: {
                    CircleIcon(systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .goal: goalStep
        case .fitness: fitnessStep
        case .currentRunning: currentRunningStep
        case .schedule: scheduleStep
        case .aboutYou: aboutYouStep
        case .health: healthStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            WelcomeCard(questionCount: Step.questions.count)

            CardSection(title: "What we'll ask", footer: "You can change your answers any time in Settings.") {
                infoRow("Your goal", detail: "A first 5K, a faster one, or further", icon: "flag.checkered")
                divider
                infoRow("Your fitness", detail: "How much you can run today", icon: "figure.run")
                divider
                infoRow("Your week", detail: "The days and time you have", icon: "calendar")
                divider
                infoRow("Your health", detail: "Anything to work around", icon: "heart")
            }
        }
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            CardSection {
                choices(OnboardingAnswers.Goal.allCases, selected: answers.goal, title: { $0.title }, icon: { $0.icon }) { goal in
                    answers.goal = goal
                    if goal == .fasterFiveK, answers.target5KMinutes == nil {
                        answers.target5KMinutes = 30
                    }
                }
            }

            if answers.goal == .fasterFiveK {
                CardSection(title: "Target 5K time", detail: fiveKText(answers.target5KMinutes ?? 30)) {
                    FiveKTimePicker(minutes: Binding(
                        get: { answers.target5KMinutes ?? 30 },
                        set: { answers.target5KMinutes = $0 }
                    ))
                    .padding(.horizontal, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            CardSection {
                toggleRow("Training for a race on a set date", icon: "calendar.badge.clock", isOn: $hasRaceDate.animation())
                if hasRaceDate {
                    divider
                    row("Race date", icon: "flag") {
                        DatePicker("Race date", selection: $raceDate, in: Date.now..., displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var fitnessStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            CardSection {
                choices(OnboardingAnswers.ContinuousRun.allCases, selected: answers.continuousRun, title: { $0.title }) {
                    answers.continuousRun = $0
                }
            }

            CardSection(footer: "Optional. Helps your coach set your paces.") {
                toggleRow("I know my recent 5K time", icon: "stopwatch", isOn: $knowsRecent5K.animation())
                if knowsRecent5K {
                    divider
                    row("Recent 5K") {
                        Text(fiveKText(answers.recent5KMinutes ?? 32))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    FiveKTimePicker(minutes: Binding(
                        get: { answers.recent5KMinutes ?? 32 },
                        set: { answers.recent5KMinutes = $0 }
                    ))
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private var currentRunningStep: some View {
        CardSection(footer: "Zero days is fine if you're just starting out.") {
            row("Days per week", icon: "calendar") {
                HStack(spacing: 12) {
                    Text("\(answers.currentDaysPerWeek)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Stepper("Days per week", value: $answers.currentDaysPerWeek.animation(), in: 0...7)
                        .labelsHidden()
                }
            }
            divider
            row("Miles per week", icon: "ruler") {
                TextField("Optional", value: $answers.currentWeeklyMiles, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        }
    }

    private var scheduleStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            CardSection(
                title: "Training days",
                detail: "\(answers.trainingDays.count) a week",
                footer: "Your plan only uses these days."
            ) {
                HStack(spacing: 6) {
                    ForEach(Weekday.allCases) { day in
                        DayToggle(day: day, isSelected: answers.trainingDays.contains(day)) {
                            toggle(day)
                        }
                    }
                }
                .padding(12)
            }

            CardSection(title: "Longest session", detail: "Minutes") {
                PillPicker(
                    options: OnboardingAnswers.sessionLengths,
                    title: { "\($0)" },
                    selection: $answers.maxSessionMinutes
                )
            }
        }
    }

    private var aboutYouStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            CardSection {
                choices(OnboardingAnswers.Experience.allCases, selected: answers.experience, title: { $0.title }) {
                    answers.experience = $0
                }
            }

            CardSection(title: "Age", detail: "Optional", footer: "Helps set realistic paces.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(OnboardingAnswers.AgeRange.allCases) { range in
                        ChoiceChip(title: range.title, isSelected: answers.ageRange == range) {
                            answers.ageRange = answers.ageRange == range ? nil : range
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private var healthStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            CardSection(title: "Where you run", detail: "Pick any") {
                HStack(spacing: 8) {
                    ForEach(OnboardingAnswers.Surface.allCases) { surface in
                        let selected = answers.surfaces.contains(surface)
                        ChoiceChip(title: surface.title, isSelected: selected) {
                            if selected {
                                answers.surfaces.removeAll { $0 == surface }
                            } else {
                                answers.surfaces.append(surface)
                            }
                        }
                    }
                }
                .padding(12)
            }

            CardSection(title: "Injuries or health conditions", detail: "Optional") {
                textArea("e.g. sore left knee, asthma", text: $answers.injuries)
            }

            CardSection(title: "Anything else for your coach", detail: "Optional") {
                textArea("e.g. I love intervals, I hate hills", text: $answers.notes)
            }

            CardSection(
                title: "Your plan and AI",
                footer: "The plan isn't medical advice. Check with a doctor before starting if you have health concerns, and stop if something hurts."
            ) {
                HStack(alignment: .top, spacing: 12) {
                    RowIcon(systemImage: "sparkles")
                    Text("Your plan is built by AI. To make it, these answers and your recent runs (times, distances, paces and heart rate) are sent to Anthropic's Claude. Your email isn't sent.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                divider
                Link(destination: AppLinks.privacyPolicy) {
                    row("Privacy policy", icon: "checkmark.shield") { RowChevron() }
                }
                .buttonStyle(.plain)
                if mode == .firstRun {
                    divider
                    toggleRow("Share my answers and runs with Claude to build my plan", isOn: $sharesWithAI.animation())
                }
            }
        }
    }

    // MARK: Footer

    /// The main button, with what's missing (or what went wrong) over it.
    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let stepProblem {
                Text(stepProblem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(action: next) {
                ZStack {
                    HStack(spacing: 8) {
                        Text(primaryTitle)
                        Image(systemName: isLastStep ? (mode == .edit ? "checkmark" : "sparkles") : "arrow.right")
                    }
                    .opacity(isSaving ? 0 : 1)
                    if isSaving { ProgressView().tint(.white) }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Phase.work.color, in: Capsule())
                .shadow(color: Phase.work.color.opacity(stepProblem == nil ? 0.35 : 0), radius: 14, y: 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSaving || stepProblem != nil)
            .opacity(stepProblem == nil ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background {
            // Fades the scrolling content out above the button, solid behind it.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)
                Color(.systemGroupedBackground)
            }
            .ignoresSafeArea()
        }
    }

    private var primaryTitle: String {
        if step == .welcome { return "Get started" }
        if isLastStep { return mode == .edit ? "Save" : "Build my plan" }
        return "Next"
    }

    // MARK: Navigation

    private var firstStep: Step { mode == .firstRun ? .welcome : .goal }

    private var isLastStep: Bool { step == Step.allCases.last }

    private var stepProblem: String? {
        switch step {
        case .schedule: answers.trainingDays.isEmpty ? "Pick at least one day" : nil
        case .health:
            if answers.surfaces.isEmpty { "Pick where you run" }
            else if mode == .firstRun && !sharesWithAI { "Agree to share with Claude to build your plan" }
            else { nil }
        default: nil
        }
    }

    private func next() {
        if answers.goal == .fasterFiveK, answers.target5KMinutes == nil {
            answers.target5KMinutes = 30
        }
        guard isLastStep else {
            go(back: false)
            return
        }
        save()
    }

    private func go(back: Bool) {
        guard let target = Step(rawValue: step.rawValue + (back ? -1 : 1)) else { return }
        isGoingBack = back
        errorMessage = nil
        withAnimation(.snappy(duration: 0.35)) { step = target }
    }

    private func toggle(_ day: Weekday) {
        if answers.trainingDays.contains(day) {
            answers.trainingDays.removeAll { $0 == day }
        } else {
            answers.trainingDays.append(day)
            answers.trainingDays.sort { Weekday.allCases.firstIndex(of: $0)! < Weekday.allCases.firstIndex(of: $1)! }
        }
    }

    private func save() {
        var final = answers
        final.raceDate = hasRaceDate ? ProgramDate.string(from: raceDate) : nil
        if !knowsRecent5K { final.recent5KMinutes = nil }
        if final.goal != .fasterFiveK { final.target5KMinutes = nil }
        if let problem = final.validationMessage {
            errorMessage = problem
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await profile.save(final)
                onFinished()
                if mode != .firstRun { dismiss() }
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
            isSaving = false
        }
    }

    private func loadExisting() {
        guard mode != .newPlan, let existing = profile.answers else { return }
        answers = existing
        if let date = existing.raceDate.flatMap(ProgramDate.date(from:)) {
            hasRaceDate = true
            raceDate = date
        }
        knowsRecent5K = existing.recent5KMinutes != nil
    }

    // MARK: Rows

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    /// One row per option, the chosen one ticked.
    private func choices<Option: Hashable>(
        _ options: [Option],
        selected: Option,
        title: @escaping (Option) -> String,
        icon: ((Option) -> String)? = nil,
        select: @escaping (Option) -> Void
    ) -> some View {
        ForEach(options, id: \.self) { option in
            if option != options.first { divider }
            ChoiceRow(title: title(option), icon: icon?(option), isSelected: option == selected) {
                withAnimation(.snappy(duration: 0.25)) { select(option) }
            }
        }
    }

    private func row<Trailing: View>(
        _ title: String,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                RowIcon(systemImage: icon)
            }
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func toggleRow(_ title: String, icon: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                if let icon {
                    RowIcon(systemImage: icon)
                }
                Text(title)
            }
        }
        .tint(Phase.work.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
    }

    /// A row with a second line of explanation, for the welcome screen.
    private func infoRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(systemImage: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private func textArea(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .lineLimit(2...4)
            .padding(16)
    }

    /// "28:30" from decimal minutes.
    private func fiveKText(_ minutes: Double) -> String {
        TimeFormat.clock(Int((minutes * 60).rounded()))
    }
}

/// A bar per question, lit up to the current one.
private struct StepProgress: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Phase.work.color : Color.primary.opacity(0.1))
                    .frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Question \(current + 1) of \(count)")
    }
}

/// The first-run welcome: a work-colored card in the style of the Free Run cards.
private struct WelcomeCard: View {
    let questionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your plan")
                        .font(.system(size: 30, weight: .bold))
                    Text("Built by your AI coach")
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(height: 1)
                .padding(.top, 20)
                .padding(.bottom, 14)

            HStack {
                Text("\(questionCount) quick questions")
                    .opacity(0.85)
                Spacer()
                Text("About 2 min")
                    .fontWeight(.semibold)
            }
            .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Phase.work.color)
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 130, weight: .bold))
                        .foregroundStyle(.black.opacity(0.12))
                        .offset(x: 6, y: 34)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Phase.work.color.opacity(0.35), radius: 20, y: 10)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An option in a card, ticked when chosen.
private struct ChoiceRow: View {
    let title: String
    var icon: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    RowIcon(systemImage: icon)
                }
                Text(title)
                    .foregroundStyle(.primary)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Phase.work.color : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(isSelected ? Phase.work.color.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small option on a capsule, filled when chosen.
private struct ChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A training day as a round button, lit in the work color when picked.
private struct DayToggle: View {
    let day: Weekday
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Circle()
                .fill(isSelected ? Phase.work.color : Color.primary.opacity(0.08))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(day.short)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Minutes and seconds wheels for a 5K time, bound to decimal minutes.
private struct FiveKTimePicker: View {
    @Binding var minutes: Double

    var body: some View {
        HStack(spacing: 0) {
            Picker("Minutes", selection: wholeMinutes) {
                ForEach(12...75, id: \.self) { Text("\($0) min").tag($0) }
            }
            Picker("Seconds", selection: seconds) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) sec").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(height: 130)
    }

    private var wholeMinutes: Binding<Int> {
        Binding(
            get: { min(max(Int(minutes), 12), 75) },
            set: { minutes = Double($0) + Double(seconds.wrappedValue) / 60 }
        )
    }

    private var seconds: Binding<Int> {
        Binding(
            get: { (Int(((minutes - minutes.rounded(.down)) * 60).rounded()) / 5) * 5 % 60 },
            set: { minutes = Double(wholeMinutes.wrappedValue) + Double($0) / 60 }
        )
    }
}
