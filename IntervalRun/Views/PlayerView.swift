import SwiftUI
import UIKit

/// Full-screen workout player, built to be read at arm's length while running.
struct PlayerView: View {
    let session: WorkoutSession
    /// Called to close the player. `true` means the workout was completed.
    let onExit: (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingEnd = false

    var body: some View {
        Group {
            if session.isFinished {
                CompleteView(name: session.name, totalTime: session.totalTime) {
                    onExit(true)
                }
            } else {
                player
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
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
        return ZStack {
            phase.color
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: phase)

            VStack(spacing: 0) {
                header

                Spacer(minLength: 12)

                Text(phase.title)
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if let round = segment?.round {
                    Text("ROUND \(round) OF \(session.plan.rounds)")
                        .font(.title2.weight(.bold))
                        .opacity(0.9)
                        .padding(.top, 4)
                }

                Text(TimeFormat.countdown(session.status.timeLeftInSegment))
                    .font(.system(size: 150, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.horizontal)
                    .accessibilityLabel("Time left in interval")

                if session.isPaused {
                    Text("PAUSED")
                        .font(.title2.weight(.heavy))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.25), in: Capsule())
                }

                Text(nextLabel)
                    .font(.title3.weight(.semibold))
                    .opacity(0.85)
                    .padding(.top, 12)

                Spacer(minLength: 12)

                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .foregroundStyle(.white)
        }
        .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Workout", role: .destructive) {
                session.stop()
                onExit(false)
            }
            Button("Keep Going", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(session.name)
                .font(.headline)
                .lineLimit(1)
                .opacity(0.85)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TOTAL LEFT")
                    .font(.caption.weight(.bold))
                    .opacity(0.8)
                Text(TimeFormat.countdown(session.status.totalRemaining))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        HStack(alignment: .center) {
            controlButton(systemImage: "xmark", size: 76, label: "End workout") {
                confirmingEnd = true
            }
            Spacer()
            controlButton(
                systemImage: session.isPaused ? "play.fill" : "pause.fill",
                size: 112,
                label: session.isPaused ? "Resume" : "Pause"
            ) {
                session.togglePause()
            }
            Spacer()
            controlButton(systemImage: "forward.end.fill", size: 76, label: "Skip to next interval") {
                session.skip()
            }
        }
        .padding(.horizontal, 8)
    }

    private func controlButton(systemImage: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .bold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.22), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var nextLabel: String {
        guard let next = session.nextSegment else { return "Next: Finish" }
        return "Next: \(next.phase.title) \(TimeFormat.clock(next.seconds))"
    }
}
