import Foundation
import Observation
import os
import Supabase

/// The user's current AI training plan, and building a new one.
///
/// Building runs on the `generate-program` Edge Function: it answers right away
/// with the new program's id, then this store watches that row until it's ready
/// (about a minute) or failed. The active plan is cached on the phone so it's
/// there offline, e.g. at the track.
@MainActor
@Observable
final class ProgramStore {
    private(set) var program: TrainingProgram?
    /// Every finished plan (the active one first, then the newest).
    private(set) var library: [TrainingProgram] = []
    private(set) var isBuilding = false
    private(set) var buildError: String?
    private(set) var isLoaded = false

    /// How long to wait for a plan before giving up.
    private static let buildTimeout: TimeInterval = 4 * 60
    private static let pollInterval: Duration = .seconds(3)

    private let log = Logger(subsystem: "IntervalRun", category: "Program")

    private struct BuildRequest: Encodable { var today: String }
    private struct BuildResponse: Decodable { var program_id: UUID }
    private struct FunctionError: Decodable { var error: String }

    func load() async {
        if program == nil { program = Self.cachedProgram() }
        do {
            let rows: [TrainingProgram] = try await supabase.from("programs")
                .select()
                .in("status", values: [
                    TrainingProgram.Status.active.rawValue,
                    TrainingProgram.Status.archived.rawValue,
                    TrainingProgram.Status.generating.rawValue,
                ])
                .order("created_at", ascending: false)
                .execute()
                .value
            let active = rows.first { $0.status == .active }
            program = active
            library = rows.filter { $0.status != .generating && $0.plan != nil }
                .sorted { ($0.status == .active ? 0 : 1, $1.createdAt) < ($1.status == .active ? 0 : 1, $0.createdAt) }
            Self.cache(active)
            // Pick up a plan that was still being built when the app closed.
            if let building = rows.first, building.status == .generating,
               Date.now.timeIntervalSince(building.createdAt) < Self.buildTimeout, !isBuilding {
                Task { await watch(building.id, startedAt: building.createdAt) }
            }
        } catch {
            log.error("Loading program failed: \(error.localizedDescription)")
        }
        isLoaded = true
    }

    /// Asks the AI coach for a new plan from the saved onboarding answers and
    /// recent runs. Replaces the current plan when it's ready.
    func build() async {
        guard !isBuilding else { return }
        isBuilding = true
        buildError = nil
        do {
            // Upload recent runs first so the coach can see them.
            await SyncService.shared.syncNow()
            let response: BuildResponse = try await supabase.functions.invoke(
                "generate-program",
                options: FunctionInvokeOptions(body: BuildRequest(today: ProgramDate.string(from: .now)))
            )
            await watch(response.program_id, startedAt: .now)
        } catch let FunctionsError.httpError(_, data) {
            buildError = (try? JSONDecoder().decode(FunctionError.self, from: data))?.error
                ?? "Couldn't start building your plan. Try again."
            isBuilding = false
        } catch {
            buildError = friendlyMessage(for: error)
            isBuilding = false
        }
    }

    private func watch(_ id: UUID, startedAt: Date) async {
        isBuilding = true
        defer { isBuilding = false }
        while Date.now.timeIntervalSince(startedAt) < Self.buildTimeout {
            try? await Task.sleep(for: Self.pollInterval)
            guard let row = try? await fetch(id) else { continue }
            switch row.status {
            case .active:
                program = row
                Self.cache(row)
                return
            case .failed:
                buildError = "Building your plan didn't work (\(row.error ?? "unknown error")). Try again."
                return
            case .generating, .archived:
                continue
            }
        }
        buildError = "Building your plan is taking too long. Try again in a few minutes."
    }

    // MARK: Library

    /// Makes another plan the active one. Progress on every plan is kept.
    func activate(_ id: UUID) async throws {
        try await supabase.from("programs")
            .update(StatusUpdate(status: .archived), returning: .minimal)
            .eq("status", value: TrainingProgram.Status.active.rawValue)
            .execute()
        try await supabase.from("programs")
            .update(StatusUpdate(status: .active), returning: .minimal)
            .eq("id", value: id.uuidString)
            .execute()
        await load()
    }

    func rename(_ id: UUID, to title: String) async throws {
        try await supabase.from("programs")
            .update(TitleUpdate(title: title), returning: .minimal)
            .eq("id", value: id.uuidString)
            .execute()
        await load()
    }

    /// Deletes a plan that isn't active. Its runs stay in History.
    func delete(_ id: UUID) async throws {
        guard id != program?.id else { return }
        try await supabase.from("programs")
            .delete(returning: .minimal)
            .eq("id", value: id.uuidString)
            .execute()
        await load()
    }

    /// The route chosen for a session, if any.
    func routeID(for sessionID: String, in programID: UUID) -> UUID? {
        loadedProgram(programID)?.sessionRoutes?[sessionID]
    }

    /// Picks the route for a session, or clears it with nil. Saved to the plan
    /// in Supabase, so it needs a connection.
    func setRoute(_ routeID: UUID?, for sessionID: String, in programID: UUID) async throws {
        guard let program = loadedProgram(programID) else { return }
        var routes = program.sessionRoutes ?? [:]
        routes[sessionID] = routeID
        try await supabase.from("programs")
            .update(SessionRoutesUpdate(sessionRoutes: routes), returning: .minimal)
            .eq("id", value: programID.uuidString)
            .execute()
        if self.program?.id == programID {
            self.program?.sessionRoutes = routes
            Self.cache(self.program)
        }
        if let index = library.firstIndex(where: { $0.id == programID }) {
            library[index].sessionRoutes = routes
        }
    }

    private func loadedProgram(_ id: UUID) -> TrainingProgram? {
        program?.id == id ? program : library.first { $0.id == id }
    }

    private struct StatusUpdate: Encodable { var status: TrainingProgram.Status }
    private struct TitleUpdate: Encodable { var title: String }
    private struct SessionRoutesUpdate: Encodable {
        var sessionRoutes: [String: UUID]
        enum CodingKeys: String, CodingKey { case sessionRoutes = "session_routes" }
    }

    private func fetch(_ id: UUID) async throws -> TrainingProgram {
        try await supabase.from("programs")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    func reset() {
        program = nil
        library = []
        isBuilding = false
        buildError = nil
        isLoaded = false
    }

    // MARK: Offline cache

    private static var cacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "active-program.json")
    }

    private static func cachedProgram() -> TrainingProgram? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrainingProgram.self, from: data)
    }

    private static func cache(_ program: TrainingProgram?) {
        guard let program else {
            clearCache()
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? encoder.encode(program).write(to: cacheURL, options: .atomic)
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
