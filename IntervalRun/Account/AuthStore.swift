import Foundation
import Observation
import Supabase

/// Who's signed in, and the sign-in / sign-out actions.
@MainActor
@Observable
final class AuthStore {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userID: UUID, email: String?)
    }

    private(set) var state: State = .loading
    @ObservationIgnored private var listener: Task<Void, Never>?

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    var email: String? {
        if case .signedIn(_, let email) = state { return email }
        return nil
    }

    /// Starts following Supabase's auth events (initial session, sign-in, sign-out).
    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await (event, session) in supabase.auth.authStateChanges {
                self?.apply(event, session)
            }
        }
    }

    private func apply(_ event: AuthChangeEvent, _ session: Session?) {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
            if let session {
                state = .signedIn(userID: session.user.id, email: session.user.email)
            } else {
                state = .signedOut
            }
        case .signedOut, .userDeleted:
            state = .signedOut
        case .passwordRecovery:
            break
        }
    }

    // MARK: Actions

    /// Emails a 6-digit sign-in code. New emails get an account automatically.
    func sendCode(to email: String) async throws {
        try await supabase.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    func verify(email: String, code: String) async throws {
        try await supabase.auth.verifyOTP(email: email, token: code, type: .email)
    }

    /// Exchanges the identity token from the Sign in with Apple sheet for a
    /// Supabase session. `rawNonce` is the value whose SHA-256 went to Apple.
    func signInWithApple(idToken: String, rawNonce: String) async throws {
        try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
    }

    func signInWithGoogle() async throws {
        try await supabase.auth.signInWithOAuth(provider: .google, redirectTo: SupabaseConfig.redirectURL)
    }

    /// Uploads anything not yet synced, then signs out and clears the phone.
    func signOut() async {
        await SyncService.shared.syncNow()
        try? await supabase.auth.signOut()
        SyncService.shared.wipeLocalData()
        ProgramStore.clearCache()
        state = .signedOut
    }

    /// Whether the account signs in with Apple, so deleting it also has to
    /// revoke Apple's tokens.
    var usesAppleSignIn: Bool {
        supabase.auth.currentUser?.identities?.contains { $0.provider == "apple" } ?? false
    }

    private struct DeleteAccountRequest: Encodable {
        var appleAuthorizationCode: String?

        enum CodingKeys: String, CodingKey {
            case appleAuthorizationCode = "apple_authorization_code"
        }
    }

    /// Permanently deletes the account and everything stored in it, then clears
    /// the phone. Unsynced changes are thrown away, not uploaded.
    /// `appleAuthorizationCode` comes from `AppleReauthorization`, for Apple accounts.
    func deleteAccount(appleAuthorizationCode: String?) async throws {
        try await supabase.functions.invoke(
            "delete-account",
            options: FunctionInvokeOptions(body: DeleteAccountRequest(appleAuthorizationCode: appleAuthorizationCode))
        )
        if let userID { ProfileStore.clearCache(userID: userID) }
        // The account is gone on the server, so only the local session is left to remove.
        try? await supabase.auth.signOut(scope: .local)
        SyncService.shared.wipeLocalData()
        ProgramStore.clearCache()
        state = .signedOut
    }
}

/// Turns Supabase errors into short, friendly messages.
func friendlyMessage(for error: Error) -> String {
    if let authError = error as? AuthError {
        switch authError.errorCode {
        case .otpExpired: return "That code has expired or isn't right. Request a new one."
        case .overEmailSendRateLimit, .overRequestRateLimit: return "Too many attempts. Wait a minute and try again."
        case .validationFailed: return "That email address doesn't look right."
        case .emailAddressNotAuthorized: return "Sign-in emails can't be sent to that address yet."
        case .providerDisabled: return "That sign-in option isn't set up yet."
        default: return authError.message
        }
    }
    if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
        return "You're offline. Connect to the internet and try again."
    }
    return error.localizedDescription
}
