import SwiftData
import SwiftUI

/// Free Run tab: pick run or walk and go, with distance tracked the whole way.
/// Each card shows the last one done; a route to follow is optional.
struct FreeRunView: View {
    @State private var session: FreeRunSession?
    @State private var routeID: UUID?
    @State private var choosingRoute = false
    @Query(sort: \RunRoute.createdAt, order: .reverse) private var routes: [RunRoute]
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var records: [WorkoutRecord]

    /// Looked up each time, so a route deleted elsewhere just drops off.
    private var route: RunRoute? {
        routeID.flatMap { id in routes.first { $0.syncID == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle(
                        eyebrow: TodayEyebrow.text,
                        title: "Free Run",
                        subtitle: "No intervals, just time, distance and pace. Pause any time and tap Finish when you're done."
                    )
                    .padding(.top, 16)

                    VStack(spacing: 14) {
                        ForEach(FreeActivity.allCases) { activity in
                            activityCard(activity)
                        }
                    }
                    .padding(.top, 24)

                    CardSection(title: "Route", detail: "Optional", footer: routeFooter) {
                        routeChips
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .clearsTabBar()
            .toolbar(.hidden, for: .navigationBar)
            .task {
                // Ask for location/motion access now rather than mid-run.
                DistancePermissions.requestIfNeeded(mode: AppSettings.distanceMode)
            }
            .sheet(isPresented: $choosingRoute) {
                RoutePickerView(selectedID: route?.syncID) { picked in
                    routeID = picked?.syncID
                }
            }
            .fullScreenCover(item: $session) { session in
                FreeRunPlayerView(session: session) {
                    self.session = nil
                }
            }
        }
    }

    // MARK: Activities

    private func activityCard(_ activity: FreeActivity) -> some View {
        let last = lastRecord(for: activity)
        return Button {
            session = FreeRunSession(activity: activity, route: route?.snapshot)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: activity.systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title)
                            .font(.system(size: 30, weight: .bold))
                        Text("Start a \(activity.title.lowercased())")
                            .font(.subheadline)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(activity.color)
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }

                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(height: 1)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                HStack {
                    Text(last.map { "Last \(activity.title.lowercased()) · \($0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" }
                         ?? "No \(activity.title.lowercased())s yet")
                        .opacity(0.85)
                    Spacer()
                    if let last {
                        Text(summary(of: last))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
            }
            .foregroundStyle(.white)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(activity.color)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: activity.systemImage)
                            .font(.system(size: 130, weight: .bold))
                            .foregroundStyle(.black.opacity(0.12))
                            .offset(x: 6, y: 34)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: activity.color.opacity(0.35), radius: 20, y: 10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a \(activity.title.lowercased())")
    }

    /// Walks are free walks; everything else, interval workouts included, counts as a run.
    private func lastRecord(for activity: FreeActivity) -> WorkoutRecord? {
        records.first { ($0.freeActivity == .walk) == (activity == .walk) }
    }

    /// "2.10 mi · 26:30", or just the time without a distance.
    private func summary(of record: WorkoutRecord) -> String {
        let time = TimeFormat.clock(Int(record.displayTime.rounded()))
        guard let meters = record.totalMeters else { return time }
        return "\(DistanceFormat.short(meters)) · \(time)"
    }

    // MARK: Route

    private var routeFooter: String {
        if let route {
            return "Follow \(route.displayName) on the map. Your path is recorded as you move."
        }
        return "Go wherever you like. Your path is recorded as you move."
    }

    /// No route, each saved route, and a way to make a new one.
    private var routeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("No route", isSelected: route == nil) { routeID = nil }
                ForEach(routes) { saved in
                    chip(saved.displayName, detail: String(format: "%.1f", DistanceFormat.miles(saved.meters)),
                         isSelected: saved.syncID != nil && saved.syncID == route?.syncID) {
                        routeID = saved.syncID
                    }
                }
                Button {
                    choosingRoute = true
                } label: {
                    Label("New route", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Phase.work.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    private func chip(_ title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let detail {
                    Text(detail).opacity(0.6)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(detail.map { "\(title), \($0) miles" } ?? title)
    }
}
