import Foundation
import Supabase

enum SupabaseConfig {
    static let url = URL(string: "https://zzybkcggdaafccuiaqfl.supabase.co")!
    /// The publishable key is meant to ship in apps; row level security protects the data.
    static let publishableKey = "sb_publishable_h2RkYj8-euRUUewgzHFZQQ_wL_T_xww"
    /// Where Google sign-in returns to (the app's URL scheme, registered in Info.plist
    /// and in the Supabase auth settings).
    static let redirectURL = URL(string: "intervalrun://login-callback")!
    /// Flip on once the Google provider is configured in Supabase.
    static let googleSignInEnabled = false
    /// Needs the paid Apple Developer Program team selected for signing.
    static let appleSignInEnabled = true
}

/// The app's one Supabase client.
let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.publishableKey,
    options: SupabaseClientOptions(
        auth: .init(
            redirectToURL: SupabaseConfig.redirectURL,
            flowType: .pkce,
            // Show the saved session straight away (even offline); it refreshes in the background.
            emitLocalSessionAsInitialSession: true
        )
    )
)
