import SwiftData
import SwiftUI

/// A plan session waiting to start while the runner picks a route.
struct PendingSessionStart: Identifiable {
    let session: ProgramSession
    var id: String { session.id }
}

extension View {
    /// Starting a plan session that has no route asks for one first. Picking a
    /// route also saves it to the session; skipping starts without one.
    /// `start` runs once the picker has closed, so the player can be presented.
    func routeBeforeStart(
        _ pending: Binding<PendingSessionStart?>,
        programID: UUID,
        start: @escaping (ProgramSession, RoutePath?) -> Void
    ) -> some View {
        modifier(RouteBeforeStart(pending: pending, programID: programID, start: start))
    }
}

private struct RouteBeforeStart: ViewModifier {
    @Binding var pending: PendingSessionStart?
    let programID: UUID
    let start: (ProgramSession, RoutePath?) -> Void

    @Environment(ProgramStore.self) private var programs
    @Query private var records: [WorkoutRecord]
    @AppStorage(AppSettings.programWarmUpKey) private var includeWarmUp = true
    @AppStorage(AppSettings.programCoolDownKey) private var includeCoolDown = true
    /// What was chosen, acted on when the picker closes. Nil means cancelled.
    @State private var decision: (session: ProgramSession, route: RoutePath?)?

    func body(content: Content) -> some View {
        content.sheet(item: $pending, onDismiss: {
            guard let decision else { return }
            self.decision = nil
            start(decision.session, decision.route)
        }) { item in
            RoutePickerView(
                targetMeters: RouteFit.targetMeters(
                    seconds: item.session.workout.workoutPlan(warmUp: includeWarmUp, coolDown: includeCoolDown).totalSeconds,
                    pace: RouteFit.usualPace(records: records)
                ),
                onPick: { route in
                    decision = (item.session, route?.snapshot)
                    if let id = route?.syncID {
                        // If this fails (offline), the run still uses the route;
                        // the session just won't remember it.
                        Task { try? await programs.setRoute(id, for: item.session.id, in: programID) }
                    }
                },
                onSkip: {
                    decision = (item.session, nil)
                }
            )
        }
    }
}
