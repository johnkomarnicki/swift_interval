import Foundation

enum DistanceFormat {
    static let metersPerMile = 1609.344

    static func miles(_ meters: Double) -> Double {
        meters / metersPerMile
    }

    /// "0.21 mi"
    static func short(_ meters: Double) -> String {
        String(format: "%.2f mi", miles(meters))
    }

    /// "8:15 /mi", or "–:–– /mi" when there's too little distance to tell.
    static func pace(seconds: TimeInterval, meters: Double) -> String {
        guard let secondsPerMile = secondsPerMile(seconds: seconds, meters: meters) else { return "–:–– /mi" }
        return "\(TimeFormat.clock(secondsPerMile)) /mi"
    }

    /// Pace in whole seconds per mile, or nil when there's too little distance to tell.
    static func secondsPerMile(seconds: TimeInterval, meters: Double) -> Int? {
        let distance = miles(meters)
        guard distance >= 0.01, seconds > 0 else { return nil }
        let secondsPerMile = seconds / distance
        guard secondsPerMile < 100 * 60 else { return nil }
        return Int(secondsPerMile.rounded())
    }

    /// For speech: "8 minutes 15 per mile", "8 minutes per mile". Spelled out
    /// because the voice reads "8:15" as a time of day.
    static func spokenPace(secondsPerMile: Int) -> String {
        let minutes = secondsPerMile / 60
        let seconds = secondsPerMile % 60
        let minutesText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return seconds == 0 ? "\(minutesText) per mile" : "\(minutesText) \(seconds) per mile"
    }

    /// Distance in hundredths of a mile, as used for spoken prompts.
    static func hundredthsOfMile(_ meters: Double) -> Int {
        Int((miles(meters) * 100).rounded())
    }

    /// For speech: "0.21 miles", "0.2 miles", "1 mile", "1.5 miles".
    static func spoken(hundredths: Int) -> String {
        var number = String(format: "%.2f", Double(max(0, hundredths)) / 100)
        while number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return number == "1" ? "1 mile" : "\(number) miles"
    }
}
