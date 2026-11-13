// What the AI coach shares between its plan reviews (`review-program`) and its
// chat (`coach-chat`): how it reads a runner's answers, plan and runs, the
// prompt text that explains them, and turning a revision from Claude into a
// suggested change (a `program_reviews` proposal) the runner accepts or dismisses.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { changedTail, type MergeOptions, mergeRevision, type RecordRow } from "./analysis.ts";
import {
  type Day,
  DAYS,
  isoDate,
  parseDate,
  type Plan,
  type PlanSession,
  type PlanWeek,
  type RawSession,
  type RawWorkout,
} from "./plan.ts";

/** The columns `RecordRow` needs, plus the ones used to pick which runs to look at. */
export const RECORD_COLUMNS =
  "id, name, started_at, completed, active_time, total_meters, intervals, program_id, program_session_id, effort, activity";
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/** The onboarding answers a plan was built from (`programs.onboarding`), as far as the coach uses them. */
export type Onboarding = {
  goal?: string;
  target_5k_minutes?: number | null;
  race_date?: string | null;
  training_days?: string[];
  max_session_minutes?: number;
  age_range?: string | null;
  injuries?: string;
};
export type ProgramRow = { id: string; status: string; plan: Plan | null; onboarding: Onboarding | null };
export type RunRecord = RecordRow & { program_id: string | null; activity: string | null };
/** `program_reviews.proposal`, as the app decodes it. */
export type Proposal = {
  reason: string;
  summary: string;
  changes: { week: number; change: string }[];
  weeks: PlanWeek[];
};
/** A suggested change as Claude writes it. */
export type RawRevision = {
  reason: string;
  summary: string;
  changes: { week: number; change: string }[];
  weeks: { week: number; focus: string; sessions: RawSession[] }[];
};

// ---------------------------------------------------------------------------
// Prompt text
// ---------------------------------------------------------------------------

export const WORKOUT_FORMAT = `How workouts are expressed:
- A workout is an optional warm-up, a round of work/rest steps repeated for a number of rounds, and an optional cool-down. All durations are whole seconds.
- "work" means running at the effort the session describes; "rest" means walking or very easy jogging.
- Easy, long and tempo runs are a single work step with rounds = 1 (for example a 25-minute easy run is one 1500-second work step).
- Run/walk sessions alternate work and rest steps.
- Every step is between 10 and 3599 seconds, a session has at most 20 steps per round and at most 50 rounds, and the whole session (warm-up and cool-down included) must fit within the runner's maximum session length.
- Warm-ups and cool-downs are usually a 3-5 minute brisk walk.`;

export const RUN_NUMBERS = `What the run numbers mean:
- completion_pct is the share of the planned running time they actually ran; skipped_work_intervals counts work intervals skipped or cut well short.
- Paces are minutes:seconds per mile. pace_fade_pct compares the end of the run with the start; positive means they slowed down.
- effort is how the runner said it felt: easy, just_right, hard or too_hard (null if they didn't say).
- Some runs include heart rate in beats per minute: work_avg_hr (average over work intervals), max_hr, hr_drift_bpm (how much higher it was in the last work interval than the first) and rest_recovery_bpm (how far it fell during rests; under about 20 bpm is small). Judge it with the runner's age range. Heart rate from different devices varies, so look at trends across runs rather than one reading, and never present it as medical advice.`;

/** Where today falls in the plan, and how far a change may take it. */
export type PlanFrame = {
  weekday: Day;
  currentWeek: number;
  raceDate: Date | null;
  raceWeek: number | null;
  /** The last week a revision can reach; mirrors the length limits `mergeRevision` enforces. */
  lastAllowedWeek: number;
};

export function planFrame(plan: Plan, onboarding: Onboarding, today: Date): PlanFrame {
  const start = parseDate(plan.start_date) ?? today;
  const raceDate = parseDate(onboarding.race_date);
  const raceWeek = raceDate ? weekNumber(start, raceDate) : null;
  return {
    weekday: DAYS[(today.getUTCDay() + 6) % 7],
    currentWeek: Math.max(1, weekNumber(start, today)),
    raceDate,
    raceWeek,
    lastAllowedWeek: raceWeek != null ? Math.min(raceWeek, 16) : Math.min(plan.weeks.length + 2, 16),
  };
}

/** The runner's answers, one per line. */
export function runnerText(onboarding: Onboarding, frame: Pick<PlanFrame, "raceDate" | "raceWeek">) {
  const { raceDate, raceWeek } = frame;
  return [
    `- Goal: ${onboarding.goal ?? "not given"}`,
    onboarding.target_5k_minutes ? `- Target 5K time: ${onboarding.target_5k_minutes} minutes` : null,
    `- Race date: ${
      raceDate ? `${isoDate(raceDate)}${raceWeek != null ? ` (week ${raceWeek} of the plan)` : ""}` : "none"
    }`,
    `- Training days: ${trainingDays(onboarding)?.join(", ") ?? "any"}`,
    `- Maximum session length: ${onboarding.max_session_minutes ?? 45} minutes`,
    `- Age range: ${onboarding.age_range ?? "not given"}`,
    onboarding.injuries?.trim() ? `- Injuries or health conditions: ${onboarding.injuries.trim()}` : null,
  ].filter(Boolean).join("\n");
}

/** The plan's weeks from `fromWeek` on, each session on its own line marked [done], [missed] or [today]. */
export function planOutline(plan: Plan, fromWeek: number, done: Set<string>, missedIds: Set<string>, today: Date) {
  const todayText = isoDate(today);
  return plan.weeks
    .filter((week) => week.week >= fromWeek)
    .map((week) => {
      const sessions = week.sessions.map((session) => {
        const status = done.has(session.id)
          ? " [done]"
          : missedIds.has(session.id)
          ? " [missed]"
          : session.date === todayText
          ? " [today]"
          : "";
        return `  ${sessionLine(session)}${status}`;
      });
      return [`Week ${week.week}: ${week.focus}`, ...sessions].join("\n");
    })
    .join("\n");
}

/** `w3-tue 2026-11-03 run_walk "Run/walk 6 × 2:00": warm-up 5:00, 6 × (work 2:00, rest 1:00), cool-down 5:00 = 12 min running` */
export function sessionLine(session: PlanSession) {
  return `${session.id} ${session.date} ${session.kind} "${session.title}": ${workoutText(session.workout)} = ${
    workMinutes(session.workout)
  } min running`;
}

function workoutText(workout: RawWorkout) {
  const steps = workout.steps.map((step) => `${step.phase} ${clock(step.seconds)}`).join(", ");
  return [
    workout.warm_up_seconds > 0 ? `warm-up ${clock(workout.warm_up_seconds)}` : null,
    workout.rounds > 1 ? `${workout.rounds} × (${steps})` : steps,
    workout.cool_down_seconds > 0 ? `cool-down ${clock(workout.cool_down_seconds)}` : null,
  ].filter(Boolean).join(", ");
}

function workMinutes(workout: RawWorkout) {
  const seconds = workout.steps.filter((step) => step.phase === "work").reduce((sum, step) => sum + step.seconds, 0);
  return Math.round((seconds * workout.rounds) / 6) / 10;
}

function clock(seconds: number) {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

// ---------------------------------------------------------------------------
// Suggested changes
// ---------------------------------------------------------------------------

/** The suggested change as stored: only the part of the plan that actually changes.
 * Throws if nothing valid is left of it (see `mergeRevision`), or it matches the plan. */
export function proposalFrom(
  plan: Plan,
  revision: RawRevision,
  fallbackReason: string,
  options: MergeOptions,
): Proposal {
  const tail = changedTail(plan, mergeRevision(plan, revision.weeks, options));
  if (tail.length === 0) throw new Error("The change matches the plan as it is.");

  const weeks = new Set(tail.map((week) => week.week));
  return {
    reason: String(revision.reason ?? "").trim() || fallbackReason,
    summary: String(revision.summary ?? "").trim(),
    changes: (revision.changes ?? [])
      .filter((change) => weeks.has(change.week))
      .map((change) => ({ week: change.week, change: String(change.change ?? "") }))
      .sort((a, b) => a.week - b.week),
    weeks: tail,
  };
}

/** Open suggestions for the plan other than `keepId`'s are replaced by it. */
export async function supersedeProposals(supabase: SupabaseClient, programId: string, keepId: string) {
  const { error } = await supabase
    .from("program_reviews")
    .update({ status: "superseded", resolved_at: new Date().toISOString() })
    .eq("program_id", programId)
    .eq("status", "ready")
    .not("proposal", "is", null)
    .neq("id", keepId);
  if (error) console.error("coach: superseding older suggestions failed", error);
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/** Every run linked to the plan, newest first. */
export async function programRecords(supabase: SupabaseClient, programId: string) {
  const { data, error } = await supabase
    .from("workout_records")
    .select(RECORD_COLUMNS)
    .eq("program_id", programId)
    .order("started_at", { ascending: false })
    .limit(300);
  if (error) throw new Error(`Loading the plan's runs failed: ${error.message}`);
  return (data ?? []) as unknown as RunRecord[];
}

/** One run, wherever it belongs. */
export async function loadRecord(supabase: SupabaseClient, recordId: string) {
  const { data, error } = await supabase.from("workout_records").select(RECORD_COLUMNS).eq("id", recordId)
    .maybeSingle();
  if (error) throw new Error(`Loading the run failed: ${error.message}`);
  return data as unknown as RunRecord | null;
}

/** The last 60 days of runs, newest first. */
export async function recentRecords(supabase: SupabaseClient) {
  const since = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString();
  const { data } = await supabase
    .from("workout_records")
    .select(RECORD_COLUMNS)
    .gte("started_at", since)
    .order("started_at", { ascending: false })
    .limit(30);
  return (data ?? []) as unknown as RunRecord[];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function mergeOptions(onboarding: Onboarding | null, done: Set<string>, today: Date): MergeOptions {
  return { done, today, trainingDays: trainingDays(onboarding), raceDate: parseDate(onboarding?.race_date) };
}

/** The runner's training days, or null when they didn't pick any. */
export function trainingDays(onboarding: Onboarding | null): Day[] | null {
  const days = (onboarding?.training_days ?? []).filter((day): day is Day => (DAYS as readonly string[]).includes(day));
  return days.length > 0 ? days : null;
}

export function findSession(plan: Plan, sessionId: string) {
  return plan.weeks.flatMap((week) => week.sessions).find((session) => session.id === sessionId) ?? null;
}

/** The runner's date (the app sends it, since it knows their time zone), at midnight UTC. */
export function dayFrom(value: string | undefined): Date {
  return parseDate(value) ?? parseDate(isoDate(new Date()))!;
}

/** 1-based week of the plan containing `date`. */
export function weekNumber(start: Date, date: Date) {
  return Math.floor(Math.round((date.getTime() - start.getTime()) / (WEEK_MS / 7)) / 7) + 1;
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
