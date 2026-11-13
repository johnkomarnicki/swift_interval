// Builds a personalized running program with Claude.
//
// The app calls this with the signed-in user's token. It responds right away
// with the new program's id (status "generating"), then finishes the work in the
// background; the app watches the `programs` row until it becomes "active" or
// "failed". The Anthropic API key lives only here, as a Supabase secret.

import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import {
  addDays,
  DAYS,
  heartRateSummary,
  isoDate,
  mondayOf,
  normalizeWorkout,
  pace,
  parseDate,
  type Day,
  type RawSession,
  type RecordedInterval,
  round2,
  WEEK_SCHEMA,
} from "../_shared/plan.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const MODEL = "claude-opus-5-5";
/** Generations allowed per user per 24 hours, to cap API spend. */
const DAILY_LIMIT = 5;

// ---------------------------------------------------------------------------
// Output format. Claude's response is constrained to this JSON schema; the
// numeric limits are enforced afterwards in `normalize` (schemas can't express them).
// The week and workout pieces are shared with review-program.
// ---------------------------------------------------------------------------

const PROGRAM_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["title", "summary", "weeks"],
  properties: {
    title: { type: "string", description: "Short plan name, e.g. '8-week 5K builder'." },
    summary: { type: "string", description: "2-3 sentences: what the plan does and how it progresses." },
    weeks: { type: "array", items: WEEK_SCHEMA },
  },
} as const;

const SYSTEM_PROMPT = `You are an experienced, encouraging running coach. You design personalized training programs for the Runwise iPhone app, which plays each session as a timed workout with voice cues and tracks distance in miles.

How workouts are expressed:
- A workout is an optional warm-up, a round of work/rest steps repeated for a number of rounds, and an optional cool-down. All durations are whole seconds.
- "work" means running at the effort the session describes; "rest" means walking or very easy jogging.
- Easy, long and tempo runs are a single work step with rounds = 1 (for example a 25-minute easy run is one 1500-second work step).
- Run/walk sessions alternate work and rest steps.
- Every step is between 10 and 3599 seconds, a session has at most 20 steps per round and at most 50 rounds, and the whole session (warm-up and cool-down included) must fit within the runner's maximum session length.
- Warm-ups and cool-downs are usually a 3-5 minute brisk walk.

How to build the program:
- Schedule sessions only on the runner's available training days, and only as many per week as they chose. Avoid hard sessions on back-to-back days; at most two hard sessions (intervals, tempo, time trial) per week.
- Start from where the runner actually is (how long they can run without stopping, their recent runs, their current weekly running) and progress gradually: increase weekly running time by no more than about 10%, and ease back by 20-30% every third or fourth week.
- For runners who can't yet run 10 minutes without stopping, use run/walk intervals that progress toward continuous running.
- With a race date, the program ends in race week and tapers in the final week; the final session can be the race or a time trial. Without one, pick a length that suits the goal (usually 6-12 weeks, never more than 16).
- If the runner reports injuries or health conditions, be conservative: more walking, lower volume, fewer hard sessions. Never give medical advice; suggest checking with a professional in the plan summary if something sounds serious.
- Use the recent run history (distances and paces per mile) to set realistic target paces in descriptions. Without pace data, describe effort ("conversational", "comfortably hard", "strong but controlled").
- Some runs include heart rate in beats per minute: work_avg_hr (average over work intervals), max_hr, and rest_recovery_bpm (how far heart rate fell, on average, from the end of each work interval to the end of the rest after it). Use it with the runner's age range to judge how hard their runs really were. If work heart rate is high for their age, max_hr is close to their likely maximum, or recovery is small (under about 20 bpm), progress more gently: longer rests, shorter work intervals, or an extra easier week. If heart rate stays moderate and recovery is quick, the plan can progress normally. Heart rate from different devices varies, so look at trends across runs rather than one reading, and never present it as medical advice.
- In week 1, only schedule sessions on or after today's weekday.
- Keep titles short and descriptions to one or two sentences.`;

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Not signed in" }, 401);

  // Acts as the signed-in user, so row level security applies to every query.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) return json({ error: "Not signed in" }, 401);
  const userId = userData.user.id;

  let body: { today?: string } = {};
  try {
    body = await req.json();
  } catch {
    // An empty body is fine.
  }
  const today = parseDate(body.today) ?? new Date();

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count } = await supabase
    .from("programs")
    .select("id", { count: "exact", head: true })
    .gte("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return json({ error: `You can build up to ${DAILY_LIMIT} plans a day. Try again tomorrow.` }, 429);
  }

  const { data: profile } = await supabase.from("profiles").select("onboarding").eq("id", userId).single();
  if (!profile?.onboarding) return json({ error: "Finish the onboarding questions first." }, 400);

  const startDate = mondayOf(today);
  const { data: program, error: insertError } = await supabase
    .from("programs")
    // Keeps the answers this plan was built from, since later plans can use different ones.
    .insert({
      user_id: userId,
      status: "generating",
      start_date: isoDate(startDate),
      model: MODEL,
      onboarding: profile.onboarding,
    })
    .select("id")
    .single();
  if (insertError || !program) return json({ error: "Couldn't start a new plan." }, 500);

  EdgeRuntime.waitUntil(
    buildProgram(supabase, userId, program.id, profile.onboarding, today, startDate),
  );
  return json({ program_id: program.id }, 202);
});

async function buildProgram(
  supabase: SupabaseClient,
  userId: string,
  programId: string,
  onboarding: unknown,
  today: Date,
  startDate: Date,
) {
  try {
    const history = await recentHistory(supabase);
    const raw = await askClaude(onboarding, history, today);
    const plan = normalize(raw, today, startDate);

    await supabase
      .from("programs")
      .update({ status: "archived" })
      .eq("user_id", userId)
      .eq("status", "active")
      .neq("id", programId);
    const { error } = await supabase
      .from("programs")
      .update({ status: "active", title: plan.title, summary: plan.summary, plan })
      .eq("id", programId);
    if (error) throw new Error(`Saving the plan failed: ${error.message}`);
  } catch (error) {
    console.error("generate-program failed", error);
    await supabase
      .from("programs")
      .update({ status: "failed", error: error instanceof Error ? error.message : String(error) })
      .eq("id", programId);
  }
}

async function askClaude(onboarding: unknown, history: unknown[], today: Date): Promise<RawProgram> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const weekday = DAYS[(today.getUTCDay() + 6) % 7];
  const userPrompt = `Today is ${isoDate(today)} (${weekday}).

The runner's answers to the onboarding questions:
${JSON.stringify(onboarding, null, 2)}

Their recent runs (newest first; paces are minutes:seconds per mile):
${history.length > 0 ? JSON.stringify(history, null, 2) : "No runs recorded yet."}

Build their program.`;

  const stream = anthropic.beta.messages.stream({
    model: MODEL,
    max_tokens: 32000,
    // If a safety classifier declines, retry on Anthropic's recommended fallback model.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: {
      effort: "medium",
      format: { type: "json_schema", schema: PROGRAM_SCHEMA },
    },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userPrompt }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === "refusal") throw new Error("The plan request was declined.");
  if (message.stop_reason === "max_tokens") throw new Error("The plan was too long to finish.");
  const text = message.content
    .filter((block) => block.type === "text")
    .map((block) => (block as { text: string }).text)
    .join("");
  console.log("generate-program usage", JSON.stringify(message.usage));
  return JSON.parse(text) as RawProgram;
}

/** The last 60 days of runs, summarized for the prompt. */
async function recentHistory(supabase: SupabaseClient) {
  const since = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString();
  const { data } = await supabase
    .from("workout_records")
    .select("name, started_at, completed, total_meters, active_time, intervals")
    .gte("started_at", since)
    .order("started_at", { ascending: false })
    .limit(30);

  return (data ?? []).map((record) => {
    const intervals = (record.intervals ?? []) as RecordedInterval[];
    const work = intervals.filter((i) => i.phase === "work" && i.activeSeconds >= 0.5);
    const workMeters = work.reduce((sum, i) => sum + (i.meters ?? 0), 0);
    const workSeconds = work.reduce((sum, i) => sum + i.activeSeconds, 0);
    const heartRate = heartRateSummary(intervals);
    return {
      date: record.started_at.slice(0, 10),
      workout: record.name,
      completed: record.completed,
      minutes: Math.round(record.active_time / 60),
      miles: record.total_meters != null ? round2(record.total_meters / 1609.344) : null,
      work_intervals: work.length,
      work_pace_per_mile: workMeters > 50 ? pace(workSeconds, workMeters) : null,
      overall_pace_per_mile: record.total_meters > 50 ? pace(record.active_time, record.total_meters) : null,
      ...heartRate,
    };
  });
}

// ---------------------------------------------------------------------------
// Validation: clamp everything to what the app can play, give each session a
// stable id and a calendar date.
// ---------------------------------------------------------------------------

type RawProgram = { title: string; summary: string; weeks: { week: number; focus: string; sessions: RawSession[] }[] };

function normalize(raw: RawProgram, today: Date, startDate: Date) {
  const todayIndex = (today.getUTCDay() + 6) % 7;
  const weeks = (raw.weeks ?? []).slice(0, 16).map((week, weekIndex) => {
    const seen = new Set<Day>();
    const sessions = (week.sessions ?? [])
      .filter((session) => DAYS.includes(session.day))
      .filter((session) => weekIndex > 0 || DAYS.indexOf(session.day) >= todayIndex)
      .filter((session) => (seen.has(session.day) ? false : (seen.add(session.day), true)))
      .map((session) => ({ ...session, workout: normalizeWorkout(session.workout) }))
      .filter((session) => session.workout !== null)
      .sort((a, b) => DAYS.indexOf(a.day) - DAYS.indexOf(b.day))
      .map((session) => {
        const date = addDays(startDate, weekIndex * 7 + DAYS.indexOf(session.day));
        return {
          id: `w${weekIndex + 1}-${session.day}`,
          day: session.day,
          date: isoDate(date),
          kind: session.kind,
          title: String(session.title ?? "").slice(0, 60),
          description: String(session.description ?? ""),
          workout: session.workout!,
        };
      });
    return { week: weekIndex + 1, focus: String(week.focus ?? ""), sessions };
  });

  if (!weeks.some((week) => week.sessions.length > 0)) throw new Error("The plan had no sessions.");
  return { title: String(raw.title ?? "Your plan"), summary: String(raw.summary ?? ""), start_date: isoDate(startDate), weeks };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
