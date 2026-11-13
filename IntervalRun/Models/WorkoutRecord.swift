import Foundation
import SwiftData

/// A finished workout in the history, stored on the phone with SwiftData and
/// synced to Supabase.
@Model
final class WorkoutRecord {
    var date: Date = Date.now
    var name: String = ""
    var completed: Bool = true
    var totalTime: Double = 0
    var activeTime: Double = 0
    /// Nil when distance wasn't tracked.
    var totalMeters: Double? = nil
    /// JSON-encoded `[IntervalResult]`.
    var intervalsData: Data? = nil
    /// Id of this record's row in Supabase. Nil only for records saved before
    /// accounts existed; one is assigned on the first sync.
    var syncID: UUID? = nil
    /// Saved on this phone and not uploaded yet.
    var needsUpload: Bool = true
    /// Set when the run was a session from an AI program.
    var programID: UUID? = nil
    var programSessionID: String? = nil
    /// `FreeActivity` raw value for a free run or walk; nil for interval workouts.
    var activity: String? = nil
    /// `RunEffort` raw value: how the runner said a program session felt.
    var effort: String? = nil

    init(results: WorkoutResults) {
        syncID = UUID()
        date = results.date
        name = results.name
        completed = results.completed
        totalTime = results.totalTime
        activeTime = results.activeTime
        totalMeters = results.totalMeters
        intervalsData = try? JSONEncoder().encode(results.intervals)
        programID = results.programLink?.programID
        programSessionID = results.programLink?.sessionID
        activity = results.activity?.rawValue
    }

    var freeActivity: FreeActivity? {
        activity.flatMap(FreeActivity.init(rawValue:))
    }

    var runEffort: RunEffort? {
        get { effort.flatMap(RunEffort.init(rawValue:)) }
        set { effort = newValue?.rawValue }
    }

    /// Saves the runner's rating and queues the record for upload again.
    @MainActor
    static func setEffort(_ effort: RunEffort, forRecord syncID: UUID, in context: ModelContext) {
        let id: UUID? = syncID
        var descriptor = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.syncID == id })
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first, record.runEffort != effort else { return }
        record.runEffort = effort
        record.needsUpload = true
        try? context.save()
        SyncService.shared.scheduleSync()
    }

    /// Time shown in lists: moving time for a free run or walk, otherwise the
    /// whole workout including pauses.
    var displayTime: TimeInterval {
        freeActivity == nil ? totalTime : activeTime
    }

    var intervals: [IntervalResult] {
        get { intervalsData.flatMap { try? JSONDecoder().decode([IntervalResult].self, from: $0) } ?? [] }
        set { intervalsData = try? JSONEncoder().encode(newValue) }
    }
}
