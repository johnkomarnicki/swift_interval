import AuthenticationServices
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage(AppSettings.beepVolumeKey) private var beepVolume = AppSettings.defaultBeepVolume
    @AppStorage(AppSettings.vibrateOnCountdownKey) private var vibrateOnCountdown = false
    @AppStorage(AppSettings.coachVoiceKey) private var coachVoice = CoachVoice.default.rawValue
    @AppStorage(AppSettings.voiceCountdownKey) private var voiceCountdown = true
    @AppStorage(AppSettings.voiceHalfwayKey) private var voiceHalfway = true
    @AppStorage(AppSettings.voiceIntervalsLeftKey) private var voiceIntervalsLeft = true
    @AppStorage(AppSettings.voiceDistanceKey) private var voiceDistance = true
    @AppStorage(AppSettings.voicePaceKey) private var voicePace = true
    @AppStorage(AppSettings.trackDistanceKey) private var trackDistance = true
    @AppStorage(AppSettings.distanceModeKey) private var distanceMode = DistanceMode.automatic.rawValue
    @AppStorage(AppSettings.healthHeartRateKey) private var healthHeartRate = false
    @AppStorage(AppSettings.playerMapModeKey) private var mapMode = PlayerMapMode.overview
    @AppStorage(AppSettings.dailyReminderKey) private var dailyReminder = true
    @AppStorage(AppSettings.dailyReminderMinuteKey) private var dailyReminderMinute = AppSettings.defaultDailyReminderMinute
    @Environment(AuthStore.self) private var auth
    @Environment(ProgramStore.self) private var programs
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingAnswers = false
    /// iOS has notifications turned off for the app.
    @State private var notificationsBlocked = false
    @State private var offerRebuild = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ScreenTitle(eyebrow: "PREFERENCES", title: "Settings")
                        .padding(.top, 16)
                        .padding(.bottom, -12)

                    CardSection(footer: "Your workouts, history and plan are backed up to your account.") {
                        accountHeader
                        Divider()
                        Button { editingAnswers = true } label: {
                            row("Edit my answers", icon: "person.text.rectangle") { RowChevron() }
                        }
                        .buttonStyle(.plain)
                        divider
                        Button { confirmingSignOut = true } label: {
                            row("Sign out", icon: "rectangle.portrait.and.arrow.right") { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        divider
                        Button { confirmingDelete = true } label: {
                            row("Delete account", icon: "trash", tint: .red) {
                                if isDeleting { ProgressView() }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    }

                    CardSection(title: "Reminders", footer: "Each morning: your run for the day, or a rest-day nudge to get out for an easy walk.") {
                        toggleRow("Daily plan reminder", icon: "bell", isOn: $dailyReminder.animation())
                        if dailyReminder {
                            divider
                            row("Time", icon: "clock") {
                                DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                            }
                            if notificationsBlocked {
                                divider
                                Button {
                                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    row("Notifications are off for Runwise. Turn them on in Settings.", icon: "bell.slash", tint: .orange) { RowChevron() }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    CardSection(title: "Volume", footer: "Relative to your phone's volume. Beeps and voice play even with the silent switch on, and briefly lower music from other apps.") {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $beepVolume, in: 0.1...1)
                                .tint(Phase.work.color)
                                .accessibilityLabel("Volume")
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        divider
                        Button {
                            let audio = AudioCueScheduler.shared
                            audio.volume = Float(beepVolume)
                            audio.vibrateOnCountdown = vibrateOnCountdown
                            audio.playTestSound(voiceCountdown: voiceCountdown)
                        } label: {
                            row("Test sound", icon: "play.circle") {
                                Text("\(Int((beepVolume * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    CardSection(title: "Voice coach", footer: "Allison and Brad are recorded coaches; the iPhone voice is built in. \"Halfway there\" plays in intervals of 20 seconds or more. Distance and pace are said early in the next interval, e.g. \"That was 0.21 miles. 8 minutes 15 per mile.\" Pace is skipped for work intervals under 30 seconds.") {
                        row("Coach voice", icon: "mic") {
                            Picker("Coach voice", selection: $coachVoice) {
                                ForEach(CoachVoice.allCases) { voice in
                                    Text(voice.title).tag(voice.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(Phase.work.color)
                            .fixedSize()
                        }
                        .onChange(of: coachVoice) {
                            // Let them hear the new voice.
                            let audio = AudioCueScheduler.shared
                            audio.volume = Float(beepVolume)
                            audio.playTestSound(voiceCountdown: true)
                        }
                        divider
                        toggleRow("Count down the last 3 seconds", isOn: $voiceCountdown)
                        divider
                        toggleRow("Say \"Halfway there\"", isOn: $voiceHalfway)
                        divider
                        toggleRow("Say how many intervals are left", isOn: $voiceIntervalsLeft)
                        divider
                        toggleRow("Say distance after each work interval", isOn: $voiceDistance)
                            .disabled(!trackDistance)
                        divider
                        toggleRow("Say pace after each work interval", isOn: $voicePace)
                            .disabled(!trackDistance)
                    }

                    CardSection(title: "Distance", footer: "GPS is most accurate outdoors; the step counter fills in when GPS is weak and works on a treadmill. With the map off, the workout fills the screen.") {
                        toggleRow("Track distance", icon: "mappin.and.ellipse", isOn: $trackDistance.animation())
                        if trackDistance {
                            divider
                            row("Measure with") {
                                Picker("Measure with", selection: $distanceMode) {
                                    Text("GPS + step counter").tag(DistanceMode.automatic.rawValue)
                                    Text("Step counter only").tag(DistanceMode.stepsOnly.rawValue)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(Phase.work.color)
                                .fixedSize()
                            }
                        }
                        if distanceMode == DistanceMode.automatic.rawValue {
                            divider
                            toggleRow("Show map while running", icon: "map", isOn: Binding(
                                get: { mapMode != .off },
                                set: { mapMode = $0 ? .overview : .off }
                            ))
                        }
                    }

                    CardSection(title: "Heart rate", footer: "Connect a chest strap, armband or Garmin watch to see heart rate live. With Apple Health on, Apple Watch heart rate is added after each run (start a workout on the watch too) and used to tailor your plan.") {
                        NavigationLink {
                            HeartRateMonitorView()
                        } label: {
                            row("Monitor", icon: "applewatch") {
                                HStack(spacing: 6) {
                                    if HeartRateMonitor.shared.status == .connected {
                                        Circle().fill(.green).frame(width: 7, height: 7)
                                    }
                                    Text(HeartRateMonitor.shared.pairedName ?? "None")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    RowChevron()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if HealthHeartRate.isAvailable {
                            divider
                            toggleRow("Read from Apple Health", icon: "heart.fill", isOn: $healthHeartRate)
                                .onChange(of: healthHeartRate) { _, on in
                                    if on { Task { await HealthHeartRate.requestAccess() } }
                                }
                        }
                    }

                    CardSection(title: "Haptics") {
                        toggleRow("Vibrate with countdown", icon: "iphone.radiowaves.left.and.right", isOn: $vibrateOnCountdown)
                    }

                    CardSection(title: "About") {
                        Link(destination: AppLinks.privacyPolicy) {
                            row("Privacy policy", icon: "checkmark.shield") { RowChevron() }
                        }
                        .buttonStyle(.plain)
                        divider
                        Link(destination: AppLinks.support) {
                            row("Help & support", icon: "questionmark.circle") { RowChevron() }
                        }
                        .buttonStyle(.plain)
                        divider
                        row("Version") {
                            Text(AppLinks.appVersion).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .clearsTabBar()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $editingAnswers) {
                OnboardingView(mode: .edit) { offerRebuild = true }
            }
            .confirmationDialog("Build a new plan with your updated answers?", isPresented: $offerRebuild, titleVisibility: .visible) {
                Button("Build a new plan") { Task { await programs.build() } }
                Button("Keep my current plan", role: .cancel) {}
            }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your data stays in your account and comes back when you sign in again.")
            }
            .alert("Delete your account?", isPresented: $confirmingDelete) {
                Button("Delete Account", role: .destructive, action: deleteAccount)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(auth.usesAppleSignIn
                     ? "This permanently deletes your account, workouts, run history and training plans. It can't be undone. Apple will ask you to confirm."
                     : "This permanently deletes your account, workouts, run history and training plans. It can't be undone.")
            }
            .alert("Account not deleted", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .task {
                AudioCueScheduler.shared.prepareSpeech(for: AudioCueScheduler.testCues(voiceCountdown: true))
            }
            .task(id: scenePhase) {
                notificationsBlocked = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            }
        }
    }

    /// The reminder time as a date today, for the time picker.
    private var reminderTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: dailyReminderMinute, to: Calendar.current.startOfDay(for: .now)) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                dailyReminderMinute = (parts.hour ?? 8) * 60 + (parts.minute ?? 0)
            }
        )
    }

    // MARK: Rows

    /// Who's signed in: an initial on a gradient, how, and the email.
    private var accountHeader: some View {
        HStack(spacing: 14) {
            Text(auth.email?.first.map { String($0).uppercased() } ?? "?")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [Phase.work.color, Phase.rest.color], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(auth.usesAppleSignIn ? "Signed in with Apple" : "Signed in")
                    .font(.headline)
                Text(auth.email ?? "–")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private func row<Trailing: View>(
        _ title: String,
        icon: String? = nil,
        tint: Color = Phase.work.color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                RowIcon(systemImage: icon, tint: tint)
            }
            Text(title)
                .foregroundStyle(tint == .red ? .red : .primary)
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
        .frame(minHeight: 56)
    }

    private func deleteAccount() {
        isDeleting = true
        Task {
            do {
                let appleCode = auth.usesAppleSignIn ? try await AppleReauthorization().authorizationCode() : nil
                try await auth.deleteAccount(appleAuthorizationCode: appleCode)
            } catch let error as ASAuthorizationError where error.code == .canceled {
                // Closed the Apple sheet, so keep the account.
            } catch {
                deleteError = "Couldn't delete your account. Check your connection and try again."
            }
            isDeleting = false
        }
    }
}
