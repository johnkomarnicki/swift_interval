import Supabase
import SwiftData
import SwiftUI

@main
struct IntervalRunApp: App {
    private let container: ModelContainer
    @State private var auth = AuthStore()
    @State private var profile = ProfileStore()
    @State private var programs = ProgramStore()
    @State private var reviews = ReviewStore()
    @State private var coach = CoachStore()

    init() {
        AppSettings.registerDefaults()
        do {
            container = try ModelContainer(for: Workout.self, WorkoutRecord.self, RunRoute.self, PendingDeletion.self)
        } catch {
            fatalError("Couldn't open the workout database: \(error)")
        }
        SyncService.shared.container = container
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(profile)
                .environment(programs)
                .environment(reviews)
                .environment(coach)
                .onAppear { auth.start() }
                .onChange(of: auth.state) { _, state in
                    if state == .signedOut {
                        profile.reset()
                        programs.reset()
                        reviews.reset()
                        coach.reset()
                        Task { await DailyReminders.clear() }
                    }
                }
                // Returning from Google sign-in.
                .onOpenURL { supabase.auth.handle($0) }
        }
        .modelContainer(container)
    }
}
