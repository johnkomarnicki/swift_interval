import SwiftData
import SwiftUI

/// Saved routes. Opened from the Plan tab.
struct RoutesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RunRoute.createdAt, order: .reverse) private var routes: [RunRoute]
    @State private var editorTarget: RouteEditorTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                NewRouteTiles(
                    onCreate: { editorTarget = .new(.create) },
                    onDraw: { editorTarget = .new(.draw) }
                )

                if routes.isEmpty {
                    Text("Choose a start and a distance and the app makes a route for you, or draw your own on the map. Then pick a route for any session in your plan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    CardSection(title: "Saved routes", detail: "\(routes.count)", footer: "Tap a route to edit it. Touch and hold to delete it.") {
                        ForEach(routes) { route in
                            if route != routes.first {
                                Divider().padding(.leading, 92)
                            }
                            Button {
                                editorTarget = .edit(route)
                            } label: {
                                RouteRow(route: route)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    SyncService.delete(route, in: modelContext)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Routes")
        .navigationBarTitleDisplayMode(.inline)
        .clearsTabBar()
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new(let mode): RouteEditorView(route: nil, mode: mode)
            case .edit(let route): RouteEditorView(route: route)
            }
        }
    }
}

/// Which route the editor sheet is for.
enum RouteEditorTarget: Identifiable {
    case new(RouteEditorMode)
    case edit(RunRoute)

    var id: String {
        switch self {
        case .new(let mode): "new-\(mode.rawValue)"
        case .edit(let route): "\(route.persistentModelID.hashValue)"
        }
    }
}

/// The two ways to start a route, as a pair of tiles: "Create for me" in the
/// work color, "Draw a route" beside it.
struct NewRouteTiles: View {
    let onCreate: () -> Void
    let onDraw: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            tile(RouteEditorMode.create, title: "Create for me", detail: "Pick a distance, we'll map it", isAccent: true, action: onCreate)
            tile(RouteEditorMode.draw, title: "Draw a route", detail: "Tap the map to plot it", isAccent: false, action: onDraw)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ mode: RouteEditorMode, title: String, detail: String, isAccent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isAccent ? .white : Phase.work.color)
                    .frame(width: 44, height: 44)
                    .background(isAccent ? Color.white.opacity(0.2) : Phase.work.color.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer(minLength: 24)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(isAccent ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
            }
            .foregroundStyle(isAccent ? .white : .primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(16)
            .background {
                if isAccent {
                    AccentCardBackground()
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A saved route: its shape, name, kind and length. With a target distance,
/// the row says whether the route fits it.
struct RouteRow: View {
    let route: RunRoute
    var targetMeters: Double?
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            RouteThumbnail(path: route.path)
            VStack(alignment: .leading, spacing: 3) {
                Text(route.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let targetMeters {
                    RouteFitBadge(match: RouteFit.match(routeMeters: route.meters, targetMeters: targetMeters))
                } else {
                    Text(kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.2f", DistanceFormat.miles(route.meters)))
                    .font(.headline.monospacedDigit())
                Text("mi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Phase.work.color)
            } else {
                RowChevron()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Loop" when it ends where it started, otherwise "One way".
    private var kind: String {
        let path = route.path
        guard let start = path.first, let end = path.last, path.count > 1 else { return "No path yet" }
        return end.distance(to: start) <= 30 ? "Loop" : "One way"
    }
}

/// A route's line, scaled to fit a small dark tile with a faint street grid,
/// and a dot where it starts.
struct RouteThumbnail: View {
    let path: [RouteCoordinate]
    var size: CGFloat = 64

    var body: some View {
        Canvas { context, canvasSize in
            let grid = Color.white.opacity(0.06)
            for step in stride(from: 0, through: canvasSize.width, by: canvasSize.width / 4) {
                context.stroke(Path { $0.move(to: CGPoint(x: step, y: 0)); $0.addLine(to: CGPoint(x: step, y: canvasSize.height)) }, with: .color(grid), lineWidth: 1)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: step)); $0.addLine(to: CGPoint(x: canvasSize.width, y: step)) }, with: .color(grid), lineWidth: 1)
            }
            let points = Self.project(path, into: canvasSize.insetBy(10))
            guard let first = points.first else { return }
            context.stroke(Path { $0.addLines(points) }, with: .color(Phase.work.color),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)), with: .color(.white))
        }
        .frame(width: size, height: size)
        .background(Color(red: 0.11, green: 0.12, blue: 0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// Flat projection, north up, keeping the route's proportions, centred in
    /// `rect`. Fine at the scale of a run.
    private static func project(_ path: [RouteCoordinate], into rect: CGRect) -> [CGPoint] {
        guard let first = path.first else { return [] }
        let lonScale = cos(first.lat * .pi / 180)
        let xs = path.map { $0.lon * lonScale }
        let ys = path.map { -$0.lat }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let span = max(maxX - minX, maxY - minY, 1e-9)
        let scale = min(rect.width, rect.height) / span
        let offsetX = rect.minX + (rect.width - (maxX - minX) * scale) / 2
        let offsetY = rect.minY + (rect.height - (maxY - minY) * scale) / 2
        return zip(xs, ys).map { CGPoint(x: offsetX + ($0 - minX) * scale, y: offsetY + ($1 - minY) * scale) }
    }
}

private extension CGSize {
    func insetBy(_ inset: CGFloat) -> CGRect {
        CGRect(origin: .zero, size: self).insetBy(dx: inset, dy: inset)
    }
}

struct RouteFitBadge: View {
    let match: RouteFit.Match

    var body: some View {
        switch match {
        case .fits:
            Label("Good fit", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Phase.rest.color)
        case .short:
            Text("Shorter").font(.caption).foregroundStyle(.secondary)
        case .long:
            Text("Longer").font(.caption).foregroundStyle(.secondary)
        }
    }
}
