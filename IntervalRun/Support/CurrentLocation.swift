import CoreLocation

/// The phone's location right now, for starting a route where the runner is.
enum CurrentLocation {
    /// Nil if there's no fix within `timeout` (no permission, indoors, etc.).
    static func fetch(timeout: Duration = .seconds(8)) async -> RouteCoordinate? {
        await withTaskGroup(of: RouteCoordinate?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 {
                            return RouteCoordinate(location.coordinate)
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
