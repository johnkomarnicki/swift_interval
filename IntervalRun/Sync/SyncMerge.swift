import Foundation

/// Decides how to reconcile local items with the rows in Supabase after local
/// changes have been uploaded. Pure, so the rules can be unit tested.
///
/// - A row that only exists remotely is added locally, unless it's waiting to be deleted.
/// - A local item with changes not yet uploaded is never touched; it wins.
/// - Otherwise a newer remote row replaces the local copy.
/// - A local item that was uploaded before but is gone remotely was deleted
///   elsewhere, so it's removed locally.
enum SyncMerge {
    struct Local: Equatable {
        var id: UUID
        var updatedAt: Date?
        var needsUpload: Bool
    }

    struct Remote: Equatable {
        var id: UUID
        var updatedAt: Date
    }

    struct Plan: Equatable {
        var insertLocally: [UUID] = []
        var updateLocally: [UUID] = []
        var deleteLocally: [UUID] = []
    }

    static func plan(local: [Local], remote: [Remote], pendingDeletes: Set<UUID>) -> Plan {
        var plan = Plan()
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteIDs = Set(remote.map(\.id))

        for row in remote {
            guard let item = localByID[row.id] else {
                if !pendingDeletes.contains(row.id) {
                    plan.insertLocally.append(row.id)
                }
                continue
            }
            guard !item.needsUpload else { continue }
            if row.updatedAt.timeIntervalSince(item.updatedAt ?? .distantPast) > 0.001 {
                plan.updateLocally.append(row.id)
            }
        }
        for item in local where !remoteIDs.contains(item.id) && !item.needsUpload {
            plan.deleteLocally.append(item.id)
        }
        return plan
    }
}
