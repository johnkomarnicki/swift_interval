import Foundation

/// How a coach's proposed weeks differ from the current plan, session by
/// session. Sessions are matched by id (`w{week}-{day}`). Pure, so it can be
/// unit tested.
///
/// The proposal's `weeks` replace the plan from the first proposed week on, so
/// a current week past the proposal's last one is dropped: its sessions show as
/// removed.
struct ProposalDiff: Equatable {
    struct SessionChange: Identifiable, Equatable {
        enum Kind: Equatable {
            case changed, added, removed, unchanged
        }

        let id: String
        let kind: Kind
        /// The session as it is now; nil when added.
        let old: ProgramSession?
        /// The session as proposed; nil when removed.
        let new: ProgramSession?

        /// The proposed session, or the current one when it's removed.
        var session: ProgramSession? { new ?? old }
    }

    struct Week: Identifiable, Equatable {
        let week: Int
        let focus: String
        /// Every session in the week, by date, unchanged ones included.
        let sessions: [SessionChange]

        var id: Int { week }

        var changes: [SessionChange] { sessions.filter { $0.kind != .unchanged } }
        var unchangedCount: Int { sessions.count - changes.count }
    }

    /// Every week the proposal touches, in order.
    let weeks: [Week]

    /// With no current plan (e.g. the runner switched plans) every proposed
    /// session counts as added.
    init(current: ProgramPlan?, proposed: [ProgramWeek]) {
        let firstWeek = proposed.map(\.week).min() ?? Int.max
        let currentWeeks = (current?.weeks ?? []).filter { $0.week >= firstWeek }
        let currentByNumber = Dictionary(currentWeeks.map { ($0.week, $0) }, uniquingKeysWith: { first, _ in first })
        let proposedByNumber = Dictionary(proposed.map { ($0.week, $0) }, uniquingKeysWith: { first, _ in first })
        let numbers = Set(currentByNumber.keys).union(proposedByNumber.keys).sorted()

        weeks = numbers.map { number in
            let old = currentByNumber[number]?.sessions ?? []
            let new = proposedByNumber[number]?.sessions ?? []
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newIDs = Set(new.map(\.id))

            var sessions: [SessionChange] = new.map { session in
                guard let before = oldByID[session.id] else {
                    return SessionChange(id: session.id, kind: .added, old: nil, new: session)
                }
                let kind: SessionChange.Kind = Self.isSame(before, session) ? .unchanged : .changed
                return SessionChange(id: session.id, kind: kind, old: before, new: session)
            }
            sessions += old.filter { !newIDs.contains($0.id) }.map {
                SessionChange(id: $0.id, kind: .removed, old: $0, new: nil)
            }
            sessions.sort { ($0.session?.date ?? "", $0.id) < ($1.session?.date ?? "", $1.id) }

            let focus = proposedByNumber[number]?.focus ?? currentByNumber[number]?.focus ?? ""
            return Week(week: number, focus: focus, sessions: sessions)
        }
    }

    /// Weeks with at least one changed, added or removed session.
    var changedWeeks: [Week] { weeks.filter { !$0.changes.isEmpty } }

    /// Same run on the same day. A reworded description alone doesn't count:
    /// the coach often rephrases sessions it didn't change.
    static func isSame(_ old: ProgramSession, _ new: ProgramSession) -> Bool {
        old.date == new.date && old.kind == new.kind && old.title == new.title && old.workout == new.workout
    }

    /// The session's whole length in minutes, warm-up and cool-down included.
    static func minutes(_ session: ProgramSession) -> Int {
        Int((Double(session.workout.workoutPlan.totalSeconds) / 60).rounded())
    }
}
