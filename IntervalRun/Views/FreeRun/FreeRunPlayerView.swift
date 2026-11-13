import SwiftData
import SwiftUI
import UIKit

/// Full-screen stopwatch for a free run or walk, readable at arm's length.
struct FreeRunPlayerView: View {
    let session: FreeRunSession
    let onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var confirmingEnd = false
    @AppStorage(AppSettings.playerMapModeKey) private var mapMode = PlayerMapMode.overview
    @State private var isMapExpanded = false
    private let heartRate = HeartRateMonitor.shared

    var body: some View {
        Group {
            if session.isFinished {
                FreeRunCompleteView(session: session, onDone: onExit)
            } else {
                player
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let context = modelContext
            session.onResultsReady = { results in
                context.insert(WorkoutRecord(results: results))
                try? context.save()
                SyncService.shared.scheduleSync()
            }
            session.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
        .onChange(of: session.isFinished) { _, finished in
            if finished {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.refresh()
            }
        }
    }

    private var player: some View {
        let activity = session.activity
        return PlayerScaffold(
            eyebrow: "FREE \(activity.title.uppercased())",
            title: session.route?.name ?? "Your own route",
            tint: activity.color,
            source: session.source,
            showsMap: showsMap,
            isMapExpanded: $isMapExpanded
        ) { bottomInset in
            RunMapBackground(route: session.route, trail: session.trail, position: session.position, tint: activity.color, bottomInset: bottomInset)
        } sheet: {
            sheet(activity: activity)
        }
        .confirmationDialog("Finish this \(activity.title.lowercased())?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("Finish and Save") {
                session.finish()
            }
            Button("Discard", role: .destructive) {
                session.stop()
                onExit()
            }
            Button("Keep Going", role: .cancel) {}
        }
    }

    /// A live map needs GPS, and the runner can switch it off in Settings.
    private var showsMap: Bool {
        session.usesGPS && !DistancePermissions.locationDenied && mapMode != .off
    }

    /// Only the activity, clock and controls while the map is enlarged.
    private var isCompact: Bool { showsMap && isMapExpanded }

    private func sheet(activity: FreeActivity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                PhasePill(text: activity.title.uppercased(), tint: activity.color)
                if session.isPaused {
                    Text("Paused")
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.85)
                }
                Spacer()
            }

            PlayerClockRow(
                time: TimeFormat.clock(Int(session.activeTime)),
                timeAccessibilityLabel: "Time",
                sideTitle: "DISTANCE",
                sideValue: DistanceFormat.short(session.meters),
                size: isCompact ? 72 : (showsMap ? 112 : 136),
                isPaused: session.isPaused
            )

            if !isCompact {
                PlayerStatGrid(stats: stats)
            }

            PlayerControls(
                endSystemImage: "stop.fill",
                endLabel: "Finish",
                onEnd: { confirmingEnd = true },
                isPaused: session.isPaused,
                tint: activity.color,
                onTogglePause: { session.togglePause() }
            )
            .padding(.top, 4)
        }
    }

    private var stats: [PlayerStat] {
        var stats = [PlayerStat.pace("AVG PACE", seconds: session.activeTime, meters: session.meters)]
        if heartRate.isLive {
            stats.append(.heartRate(heartRate))
        }
        return stats
    }
}

/// Shown when a free run or walk is finished.
private struct FreeRunCompleteView: View {
    let session: FreeRunSession
    let onDone: () -> Void

    var body: some View {
        let activity = session.activity
        ZStack {
            activity.color.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                Text("\(activity.title) complete")
                    .font(.largeTitle.bold())

                HStack(spacing: 0) {
                    summaryStat("TIME", TimeFormat.clock(Int(session.activeTime)))
                    summaryStat("DISTANCE", session.results == nil ? "–" : DistanceFormat.short(session.meters))
                    summaryStat("AVG PACE", session.results == nil ? "–" : DistanceFormat.pace(seconds: session.activeTime, meters: session.meters))
                    if let heartRate = session.results?.intervals.averageHeartRate {
                        summaryStat("AVG HR", "\(heartRate)")
                    }
                }
                .padding(.top, 4)

                if let result = session.results?.intervals.first {
                    if result.source == .steps {
                        Label("Measured mostly by the step counter", systemImage: "figure.walk")
                            .font(.subheadline)
                            .opacity(0.8)
                    }
                } else {
                    ProgressView("Calculating distance…")
                        .tint(.white)
                }
                Spacer()

                Button(action: onDone) {
                    Text("Done")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(activity.color)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
    }

    private func summaryStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .opacity(0.8)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}
