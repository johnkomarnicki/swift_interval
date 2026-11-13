// Permanently deletes the signed-in user's account (App Store guideline 5.1.1(v)).
//
// Deleting the auth user cascades to every table (profiles, programs, workouts,
// workout_records, routes all reference auth.users with `on delete cascade`).
//
// For Sign in with Apple accounts, the app first asks Apple for a fresh
// authorization code and sends it here; we swap it for a refresh token and
// revoke it, as Apple requires. That step needs three Supabase secrets from a
// "Sign in with Apple" key in the Apple Developer portal:
//   APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY (the .p8 file's contents)
// Without them the account is still deleted; the revoke is skipped and logged.

import { createClient } from "npm:@supabase/supabase-js@2.118.0";

/** The app's bundle ID, which is the Sign in with Apple client ID. */
const APPLE_CLIENT_ID = "com.johnkomarnicki.IntervalRun";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Not signed in" }, 401);

  const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: userData, error: userError } = await asUser.auth.getUser();
  if (userError || !userData.user) return json({ error: "Not signed in" }, 401);
  const userId = userData.user.id;

  let body: { apple_authorization_code?: string } = {};
  try {
    body = await req.json();
  } catch {
    // An empty body is fine.
  }

  if (body.apple_authorization_code) {
    try {
      await revokeAppleToken(body.apple_authorization_code);
    } catch (error) {
      // Don't keep the account just because Apple's side failed.
      console.error("delete-account: Apple token revoke failed", error);
    }
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) {
    console.error("delete-account: deleteUser failed", error);
    return json({ error: "Couldn't delete your account. Try again." }, 500);
  }
  return json({ deleted: true });
});

// ---------------------------------------------------------------------------
// Sign in with Apple token revocation
// https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens
// ---------------------------------------------------------------------------

async function revokeAppleToken(authorizationCode: string) {
  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const privateKey = Deno.env.get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !privateKey) {
    console.warn("delete-account: Apple secrets not set, skipping token revoke");
    return;
  }
  const clientSecret = await appleClientSecret(teamId, keyId, privateKey);

  const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: APPLE_CLIENT_ID,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenResponse.ok) throw new Error(`Apple token exchange: ${tokenResponse.status} ${await tokenResponse.text()}`);
  const tokens = (await tokenResponse.json()) as { refresh_token?: string; access_token?: string };
  const token = tokens.refresh_token ?? tokens.access_token;
  if (!token) throw new Error("Apple token exchange returned no token");

  const revokeResponse = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: APPLE_CLIENT_ID,
      client_secret: clientSecret,
      token,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    }),
  });
  if (!revokeResponse.ok) throw new Error(`Apple revoke: ${revokeResponse.status} ${await revokeResponse.text()}`);
}

/** The ES256-signed JWT Apple accepts as a client secret. */
async function appleClientSecret(teamId: string, keyId: string, pem: string) {
  const der = base64ToBytes(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const payload = base64url(
    JSON.stringify({ iss: teamId, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: APPLE_CLIENT_ID }),
  );
  // Web Crypto returns the raw r||s signature, which is what JWS ES256 expects.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${payload}`),
  );
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function base64ToBytes(base64: string) {
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function base64url(input: string | Uint8Array) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
