import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// The nonce for one Sign in with Apple attempt. Apple gets its SHA-256 hash and
/// puts it in the identity token; Supabase gets the raw value and checks that
/// they match, so a stolen token can't be replayed.
struct AppleSignInNonce {
    let raw: String

    init() {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        raw = String((0..<32).map { _ in characters.randomElement(using: &generator)! })
    }

    var sha256: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum AppleSignInError: LocalizedError {
    case missingToken

    var errorDescription: String? {
        "Apple didn't return a sign-in token. Try again."
    }
}

/// Shows the Sign in with Apple sheet again to get a fresh authorization code.
/// Deleting an Apple account sends it to the server, which uses it to revoke
/// the app's Apple tokens (Apple requires this when an account is deleted).
@MainActor
final class AppleReauthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    /// Throws `ASAuthorizationError.canceled` if the sheet is closed.
    func authorizationCode() async throws -> String {
        let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()])
        controller.delegate = self
        controller.presentationContextProvider = self
        let authorization = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.authorizationCode,
              let code = String(data: data, encoding: .utf8) else {
            throw AppleSignInError.missingToken
        }
        return code
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

extension ASAuthorization {
    /// The identity token from a successful Sign in with Apple, as a string.
    func appleIdentityToken() throws -> String {
        guard let credential = credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            throw AppleSignInError.missingToken
        }
        return token
    }
}
