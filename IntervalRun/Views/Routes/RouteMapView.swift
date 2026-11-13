import MapKit
import SwiftUI

/// A route drawn on a map with a start marker and the runner's position, for
/// previews. The player uses `RunMapBackground`.
struct RouteMapView: View {
    let path: [RouteCoordinate]
    var interactive = true

    @State private var position: MapCameraPosition

    init(path: [RouteCoordinate], interactive: Bool = true) {
        self.path = path
        self.interactive = interactive
        _position = State(initialValue: RouteMapView.overview(of: path))
    }

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            RouteMapContent(path: path)
            UserAnnotation()
        }
        .mapControls {
            if interactive {
                MapUserLocationButton()
                MapCompass()
            }
        }
    }

    /// The whole route in view, with a margin; the user's area if it's empty.
    static func overview(of path: [RouteCoordinate]) -> MapCameraPosition {
        guard !path.isEmpty else { return .userLocation(fallback: .automatic) }
        var rect = MKMapRect.null
        for point in path {
            let mapPoint = MKMapPoint(point.coordinate)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
        }
        let margin = max(rect.width, rect.height, 800) * 0.2
        return .rect(rect.insetBy(dx: -margin, dy: -margin))
    }
}

/// The route line plus start and finish markers, for use inside a `Map`.
struct RouteMapContent: MapContent {
    let path: [RouteCoordinate]
    var lineColor = Phase.work.color
    var dash: [CGFloat] = []

    var body: some MapContent {
        if path.count > 1 {
            MapPolyline(coordinates: path.map(\.coordinate))
                .stroke(lineColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: dash))
        }
        if let start = path.first {
            Annotation("Start", coordinate: start.coordinate) {
                RouteDot(color: Phase.rest.color, systemImage: "flag.fill")
            }
        }
        if let end = path.last, let start = path.first, path.count > 1, end.distance(to: start) > 30 {
            Annotation("Finish", coordinate: end.coordinate) {
                RouteDot(color: Phase.work.color, systemImage: "flag.checkered")
            }
        }
    }
}

struct RouteDot: View {
    let color: Color
    var systemImage: String?
    var iconColor: Color = .white

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: systemImage == nil ? 12 : 24, height: systemImage == nil ? 12 : 24)
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(radius: 1)
    }
}
