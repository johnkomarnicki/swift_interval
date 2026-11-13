// Runwise MCP server: lets a runner connect Claude (claude.ai, Claude Desktop,
// Claude Code) to their own Runwise data. Read-only.
//
// Auth is Supabase's OAuth 2.1 server. A client that calls without a token gets
// a 401 pointing at `/functions/v1/mcp/oauth-protected-resource`, which names
// this project's Supabase Auth as the authorization server. The runner signs in
// on the consent page (`docs/oauth/consent.html`) and approves; the client then
// calls with the runner's access token. `withSupabase({ auth: "user" })` checks
// that token against the project's JWKS and hands the tools a client scoped to
// the runner, so row level security limits every query to their own rows.
//
// Stateless Streamable HTTP: a fresh McpServer per request, no sessions.
// `config.toml` sets `verify_jwt = false` so the discovery request reaches us.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createMcpHandler } from "npm:@modelcontextprotocol/server@2.4.0";
import { pipeline } from "npm:@supabase/middleware@1.0.0";
import { withOAuthProtectedResource, withSupabase } from "npm:@supabase/server@1.9.2";
import { buildServer } from "./server.ts";

Deno.serve(
  pipeline(
    [withOAuthProtectedResource(), withSupabase({ auth: "user" })],
    async (req, { supabase, userClaims }) => {
      const handler = createMcpHandler(() => buildServer(supabase, userClaims?.email), {
        onerror: (error) => console.error("mcp: request failed", error),
      });
      return handler.fetch(req);
    },
  ),
);
