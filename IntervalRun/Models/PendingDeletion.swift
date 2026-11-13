import Foundation
import SwiftData

/// Something deleted on this phone that still has to be deleted in Supabase.
/// Kept until the next successful sync, so offline deletes aren't lost.
@Model
final class PendingDeletion {
    var table: String = ""
    var remoteID: UUID = UUID()

    init(table: String, remoteID: UUID) {
        self.table = table
        self.remoteID = remoteID
    }
}
