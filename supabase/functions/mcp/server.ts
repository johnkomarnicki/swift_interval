// The Runwise MCP tools. All read-only; `index.ts` wires them to OAuth and HTTP.

import { McpServer } from "npm:@modelcontextprotocol/server@2.4.0";
import type { SupabaseClient } from "npm:@supabase/server@1.9.2/peer/supabase-js";
import { z } from "npm:zod@4.6.7";
import { addDays, isoDate, parseDate, type Plan } from "../_shared/plan.ts";
import { periodSummary, planStatus, runDetail, type RunRow, runSummary } from "./summaries.ts";

const RUN_COLUMNS =
  "id, name, started_at, completed, total_time, active_time, total_meters, intervals, program_id, program_session_id, effort, activity";
/** `periodSummary` doesn't need the intervals, which are most of a row's size. */
const TOTAL_COLUMNS = "started_at, completed, total_meters, active_time, activity, effort";
/** PostgREST's default row cap. */
const MAX_ROWS = 1000;

const INSTRUCTIONS = `Runwise is an iPhone app for run/walk interval training with an AI coach.
This server reads the signed-in runner's own data: their runs (interval workouts, free runs and walks),
their AI training plan and how they're tracking against it, the coach's run reviews and chat, saved
workouts and routes. Distances are in miles and paces in minutes:seconds per mile. Times are UTC;
pass the runner's local date as \`today\` where a tool takes it. Everything here is read-only: to change
a plan, accept a coach suggestion or edit runs, the runner uses the app.`;

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Use yyyy-MM-dd");
const READ_ONLY = { readOnlyHint: true, idempotentHint: true, openWorldHint: false } as const;

function ok(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data) }] };
}

function fail(what: string, error: { message: string }): never {
  console.error(`mcp: ${what} failed`, error);
  throw new Error(`${what} failed: ${error.message}`);
}

/** The day after `value`, for an inclusive `to` date. */
function dayAfter(value: string) {
  return isoDate(addDays(parseDate(value)!, 1));
}

/** The Runwise MCP server for one request, reading through `supabase` (scoped to the runner by RLS). */
export function buildServer(supabase: SupabaseClient, email: string | undefined) {
  const server = new McpServer({ name: "runwise", version: "1.0.0" }, { instructions: INSTRUCTIONS });

  server.registerTool(
    "get_profile",
    {
      title: "Get profile",
      description:
        "The runner's account: email, when they joined, and their onboarding answers (goal, target 5K time, race date, training days, longest session they can fit, age range, injuries).",
      annotations: READ_ONLY,
    },
    async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("onboarding, onboarding_completed_at, created_at")
        .maybeSingle();
      if (error) fail("Loading the profile", error);
      return ok({ email: email ?? null, ...data });
    },
  );

  server.registerTool(
    "list_runs",
    {
      title: "List runs",
      description:
        "The runner's recorded runs, newest first, with distance, pace, heart rate, effort rating and, for interval workouts, how much of the planned work they did and whether they faded. Filter by date range, kind or plan. Use get_run for one run's interval-by-interval log.",
      inputSchema: z.object({
        from: date.optional().describe("First day to include (yyyy-MM-dd)."),
        to: date.optional().describe("Last day to include (yyyy-MM-dd)."),
        kind: z.enum(["interval", "run", "walk"]).optional().describe(
          "interval: timed interval workouts; run / walk: free runs and walks.",
        ),
        program_id: z.guid().optional().describe("Only sessions of this training plan."),
        limit: z.number().int().min(1).max(200).default(30),
      }),
      annotations: READ_ONLY,
    },
    async ({ from, to, kind, program_id, limit }) => {
      let query = supabase.from("workout_records").select(RUN_COLUMNS);
      if (from) query = query.gte("started_at", from);
      if (to) query = query.lt("started_at", dayAfter(to));
      if (kind === "interval") query = query.is("activity", null);
      else if (kind) query = query.eq("activity", kind);
      if (program_id) query = query.eq("program_id", program_id);
      const { data, error } = await query.order("started_at", { ascending: false }).limit(limit);
      if (error) fail("Loading runs", error);
      const runs = (data ?? []) as unknown as RunRow[];
      return ok({ count: runs.length, runs: runs.map(runSummary) });
    },
  );

  server.registerTool(
    "get_run",
    {
      title: "Get run",
      description:
        "One run in full: its summary plus every interval (warm-up, work, rest, cool-down) with planned and actual time, distance, pace and heart rate.",
      inputSchema: z.object({ run_id: z.guid().describe("A run id from list_runs.") }),
      annotations: READ_ONLY,
    },
    async ({ run_id }) => {
      const { data, error } = await supabase.from("workout_records").select(RUN_COLUMNS).eq("id", run_id)
        .maybeSingle();
      if (error) fail("Loading the run", error);
      if (!data) throw new Error("No run with that id.");
      return ok(runDetail(data as unknown as RunRow));
    },
  );

  server.registerTool(
    "training_summary",
    {
      title: "Training summary",
      description:
        "Totals over a date range: runs, miles, active minutes, average pace, longest run, effort ratings, a breakdown by kind, and week-by-week totals (Monday to Sunday, including empty weeks). Defaults to the last 8 weeks.",
      inputSchema: z.object({
        from: date.optional().describe("First day (yyyy-MM-dd). Defaults to 8 weeks before `to`."),
        to: date.optional().describe("Last day (yyyy-MM-dd). Defaults to today."),
      }),
      annotations: READ_ONLY,
    },
    async (args) => {
      const to = args.to ?? isoDate(new Date());
      const from = args.from ?? isoDate(addDays(parseDate(to)!, -55));
      if (from > to) throw new Error("`from` is after `to`.");
      const { data, error } = await supabase
        .from("workout_records")
        .select(TOTAL_COLUMNS)
        .gte("started_at", from)
        .lt("started_at", dayAfter(to))
        .order("started_at", { ascending: false })
        .limit(MAX_ROWS);
      if (error) fail("Loading runs", error);
      const rows = (data ?? []) as unknown as RunRow[];
      return ok({
        ...periodSummary(rows, from, to),
        ...(rows.length === MAX_ROWS ? { note: `Only the newest ${MAX_ROWS} runs were counted; narrow the range.` } : {}),
      });
    },
  );

  server.registerTool(
    "get_training_plan",
    {
      title: "Get training plan",
      description:
        "The runner's AI training plan (the active one unless program_id is given): every week and session marked done, missed, today or upcoming, the next session, counts, and the coach's read of recent plan runs (too hard, too easy, cut short). Also lists their other plans and the onboarding answers the plan was built from.",
      inputSchema: z.object({
        program_id: z.guid().optional().describe("A plan id; defaults to the active plan."),
        today: date.optional().describe("The runner's local date (yyyy-MM-dd); defaults to today in UTC."),
      }),
      annotations: READ_ONLY,
    },
    async ({ program_id, today }) => {
      const { data: programs, error } = await supabase
        .from("programs")
        .select("id, status, title, summary, start_date, plan, onboarding, created_at")
        .order("created_at", { ascending: false });
      if (error) fail("Loading plans", error);
      const all = programs ?? [];
      const program = program_id
        ? all.find((p) => p.id === program_id)
        : all.find((p) => p.status === "active");
      const others = all.filter((p) => p !== program).map(({ id, status, title, start_date, created_at }) => ({
        id,
        status,
        title,
        start_date,
        created_at,
      }));
      if (!program) {
        return ok({ plan: null, message: program_id ? "No plan with that id." : "No active plan.", other_plans: others });
      }
      if (!program.plan) {
        return ok({ plan: null, id: program.id, status: program.status, message: "This plan has no sessions.", other_plans: others });
      }

      const { data: records, error: recordsError } = await supabase
        .from("workout_records")
        .select(RUN_COLUMNS)
        .eq("program_id", program.id)
        .order("started_at", { ascending: false })
        .limit(MAX_ROWS);
      if (recordsError) fail("Loading the plan's runs", recordsError);
      const day = parseDate(today) ?? parseDate(isoDate(new Date()))!;
      return ok({
        id: program.id,
        status: program.status,
        created_at: program.created_at,
        built_from: program.onboarding,
        ...planStatus(program.plan as Plan, (records ?? []) as unknown as RunRow[], day),
        other_plans: others,
      });
    },
  );

  server.registerTool(
    "list_coach_reviews",
    {
      title: "List coach reviews",
      description:
        "The AI coach's reviews of the runner's plan runs and missed sessions, newest first: its feedback, any plan change it suggested (reason, summary, week-by-week changes) and whether the runner accepted or dismissed it.",
      inputSchema: z.object({
        program_id: z.guid().optional().describe("Only reviews of this plan."),
        limit: z.number().int().min(1).max(100).default(20),
      }),
      annotations: READ_ONLY,
    },
    async ({ program_id, limit }) => {
      let query = supabase
        .from("program_reviews")
        .select("id, program_id, record_id, trigger, status, feedback, proposal, created_at, resolved_at")
        .in("status", ["ready", "accepted", "dismissed", "superseded", "reverted"]);
      if (program_id) query = query.eq("program_id", program_id);
      const { data, error } = await query.order("created_at", { ascending: false }).limit(limit);
      if (error) fail("Loading reviews", error);
      const reviews = (data ?? []).map(({ proposal, ...review }) => ({
        ...review,
        // The revised weeks are the whole plan tail; the summary and changes say what moved.
        suggested_change: proposal
          ? { reason: proposal.reason, summary: proposal.summary, changes: proposal.changes }
          : null,
      }));
      return ok({ count: reviews.length, reviews });
    },
  );

  server.registerTool(
    "get_coach_chat",
    {
      title: "Get coach chat",
      description: "The runner's conversation with the in-app AI coach, oldest to newest, ending with the latest message.",
      inputSchema: z.object({
        limit: z.number().int().min(1).max(200).default(40).describe("How many of the latest messages."),
        before: z.iso.datetime({ offset: true }).optional().describe(
          "Only messages before this time (ISO 8601), to page back.",
        ),
      }),
      annotations: READ_ONLY,
    },
    async ({ limit, before }) => {
      let query = supabase
        .from("coach_messages")
        .select("role, content, record_id, program_id, review_id, created_at")
        .eq("status", "ready");
      if (before) query = query.lt("created_at", before);
      const { data, error } = await query.order("created_at", { ascending: false }).limit(limit);
      if (error) fail("Loading the coach chat", error);
      return ok({ messages: (data ?? []).reverse() });
    },
  );

  server.registerTool(
    "list_saved_workouts",
    {
      title: "List saved workouts",
      description:
        "Interval workouts the runner built and saved in the app, each with its structure (warm-up, work/rest lengths, rounds, cool-down).",
      annotations: READ_ONLY,
    },
    async () => {
      const { data, error } = await supabase
        .from("workouts")
        .select("id, name, plan, created_at, updated_at")
        .order("updated_at", { ascending: false })
        .limit(MAX_ROWS);
      if (error) fail("Loading workouts", error);
      return ok({ count: data?.length ?? 0, workouts: data ?? [] });
    },
  );

  server.registerTool(
    "list_routes",
    {
      title: "List routes",
      description: "Routes the runner drew on the map in the app, with their length. Map coordinates are left out.",
      annotations: READ_ONLY,
    },
    async () => {
      const { data, error } = await supabase
        .from("routes")
        .select("id, name, meters, waypoints, created_at, updated_at")
        .order("updated_at", { ascending: false })
        .limit(MAX_ROWS);
      if (error) fail("Loading routes", error);
      const routes = (data ?? []).map(({ meters, waypoints, ...route }) => ({
        ...route,
        distance_miles: Math.round((meters / 1609.344) * 100) / 100,
        waypoints: Array.isArray(waypoints) ? waypoints.length : 0,
      }));
      return ok({ count: routes.length, routes });
    },
  );

  return server;
}
