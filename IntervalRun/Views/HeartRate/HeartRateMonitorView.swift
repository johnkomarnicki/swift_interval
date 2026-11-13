import SwiftUI
import UIKit

/// Settings → Heart rate monitor: finds Bluetooth heart rate monitors nearby
/// and remembers the one picked.
struct HeartRateMonitorView: View {
    private let monitor = HeartRateMonitor.shared

    var body: some View {
        Form {
            if monitor.isPaired {
                Section("Your monitor") {
                    LabeledContent(monitor.pairedName ?? "Heart rate monitor") {
                        Text(statusText)
                            .monospacedDigit()
                    }
                    Button("Forget This Monitor", role: .destructive) {
                        monitor.forget()
                        monitor.startSearching()
                    }
                }
            }

            if monitor.status == .notAllowed {
                Section {
                    Text("Runwise isn't allowed to use Bluetooth.")
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open iPhone Settings", destination: url)
                    }
                }
            } else if monitor.status == .bluetoothOff {
                Section {
                    Text("Turn on Bluetooth in Control Center to find your monitor.")
                }
            } else {
                Section {
                    ForEach(monitor.found) { found in
                        Button {
                            monitor.pair(found)
                        } label: {
                            Label(found.name, systemImage: "heart.circle")
                        }
                    }
                    if monitor.found.isEmpty {
                        Text("Looking for monitors…")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(monitor.isPaired ? "Switch to another monitor" : "Monitors nearby")
                        if monitor.isSearching { ProgressView().controlSize(.mini) }
                    }
                } footer: {
                    Text("Put on your strap or armband so it wakes up. On a Garmin watch, turn on Broadcast Heart Rate: hold MENU, then choose Sensors & Accessories → Wrist Heart Rate. To broadcast while the watch records a run too, turn on Broadcast Heart Rate in that activity's settings: hold MENU, then choose Activities & Apps → Run → Run Settings. An Apple Watch can't connect here; turn on Apple Health in Settings instead.")
                }
            }
        }
        .navigationTitle("Heart Rate Monitor")
        .clearsTabBar()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            monitor.acquire()
            monitor.startSearching()
        }
        .onDisappear {
            monitor.stopSearching()
            monitor.release()
        }
    }

    private var statusText: String {
        switch monitor.status {
        case .connected: monitor.bpm.map { "\($0) bpm" } ?? "Waiting for heart rate…"
        case .connecting: "Looking for it…"
        case .noHeartRate: "Not sending heart rate"
        case .idle, .notPaired: ""
        case .bluetoothOff: "Bluetooth is off"
        case .notAllowed: "Bluetooth not allowed"
        case .unavailable: "No Bluetooth"
        }
    }
}
