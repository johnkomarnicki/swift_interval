// Makes the client secret Supabase needs for Sign in with Apple on the web (the
// MCP consent page). Apple caps it at 6 months, so rerun this before it expires.
//
//   node scripts/apple-client-secret.mjs <path/to/AuthKey_XXXXXXXXXX.p8> <KEY_ID> <TEAM_ID> [SERVICES_ID]
//
// Prints the secret and when it expires. Set it as SUPABASE_AUTH_EXTERNAL_APPLE_SECRET
// before `supabase config push`, or paste it into Dashboard → Authentication →
// Sign In / Providers → Apple → Secret Key.

import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";

const [keyPath, keyId, teamId, servicesId = "com.johnkomarnicki.IntervalRun.web"] = process.argv.slice(2);
if (!keyPath || !keyId || !teamId) {
  console.error("Usage: node scripts/apple-client-secret.mjs <AuthKey.p8> <KEY_ID> <TEAM_ID> [SERVICES_ID]");
  process.exit(1);
}

const SIX_MONTHS = 180 * 24 * 60 * 60 - 60;
const now = Math.floor(Date.now() / 1000);
const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

const header = base64url({ alg: "ES256", kid: keyId, typ: "JWT" });
const payload = base64url({ iss: teamId, iat: now, exp: now + SIX_MONTHS, aud: "https://appleid.apple.com", sub: servicesId });
const signature = sign("sha256", Buffer.from(`${header}.${payload}`), {
  key: createPrivateKey(readFileSync(keyPath)),
  dsaEncoding: "ieee-p1363",
}).toString("base64url");

console.log(`${header}.${payload}.${signature}`);
console.error(`\nExpires ${new Date((now + SIX_MONTHS) * 1000).toDateString()}. Make a new one before then.`);
