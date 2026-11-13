import Foundation
import os
import Supabase
import SwiftData

/// Keeps the phone's workouts and history in step with Supabase.
///
/// The phone is always written first, so everything works offline. Each sync
/// uploads pending deletes and changes, then pulls the account's rows and merges
/// them in (see `SyncMerge`). Syncs run on sign-in, when the app comes to the
/// foreground, and shortly after any local change.
@MainActor
final class SyncService {
    static let shared = SyncService()

    var container: ModelContainer?

    private var isSyncing = false
    private var syncAgain = false
    private var scheduled: Task<Void, Never>?
    private let log = Logger(subsystem: "IntervalRun", category: "Sync")

    private enum Table {
        static let workouts = "workouts"
        static let records = "workout_records"
        static let routes = "routes"
    }

    /// Syncs in a moment, coalescing bursts of changes into one sync.
    func scheduleSync() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let context = container?.mainContext, supabase.auth.currentUser != nil else { return }
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            do {
                try await pushDeletions(context)
                try await pushWorkouts(context)
                try await pushRecords(context)
                try await pullWorkouts(context)
                try await pullRecords(context)
                try await pushRoutes(context)
                try await pullRoutes(context)
                try context.save()
            } catch {
                log.error("Sync failed: \(error.localizedDescription)")
                return
            }
        } while syncAgain
    }

    // MARK: Local changes

    /// Deletes a workout here and, at the next sync, in Supabase.
    static func delete(_ workout: Workout, in context: ModelContext) {
        if let id = workout.syncID {
            context.insert(PendingDeletion(table: Table.workouts, remoteID: id))
        }
        context.delete(workout)
        shared.scheduleSync()
    }

    /// Deletes a history record here and, at the next sync, in Supabase.
    static func delete(_ record: WorkoutRecord, in context: ModelContext) {
        if let id = record.syncID {
            context.insert(PendingDeletion(table: Table.records, remoteID: id))
        }
        context.delete(record)
        shared.scheduleSync()
    }

    /// Deletes a route here and, at the next sync, in Supabase. Plan sessions
    /// that used it are left with no route.
    static func delete(_ route: RunRoute, in context: ModelContext) {
        if let id = route.syncID {
            context.insert(PendingDeletion(table: Table.routes, remoteID: id))
        }
        context.delete(route)
        shared.scheduleSync()
    }

    /// Removes everything stored on the phone (after signing out). The data
    /// stays in the account.
    func wipeLocalData() {
        guard let context = container?.mainContext else { return }
        try? context.delete(model: Workout.self)
        try? context.delete(model: WorkoutRecord.self)
        try? context.delete(model: RunRoute.self)
        try? context.delete(model: PendingDeletion.self)
        try? context.save()
    }

    // MARK: Upload

    private func pushDeletions(_ context: ModelContext) async throws {
        let pending = try context.fetch(FetchDescriptor<PendingDeletion>())
        guard !pending.isEmpty else { return }
        for table in Set(pending.map(\.table)) {
            let items = pending.filter { $0.table == table }
            try await supabase.from(table)
                .delete(returning: .minimal)
                .in("id", values: items.map { $0.remoteID.uuidString })
                .execute()
            items.forEach { context.delete($0) }
        }
    }

    private func pushWorkouts(_ context: ModelContext) async throws {
        let changed = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.needsUpload == true }))
        guard !changed.isEmpty else { return }
        for workout in changed {
            if workout.syncID == nil { workout.syncID = UUID() }
            if workout.updatedAt == nil { workout.updatedAt = .now }
        }
        let rows = changed.map(RemoteWorkout.init)
        try await supabase.from(Table.workouts).upsert(rows, returning: .minimal).execute()
        // Only clear the flag if nothing changed while uploading.
        for (workout, row) in zip(changed, rows) where workout.updatedAt == row.updatedAt {
            workout.needsUpload = false
        }
    }

    private func pushRecords(_ context: ModelContext) async throws {
        let unsent = try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.needsUpload == true }))
        guard !unsent.isEmpty else { return }
        for record in unsent where record.syncID == nil {
            record.syncID = UUID()
        }
        let rows = unsent.map(RemoteWorkoutRecord.init)
        try await supabase.from(Table.records).upsert(rows, returning: .minimal).execute()
        // Only clear the flag if nothing changed while uploading (an effort
        // rating can land mid-upload, right after the run is saved).
        for (record, row) in zip(unsent, rows) where RemoteWorkoutRecord(record) == row {
            record.needsUpload = false
        }
    }

    // MARK: Download

    private func pullWorkouts(_ context: ModelContext) async throws {
        let remote: [RemoteWorkout] = try await supabase.from(Table.workouts).select().execute().value
        let locals = try context.fetch(FetchDescriptor<Workout>())
        let plan = SyncMerge.plan(
            local: locals.compactMap { workout in
                workout.syncID.map { SyncMerge.Local(id: $0, updatedAt: workout.updatedAt, needsUpload: workout.needsUpload) }
            },
            remote: remote.map { SyncMerge.Remote(id: $0.id, updatedAt: $0.updatedAt) },
            pendingDeletes: try pendingDeletes(Table.workouts, context)
        )
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(locals.compactMap { w in w.syncID.map { ($0, w) } }, uniquingKeysWith: { first, _ in first })

        for id in plan.insertLocally {
            guard let row = remoteByID[id] else { continue }
            let workout = Workout(name: row.name, plan: row.plan, createdAt: row.createdAt)
            workout.syncID = row.id
            workout.updatedAt = row.updatedAt
            workout.needsUpload = false
            context.insert(workout)
        }
        for id in plan.updateLocally {
            guard let row = remoteByID[id], let workout = localByID[id] else { continue }
            workout.name = row.name
            workout.plan = row.plan
            workout.updatedAt = row.updatedAt
            workout.needsUpload = false
        }
        for id in plan.deleteLocally {
            if let workout = localByID[id] { context.delete(workout) }
        }
    }

    private func pullRecords(_ context: ModelContext) async throws {
        let remote: [RemoteWorkoutRecord] = try await supabase.from(Table.records).select().execute().value
        let locals = try context.fetch(FetchDescriptor<WorkoutRecord>())
        // Records barely change after they're saved, so only adds, deletes and
        // the effort rating matter. The table has no updated_at, so a synced
        // local copy just takes the remote rating.
        let plan = SyncMerge.plan(
            local: locals.compactMap { record in
                record.syncID.map { SyncMerge.Local(id: $0, updatedAt: .distantFuture, needsUpload: record.needsUpload) }
            },
            remote: remote.map { SyncMerge.Remote(id: $0.id, updatedAt: $0.startedAt) },
            pendingDeletes: try pendingDeletes(Table.records, context)
        )
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(locals.compactMap { r in r.syncID.map { ($0, r) } }, uniquingKeysWith: { first, _ in first })

        for id in plan.insertLocally {
            guard let row = remoteByID[id] else { continue }
            context.insert(row.makeRecord())
        }
        for (id, record) in localByID where !record.needsUpload {
            guard let row = remoteByID[id], row.effort != record.runEffort else { continue }
            record.runEffort = row.effort
        }
        for id in plan.deleteLocally {
            if let record = localByID[id] { context.delete(record) }
        }
    }

    private func pushRoutes(_ context: ModelContext) async throws {
        let changed = try context.fetch(FetchDescriptor<RunRoute>(predicate: #Predicate { $0.needsUpload == true }))
        guard !changed.isEmpty else { return }
        for route in changed {
            if route.syncID == nil { route.syncID = UUID() }
            if route.updatedAt == nil { route.updatedAt = .now }
        }
        let rows = changed.map(RemoteRoute.init)
        try await supabase.from(Table.routes).upsert(rows, returning: .minimal).execute()
        // Only clear the flag if nothing changed while uploading.
        for (route, row) in zip(changed, rows) where route.updatedAt == row.updatedAt {
            route.needsUpload = false
        }
    }

    private func pullRoutes(_ context: ModelContext) async throws {
        let remote: [RemoteRoute] = try await supabase.from(Table.routes).select().execute().value
        let locals = try context.fetch(FetchDescriptor<RunRoute>())
        let plan = SyncMerge.plan(
            local: locals.compactMap { route in
                route.syncID.map { SyncMerge.Local(id: $0, updatedAt: route.updatedAt, needsUpload: route.needsUpload) }
            },
            remote: remote.map { SyncMerge.Remote(id: $0.id, updatedAt: $0.updatedAt) },
            pendingDeletes: try pendingDeletes(Table.routes, context)
        )
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(locals.compactMap { r in r.syncID.map { ($0, r) } }, uniquingKeysWith: { first, _ in first })

        for id in plan.insertLocally {
            guard let row = remoteByID[id] else { continue }
            let route = RunRoute(name: row.name, waypoints: row.waypoints, legs: row.legs, createdAt: row.createdAt)
            route.syncID = row.id
            route.updatedAt = row.updatedAt
            route.meters = row.meters
            route.needsUpload = false
            context.insert(route)
        }
        for id in plan.updateLocally {
            guard let row = remoteByID[id], let route = localByID[id] else { continue }
            route.name = row.name
            route.waypoints = row.waypoints
            route.legs = row.legs
            route.meters = row.meters
            route.updatedAt = row.updatedAt
            route.needsUpload = false
        }
        for id in plan.deleteLocally {
            if let route = localByID[id] { context.delete(route) }
        }
    }

    private func pendingDeletes(_ table: String, _ context: ModelContext) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<PendingDeletion>()).filter { $0.table == table }.map(\.remoteID))
    }
}

// MARK: - Rows

/// A row of the `workouts` table.
struct RemoteWorkout: Codable {
    var id: UUID
    var name: String
    var plan: WorkoutPlan
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, plan
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: UUID, name: String, plan: WorkoutPlan, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.plan = plan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    @MainActor
    init(_ workout: Workout) {
        self.init(
            id: workout.syncID ?? UUID(),
            name: workout.name,
            plan: workout.plan,
            createdAt: workout.createdAt,
            updatedAt: workout.updatedAt ?? workout.createdAt
        )
    }
}

/// A row of the `workout_records` table.
struct RemoteWorkoutRecord: Codable, Equatable {
    var id: UUID
    var name: String
    var startedAt: Date
    var completed: Bool
    var totalTime: Double
    var activeTime: Double
    var totalMeters: Double?
    var intervals: [IntervalResult]
    var programID: UUID?
    var programSessionID: String?
    var activity: FreeActivity?
    var effort: RunEffort?

    enum CodingKeys: String, CodingKey {
        case id, name, completed, intervals, activity, effort
        case startedAt = "started_at"
        case totalTime = "total_time"
        case activeTime = "active_time"
        case totalMeters = "total_meters"
        case programID = "program_id"
        case programSessionID = "program_session_id"
    }

    /// Writes nil values as null rather than leaving them out, so every row in
    /// an upsert batch has the same columns.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completed, forKey: .completed)
        try container.encode(totalTime, forKey: .totalTime)
        try container.encode(activeTime, forKey: .activeTime)
        try container.encode(totalMeters, forKey: .totalMeters)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(programID, forKey: .programID)
        try container.encode(programSessionID, forKey: .programSessionID)
        try container.encode(activity, forKey: .activity)
        try container.encode(effort, forKey: .effort)
    }

    @MainActor
    init(_ record: WorkoutRecord) {
        id = record.syncID ?? UUID()
        name = record.name
        startedAt = record.date
        completed = record.completed
        totalTime = record.totalTime
        activeTime = record.activeTime
        totalMeters = record.totalMeters
        intervals = record.intervals
        programID = record.programID
        programSessionID = record.programSessionID
        activity = record.freeActivity
        effort = record.runEffort
    }

    func makeRecord() -> WorkoutRecord {
        var link: ProgramLink?
        if let programID, let programSessionID {
            link = ProgramLink(programID: programID, sessionID: programSessionID)
        }
        let record = WorkoutRecord(results: WorkoutResults(
            name: name,
            date: startedAt,
            completed: completed,
            totalTime: totalTime,
            intervals: intervals,
            programLink: link,
            activity: activity
        ))
        record.syncID = id
        record.needsUpload = false
        record.runEffort = effort
        // Keep the stored totals exactly as uploaded.
        record.activeTime = activeTime
        record.totalMeters = totalMeters
        return record
    }
}

/// A row of the `routes` table.
struct RemoteRoute: Codable {
    var id: UUID
    var name: String
    var waypoints: [RouteCoordinate]
    var legs: [[RouteCoordinate]]
    var meters: Double
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, waypoints, legs, meters
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    @MainActor
    init(_ route: RunRoute) {
        id = route.syncID ?? UUID()
        name = route.name
        waypoints = route.waypoints
        legs = route.legs
        meters = route.meters
        createdAt = route.createdAt
        updatedAt = route.updatedAt ?? route.createdAt
    }
}
