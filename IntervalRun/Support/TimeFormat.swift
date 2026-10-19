import Foundation

enum TimeFormat {
    /// "m:ss" for under an hour, "h:mm:ss" otherwise.
    static func clock(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        let seconds = s % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formats a countdown value, rounding up so the display reads 0:01 during the
    /// final second and switches to the next interval exactly at zero.
    static func countdown(_ interval: TimeInterval) -> String {
        clock(wholeSecondsRoundingUp(interval))
    }

    static func wholeSecondsRoundingUp(_ interval: TimeInterval) -> Int {
        // The small tolerance absorbs floating-point noise from clock subtraction.
        Int((max(0, interval) - 1e-6).rounded(.up))
    }
}
