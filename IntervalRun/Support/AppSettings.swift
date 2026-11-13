import Foundation

/// How distance is tracked during a workout.
struct DistanceSettings: Equatable {
    var mode: DistanceMode
    /// Say "That was 0.21 miles" after each work interval.
    var announceDistance: Bool
    /// Say "8 minutes 15 per mile" after each work interval of 30 seconds or more.
    var announcePace: Bool
}

/// UserDefaults keys for the Settings screen. Read with `@AppStorage` in views.
enum AppSettings {
    static let beepVolumeKey = "beepVolume"
    static let vibrateOnCountdownKey = "vibrateOnCountdown"
    /// `CoachVoice`: who speaks the voice prompts.
    static let coachVoiceKey = "coachVoice"
    /// Read heart rate from Apple Health after runs.
    static let healthHeartRateKey = "healthHeartRate"
    static let voiceCountdownKey = "voiceCountdown"
    static let voiceHalfwayKey = "voiceHalfway"
    static let voiceIntervalsLeftKey = "voiceIntervalsLeft"
    static let voiceDistanceKey = "voiceDistance"
    static let voicePaceKey = "voicePace"
    static let trackDistanceKey = "trackDistance"
    static let distanceModeKey = "distanceMode"
    static let hasSeededSampleKey = "hasSeededSample"
    /// `PlayerMapMode`: how the live map behind the player looks, or off.
    static let playerMapModeKey = "playerMapMode"
    /// Whether plan sessions start with their warm-up and end with their cool-down.
    /// Toggled on the session screen and remembered for the next run.
    static let programWarmUpKey = "programWarmUp"
    static let programCoolDownKey = "programCoolDown"
    /// A morning notification with the day's plan run, or a rest-day nudge.
    static let dailyReminderKey = "dailyReminder"
    /// When it arrives, in minutes after midnight.
    static let dailyReminderMinuteKey = "dailyReminderMinute"

    static let defaultBeepVolume = 0.8
    /// 8:00 AM.
    static let defaultDailyReminderMinute = 8 * 60

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            beepVolumeKey: defaultBeepVolume,
            vibrateOnCountdownKey: false,
            coachVoiceKey: CoachVoice.default.rawValue,
            healthHeartRateKey: false,
            voiceCountdownKey: true,
            voiceHalfwayKey: true,
            voiceIntervalsLeftKey: true,
            voiceDistanceKey: true,
            voicePaceKey: true,
            trackDistanceKey: true,
            distanceModeKey: DistanceMode.automatic.rawValue,
            playerMapModeKey: PlayerMapMode.overview.rawValue,
            programWarmUpKey: true,
            programCoolDownKey: true,
            dailyReminderKey: true,
            dailyReminderMinuteKey: defaultDailyReminderMinute,
        ])
    }

    static var beepVolume: Double { UserDefaults.standard.double(forKey: beepVolumeKey) }
    static var vibrateOnCountdown: Bool { UserDefaults.standard.bool(forKey: vibrateOnCountdownKey) }

    static var healthHeartRate: Bool { UserDefaults.standard.bool(forKey: healthHeartRateKey) }

    static var coachVoice: CoachVoice {
        UserDefaults.standard.string(forKey: coachVoiceKey).flatMap(CoachVoice.init(rawValue:)) ?? .default
    }

    static var voiceOptions: VoiceOptions {
        let defaults = UserDefaults.standard
        return VoiceOptions(
            countdown: defaults.bool(forKey: voiceCountdownKey),
            halfway: defaults.bool(forKey: voiceHalfwayKey),
            intervalsLeft: defaults.bool(forKey: voiceIntervalsLeftKey)
        )
    }

    /// GPS or step counter only. Free runs use this even when distance tracking
    /// for interval workouts is turned off.
    static var distanceMode: DistanceMode {
        UserDefaults.standard.string(forKey: distanceModeKey).flatMap(DistanceMode.init(rawValue:)) ?? .automatic
    }

    /// Nil when distance tracking is turned off.
    static var distanceSettings: DistanceSettings? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: trackDistanceKey) else { return nil }
        return DistanceSettings(
            mode: distanceMode,
            announceDistance: defaults.bool(forKey: voiceDistanceKey),
            announcePace: defaults.bool(forKey: voicePaceKey)
        )
    }
}
