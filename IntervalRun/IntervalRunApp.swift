import SwiftData
import SwiftUI

@main
struct IntervalRunApp: App {
    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            WorkoutListView()
        }
        .modelContainer(for: Workout.self)
    }
}
