import MapKit
import SwiftUI

/// Whether the live map shows above the player's sheet. Set in Settings.
enum PlayerMapMode: String, CaseIterable {
    /// Flat, north up, following the runner.
    case overview
    /// The plain color screen.
    case off
}

/// Full-screen live map behind the player: the planned route (dotted), the line
/// run so far in the phase color, where it started, and the runner's position.
/// The player's sheet covers the bottom of the map; `bottomInset` keeps the
/// runner centred in the part that's still showing.
///
/// Not interactive: a stray touch mid-run shouldn't pan the map away from the
/// runner. The camera follows `position` from the run's own GPS.
struct RunMapBackground: View {
    let route: RoutePath?
    let trail: RunTrail
    let position: LivePosition?
    let tint: Color
    var bottomInset: CGFloat = 0

    @State private var camera: MapCameraPosition

    /// Meters from the camera to the runner.
    private static let distance: Double = 1500

    init(route: RoutePath?, trail: RunTrail, position: LivePosition?, tint: Color, bottomInset: CGFloat = 0) {
        self.route = route
        self.trail = trail
        self.position = position
        self.tint = tint
        self.bottomInset = bottomInset
        _camera = State(initialValue: Self.camera(position: position, route: route))
    }

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            if let route {
                RouteMapContent(path: route.coordinates, lineColor: .white.opacity(0.6), dash: [1, 10])
            }
            ForEach(Array(trail.lines.enumerated()), id: \.offset) { _, line in
                if line.count > 1 {
                    MapPolyline(coordinates: line.map(\.coordinate))
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            // A planned route already marks its own start.
            if route == nil, let start = trail.lines.first?.first {
                Annotation("Start", coordinate: start.coordinate) {
                    RouteDot(color: .white, systemImage: "flag.fill", iconColor: .black)
                }
            }
            if let position {
                Annotation("You", coordinate: position.coordinate.coordinate) {
                    Circle()
                        .fill(tint)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            } else {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(
            elevation: .flat,
            emphasis: .muted,
            pointsOfInterest: .excludingAll
        ))
        .environment(\.colorScheme, .dark)
        .safeAreaPadding(.bottom, bottomInset)
        .onChange(of: position) {
            // Fixes come about once a second; gliding between them reads as
            // continuous movement.
            withAnimation(.linear(duration: 1)) {
                camera = Self.camera(position: position, route: route)
            }
        }
        .overlay(alignment: .top) {
            // Keeps the header readable over light patches of map.
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    /// Until the run's GPS has a good fix, MapKit's own location (or the route)
    /// stands in.
    private static func camera(position: LivePosition?, route: RoutePath?) -> MapCameraPosition {
        guard let position else {
            return .userLocation(fallback: route.map { RouteMapView.overview(of: $0.coordinates) } ?? .automatic)
        }
        return .camera(MapCamera(centerCoordinate: position.coordinate.coordinate, distance: distance, heading: 0, pitch: 0))
    }
}
