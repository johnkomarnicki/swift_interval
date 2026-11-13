import Foundation
import HealthKit
import SwiftData

/// Heart rate saved to Apple Health by an Apple Watch (or AirPods, Powerbeats,
/// or a strap paired with another app), read after a run. Only read when
/// turned on in Settings.
enum HealthHeartRate {
    private static let store = HKHealthStore()
    private static let type = HKQuantityType(.heartRate)
    private static let unit = HKUnit.count().unitDivided(by: .minute())

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Shows Apple's permission sheet (only the first time). Health never says
    /// whether reading was allowed; without permission, queries just find nothing.
    static func requestAccess() async {
        guard isAvailable else { return }
        try? await store.requestAuthorization(toShare: [], read: [type])
    }

    /// Every reading during `interval`. A watch saves readings in batches, so
    /// each reading in a batch is returned on its own.
    static func samples(in interval: DateInterval) async -> [HeartRateSample] {
        guard isAvailable else { return [] }
        let predicate = HKSamplePredicate.quantitySample(
            type: type,
            predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        )
        let query = HKQuantitySeriesSampleQueryDescriptor(predicate: predicate, options: .orderByQuantitySampleStartDate)
        var samples: [HeartRateSample] = []
        do {
            for try await result in query.results(for: store) {
                samples.append(HeartRateSample(
                    date: result.dateInterval.start,
                    bpm: Int(result.quantity.doubleValue(for: unit).rounded())
                ))
            }
        } catch {
            return samples
        }
        return samples
    }
}

/// Adds heart rate to finished runs.
@MainActor
enum HeartRateRecorder {
    /// Runs this recent are checked for heart rate that reached Apple Health late.
    private static let backfillWindow: TimeInterval = 2 * 24 * 3600

    /// Heart rate for a finished run's intervals: from the Bluetooth monitor if
    /// it recorded the run, otherwise from Apple Health when that's turned on.
    static func addHeartRate(to intervals: [IntervalResult]) async -> [IntervalResult] {
        let periods = intervals.flatMap { $0.periods ?? [] }
        guard let run = span(of: periods) else { return intervals }
        let live = HeartRateMonitor.shared.samples(in: run)
        if HeartRateSample.enough(live, for: periods) {
            return WorkoutResults.addingHeartRate(intervals, from: live)
        }
        guard AppSettings.healthHeartRate else { return intervals }
        return WorkoutResults.addingHeartRate(intervals, from: await HealthHeartRate.samples(in: run))
    }

    /// Fills in heart rate from Apple Health for recent runs saved without it.
    /// An Apple Watch often hands its readings to the phone a while after the
    /// run, so this runs whenever the app comes to the foreground.
    static func backfill(_ context: ModelContext) async {
        guard AppSettings.healthHeartRate, HealthHeartRate.isAvailable else { return }
        let since = Date.now.addingTimeInterval(-backfillWindow)
        let recent = (try? context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.date >= since }))) ?? []
        var changed = false
        for record in recent {
            let intervals = record.intervals
            guard !intervals.contains(where: { $0.heartRate != nil }) else { continue }
            let periods = intervals.flatMap { $0.periods ?? [] }
            guard let run = span(of: periods) else { continue } // saved before periods were recorded
            let filled = WorkoutResults.addingHeartRate(intervals, from: await HealthHeartRate.samples(in: run))
            guard filled != intervals else { continue }
            record.intervals = filled
            record.needsUpload = true
            changed = true
        }
        if changed {
            try? context.save()
            SyncService.shared.scheduleSync()
        }
    }

    private static func span(of periods: [DateInterval]) -> DateInterval? {
        guard let start = periods.map(\.start).min(), let end = periods.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }
}
