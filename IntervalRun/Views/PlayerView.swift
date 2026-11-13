import SwiftData
import SwiftUI
import UIKit

/// Full-screen workout player, built to be read at arm's length while running.
struct PlayerView: View {
    let session: WorkoutSession
    /// Called to close the player. `true` means the workout was completed.
    let onExit: (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(ReviewStore.self) private var reviews
    @State private var confirmingEnd = false
    /// `syncID` of the saved history record, once the results are in.
    @State private var recordID: UUID?
    @AppStorage(AppSettings.playerMapModeKey) private var mapMode = PlayerMapMode.overview
    @State private var isMapExpanded = false
    private let heartRate = HeartRateMonitor.shared

    var body: some View {
        Group {
            if session.isFinished {
                CompleteView(
                    name: session.name,
                    totalTime: session.totalTime,
                    tracksDistance: session.liveDistance != nil,
                    results: session.results,
                    recordID: recordID
                ) {
                    onExit(true)
                }
            } else {
                player
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Saves to history even if the player has closed by the time the
            // results are ready (ending early).
            let context = modelContext
            let reviews = reviews
            session.onResultsReady = { results in
                let record = WorkoutRecord(results: results)
                context.insert(record)
                try? context.save()
                SyncService.shared.scheduleSync()
                recordID = record.syncID
                // A program session ended early never reaches the Complete
                // screen, so the coach is asked to look at it straight away.
                if !results.completed, let link = results.programLink, let syncID = record.syncID {
                    Task { await reviews.requestRunReview(programID: link.programID, recordID: syncID) }
                }
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
                session.handleReturnToForeground()
            }
        }
    }

    private var player: some View {
        let segment = session.currentSegment
        let phase = segment?.phase ?? .coolDown
        return PlayerScaffold(
            eyebrow: "INTERVAL WORKOUT",
            title: session.name,
            tint: phase.color,
            source: session.liveDistance?.source,
            showsMap: showsMap,
            isMapExpanded: $isMapExpanded
        ) { bottomInset in
            RunMapBackground(route: session.route, trail: session.trail, position: session.position, tint: phase.color, bottomInset: bottomInset)
        } sheet: {
            sheet(segment: segment, phase: phase)
        }
        .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Workout", role: .destructive) {
                session.stop()
                onExit(false)
            }
            Button("Keep Going", role: .cancel) {}
        }
    }

    /// A live map needs GPS, and the runner can switch it off in Settings.
    private var showsMap: Bool {
        session.usesGPS && !DistancePermissions.locationDenied && mapMode != .off
    }

    /// Only the phase, clock and controls while the map is enlarged.
    private var isCompact: Bool { showsMap && isMapExpanded }

    private func sheet(segment: Segment?, phase: Phase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                PhasePill(text: phase.title, tint: phase.color)
                if let subtitle = subtitle(segment) {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                if let next = session.nextSegment {
                    NextChip(text: "\(next.phase.title.capitalized) \(TimeFormat.clock(next.seconds))", dotColor: next.phase.color)
                } else {
                    NextChip(text: "Finish", dotColor: .white)
                }
            }

            PlayerClockRow(
                time: TimeFormat.countdown(session.status.timeLeftInSegment),
                timeAccessibilityLabel: "Time left in interval",
                sideTitle: "TOTAL LEFT",
                sideValue: TimeFormat.countdown(session.status.totalRemaining),
                size: isCompact ? 72 : (showsMap ? 112 : 136),
                isPaused: session.isPaused
            )

            if !isCompact {
                SegmentProgressBar(
                    segments: session.engine.segments,
                    starts: session.engine.segmentStarts,
                    elapsed: session.status.elapsed
                )
                if !stats.isEmpty {
                    PlayerStatGrid(stats: stats)
                }
            }

            PlayerControls(
                endSystemImage: "xmark",
                endLabel: "End workout",
                onEnd: { confirmingEnd = true },
                isPaused: session.isPaused,
                tint: phase.color,
                onTogglePause: { session.togglePause() },
                onSkip: { session.skip() }
            )
            .padding(.top, 4)
        }
    }

    private func subtitle(_ segment: Segment?) -> String? {
        if session.isPaused { return "Paused" }
        return segment?.round.map { "Round \($0) of \(session.plan.rounds)" }
    }

    private var stats: [PlayerStat] {
        var stats: [PlayerStat] = []
        let distance = session.liveDistance
        if let distance {
            stats.append(.pace("PACE", seconds: distance.intervalSeconds, meters: distance.interval))
        }
        if heartRate.isLive {
            stats.append(.heartRate(heartRate))
        }
        if let distance {
            stats.append(.distance("INTERVAL", meters: distance.interval))
            stats.append(.distance("DISTANCE", meters: distance.total))
        }
        return stats
    }
}
