import Foundation
import Observation
import Supabase

/// The signed-in user's onboarding answers (from `profiles`), cached on the
/// phone so the app opens straight to the main screens when offline.
@MainActor
@Observable
final class ProfileStore {
    private(set) var answers: OnboardingAnswers?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// The signed-in account no longer exists on the server (e.g. it was deleted).
    private(set) var accountMissing = false

    @ObservationIgnored private var userID: UUID?

    private struct ProfileRow: Codable {
        var onboarding: OnboardingAnswers?
    }

    private struct ProfileUpdate: Encodable {
        var onboarding: OnboardingAnswers
        var onboardingCompletedAt: Date

        enum CodingKeys: String, CodingKey {
            case onboarding
            case onboardingCompletedAt = "onboarding_completed_at"
        }
    }

    func load(userID: UUID) async {
        self.userID = userID
        loadError = nil
        if let cached = cachedAnswers(userID) {
            answers = cached
            isLoaded = true
        }
        do {
            let rows: [ProfileRow] = try await supabase.from("profiles")
                .select("onboarding")
                .eq("id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value
            // Every account gets a profile at sign-up, so none means the account is gone.
            guard let row = rows.first else {
                accountMissing = true
                return
            }
            answers = row.onboarding
            cache(row.onboarding, userID)
            isLoaded = true
        } catch {
            // Offline with cached answers is fine; otherwise offer a retry.
            if !isLoaded { loadError = friendlyMessage(for: error) }
        }
    }

    func save(_ newAnswers: OnboardingAnswers) async throws {
        guard let userID else { return }
        try await supabase.from("profiles")
            .update(ProfileUpdate(onboarding: newAnswers, onboardingCompletedAt: .now), returning: .minimal)
            .eq("id", value: userID.uuidString)
            .execute()
        answers = newAnswers
        cache(newAnswers, userID)
    }

    func reset() {
        answers = nil
        isLoaded = false
        loadError = nil
        accountMissing = false
        userID = nil
    }

    private static func cacheKey(_ userID: UUID) -> String { "onboarding-\(userID.uuidString)" }

    /// Removes the cached answers, e.g. after the account is deleted.
    static func clearCache(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: cacheKey(userID))
    }

    private func cachedAnswers(_ userID: UUID) -> OnboardingAnswers? {
        UserDefaults.standard.data(forKey: Self.cacheKey(userID))
            .flatMap { try? JSONDecoder().decode(OnboardingAnswers.self, from: $0) }
    }

    private func cache(_ answers: OnboardingAnswers?, _ userID: UUID) {
        if let answers, let data = try? JSONEncoder().encode(answers) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey(userID))
        } else {
            Self.clearCache(userID: userID)
        }
    }
}
