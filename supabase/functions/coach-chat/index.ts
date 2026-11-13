// Chat with the AI coach, with Claude.
//
// The runner asks anything about their running, one of their runs or their
// plan. The coach answers with their plan, their recent runs and (when they
// ask from a run in History) that run in front of it. When the runner wants
// their plan changed, it suggests a change through the same machinery as
// review-program: a `program_reviews` row with trigger "chat", which the
// runner accepts, dismisses or undoes in the app.
//
// The conversation is one thread per runner, in `coach_messages`. Like a
// review, sending responds right away with the reply's id (status
// "generating") and the reply is written in the background. Its text is saved
// as it streams, so the app, watching the row, shows it as it's written.
//
// The body's `action` picks what to do:
//   send   { message, record_id?, today }  -> 202 { message_id }
//   retry  { message_id, today }           -> 202 { message_id }  writes a failed reply again
//   clear  {}                              deletes the conversation

import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { doneSessionIds, missedSessions, type RunSignals, runSignals, trend } from "../_shared/analysis.ts";
import { DAYS, isoDate, parseDate, type Plan, WEEK_SCHEMA } from "../_shared/plan.ts";
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
import { afterFallback, conversation, echoable, joinText, type MessageRow, textOf } from "./conversation.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

type MessageParam = Anthropic.Beta.Messages.BetaMessageParam;
type ToolResult = Anthropic.Beta.Messages.BetaToolResultBlockParam;

const MODEL = "claude-opus-5-5";
/** Messages a runner can send per 24 hours, to cap API spend. */
const DAILY_LIMIT = 40;
const MAX_MESSAGE_LENGTH = 2000;
/** How much of the conversation Claude sees, in messages. */
const HISTORY_MESSAGES = 40;
/** How many of the newest runs the context shows. */
const RECENT_RUNS = 10;
/** A reply that hasn't been saved for this long is taken to have failed (the
 * app gives up on it then too), so the runner can send or try again. */
const REPLY_TIMEOUT_MS = 3 * 60 * 1000;
/** How often a reply's text is saved while it's written. */
const SAVE_INTERVAL_MS = 700;
/** Rounds of tool use in one reply before the coach has to answer in words. */
const MAX_TOOL_ROUNDS = 3;

type Body = { action?: string; message?: string; record_id?: string; message_id?: string; today?: string };
type ActiveProgram = ProgramRow & { plan: Plan };
/** What the coach knows going into a reply. */
type Coaching = {
  program: ActiveProgram | null;
  done: Set<string>;
  today: Date;
  /** The context put in front of the runner's message. */
  text: string;
};

// ---------------------------------------------------------------------------
// Prompt and tool
// ---------------------------------------------------------------------------

const SYSTEM_PROMPT =
  `You are an experienced, encouraging running coach. You wrote this runner's personalized training plan in the Runwise iPhone app, which plays each session as a timed workout with voice cues and tracks distance in miles, and you check in after their runs. Here the runner chats with you: they can ask anything about their running, one of their runs or their plan, and ask you to change the plan.

${WORKOUT_FORMAT}

${RUN_NUMBERS}

The runner's latest message starts with <context> from the app: today's date, their onboarding answers, their plan with each session marked [done], [missed] or [today], their recent runs and, when they asked from a run in their history, that run. It's the app's picture right now, newer than anything earlier in the conversation. The runner doesn't see it, so don't talk about it as something they sent.

How to answer:
- Answer what they asked, like a coach texting back: warm, direct and specific to their plan and their numbers. Usually 2-5 sentences; go longer only when they ask for detail. Write plain text for a phone screen: no headings or tables; a short list (lines starting with "- ") and **bold** are fine sparingly.
- Use the numbers you have, and say so when you don't have something (for example a run that isn't in the context) rather than guessing.
- Stick to running, training, recovery, fueling for runs and the app. For anything else, say briefly that you're their running coach and steer back.
- If something sounds like pain, injury or illness, be conservative: suggest rest and checking with a professional, and don't diagnose or give medical advice. For chest pain, fainting or trouble breathing, tell them to stop running and get medical help.

Changing the plan:
- You can't edit the plan yourself. To change it, call propose_plan_change: the app shows the runner your suggestion, week by week and session by session, and they accept it or keep their plan. Never say the plan has changed; say what you suggest and that they can accept it below your message.
- Suggest a change when they ask for one (an easier or harder week, moving a run, time away, getting back after missed runs) or agree to one you offered. If what they want is unclear, ask first. Don't suggest a change they didn't ask for: offer it, and suggest it once they say yes. If what they ask for is risky (a big jump in running, training through pain), explain why and offer something safer.
- To pull back: lower running volume or intensity by 10-20%, lengthen rests, shorten work intervals, or repeat a week. To move faster: at most about 10% more than the plan already asks.
- A change rewrites the plan from the first week it changes to the end. Return each week you change with all of its sessions. Weeks after the first one you change that you leave out stay as they are, so if a change shifts later weeks (for example repeating a week), return every week from there to the new final week.
- Sessions marked done or dated before today stay exactly as they are, whatever you return for those days. Weeks before the current week can't change.
- Sessions can only go on the runner's training days. Keep to their usual number of sessions per week, keep every session within their maximum session length, and keep at most two hard sessions (intervals, tempo, time trial) a week, never on back-to-back days. With a race date the plan still ends in race week and tapers in the final week. Never go past the last week the context says the plan can reach.
- If they want different training days, a new goal or race date, or longer sessions, those come from their answers: they can update them in Settings and build a new plan from them.
- Keep titles short (at most 30 characters) and descriptions to one or two sentences.
- Suggest at most one change per reply. After suggesting it, finish with a sentence or two; the app shows the details.
- Your earlier suggestions in the conversation are followed by a note saying what the runner did with them.
- Without a plan you can't suggest changes; they can build one on the Plan tab.`;

const PROPOSE_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: "propose_plan_change",
  description:
    "Suggest a change to the rest of the runner's plan. The app shows it to them under your message, with the changes week by week, and buttons to accept it or keep their plan. Nothing changes until they accept.",
  strict: true,
  input_schema: {
    type: "object",
    additionalProperties: false,
    required: ["summary", "reason", "changes", "weeks"],
    properties: {
      summary: { type: "string", description: "One short line, e.g. 'Ease weeks 4-8 back by about 10%'." },
      reason: {
        type: "string",
        description:
          "2-4 sentences to the runner: what the change does and why. Shown with the change, so it stands on its own.",
      },
      changes: {
        type: "array",
        description: "One entry per changed week.",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["week", "change"],
          properties: {
            week: { type: "integer" },
            change: {
              type: "string",
              description: "A few words, e.g. 'About 10% less running; long run peaks at 30 min'.",
            },
          },
        },
      },
      weeks: { type: "array", description: "The revised weeks, each with all of its sessions.", items: WEEK_SCHEMA },
    },
  },
};

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
  body.record_id = body.record_id?.toLowerCase();
  body.message_id = body.message_id?.toLowerCase();

  switch (body.action) {
    case "send":
      return await send(supabase, userId, body);
    case "retry":
      return await retry(supabase, userId, body);
    case "clear":
      return await clear(supabase, userId);
    default:
      return json({ error: "Unknown action" }, 400);
  }
});

async function send(supabase: SupabaseClient, userId: string, body: Body) {
  const text = String(body.message ?? "").trim();
  if (!text) return json({ error: "Write a message first." }, 400);
  if (text.length > MAX_MESSAGE_LENGTH) {
    return json({ error: `Keep messages under ${MAX_MESSAGE_LENGTH} characters.` }, 400);
  }
  if (await isAnswering(supabase)) return json({ error: "Your coach is still answering your last message." }, 409);

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { count } = await supabase
    .from("coach_messages")
    .select("id", { count: "exact", head: true })
    .eq("role", "user")
    .gte("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return json({ error: `You can send your coach up to ${DAILY_LIMIT} messages a day. Try again tomorrow.` }, 429);
  }

  if (body.record_id) {
    const { data: record } = await supabase.from("workout_records").select("id").eq("id", body.record_id).maybeSingle();
    if (!record) return json({ error: "That run hasn't uploaded yet. Try again in a moment." }, 400);
  }

  const { data: question, error: questionError } = await supabase
    .from("coach_messages")
    .insert({ user_id: userId, role: "user", content: text, record_id: body.record_id ?? null })
    .select("id")
    .single();
  if (questionError || !question) return json({ error: "Couldn't send your message." }, 500);

  const { data: reply, error: replyError } = await supabase
    .from("coach_messages")
    .insert({ user_id: userId, role: "assistant", status: "generating", model: MODEL })
    .select("id")
    .single();
  if (replyError || !reply) {
    await supabase.from("coach_messages").delete().eq("id", question.id);
    return json({ error: "Couldn't send your message." }, 500);
  }

  EdgeRuntime.waitUntil(writeReply(supabase, userId, reply.id, dayFrom(body.today)));
  return json({ message_id: reply.id }, 202);
}

/** Writes the coach's last reply again after it failed (or was lost). */
async function retry(supabase: SupabaseClient, userId: string, body: Body) {
  if (!body.message_id) return json({ error: "Missing message" }, 400);
  const { data: latest } = await supabase
    .from("coach_messages")
    .select("id, role, status, updated_at")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (latest?.id !== body.message_id || latest.role !== "assistant") {
    return json({ error: "Only your coach's last reply can be tried again." }, 409);
  }
  const isLost = latest.status === "generating" && Date.now() - Date.parse(latest.updated_at) >= REPLY_TIMEOUT_MS;
  if (latest.status !== "failed" && !isLost) return json({ error: "This reply doesn't need trying again." }, 409);

  // Claims the reply, so two retries can't both write it.
  const { data: claimed } = await supabase
    .from("coach_messages")
    .update({ status: "generating", content: "", error: null, review_id: null, model: MODEL })
    .eq("id", latest.id)
    .eq("status", latest.status)
    .eq("updated_at", latest.updated_at)
    .select("id");
  if (!claimed?.length) return json({ error: "This reply doesn't need trying again." }, 409);

  EdgeRuntime.waitUntil(writeReply(supabase, userId, latest.id, dayFrom(body.today)));
  return json({ message_id: latest.id }, 202);
}

async function clear(supabase: SupabaseClient, userId: string) {
  const { error } = await supabase.from("coach_messages").delete().eq("user_id", userId);
  if (error) return json({ error: "Couldn't clear the conversation. Try again." }, 500);
  return json({ ok: true });
}

/** A reply is being written (and was saved recently enough not to count as lost). */
async function isAnswering(supabase: SupabaseClient) {
  const { count } = await supabase
    .from("coach_messages")
    .select("id", { count: "exact", head: true })
    .eq("status", "generating")
    .gte("updated_at", new Date(Date.now() - REPLY_TIMEOUT_MS).toISOString());
  return (count ?? 0) > 0;
}

// ---------------------------------------------------------------------------
// Writing a reply
// ---------------------------------------------------------------------------

async function writeReply(supabase: SupabaseClient, userId: string, replyId: string, today: Date) {
  const saver = new ReplySaver(supabase, replyId);
  let reviewId: string | null = null;
  try {
    const history = await loadHistory(supabase, replyId);
    const question = history.at(-1);
    if (question?.role !== "user") throw new Error("There's no message to answer.");

    const coaching = await coachingContext(supabase, question.record_id, today);
    const messages = conversation(history, await suggestionNotes(supabase, history), coaching.text);
    const reply = await converse(messages, coaching, saver, async (input) => {
      const outcome = await suggestChange(supabase, userId, coaching, input);
      if (outcome.reviewId) reviewId = outcome.reviewId;
      return outcome;
    });

    const content = reply.trim() || (reviewId ? "Here's a change to your plan. Take a look below." : "");
    if (!content) throw new Error("The reply was empty.");
    await saver.finish({ status: "ready", content, review_id: reviewId, program_id: coaching.program?.id ?? null });
  } catch (error) {
    console.error("coach-chat failed", error);
    await saver.finish({
      status: "failed",
      content: "",
      review_id: reviewId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/** Runs the conversation with Claude, suggesting a plan change when it calls
 * the tool, and returns the reply's text. */
async function converse(
  messages: MessageParam[],
  coaching: Coaching,
  saver: ReplySaver,
  suggest: (input: unknown) => Promise<ToolOutcome>,
): Promise<string> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  const tools = coaching.program ? [PROPOSE_TOOL] : [];
  let earlierText = "";
  let hasSuggested = false;

  for (let round = 0;; round++) {
    const stream = anthropic.beta.messages.stream({
      model: MODEL,
      max_tokens: 32000,
      // If a safety classifier declines, retry on Anthropic's recommended fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      // A suggested change rewrites weeks of the plan under the same rules as a
      // review, so it gets the same care.
      output_config: { effort: "medium" },
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      // Without a plan there's nothing to change. After a few rounds of tool
      // use, the coach answers in words.
      ...(tools.length > 0 ? { tools } : {}),
      ...(tools.length > 0 && round >= MAX_TOOL_ROUNDS ? { tool_choice: { type: "none" as const } } : {}),
      messages,
    });
    let streamed = "";
    stream.on("text", (delta) => {
      streamed += delta;
      saver.progress(joinText(earlierText, streamed));
    });
    const message = await stream.finalMessage();
    console.log("coach-chat usage", JSON.stringify(message.usage));

    if (message.stop_reason === "refusal") throw new Error("The message was declined.");
    if (message.stop_reason === "max_tokens") throw new Error("The reply was too long to finish.");
    earlierText = joinText(earlierText, textOf(message.content));

    const toolUses = afterFallback(message.content)
      .filter((block): block is Anthropic.Beta.Messages.BetaToolUseBlock => block.type === "tool_use");
    if (message.stop_reason !== "tool_use" || toolUses.length === 0) return earlierText;

    messages.push({ role: "assistant", content: echoable(message.content) });
    const results: ToolResult[] = [];
    for (const use of toolUses) {
      const outcome = hasSuggested
        ? { message: "You've already suggested a change in this reply. Finish your reply instead.", isError: true }
        : await suggest(use.input);
      if (outcome.reviewId) hasSuggested = true;
      results.push({ type: "tool_result", tool_use_id: use.id, content: outcome.message, is_error: outcome.isError });
    }
    messages.push({ role: "user", content: results });
  }
}

type ToolOutcome = { message: string; isError: boolean; reviewId?: string };

/** Turns a propose_plan_change call into a suggested change for the runner. */
async function suggestChange(
  supabase: SupabaseClient,
  userId: string,
  coaching: Coaching,
  input: unknown,
): Promise<ToolOutcome> {
  const program = coaching.program;
  if (!program) return { message: "The runner has no plan to change.", isError: true };
  const revision = input as RawRevision;
  if (!Array.isArray(revision?.weeks) || revision.weeks.length === 0) {
    return { message: "Include each week you're changing, with all of its sessions.", isError: true };
  }

  let proposal: Proposal;
  try {
    const summary = String(revision.summary ?? "").trim();
    proposal = proposalFrom(
      program.plan,
      revision,
      summary,
      mergeOptions(program.onboarding, coaching.done, coaching.today),
    );
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return {
      message:
        `That change can't be applied: ${reason} Check it against the plan's rules and try again, or tell the runner why it can't be done.`,
      isError: true,
    };
  }

  const { data: review, error } = await supabase
    .from("program_reviews")
    .insert({
      user_id: userId,
      program_id: program.id,
      trigger: "chat",
      status: "ready",
      feedback: proposal.reason,
      proposal,
      model: MODEL,
    })
    .select("id")
    .single();
  if (error || !review) {
    console.error("coach-chat: saving the suggestion failed", error);
    return {
      message: "Saving the suggestion failed. Tell the runner you couldn't put the change together just now.",
      isError: true,
    };
  }
  await supersedeProposals(supabase, program.id, review.id);
  return {
    message:
      "The runner now sees your suggestion under your message, with Accept change and Keep my plan buttons. Nothing has changed yet. Finish your reply in a sentence or two, without repeating the week-by-week details.",
    isError: false,
    reviewId: review.id,
  };
}

/** Saves a reply's text while it's written, at most every SAVE_INTERVAL_MS and
 * one write at a time, then its final state after every earlier write. */
class ReplySaver {
  private lastSaved = 0;
  private isSaving = false;
  private writes: Promise<void> = Promise.resolve();

  constructor(private supabase: SupabaseClient, private id: string) {}

  progress(content: string) {
    if (this.isSaving || Date.now() - this.lastSaved < SAVE_INTERVAL_MS) return;
    this.lastSaved = Date.now();
    this.isSaving = true;
    this.write({ content }).then(() => this.isSaving = false);
  }

  finish(fields: Record<string, unknown>) {
    return this.write(fields);
  }

  private write(fields: Record<string, unknown>) {
    this.writes = this.writes.then(async () => {
      // Only while generating: the conversation may have been cleared meanwhile.
      const { error } = await this.supabase
        .from("coach_messages")
        .update(fields)
        .eq("id", this.id)
        .eq("status", "generating");
      if (error) console.error("coach-chat: saving the reply failed", error);
    });
    return this.writes;
  }
}

// ---------------------------------------------------------------------------
// Conversation and context
// ---------------------------------------------------------------------------

/** The newest messages before the reply being written, oldest first. */
async function loadHistory(supabase: SupabaseClient, replyId: string): Promise<MessageRow[]> {
  const { data, error } = await supabase
    .from("coach_messages")
    .select("id, role, content, status, record_id, review_id")
    .neq("id", replyId)
    .order("created_at", { ascending: false })
    .limit(HISTORY_MESSAGES);
  if (error) throw new Error(`Loading the conversation failed: ${error.message}`);
  return ((data ?? []) as MessageRow[]).reverse();
}

/** For each earlier suggestion, what became of it. */
async function suggestionNotes(supabase: SupabaseClient, history: MessageRow[]) {
  const ids = history.map((row) => row.review_id).filter((id): id is string => id != null);
  const notes = new Map<string, string>();
  if (ids.length === 0) return notes;
  const { data } = await supabase.from("program_reviews").select("id, status, proposal").in("id", ids);
  for (const review of (data ?? []) as { id: string; status: string; proposal: Proposal | null }[]) {
    const summary = review.proposal?.summary ? ` "${review.proposal.summary}"` : "";
    const outcome = {
      ready: "They haven't accepted or dismissed it yet.",
      accepted: "They accepted it, so it's in their plan now.",
      dismissed: "They kept their plan instead.",
      superseded: "A newer suggestion replaced it.",
      reverted: "They accepted it, then undid it.",
    }[review.status] ?? "It's no longer open.";
    notes.set(review.id, `[You suggested a plan change${summary}. ${outcome}]`);
  }
  return notes;
}

/** The runner, their plan and their runs, as the context for the latest message. */
async function coachingContext(supabase: SupabaseClient, recordId: string | null, today: Date): Promise<Coaching> {
  const [{ data: programRow }, recent, asked] = await Promise.all([
    supabase
      .from("programs")
      .select("id, status, plan, onboarding")
      .eq("status", "active")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
    recentRecords(supabase),
    recordId ? loadRecord(supabase, recordId) : Promise.resolve(null),
  ]);
  const program = programRow?.plan ? programRow as ActiveProgram : null;
  const [linked, onboarding, openSuggestion] = await Promise.all([
    program ? programRecords(supabase, program.id) : Promise.resolve([] as RunRecord[]),
    // The plan's guardrails come from the answers it was built from.
    program ? Promise.resolve(program.onboarding ?? {}) : profileAnswers(supabase),
    program ? openSuggestionSummary(supabase, program.id) : Promise.resolve(null),
  ]);

  const done = doneSessionIds(linked);
  // A run from another plan has session ids that would match this plan's by accident.
  const signals = (record: RunRecord): RunSignals => {
    const run = runSignals(record);
    return record.program_id === program?.id ? run : { ...run, session_id: null };
  };
  const byId = new Map<string, RunRecord>();
  for (const record of [...linked, ...recent]) byId.set(record.id, record);
  const runs = [...byId.values()]
    .filter((record) => record.activity !== "walk")
    .sort((a, b) => Date.parse(b.started_at) - Date.parse(a.started_at))
    .slice(0, RECENT_RUNS)
    .map(signals);

  const sections: (string | null)[] = [`Today is ${isoDate(today)} (${DAYS[(today.getUTCDay() + 6) % 7]}).`];
  if (program) {
    const { plan } = program;
    const frame = planFrame(plan, onboarding, today);
    const missedIds = new Set(missedSessions(plan, done, today).map((session) => session.id));
    const planTrend = trend(linked.slice(0, 10).map(runSignals));
    sections.push(
      `The runner:\n${runnerText(onboarding, frame)}`,
      `Their plan "${plan.title}", which started ${plan.start_date}. Week ${frame.currentWeek} of ${plan.weeks.length} is the current week; a change can take the plan to week ${frame.lastAllowedWeek} at most. Each session: id, date, kind, title, workout, and its running time:\n${
        planOutline(plan, 1, done, missedIds, today) || "The plan has no weeks."
      }`,
      openSuggestion
        ? `Your open suggestion, which the runner hasn't accepted or dismissed yet: "${openSuggestion}". A new suggestion replaces it.`
        : null,
      `Trend over their last ${planTrend.runs_considered} plan runs: ${planTrend.too_hard_count} looked too hard, ${planTrend.too_easy_count} too easy, ${planTrend.incomplete_count} cut short.${
        planTrend.notes.map((note) => `\n- ${note}`).join("")
      }`,
    );
  } else {
    sections.push(
      `The runner:\n${runnerText(onboarding, { raceDate: parseDate(onboarding.race_date), raceWeek: null })}`,
      "They don't have a training plan right now.",
    );
  }
  sections.push(
    `Their recent runs (newest first; session_id is null for runs outside the plan):\n${
      runs.length > 0 ? runs.map((run) => JSON.stringify(run)).join("\n") : "None."
    }`,
  );
  if (recordId) {
    if (asked) {
      const inPlan = program != null && asked.program_id === program.id;
      const planned = inPlan && asked.program_session_id ? findSession(program.plan, asked.program_session_id) : null;
      sections.push(`They're asking about this run:
Planned: ${
        planned
          ? sessionLine(planned)
          : "not a session of their current plan (a free run, their own workout, or a run from an earlier plan)"
      }
What happened: ${JSON.stringify(signals(asked))}`);
    } else {
      sections.push("They're asking about one of their runs, but it couldn't be found (it may have been deleted).");
    }
  }

  return { program, done, today, text: sections.filter(Boolean).join("\n\n") };
}

/** The runner's current onboarding answers, for when there's no plan. */
async function profileAnswers(supabase: SupabaseClient): Promise<Onboarding> {
  const { data } = await supabase.from("profiles").select("onboarding").maybeSingle();
  return (data?.onboarding ?? {}) as Onboarding;
}

async function openSuggestionSummary(supabase: SupabaseClient, programId: string) {
  const { data } = await supabase
    .from("program_reviews")
    .select("proposal")
    .eq("program_id", programId)
    .eq("status", "ready")
    .not("proposal", "is", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data?.proposal as Proposal | undefined)?.summary ?? null;
}
