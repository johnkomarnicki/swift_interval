// The AI coach's review of how a training plan is going, with Claude.
//
// After a plan session (or when a few sessions have been missed) the app calls
// this with the signed-in user's token. The runner can also ask about any
// earlier run that never got a review (from before the coach existed, outside
// the plan, or one whose review failed): it's reviewed against the current plan. The coach always gives short feedback
// and, when it sees a trend, suggests a change to the rest of the plan, which
// the runner accepts or dismisses. Like generate-program, a review responds
// right away with the new review's id (status "generating") and finishes in the
// background; the app watches the `program_reviews` row until it becomes
// "ready" or "failed".
//
// The body's `action` picks what to do:
//   review   { program_id, trigger: "run" | "missed", record_id?, today }  -> 202 { review_id }
//   accept   { review_id, today? }  writes the suggested change into the plan
//   dismiss  { review_id }          keeps the plan as it is
//   undo     { review_id }          puts back the plan from before an accepted change

import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { isoDate, parseDate, type Plan, type PlanSession, WEEK_SCHEMA } from "../_shared/plan.ts";
import {
  doneSessionIds,
  type MergeOptions,
  mergeRevision,
  missedSessions,
  type RunSignals,
  runSignals,
  type Trend,
  trend,
} from "../_shared/analysis.ts";
import {
  dayFrom,
  findSession,
  json,
  loadRecord,
  mergeOptions,
  type Onboarding,
  planFrame,
  planOutline,
  programRecords,
  type ProgramRow,
  type Proposal,
  proposalFrom,
  type RawRevision,
  recentRecords,
  RUN_NUMBERS,
  runnerText,
  type RunRecord,
  sessionLine,
  supersedeProposals,
  WORKOUT_FORMAT,
} from "../_shared/coach.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const MODEL = "claude-opus-5-5";
/** Reviews allowed per user per 24 hours, to cap API spend. */
const DAILY_LIMIT = 10;
/** How many of the newest runs the prompt shows, besides the one being reviewed. */
const RECENT_RUNS = 8;
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
/** A run at least this many days old is reviewed as a look back. Not 1: the run's
 * date is in UTC and today is the runner's, so a run from last night can look a day old. */
const LOOKING_BACK_DAYS = 2;

type Body = {
  action?: string;
  program_id?: string;
  trigger?: string;
  record_id?: string;
  review_id?: string;
  today?: string;
};
type ReviewRow = {
  id: string;
  program_id: string;
  status: string;
  proposal: Proposal | null;
  previous_plan: Plan | null;
};
type RawReview = RawRevision & { feedback: string; propose_change: boolean };

// ---------------------------------------------------------------------------
// Output format. Claude's response is constrained to this JSON schema; the
// revised weeks are merged into the plan and clamped by `mergeRevision`.
// ---------------------------------------------------------------------------

const REVIEW_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["feedback", "propose_change", "reason", "summary", "changes", "weeks"],
  properties: {
    feedback: {
      type: "string",
      description: "2-4 sentences to the runner: specific, encouraging, and mentioning what the numbers show.",
    },
    propose_change: { type: "boolean", description: "True only for a trend or 2+ missed sessions, never for one run." },
    reason: {
      type: "string",
      description: "2-4 sentences to the runner: what you noticed and why you're changing the plan. Empty without a change.",
    },
    summary: {
      type: "string",
      description: "One short line, e.g. 'Ease weeks 4-8 back by about 10%'. Empty without a change.",
    },
    changes: {
      type: "array",
      description: "One entry per changed week. Empty without a change.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["week", "change"],
        properties: {
          week: { type: "integer" },
          change: { type: "string", description: "A few words, e.g. 'About 10% less running; long run peaks at 30 min'." },
        },
      },
    },
    weeks: { type: "array", description: "The revised weeks. Empty without a change.", items: WEEK_SCHEMA },
  },
} as const;

const SYSTEM_PROMPT = `You are an experienced, encouraging running coach. You wrote this runner's personalized training plan in the Runwise iPhone app, which plays each session as a timed workout with voice cues and tracks distance in miles. Now you check in on how training is going: after a session, when they've missed a few, or when they ask about an earlier run that wasn't reviewed at the time.

${WORKOUT_FORMAT}

${RUN_NUMBERS}

Your review:
- Always write feedback: 2-4 sentences, specific and encouraging, that mention what the numbers show (their pace, how much they completed, how their heart rate settled). Speak to the runner directly. When they've missed sessions, acknowledge it kindly, without guilt, and focus on getting going again.
- Suggest a plan change only for a trend, for example 2 or more of their last 3 runs felt too hard, were cut short or faded badly, or runs are consistently easy with good recovery; or when 2 or more sessions were missed. One off run, good or bad, gets feedback only. When in doubt, keep the plan.
- To pull back: lower running volume or intensity by 10-20%, lengthen rests, shorten work intervals, or repeat a week. To move faster: at most about 10% more than the plan already asks.
- A change rewrites the plan from the first week it changes to the end. Return each week you change with all of its sessions. Weeks after the first one you change that you leave out stay as they are, so if a change shifts later weeks (for example repeating a week), return every week from there to the new final week.
- Sessions marked done or dated before today stay exactly as they are, whatever you return for those days. Weeks before the current week can't change.
- Keep to the runner's training days and their usual number of sessions per week, keep every session within their maximum session length, and keep at most two hard sessions (intervals, tempo, time trial) a week, never on back-to-back days. With a race date the plan still ends in race week and tapers in the final week. Never go past the last week you're told the plan can reach.
- With a change: reason speaks to the runner and explains what you saw and why you're changing the plan; summary is one short line; changes has one short line per changed week. Without a change, reason and summary are empty strings and changes and weeks are empty.
- If the runner reports injuries or something sounds like pain, be conservative. Never give medical advice; suggest checking with a professional if something sounds serious.
- Keep titles short (at most 30 characters) and descriptions to one or two sentences.`;

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

  let body: Body = {};
  try {
    body = await req.json();
  } catch {
    // Falls through to "Unknown action".
  }
  // Swift sends UUIDs in upper case; Postgres returns them in lower case.
  body.program_id = body.program_id?.toLowerCase();
  body.record_id = body.record_id?.toLowerCase();
  body.review_id = body.review_id?.toLowerCase();

  switch (body.action) {
    case "review":
      return await startReview(supabase, userId, body);
    case "accept":
      return await accept(supabase, body);
    case "dismiss":
      return await dismiss(supabase, body);
    case "undo":
      return await undo(supabase, body);
    default:
      return json({ error: "Unknown action" }, 400);
  }
});

async function startReview(supabase: SupabaseClient, userId: string, body: Body) {
  const { program_id: programId, trigger, record_id: recordId } = body;
  if (!programId || (trigger !== "run" && trigger !== "missed")) return json({ error: "Missing plan or trigger" }, 400);
  if (trigger === "run" && !recordId) return json({ error: "Missing run" }, 400);
  const today = dayFrom(body.today);

  // One review per run, so the app can safely ask again (e.g. after being offline).
  // A failed one is cleared so the runner can try again.
  if (recordId) {
    await supabase.from("program_reviews").delete().eq("record_id", recordId).eq("status", "failed");
    const existing = await reviewIdForRecord(supabase, recordId);
    if (existing) return json({ review_id: existing });
  }

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count } = await supabase
    .from("program_reviews")
    .select("id", { count: "exact", head: true })
    .gte("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return json({ error: `Your coach can review up to ${DAILY_LIMIT} runs a day. Try again tomorrow.` }, 429);
  }

  const { data: program } = await supabase
    .from("programs")
    .select("id, status, plan, onboarding")
    .eq("id", programId)
    .maybeSingle();
  if (!program?.plan) return json({ error: "That plan wasn't found." }, 404);
  if (program.status !== "active") return json({ error: "Only your current plan can be reviewed." }, 400);

  if (trigger === "run") {
    const { data: record } = await supabase.from("workout_records").select("activity").eq("id", recordId!).maybeSingle();
    // 400 tells the app to retry once the run has synced; 422 means retrying won't help.
    if (!record) return json({ error: "Your run hasn't uploaded yet." }, 400);
    if (record.activity === "walk") return json({ error: "Your coach reviews runs, not walks." }, 422);
  }

  const { data: review, error: insertError } = await supabase
    .from("program_reviews")
    .insert({ user_id: userId, program_id: programId, record_id: recordId ?? null, trigger, model: MODEL })
    .select("id")
    .single();
  if (insertError?.code === "23505" && recordId) {
    // Another request for the same run got there first (record_id is unique).
    const existing = await reviewIdForRecord(supabase, recordId);
    if (existing) return json({ review_id: existing });
  }
  if (insertError || !review) return json({ error: "Couldn't start the review." }, 500);

  EdgeRuntime.waitUntil(
    runReview(supabase, review.id, program as ProgramRow & { plan: Plan }, trigger, recordId ?? null, today),
  );
  return json({ review_id: review.id }, 202);
}

async function runReview(
  supabase: SupabaseClient,
  reviewId: string,
  program: ProgramRow & { plan: Plan },
  trigger: "run" | "missed",
  recordId: string | null,
  today: Date,
) {
  try {
    const plan = program.plan;
    const onboarding = program.onboarding ?? {};
    const [linked, recent, lastReview] = await Promise.all([
      programRecords(supabase, program.id),
      recentRecords(supabase),
      supabase
        .from("program_reviews")
        .select("created_at")
        .eq("program_id", program.id)
        .neq("id", reviewId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle(),
    ]);

    const done = doneSessionIds(linked);
    // A run outside the plan (or from an earlier one) is looked up on its own.
    const reviewed = recordId
      ? linked.find((record) => record.id === recordId) ?? await loadRecord(supabase, recordId)
      : null;
    if (recordId && !reviewed) throw new Error("The run to review wasn't found.");
    const inPlan = reviewed?.program_id === program.id;

    // The trend is about how this plan fits, so it only looks at the plan's runs;
    // other recent runs are shown for context.
    const planSignals = new Map(linked.slice(0, 10).map((record) => [record.id, runSignals(record)]));
    const byId = new Map<string, RunRecord>();
    for (const record of [...linked, ...recent]) byId.set(record.id, record);
    const earlier = [...byId.values()]
      .filter((record) => record.id !== recordId && record.activity !== "walk")
      .sort((a, b) => Date.parse(b.started_at) - Date.parse(a.started_at))
      .slice(0, RECENT_RUNS)
      .map((record) => planSignals.get(record.id) ?? runSignals(record));

    const since = lastReview.data?.created_at ? new Date(lastReview.data.created_at) : undefined;
    const raw = await askClaude(reviewPrompt({
      today,
      trigger,
      plan,
      onboarding,
      done,
      missedIds: new Set(missedSessions(plan, done, today).map((session) => session.id)),
      missed: missedSessions(plan, done, today, since),
      reviewed: reviewed ? reviewedSignals(reviewed, inPlan, planSignals) : null,
      inPlan,
      planned: inPlan && reviewed?.program_session_id ? findSession(plan, reviewed.program_session_id) : null,
      earlier,
      trend: trend([...planSignals.values()]),
    }));

    const feedback = String(raw.feedback ?? "").trim();
    if (!feedback) throw new Error("The review had no feedback.");
    const proposal = buildProposal(plan, raw, feedback, mergeOptions(onboarding, done, today));

    const { error } = await supabase
      .from("program_reviews")
      .update({ status: "ready", feedback, proposal })
      .eq("id", reviewId);
    if (error) throw new Error(`Saving the review failed: ${error.message}`);
    if (proposal) await supersedeProposals(supabase, program.id, reviewId);
  } catch (error) {
    console.error("review-program failed", error);
    await supabase
      .from("program_reviews")
      .update({ status: "failed", error: error instanceof Error ? error.message : String(error) })
      .eq("id", reviewId);
  }
}

/** The reviewed run's numbers. Session ids from another plan would match this
 * plan's by accident (both have a `w3-tue`), so they're dropped. */
function reviewedSignals(record: RunRecord, inPlan: boolean, planSignals: Map<string, RunSignals>): RunSignals {
  const signals = planSignals.get(record.id) ?? runSignals(record);
  return inPlan ? signals : { ...signals, session_id: null };
}

/** The suggested change as stored: only the part of the plan that actually changes.
 * Null when the coach suggested none, or nothing valid was left of it. */
function buildProposal(plan: Plan, raw: RawReview, feedback: string, options: MergeOptions): Proposal | null {
  if (!raw.propose_change || !Array.isArray(raw.weeks) || raw.weeks.length === 0) return null;
  try {
    return proposalFrom(plan, raw, feedback, options);
  } catch (error) {
    // The feedback still stands; only the revision is dropped.
    console.error("review-program: revision discarded", error);
    return null;
  }
}

async function askClaude(userPrompt: string): Promise<RawReview> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const stream = anthropic.beta.messages.stream({
    model: MODEL,
    max_tokens: 32000,
    // If a safety classifier declines, retry on Anthropic's recommended fallback model.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: {
      // Same as generate-program: a suggested change rewrites weeks of the plan
      // under the same rules, so it gets the same care.
      effort: "medium",
      format: { type: "json_schema", schema: REVIEW_SCHEMA },
    },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userPrompt }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === "refusal") throw new Error("The review request was declined.");
  if (message.stop_reason === "max_tokens") throw new Error("The review was too long to finish.");
  const text = message.content
    .filter((block) => block.type === "text")
    .map((block) => (block as { text: string }).text)
    .join("");
  console.log("review-program usage", JSON.stringify(message.usage));
  return JSON.parse(text) as RawReview;
}

// ---------------------------------------------------------------------------
// Accept, dismiss, undo
// ---------------------------------------------------------------------------

async function accept(supabase: SupabaseClient, body: Body) {
  const review = await loadReview(supabase, body.review_id);
  if (!review) return json({ error: "That review wasn't found." }, 404);
  if (review.status !== "ready" || !review.proposal) return json({ error: "This change is no longer available." }, 409);

  const { data: program } = await supabase
    .from("programs")
    .select("id, status, plan, onboarding")
    .eq("id", review.program_id)
    .maybeSingle();
  if (!program?.plan) return json({ error: "That plan wasn't found." }, 404);
  if (program.status !== "active") return json({ error: "This plan is no longer your current one." }, 409);

  // The plan may have moved on since the review (runs done, days gone by), so
  // the change is merged again into the plan as it is now.
  const today = dayFrom(body.today);
  const done = doneSessionIds(await programRecords(supabase, program.id));
  let merged: Plan;
  try {
    merged = mergeRevision(program.plan, review.proposal.weeks, mergeOptions(program.onboarding, done, today));
  } catch (error) {
    console.error("review-program: change no longer fits", error);
    await supabase
      .from("program_reviews")
      .update({ status: "superseded", resolved_at: new Date().toISOString() })
      .eq("id", review.id)
      .eq("status", "ready");
    return json({ error: "Your plan has moved on since this suggestion, so it no longer applies." }, 409);
  }

  // Claims the review first, so accepting twice can't overwrite previous_plan.
  const { data: claimed } = await supabase
    .from("program_reviews")
    .update({ status: "accepted", previous_plan: program.plan, resolved_at: new Date().toISOString() })
    .eq("id", review.id)
    .eq("status", "ready")
    .select("id");
  if (!claimed?.length) return json({ error: "This change is no longer available." }, 409);

  const { error } = await supabase.from("programs").update({ plan: merged }).eq("id", program.id);
  if (error) {
    console.error("review-program: saving the plan failed", error);
    await supabase
      .from("program_reviews")
      .update({ status: "ready", previous_plan: null, resolved_at: null })
      .eq("id", review.id);
    return json({ error: "Couldn't update your plan. Try again." }, 500);
  }
  await supersedeProposals(supabase, program.id, review.id);
  return json({ ok: true });
}

async function dismiss(supabase: SupabaseClient, body: Body) {
  const review = await loadReview(supabase, body.review_id);
  if (!review) return json({ error: "That review wasn't found." }, 404);
  if (review.status === "dismissed") return json({ ok: true });
  if (review.status !== "ready") return json({ error: "This suggestion is no longer open." }, 409);

  const { error } = await supabase
    .from("program_reviews")
    .update({ status: "dismissed", resolved_at: new Date().toISOString() })
    .eq("id", review.id)
    .eq("status", "ready");
  if (error) return json({ error: "Couldn't update the review. Try again." }, 500);
  return json({ ok: true });
}

async function undo(supabase: SupabaseClient, body: Body) {
  const review = await loadReview(supabase, body.review_id);
  if (!review) return json({ error: "That review wasn't found." }, 404);
  if (review.status !== "accepted" || !review.previous_plan) return json({ error: "This change can't be undone." }, 409);

  // Only the latest change can be undone; undoing an older one would also throw
  // away every change accepted after it.
  const { data: latest } = await supabase
    .from("program_reviews")
    .select("id")
    .eq("program_id", review.program_id)
    .eq("status", "accepted")
    .order("resolved_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (latest?.id !== review.id) return json({ error: "Only your latest plan change can be undone." }, 409);

  const { data: claimed } = await supabase
    .from("program_reviews")
    .update({ status: "reverted" })
    .eq("id", review.id)
    .eq("status", "accepted")
    .select("id");
  if (!claimed?.length) return json({ error: "This change can't be undone." }, 409);

  const { error } = await supabase.from("programs").update({ plan: review.previous_plan }).eq("id", review.program_id);
  if (error) {
    console.error("review-program: restoring the plan failed", error);
    await supabase.from("program_reviews").update({ status: "accepted" }).eq("id", review.id);
    return json({ error: "Couldn't undo the change. Try again." }, 500);
  }
  return json({ ok: true });
}

// ---------------------------------------------------------------------------
// Prompt
// ---------------------------------------------------------------------------

type PromptInput = {
  today: Date;
  trigger: "run" | "missed";
  plan: Plan;
  onboarding: Onboarding;
  done: Set<string>;
  /** Every missed session, to mark them in the plan. */
  missedIds: Set<string>;
  /** Sessions missed since the last review. */
  missed: PlanSession[];
  reviewed: RunSignals | null;
  /** The reviewed run was a session of this plan. */
  inPlan: boolean;
  planned: PlanSession | null;
  /** Other recent runs, newest first. */
  earlier: RunSignals[];
  trend: Trend;
};

function reviewPrompt(input: PromptInput) {
  const { today, plan, onboarding, trend } = input;
  const frame = planFrame(plan, onboarding, today);
  const { weekday, currentWeek, lastAllowedWeek } = frame;
  const runner = runnerText(onboarding, frame);
  const todayText = isoDate(today);
  const outline = planOutline(plan, currentWeek, input.done, input.missedIds, today);

  const runDate = parseDate(input.reviewed?.date);
  const daysAgo = runDate ? Math.round((today.getTime() - runDate.getTime()) / (WEEK_MS / 7)) : 0;
  const isPast = daysAgo >= LOOKING_BACK_DAYS;
  const planned = input.planned
    ? sessionLine(input.planned)
    : input.inPlan
    ? "not found in the plan"
    : "not a session of this plan (a free run, their own workout, or a run from an earlier plan)";
  const reviewed = input.reviewed
    ? `The run you're reviewing${isPast ? ` (from ${input.reviewed.date}, ${daysAgo} days ago; it wasn't reviewed at the time, so some of their other runs below are newer)` : ""}:
Planned: ${planned}
What happened: ${JSON.stringify(input.reviewed)}`
    : "No new run: this review is about the missed sessions.";
  const ask = input.trigger === "missed"
    ? `They've missed ${input.missed.length} sessions. Review how their training is going.`
    : isPast
    ? "Review this run. Talk about it as a past run, and base any plan change on how their training is going now, not on this run alone."
    : "Review this run.";

  const missed = input.missed.length > 0
    ? input.missed.map((session) => `- ${session.id} ${session.date} "${session.title}"`).join("\n")
    : "None.";

  return `Today is ${todayText} (${weekday}).

The runner:
${runner}

Their plan "${plan.title}" from this week on (week ${currentWeek} is the current week; the plan can end no later than week ${lastAllowedWeek}). Each session: id, date, kind, title, workout, and its running time:
${outline || "The plan has no weeks left."}

${reviewed}

Their other recent runs (newest first; paces are minutes:seconds per mile; session_id is null for runs outside the plan):
${input.earlier.length > 0 ? input.earlier.map((run) => JSON.stringify(run)).join("\n") : "None."}

Trend over their last ${trend.runs_considered} plan runs: ${trend.too_hard_count} looked too hard, ${trend.too_easy_count} too easy, ${trend.incomplete_count} cut short.
${trend.notes.map((note) => `- ${note}`).join("\n")}

Sessions missed since your last review:
${missed}

${ask}`;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

async function loadReview(supabase: SupabaseClient, reviewId: string | undefined) {
  if (!reviewId) return null;
  const { data } = await supabase
    .from("program_reviews")
    .select("id, program_id, status, proposal, previous_plan")
    .eq("id", reviewId)
    .maybeSingle();
  return data as ReviewRow | null;
}

async function reviewIdForRecord(supabase: SupabaseClient, recordId: string): Promise<string | null> {
  const { data } = await supabase.from("program_reviews").select("id").eq("record_id", recordId).maybeSingle();
  return data?.id ?? null;
}
