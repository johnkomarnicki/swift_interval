import AuthenticationServices
import SwiftUI

/// Email + 6-digit code sign-in (and Google, once it's set up).
struct SignInView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var code = ""
    @State private var codeSentTo: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var appleNonce = AppleSignInNonce()
    @FocusState private var focused: Field?

    private enum Field { case email, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                if let codeSentTo {
                    codeStep(codeSentTo)
                } else {
                    emailStep
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                    .font(.footnote)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Phase.work.color)
                .padding(.top, 40)
            Text("Runwise")
                .font(.largeTitle.bold())
            Text("Sign in to get a training plan built for you, and keep your runs backed up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var emailStep: some View {
        VStack(spacing: 14) {
            if SupabaseConfig.appleSignInEnabled {
                SignInWithAppleButton(.signIn) { request in
                    appleNonce = AppleSignInNonce()
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = appleNonce.sha256
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        let rawNonce = appleNonce.raw
                        run {
                            try await auth.signInWithApple(idToken: try authorization.appleIdentityToken(), rawNonce: rawNonce)
                        }
                    case .failure(let error):
                        // Closing the sheet isn't an error worth showing.
                        if (error as? ASAuthorizationError)?.code != .canceled {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isWorking)

                Text("or use your email").font(.subheadline).foregroundStyle(.secondary)
            }

            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .submitLabel(.continue)
                .onSubmit(sendCode)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            primaryButton("Email me a code", action: sendCode)
                .disabled(!isValidEmail)

            if SupabaseConfig.googleSignInEnabled {
                Text("or").foregroundStyle(.secondary)
                Button(action: signInWithGoogle) {
                    Label("Continue with Google", systemImage: "g.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
    }

    private func codeStep(_ address: String) -> some View {
        VStack(spacing: 14) {
            Text("We emailed a 6-digit code to **\(address)**.")
                .multilineTextAlignment(.center)
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focused, equals: .code)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { code = digits }
                    if digits.count == 6 { verify() }
                }

            primaryButton("Sign in", action: verify)
                .disabled(code.count != 6)

            HStack {
                Button("Use a different email") {
                    codeSentTo = nil
                    code = ""
                    errorMessage = nil
                }
                Spacer()
                Button("Resend code", action: sendCode)
            }
            .font(.callout)
            .disabled(isWorking)
        }
        .onAppear { focused = .code }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().tint(.white) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(Phase.work.color)
        .disabled(isWorking)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isValidEmail: Bool {
        let parts = trimmedEmail.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    private func sendCode() {
        guard isValidEmail, !isWorking else { return }
        run {
            try await auth.sendCode(to: trimmedEmail)
            codeSentTo = trimmedEmail
            code = ""
        }
    }

    private func verify() {
        guard let codeSentTo, code.count == 6, !isWorking else { return }
        run { try await auth.verify(email: codeSentTo, code: code) }
    }

    private func signInWithGoogle() {
        run { try await auth.signInWithGoogle() }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await work()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
            isWorking = false
        }
    }
}
