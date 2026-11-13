import Foundation

/// Web pages the app links to. They're the files in `docs/`, served by GitHub
/// Pages; the same URLs go in App Store Connect.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://johnkomarnicki.github.io/swift_interval/privacy.html")!
    static let support = URL(string: "https://johnkomarnicki.github.io/swift_interval/support.html")!

    /// e.g. "1.0 (3)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
