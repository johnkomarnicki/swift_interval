import CoreLocation
import CoreMotion
import os

/// How distance is measured.
enum DistanceMode: String, CaseIterable {
    /// GPS, falling back to the step counter for intervals GPS didn't cover.
    case automatic
    /// Step counter only (treadmill, indoor track).
    case stepsOnly
}

/// Measures distance during a workout with GPS and the step counter.
///
/// GPS fixes go into a `DistanceAccumulator`. Step-counter updates are split
/// across intervals as they arrive for the live display. When the workout ends,
/// any interval GPS didn't cover is measured exactly by asking the step counter
/// for that interval's real time ranges (the phone records steps by itself, even
/// while the app is in the background).
@MainActor
final class DistanceTracker: NSObject, CLLocationManagerDelegate {
    /// Called whenever new distance data arrives.
    var onChange: (@MainActor () -> Void)?
    /// Where GPS has seen the runner go, for the player's map.
    private(set) var trail = RunTrail()
    /// The latest good fix and direction of travel, for the player's map.
    /// Kept up to date while paused too, so the map still follows the runner.
    private(set) var position: LivePosition?

    /// Fixes older than this when they arrive are cached positions, not live ones.
    private static let maxFixAge: TimeInterval = 10

    private let mode: DistanceMode
    private let elapsedAt: @MainActor (Date) -> TimeInterval?
    private var accumulator: DistanceAccumulator
    /// Live step-counter meters per segment.
    private var stepMeters: [Double]
    private var lastStepTotal: Double = 0
    private var startDate: Date?
    /// Set when the workout ends: later fixes are ignored, but ones taken before
    /// it that arrive late (GPS lags about a second) still count.
    private var cutoff: Date?
    private var isTracking = false
    private let locationManager = CLLocationManager()
    private let pedometer = CMPedometer()
    private let log = Logger(subsystem: "IntervalRun", category: "Distance")

    /// - Parameter elapsedAt: workout-elapsed time at a moment, or nil while paused.
    init(segments: [Segment], mode: DistanceMode, elapsedAt: @escaping @MainActor (Date) -> TimeInterval?) {
        self.mode = mode
        self.elapsedAt = elapsedAt
        accumulator = DistanceAccumulator(segments: segments)
        stepMeters = Array(repeating: 0, count: segments.count)
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    var usesGPS: Bool { mode == .automatic }

    private var stepsAvailable: Bool {
        CMPedometer.isDistanceAvailable() && CMPedometer.authorizationStatus() != .denied
            && CMPedometer.authorizationStatus() != .restricted
    }

    // MARK: Control

    func start(at date: Date) {
        guard !isTracking else { return }
        isTracking = true
        startDate = date
        if usesGPS {
            startLocationUpdates()
        }
        if CMPedometer.isDistanceAvailable() {
            pedometer.startUpdates(from: date) { [weak self] data, _ in
                guard let meters = data?.distance?.doubleValue else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.addSteps(totalMeters: meters) }
                }
            }
        }
    }

    /// Call on pause, resume and skip, so the gap doesn't count as distance.
    func breakPath() {
        accumulator.breakPath()
    }

    /// The workout ended at `date`. Keep listening briefly for late fixes taken
    /// before then; call `stop()` a couple of seconds later.
    func finish(at date: Date) {
        cutoff = date
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        accumulator.flush()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        pedometer.stopUpdates()
    }

    // MARK: Results

    /// Best current distance for a segment, for the live display and voice.
    func liveDistance(segment: Int, activeSeconds: TimeInterval) -> (meters: Double, source: DistanceSource) {
        guard stepMeters.indices.contains(segment) else { return (0, .none) }
        if usesGPS, accumulator.hasGoodCoverage(segment: segment, activeSeconds: activeSeconds) {
            return (accumulator.liveMeters(segment: segment), .gps)
        }
        if stepsAvailable {
            return (stepMeters[segment], .steps)
        }
        if usesGPS, accumulator.fixes[segment] > 0 {
            return (accumulator.liveMeters(segment: segment), .gps)
        }
        return (0, .none)
    }

    /// Fills in each interval's distance: GPS where it covered the interval,
    /// otherwise the step counter's exact count for the interval's time ranges.
    func fillDistances(_ intervals: [IntervalResult], timeline: RunTimeline, now: Date) async -> [IntervalResult] {
        var filled = intervals
        for i in filled.indices {
            let index = filled[i].index
            guard !filled[i].wasSkipped else {
                filled[i].meters = 0
                filled[i].source = .none
                continue
            }
            if usesGPS, accumulator.hasGoodCoverage(segment: index, activeSeconds: filled[i].activeSeconds) {
                filled[i].meters = accumulator.meters[index]
                filled[i].source = .gps
                continue
            }
            if stepsAvailable {
                let start = accumulator.segmentStarts[index]
                let span = start..<(start + TimeInterval(filled[i].plannedSeconds))
                var total: Double? = 0
                for range in timeline.dateRanges(for: span, now: now) {
                    guard let meters = await queryStepMeters(range) else {
                        total = nil
                        break
                    }
                    total? += meters
                }
                filled[i].meters = total ?? stepMeters[index]
                filled[i].source = .steps
                continue
            }
            let (meters, source) = liveDistance(segment: index, activeSeconds: filled[i].activeSeconds)
            filled[i].meters = meters
            filled[i].source = source
        }
        return filled
    }

    private func queryStepMeters(_ range: DateInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: range.start, to: range.end) { data, error in
                continuation.resume(returning: error == nil ? (data?.distance?.doubleValue ?? 0) : nil)
            }
        }
    }

    // MARK: Updates

    /// No `locationServicesEnabled()` check: it blocks the main thread. With
    /// Location Services off, updates just fail (`didFailWithError`) and the
    /// step counter covers distance.
    private func startLocationUpdates() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if Self.hasLocationBackgroundMode {
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
            }
            locationManager.startUpdatingLocation()
        default:
            log.info("Location not authorized; using the step counter")
        }
    }

    private func addSteps(totalMeters: Double) {
        defer { lastStepTotal = totalMeters }
        guard isTracking, cutoff == nil, totalMeters > lastStepTotal,
              let elapsed = elapsedAt(.now),
              let index = accumulator.segmentIndex(forElapsed: elapsed) else { return }
        stepMeters[index] += totalMeters - lastStepTotal
        onChange?()
    }

    private func addLocations(_ locations: [CLLocation]) {
        guard isTracking, let startDate else { return }
        for location in locations {
            guard location.timestamp >= startDate,
                  location.timestamp <= cutoff ?? .distantFuture,
                  -location.timestamp.timeIntervalSinceNow < Self.maxFixAge else { continue }
            if location.horizontalAccuracy >= 0, location.horizontalAccuracy <= DistanceAccumulator.maxAccuracy {
                position = LivePosition(coordinate: RouteCoordinate(location.coordinate))
            }
            guard let elapsed = elapsedAt(location.timestamp) else {
                accumulator.breakPath() // paused
                trail.breakLine()
                continue
            }
            accumulator.add(location, elapsed: elapsed)
            trail.add(location)
        }
        onChange?()
    }

    // MARK: CLLocationManagerDelegate (called on the main thread)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { addLocations(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if isTracking, usesGPS { startLocationUpdates() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporary failures (no fix yet) are normal; the step counter covers gaps.
    }

    /// Background location updates crash without this Info.plist entry, so check.
    private static let hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }()
}

/// Asks for location and motion permission before a workout starts, so the
/// prompts don't appear mid-run.
@MainActor
enum DistancePermissions {
    private static let locationManager = CLLocationManager()
    private static let pedometer = CMPedometer()

    /// The user turned location off for the app, so there's no live map.
    static var locationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    static func requestIfNeeded(mode: DistanceMode) {
        if mode == .automatic, locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if CMPedometer.isDistanceAvailable(), CMPedometer.authorizationStatus() == .notDetermined {
            // Any query triggers the Motion & Fitness prompt.
            pedometer.queryPedometerData(from: .now.addingTimeInterval(-60), to: .now) { _, _ in }
        }
    }
}
