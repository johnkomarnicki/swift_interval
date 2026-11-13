import MapKit
import SwiftData
import SwiftUI

/// How a new route is started in the editor.
enum RouteEditorMode: String, CaseIterable, Identifiable {
    /// Pick a start and a distance, and the app makes the route.
    case create
    /// Tap the map point by point.
    case draw

    var id: Self { self }

    var title: String {
        switch self {
        case .create: "Create for me"
        case .draw: "Draw"
        }
    }

    var systemImage: String {
        switch self {
        case .create: "wand.and.stars"
        case .draw: "hand.point.up.left"
        }
    }
}

/// Make, draw or edit a route. "Create for me" builds routes of a chosen length
/// from a start point; "Draw" adds a point per tap, each stretch following
/// roads and paths. Changes are kept in a draft until Save.
struct RouteEditorView: View {
    /// The route being edited, or nil to create a new one.
    let route: RunRoute?
    /// The distance a plan session needs, shown as a guide and used as the
    /// starting distance for "Create for me".
    var targetMeters: Double?
    /// Called with the saved route.
    var onSave: ((RunRoute) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RouteEditorMode
    @State private var name: String
    @State private var builder: RouteBuilder
    @State private var position: MapCameraPosition

    // "Create for me"
    @State private var start: RouteCoordinate?
    @State private var miles: Double
    @State private var shape: RouteGenerator.Shape = .loop
    @State private var options: [RouteGenerator.Option] = []
    @State private var selectedOption: Int?
    @State private var isGenerating = false
    @State private var isLocating = false
    @State private var message: String?
    @AppStorage("autoRoutePrefersPaths") private var prefersPaths = true
    @Query private var savedRoutes: [RunRoute]

    private static let lastMilesKey = "autoRouteMiles"
    private static let milesRange = 0.5...26.2

    init(route: RunRoute?, mode: RouteEditorMode = .draw, targetMeters: Double? = nil, onSave: ((RunRoute) -> Void)? = nil) {
        self.route = route
        self.targetMeters = targetMeters
        self.onSave = onSave
        _mode = State(initialValue: route == nil ? mode : .draw)
        _name = State(initialValue: route?.name ?? "")
        _builder = State(initialValue: RouteBuilder(waypoints: route?.waypoints ?? [], legs: route?.legs ?? []))
        _position = State(initialValue: RouteMapView.overview(of: route?.path ?? []))
        let lastMiles = UserDefaults.standard.double(forKey: Self.lastMilesKey)
        let startMiles = targetMeters.map { ($0 / DistanceFormat.metersPerMile * 4).rounded() / 4 } ?? (lastMiles > 0 ? lastMiles : 2)
        _miles = State(initialValue: min(max(startMiles, Self.milesRange.lowerBound), Self.milesRange.upperBound))
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if mode == .create {
                        ForEach(options.filter { $0.id != selectedOption }) { option in
                            MapPolyline(coordinates: RoutePath.joined(option.legs).map(\.coordinate))
                                .stroke(.gray.opacity(0.6), lineWidth: 3)
                        }
                    }
                    RouteMapContent(path: builder.path)
                    if mode == .draw {
                        ForEach(Array(builder.waypoints.enumerated().dropFirst()), id: \.offset) { _, point in
                            Annotation("", coordinate: point.coordinate) {
                                RouteDot(color: .white)
                            }
                        }
                    } else if let start, builder.path.isEmpty {
                        Annotation("Start", coordinate: start.coordinate) {
                            RouteDot(color: Phase.rest.color, systemImage: "flag.fill")
                        }
                    }
                    UserAnnotation { _ in
                        UserLocationDot()
                    }
                }
                .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapCompass()
                }
                .onTapGesture { location in
                    guard let coordinate = proxy.convert(location, from: .local) else { return }
                    tapped(RouteCoordinate(coordinate))
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation { position = .userLocation(fallback: position) }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Phase.work.color)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show my location")
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { panel }
            .navigationTitle(route == nil ? "New route" : "Edit route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!builder.canSave || builder.pendingLegs > 0 || isGenerating)
                }
            }
            .task {
                DistancePermissions.requestIfNeeded(mode: .automatic)
                if mode == .create, start == nil, builder.waypoints.isEmpty {
                    await useCurrentLocation()
                }
            }
        }
    }

    // MARK: Panel

    /// A sheet over the bottom of the map: mode, that mode's controls, the
    /// route's name.
    private var panel: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)

            if route == nil {
                PillPicker(options: RouteEditorMode.allCases, title: \.title, selection: $mode, trackColor: fieldColor)
                    .onChange(of: mode) { _, newMode in switched(to: newMode) }
            }

            switch mode {
            case .create: createControls
            case .draw: drawControls
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Route name (e.g. River loop)", text: $name)
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(fieldColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if route == nil, !savedRoutes.isEmpty {
                    Text(savedRoutes.count == 1 ? "1 saved route" : "\(savedRoutes.count) saved routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.25), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Fields and buttons on the panel, a step lighter than it.
    private var fieldColor: Color { .primary.opacity(0.07) }

    private var createControls: some View {
        VStack(spacing: 14) {
            HStack {
                Label(startText, systemImage: "flag.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isLocating {
                    ProgressView()
                } else {
                    Button("My location", systemImage: "location.fill") {
                        Task { await useCurrentLocation() }
                    }
                    .font(.subheadline)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Start at my location")
                }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    bigDistance(miles)
                    if let targetMeters {
                        Text("This session needs about \(DistanceFormat.short(targetMeters))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                StepperCapsule(
                    value: "",
                    spokenValue: String(format: "%.2f miles", miles),
                    accessibilityLabel: "Distance",
                    canDecrement: miles > Self.milesRange.lowerBound,
                    canIncrement: miles < Self.milesRange.upperBound,
                    onDecrement: { miles = max(miles - 0.25, Self.milesRange.lowerBound) },
                    onIncrement: { miles = min(miles + 0.25, Self.milesRange.upperBound) }
                )
            }
            .onChange(of: miles) { _, _ in clearOptions() }

            PillPicker(options: RouteGenerator.Shape.allCases, title: \.title, selection: $shape, trackColor: fieldColor)
                .onChange(of: shape) { _, _ in clearOptions() }

            Toggle(isOn: $prefersPaths) {
                Label("Prefer parks & trails", systemImage: "tree")
                    .font(.subheadline)
            }
            .tint(Phase.work.color)
            .onChange(of: prefersPaths) { _, _ in clearOptions() }

            Button {
                Task { await generate() }
            } label: {
                HStack(spacing: 8) {
                    if isGenerating { ProgressView().tint(.white) }
                    Text(options.isEmpty ? "Create routes" : "Try different routes")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(start == nil || isGenerating)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(options) { option in
                            optionChip(option)
                        }
                    }
                }
            }
        }
    }

    private func optionChip(_ option: RouteGenerator.Option) -> some View {
        let isSelected = option.id == selectedOption
        return Button {
            select(option)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(DistanceFormat.short(option.meters))
                    .font(.headline.monospacedDigit())
                Text(option.via.isEmpty
                     ? "Heads \(RouteGenerator.compassName(option.bearing))"
                     : "Via \(option.via.joined(separator: ", "))")
                    .lineLimit(1)
                    .font(.caption)
                    .opacity(0.8)
            }
            .frame(maxWidth: 190, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Phase.work.color : fieldColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var drawControls: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    bigDistance(DistanceFormat.miles(builder.meters))
                    Text(guideText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if builder.pendingLegs > 0 {
                    ProgressView()
                }
                Toggle("Follow roads", isOn: $builder.followsRoads)
                    .fixedSize()
                    .font(.subheadline)
                    .tint(Phase.work.color)
            }

            HStack(spacing: 8) {
                panelButton("Undo", systemImage: "arrow.uturn.backward") { builder.undo() }
                    .disabled(builder.waypoints.isEmpty)
                panelButton("To start", systemImage: "point.forward.to.point.capsulepath") {
                    Task { await builder.backToStart() }
                }
                .disabled(builder.waypoints.count < 2 || builder.isLoop)
                panelButton("Out & back", systemImage: "arrow.left.arrow.right") { builder.outAndBack() }
                    .disabled(builder.waypoints.count < 2 || builder.isLoop)
                panelButton("Clear", systemImage: "trash") { builder.clear() }
                    .disabled(builder.waypoints.isEmpty)
            }
        }
    }

    /// "2.27 mi", the number large.
    private func bigDistance(_ miles: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(format: "%.2f", miles))
                .font(.system(size: 44, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            Text("mi")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var startText: String {
        if isLocating { return "Finding your location…" }
        return start == nil ? "Tap the map to set your start" : "Start set. Tap the map to move it"
    }

    private var guideText: String {
        if builder.waypoints.isEmpty { return "Tap the map where you'll start" }
        if builder.waypoints.count == 1 { return "Tap to add the next point" }
        if let targetMeters {
            return "This session needs about \(DistanceFormat.short(targetMeters))"
        }
        return builder.isLoop ? "Loop" : "Tap to keep going"
    }

    private func panelButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        PanelButton(title: title, systemImage: systemImage, action: action)
    }

    // MARK: Actions

    private func tapped(_ point: RouteCoordinate) {
        switch mode {
        case .draw:
            Task { await builder.add(point) }
        case .create:
            guard !isGenerating else { return }
            start = point
            clearOptions()
        }
    }

    /// Carries the route across: a made route can be fine-tuned by hand, and a
    /// drawn route's start becomes the start for making one. A drawn route stays
    /// on the map until new routes are made or the start is moved.
    private func switched(to newMode: RouteEditorMode) {
        if newMode == .create {
            start = builder.waypoints.first ?? start
            options = []
            selectedOption = nil
        }
        message = nil
    }

    private func clearOptions() {
        options = []
        selectedOption = nil
        message = nil
        builder.clear()
    }

    private func useCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        guard let here = await CurrentLocation.fetch() else {
            message = "Couldn't find your location. Tap the map to set your start."
            return
        }
        start = here
        clearOptions()
        position = .region(MKCoordinateRegion(
            center: here.coordinate,
            latitudinalMeters: max(1500, miles * DistanceFormat.metersPerMile * 0.6),
            longitudinalMeters: max(1500, miles * DistanceFormat.metersPerMile * 0.6)
        ))
    }

    private func generate() async {
        guard let start else { return }
        UserDefaults.standard.set(miles, forKey: Self.lastMilesKey)
        isGenerating = true
        message = nil
        defer { isGenerating = false }
        let found = await RouteGenerator().options(
            from: start,
            meters: miles * DistanceFormat.metersPerMile,
            shape: shape,
            bearingOffset: options.isEmpty ? 0 : Double.random(in: 20..<100),
            prefersPaths: prefersPaths
        )
        options = found
        guard let best = found.first else {
            builder.clear()
            message = "Couldn't find walking paths from here. Check your connection, or try another start or a shorter distance."
            return
        }
        select(best)
        if prefersPaths, found.allSatisfy(\.via.isEmpty) {
            message = "No parks or trails close enough for this distance, so these routes use streets."
        }
        withAnimation {
            position = RouteMapView.overview(of: found.flatMap { RoutePath.joined($0.legs) })
        }
    }

    private func select(_ option: RouteGenerator.Option) {
        selectedOption = option.id
        builder.replace(waypoints: option.waypoints, legs: option.legs)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = mode == .create ? options.first { $0.id == selectedOption } : nil
        let finalName: String
        if !trimmed.isEmpty {
            finalName = trimmed
        } else if let made, let park = made.via.first {
            finalName = "\(park) \(shape.title.lowercased())"
        } else {
            finalName = "\(DistanceFormat.short(builder.meters)) \(made == nil ? "route" : shape.title.lowercased())"
        }
        let saved: RunRoute
        if let route {
            route.name = finalName
            route.waypoints = builder.waypoints
            route.legs = builder.legs
            route.markChanged()
            saved = route
        } else {
            saved = RunRoute(name: finalName, waypoints: builder.waypoints, legs: builder.legs)
            modelContext.insert(saved)
        }
        SyncService.shared.scheduleSync()
        onSave?(saved)
        dismiss()
    }
}

/// An icon over a short label on a rounded tile, for the draw tools.
private struct PanelButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Phase.work.color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The runner's position: a work-colored dot in a white ring, with a soft halo.
private struct UserLocationDot: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Phase.work.color.opacity(0.25))
                .frame(width: 44, height: 44)
            Circle()
                .fill(Phase.work.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 3)
        }
        .accessibilityLabel("You")
    }
}
