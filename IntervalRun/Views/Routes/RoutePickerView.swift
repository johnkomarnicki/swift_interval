import SwiftData
import SwiftUI

/// Pick a saved route (or draw a new one). With a target distance, routes that
/// fit it come first.
struct RoutePickerView: View {
    var targetMeters: Double?
    var selectedID: UUID?
    let onPick: (RunRoute?) -> Void
    /// When set, the picker is shown before a run starts and offers to start
    /// without a route.
    var onSkip: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RunRoute.createdAt, order: .reverse) private var routes: [RunRoute]
    @State private var newRouteMode: RouteEditorMode?
    @State private var newRoute: RunRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if onSkip != nil || targetMeters != nil {
                        Text(introText)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    NewRouteTiles(onCreate: { newRouteMode = .create }, onDraw: { newRouteMode = .draw })

                    if !routes.isEmpty {
                        CardSection(title: "Saved routes", detail: "\(routes.count)", footer: "Choose one to follow its map while you run.") {
                            ForEach(sortedRoutes) { route in
                                if route != sortedRoutes.first {
                                    Divider().padding(.leading, 92)
                                }
                                Button {
                                    pick(route)
                                } label: {
                                    RouteRow(route: route, targetMeters: targetMeters,
                                             isSelected: route.syncID != nil && route.syncID == selectedID)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let onSkip {
                        Button {
                            onSkip()
                            dismiss()
                        } label: {
                            Label("Start without a route", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else if selectedID != nil {
                        Button("No route", role: .destructive) { pick(nil) }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Choose a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $newRouteMode, onDismiss: {
                // Pick a just-made route once its editor has closed.
                if let newRoute { pick(newRoute) }
            }) { mode in
                RouteEditorView(route: nil, mode: mode, targetMeters: targetMeters) { route in
                    newRoute = route
                }
            }
        }
    }

    private var introText: String {
        let need = targetMeters.map { "This session needs about \(DistanceFormat.short($0))." }
        guard onSkip != nil else { return need ?? "" }
        return ["Where are you running today?", need].compactMap { $0 }.joined(separator: " ")
    }

    /// Closest to the target first; otherwise newest first.
    private var sortedRoutes: [RunRoute] {
        guard let targetMeters else { return routes }
        return routes.sorted { abs($0.meters - targetMeters) < abs($1.meters - targetMeters) }
    }

    private func pick(_ route: RunRoute?) {
        onPick(route)
        dismiss()
    }
}
