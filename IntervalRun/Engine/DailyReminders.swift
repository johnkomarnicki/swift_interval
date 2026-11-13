import Foundation
import os
import UserNotifications

/// One morning notification: the day's run, or a nudge on a rest day.
struct DailyReminder: Equatable {
    var fireDate: Date
    var title: String
    var body: String
}

/// Works out the plan's morning notifications for the coming days. Pure, so it
/// can be unit tested.
enum DailyReminderPlanner {
    /// How many days ahead to schedule. Refreshed every time the app opens, so
    /// someone who stops opening it stops hearing from it after this long.
    static let daysAhead = 14

    /// A reminder for each day from today on, at `minuteOfDay` (minutes after
    /// midnight), from the plan's first day to its last run. Skips a time that's
    /// already passed and a day whose runs are all done.
    static func reminders(
        plan: ProgramPlan,
        doneSessionIDs: Set<String>,
        minuteOfDay: Int,
        now: Date = .now,
        days: Int = daysAhead,
        calendar: Calendar = .current
    ) -> [DailyReminder] {
        let progress = ProgramProgress(plan: plan, doneSessionIDs: doneSessionIDs, now: now, calendar: calendar)
        guard let firstDay = ProgramDate.date(from: plan.startDate),
              let lastDay = plan.sessions.compactMap(\.calendarDate).max() else { return [] }

        return (0..<days).compactMap { offset -> DailyReminder? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: progress.today),
                  day >= calendar.startOfDay(for: firstDay), day <= lastDay,
                  let fireDate = calendar.date(byAdding: .minute, value: minuteOfDay, to: day),
                  fireDate > now else { return nil }

            let sessions = progress.sessions(on: day)
            if sessions.isEmpty {
                return restDay(on: fireDate, dayNumber: offset)
            }
            guard let session = sessions.first(where: { !doneSessionIDs.contains($0.id) }) else { return nil }
            return runDay(session, on: fireDate)
        }
    }

    private static func runDay(_ session: ProgramSession, on fireDate: Date) -> DailyReminder {
        let minutes = Int((Double(session.workout.workoutPlan.totalSeconds) / 60).rounded())
        return DailyReminder(
            fireDate: fireDate,
            title: "Run day: \(session.title)",
            body: "\(session.kindLabel), about \(minutes) min. Open Runwise when you're ready to go."
        )
    }

    /// A few wordings, taken in turn, so rest days don't all read the same.
    static let restDayBodies = [
        "Enjoy your rest day. Feel like moving? Go for an easy free walk.",
        "No run today, your legs are recovering. A relaxed free walk is a nice way to stay loose.",
        "Rest day. Take it easy, or head out for a gentle free walk.",
    ]

    private static func restDay(on fireDate: Date, dayNumber: Int) -> DailyReminder {
        DailyReminder(
            fireDate: fireDate,
            title: "Rest day",
            body: restDayBodies[dayNumber % restDayBodies.count]
        )
    }
}

/// Keeps the plan's morning notifications in line with the plan, the runs done
/// and the setting. Each refresh replaces what was scheduled before.
enum DailyReminders {
    private static let idPrefix = "daily-reminder-"
    private static let log = Logger(subsystem: "IntervalRun", category: "Reminders")

    /// Schedules the reminders, asking permission the first time. Passing an
    /// empty list (no plan, or reminders off) just clears them.
    static func schedule(_ reminders: [DailyReminder]) async {
        let center = UNUserNotificationCenter.current()
        await clear()
        guard !reminders.isEmpty else { return }

        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        guard await isAllowed() else { return }

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let request = UNNotificationRequest(
                identifier: idPrefix + ProgramDate.string(from: reminder.fireDate),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
            } catch {
                log.error("Scheduling a reminder failed: \(error.localizedDescription)")
            }
        }
    }

    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Whether iOS lets the app show notifications.
    static func isAllowed() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}
