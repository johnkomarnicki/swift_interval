import Foundation

/// UserDefaults keys for the Settings screen. Read with `@AppStorage` in views.
enum AppSettings {
    static let beepVolumeKey = "beepVolume"
    static let vibrateOnCountdownKey = "vibrateOnCountdown"
    static let hasSeededSampleKey = "hasSeededSample"

    static let defaultBeepVolume = 0.8

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            beepVolumeKey: defaultBeepVolume,
            vibrateOnCountdownKey: false,
        ])
    }

    static var beepVolume: Double { UserDefaults.standard.double(forKey: beepVolumeKey) }
    static var vibrateOnCountdown: Bool { UserDefaults.standard.bool(forKey: vibrateOnCountdownKey) }
}
