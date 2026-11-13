// The pure part of the coach's plan reviews and chat: what a run says about how
// the plan is going (`runSignals`, `trend`), which sessions are done or missed,
// and how a revision from Claude is merged into the plan without breaking the
// guardrails (`mergeRevision`). No I/O, so it's covered by `analysis.test.ts`.

import {
  addDays,
  DAYS,
  type Day,
  heartRateSummary,
  isoDate,
  normalizeWorkout,
  pace,
  parseDate,
  type Plan,
  type PlanSession,
  type PlanWeek,
  type RawSession,
  type RecordedInterval,
} from "./plan.ts";

export type Effort = "easy" | "just_right" | "hard" | "too_hard";

/** A row of `workout_records`, with the columns the review reads. */
export type RecordRow = {
  id: string;
  name: string;
  started_at: string;
  completed: boolean;
  active_time: number;
  total_meters: number | null;
  intervals: RecordedInterval[];
  program_session_id: string | null;
  effort: Effort | null;
};

// ---------------------------------------------------------------------------
// One run
// ---------------------------------------------------------------------------

/** Intervals shorter than this were skipped before they started (the app's `wasSkipped`). */
const MIN_ACTIVE_SECONDS = 0.5;
/** A work interval run for less than this share of its planned time counts as skipped. */
export const SHORT_REP_SHARE = 0.75;
/** Reps need at least this much distance for a pace (shorter GPS readings are noise). */
const MIN_REP_METERS = 50;
/** With this many paced reps or more, fade compares the first third with the last third
 * (so one odd rep doesn't decide it); with fewer, the first rep with the last. */
export const FADE_THIRDS_MIN_REPS = 6;

export type RunSignals = {
  date: string;
  workout: string;
  session_id: string | null;
  completed: boolean;
  effort: Effort | null;
  planned_work_minutes: number;
  actual_work_minutes: number;
  completion_pct: number;
  skipped_work_intervals: number;
  work_pace_per_mile: string | null;
  first_rep_pace: string | null;
  last_rep_pace: string | null;
  /** + = slower at the end. */
  pace_fade_pct: number | null;
  work_avg_hr: number | null;
  max_hr: number | null;
  /** Last work interval's average heart rate − the first's. */
  hr_drift_bpm: number | null;
  rest_recovery_bpm: number | null;
};

/** The numbers the coach looks at for one run. */
export function runSignals(record: RecordRow): RunSignals {
  const intervals = record.intervals ?? [];
  const planned = intervals.filter((i) => i.phase === "work");
  // Records without planned lengths fall back to the time actually run.
  const plannedSeconds = (i: RecordedInterval) => i.plannedSeconds ?? i.activeSeconds;
  const work = planned.filter((i) => i.activeSeconds >= MIN_ACTIVE_SECONDS);

  const plannedWork = planned.reduce((sum, i) => sum + plannedSeconds(i), 0);
  const actualWork = work.reduce((sum, i) => sum + Math.min(i.activeSeconds, plannedSeconds(i)), 0);
  const skipped = planned.filter(
    (i) => i.activeSeconds < MIN_ACTIVE_SECONDS || i.activeSeconds < plannedSeconds(i) * SHORT_REP_SHARE,
  ).length;

  const paced = work.filter((i) => (i.meters ?? 0) > MIN_REP_METERS);
  const pacedMeters = paced.reduce((sum, i) => sum + i.meters!, 0);
  const pacedSeconds = paced.reduce((sum, i) => sum + i.activeSeconds, 0);
  const first = paced[0];
  const last = paced[paced.length - 1];

  const measured = work.filter((i) => i.heartRate);
  const heartRate = heartRateSummary(intervals);

  return {
    date: record.started_at.slice(0, 10),
    workout: record.name,
    session_id: record.program_session_id,
    completed: record.completed,
    effort: record.effort,
    planned_work_minutes: round1(plannedWork / 60),
    actual_work_minutes: round1(actualWork / 60),
    completion_pct: plannedWork > 0 ? Math.round(Math.min(1, actualWork / plannedWork) * 100) : record.completed ? 100 : 0,
    skipped_work_intervals: skipped,
    work_pace_per_mile: pacedMeters > MIN_REP_METERS ? pace(pacedSeconds, pacedMeters) : null,
    first_rep_pace: first ? pace(first.activeSeconds, first.meters!) : null,
    last_rep_pace: paced.length > 1 ? pace(last.activeSeconds, last.meters!) : null,
    pace_fade_pct: paceFade(paced),
    work_avg_hr: heartRate.work_avg_hr ?? null,
    max_hr: heartRate.max_hr ?? null,
    hr_drift_bpm: measured.length > 1
      ? Math.round(measured[measured.length - 1].heartRate!.average - measured[0].heartRate!.average)
      : null,
    rest_recovery_bpm: heartRate.rest_recovery_bpm ?? null,
  };
}

/** How much slower (+) or faster (−) the end of the run was than the start, in percent. */
function paceFade(reps: RecordedInterval[]): number | null {
  if (reps.length < 2) return null;
  const size = reps.length >= FADE_THIRDS_MIN_REPS ? Math.floor(reps.length / 3) : 1;
  const secondsPerMeter = (group: RecordedInterval[]) =>
    group.reduce((sum, i) => sum + i.activeSeconds, 0) / group.reduce((sum, i) => sum + i.meters!, 0);
  const start = secondsPerMeter(reps.slice(0, size));
  const end = secondsPerMeter(reps.slice(-size));
  return round1((end / start - 1) * 100);
}

// ---------------------------------------------------------------------------
// Recent trend
// ---------------------------------------------------------------------------

/** Only the newest runs count towards the trend. */
export const TREND_RUNS = 6;
/** Below this share of planned work time, a run counts as cut short. */
export const INCOMPLETE_PCT = 90;
/** Slowing by more than this from the first reps to the last suggests the run was too hard. */
export const FADE_TOO_HARD_PCT = 8;
/** An easy run shouldn't slow by more than this. */
export const FADE_EASY_MAX_PCT = 3;
/** Heart rate dropping less than this during rests suggests the work was too hard. */
export const LOW_RECOVERY_BPM = 20;
/** An easy run's rests drop heart rate at least this much (when it was recorded). */
export const GOOD_RECOVERY_BPM = 25;

export type Trend = {
  runs_considered: number;
  too_hard_count: number;
  too_easy_count: number;
  incomplete_count: number;
  /** Plain-English observations for the prompt. */
  notes: string[];
};

function isIncomplete(run: RunSignals) {
  return !run.completed || run.completion_pct < INCOMPLETE_PCT;
}

/** Rated hard, cut short, slowing a lot, or slow heart rate recovery: any one is enough. */
export function looksTooHard(run: RunSignals) {
  return run.effort === "hard" || run.effort === "too_hard" || isIncomplete(run) ||
    (run.pace_fade_pct ?? 0) > FADE_TOO_HARD_PCT ||
    (run.rest_recovery_bpm != null && run.rest_recovery_bpm < LOW_RECOVERY_BPM);
}

/** Rated easy, done in full, steady pace and quick recovery: all of them. */
export function looksTooEasy(run: RunSignals) {
  return run.effort === "easy" && !isIncomplete(run) &&
    (run.pace_fade_pct ?? 0) <= FADE_EASY_MAX_PCT &&
    (run.rest_recovery_bpm == null || run.rest_recovery_bpm >= GOOD_RECOVERY_BPM);
}

/** Patterns across the newest runs (`signals` is newest first). */
export function trend(signals: RunSignals[]): Trend {
  const runs = signals.slice(0, TREND_RUNS);
  const count = (test: (run: RunSignals) => boolean) => runs.filter(test).length;
  const tooHard = count(looksTooHard);
  const tooEasy = count(looksTooEasy);
  const incomplete = count(isIncomplete);
  const n = runs.length;
  const notes: string[] = [];

  if (n === 0) {
    notes.push("No runs from this plan recorded yet.");
  } else {
    const ratedHard = count((run) => run.effort === "hard" || run.effort === "too_hard");
    const ratedTooHard = count((run) => run.effort === "too_hard");
    const ratedEasy = count((run) => run.effort === "easy");
    const fading = count((run) => (run.pace_fade_pct ?? 0) > FADE_TOO_HARD_PCT);
    const slowRecovery = count((run) => run.rest_recovery_bpm != null && run.rest_recovery_bpm < LOW_RECOVERY_BPM);
    const skipping = count((run) => run.skipped_work_intervals > 0);

    if (ratedHard > 0) {
      notes.push(`Rated ${runsText(ratedHard, n)} hard or too hard${ratedTooHard > 0 ? ` (${ratedTooHard} too hard)` : ""}.`);
    }
    if (ratedEasy > 0) notes.push(`Rated ${runsText(ratedEasy, n)} easy.`);
    if (incomplete > 0) notes.push(`Did less than ${INCOMPLETE_PCT}% of the planned running, or stopped early, in ${runsText(incomplete, n)}.`);
    if (skipping > 0) notes.push(`Skipped or cut short work intervals in ${runsText(skipping, n)}.`);
    if (fading > 0) notes.push(`Slowed by more than ${FADE_TOO_HARD_PCT}% from the first reps to the last in ${runsText(fading, n)}.`);
    if (slowRecovery > 0) {
      notes.push(`Heart rate dropped less than ${LOW_RECOVERY_BPM} bpm during rests in ${runsText(slowRecovery, n)}.`);
    }

    const streak = (test: (run: RunSignals) => boolean) => {
      const index = runs.findIndex((run) => !test(run));
      return index === -1 ? n : index;
    };
    const hardStreak = streak(looksTooHard);
    const easyStreak = streak(looksTooEasy);
    if (hardStreak >= 2) notes.push(`The last ${hardStreak} runs in a row looked too hard.`);
    if (easyStreak >= 2) notes.push(`The last ${easyStreak} runs in a row looked too easy.`);
    if (tooHard === 0 && tooEasy === 0) notes.push(`No sign the plan is too hard or too easy across ${runsText(n, n)}.`);
    if (n === 1) notes.push("Only one run so far, so there's no trend yet.");
  }

  return { runs_considered: n, too_hard_count: tooHard, too_easy_count: tooEasy, incomplete_count: incomplete, notes };
}

/** "2 of the last 5 runs", "the last run", "both recent runs", "all 3 recent runs". */
function runsText(count: number, total: number) {
  if (total === 1) return "the last run";
  if (count === total) return total === 2 ? "both recent runs" : `all ${total} recent runs`;
  return `${count} of the last ${total} runs`;
}

// ---------------------------------------------------------------------------
// Done and missed sessions
// ---------------------------------------------------------------------------

/** Sessions with a completed run (records already filtered to the program). */
export function doneSessionIds(records: RecordRow[]): Set<string> {
  return new Set(
    records.filter((record) => record.completed && record.program_session_id)
      .map((record) => record.program_session_id!),
  );
}

/** Sessions dated before today and not done, oldest first. With `since`, only those
 * on or after that day (a session on the day of the last review was still "today" then). */
export function missedSessions(plan: Plan, done: Set<string>, today: Date, since?: Date): PlanSession[] {
  const todayText = isoDate(today);
  const sinceText = since ? isoDate(since) : null;
  return plan.weeks.flatMap((week) => week.sessions)
    .filter((session) => !done.has(session.id) && session.date < todayText)
    .filter((session) => sinceText === null || session.date >= sinceText)
    .sort((a, b) => a.date.localeCompare(b.date));
}

// ---------------------------------------------------------------------------
// Merging a revision. Weeks are numbered from 1; week n starts on
// start_date + 7(n − 1) days.
// ---------------------------------------------------------------------------

export type MergeOptions = {
  done: Set<string>;
  today: Date;
  /** The runner's training days; null (or empty) for no restriction. */
  trainingDays: Day[] | null;
  raceDate: Date | null;
  /** Without a race date, how many weeks longer the plan may get. Default 2. */
  maxExtraWeeks?: number;
  /** The plan never goes past this many weeks. Default 16. */
  maxWeeks?: number;
};

type RevisedWeek = { week: number; focus: string; sessions: RawSession[] };

/** Revised weeks (raw from Claude, or a stored proposal's weeks) → the full new plan.
 *
 * - Weeks before the first revised week stay exactly as they are. Revised weeks before
 *   the week containing today, or past the length limit, are ignored.
 * - From the first revised week to the end, every week is rebuilt: a week Claude didn't
 *   send keeps its current sessions, run through the same checks.
 * - Done sessions and sessions dated before today are kept exactly as they are; new
 *   sessions on their day, before today, or off the training days are dropped.
 * - Workouts are clamped by `normalizeWorkout`, one session per day, ids `w{week}-{day}`
 *   and dates from `start_date`.
 * - Length: with a race date, no weeks after race week; otherwise at most `maxExtraWeeks`
 *   longer than now; never more than `maxWeeks`. Weeks holding a done session are kept.
 *
 * Merging `changedTail(plan, merged)` into `plan` again gives `merged` (that's how a
 * stored proposal is re-applied on accept). If the revision matches the plan, the plan
 * comes back as it was (and `changedTail` is empty).
 * Throws if nothing valid is left to change: no revised week that can still change, or
 * a changed part with no sessions left to run. */
export function mergeRevision(plan: Plan, revised: RevisedWeek[], options: MergeOptions): Plan {
  const start = parseDate(plan.start_date);
  if (!start) throw new Error("The plan has no valid start date.");
  const { done, today } = options;
  const todayText = isoDate(today);
  const maxWeeks = options.maxWeeks ?? 16;
  const maxExtraWeeks = options.maxExtraWeeks ?? 2;
  const allowedDays = (options.trainingDays ?? []).filter((day) => DAYS.includes(day));
  const original = plan.weeks;

  const currentWeek = Math.max(1, weekNumberOf(start, today));
  const limit = options.raceDate
    ? Math.min(weekNumberOf(start, options.raceDate), maxWeeks)
    : Math.min(original.length + maxExtraWeeks, maxWeeks);

  const isProtected = (session: PlanSession) => done.has(session.id) || session.date < todayText;
  const lastDoneWeek = original.reduce(
    (last, week, index) => (week.sessions.some((session) => done.has(session.id)) ? index + 1 : last),
    0,
  );

  // The first copy of each usable week number wins. Weeks past the limit that hold a
  // done session are usable too (nothing new goes in them), so a tail that ends in
  // one can be merged again.
  const byWeek = new Map<number, RevisedWeek>();
  for (const week of revised ?? []) {
    const number = week?.week;
    if (!Number.isInteger(number) || number < currentWeek || byWeek.has(number)) continue;
    if (number > Math.max(limit, lastDoneWeek)) continue;
    byWeek.set(number, week);
  }
  if (byWeek.size === 0) throw new Error("The revision had no weeks that can still change.");
  const firstRevised = Math.min(...byWeek.keys());
  const length = Math.max(Math.min(Math.max(original.length, ...byWeek.keys()), limit), lastDoneWeek);

  const weeks: PlanWeek[] = original.slice(0, firstRevised - 1);
  // Starts at the plan's old end when the first revised week is past it, leaving the gap empty.
  for (let number = weeks.length + 1; number <= length; number++) {
    const current = original[number - 1];
    const kept = (current?.sessions ?? []).filter(isProtected);
    const source = byWeek.get(number);
    // Past the limit (only reached to keep a done session), nothing new is added.
    const candidates = number > limit ? [] : source ? source.sessions ?? [] : current?.sessions ?? [];

    const taken = new Set<Day>(kept.map((session) => session.day));
    const sessions: PlanSession[] = [...kept];
    for (const session of candidates) {
      const day = session?.day;
      if (!DAYS.includes(day) || taken.has(day)) continue;
      if (allowedDays.length > 0 && !allowedDays.includes(day)) continue;
      const date = isoDate(addDays(start, (number - 1) * 7 + DAYS.indexOf(day)));
      if (date < todayText) continue;
      const workout = normalizeWorkout(session.workout);
      if (!workout) continue;
      taken.add(day);
      sessions.push({
        id: `w${number}-${day}`,
        day,
        date,
        kind: String(session.kind ?? ""),
        title: String(session.title ?? "").slice(0, 60),
        description: String(session.description ?? ""),
        workout,
      });
    }
    sessions.sort((a, b) => DAYS.indexOf(a.day) - DAYS.indexOf(b.day));
    weeks.push({ week: number, focus: String((source ?? current)?.focus ?? ""), sessions });
  }

  const merged = { ...plan, weeks };
  // Checked on the changed part only, so merging that part again gives the same answer.
  const tail = changedTail(plan, merged);
  if (tail.length > 0 && !tail.some((week) => week.sessions.some((session) => !isProtected(session)))) {
    throw new Error("The revision had no sessions that can still be scheduled.");
  }
  return merged;
}

/** The tail of `merged` from the first week that differs from `original`. Empty when
 * nothing changed. When the only change is that weeks were cut off the end, it's the
 * new last week, so merging the tail again reproduces the cut. */
export function changedTail(original: Plan, merged: Plan): PlanWeek[] {
  const index = merged.weeks.findIndex((week, i) => !sameValue(week, original.weeks[i]));
  if (index !== -1) return merged.weeks.slice(index);
  if (merged.weeks.length < original.weeks.length && merged.weeks.length > 0) return merged.weeks.slice(-1);
  return [];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** 1-based week of the plan containing `date` (0 or less before the plan starts). */
function weekNumberOf(start: Date, date: Date) {
  return Math.floor(Math.round((date.getTime() - start.getTime()) / 86_400_000) / 7) + 1;
}

/** Deep equality that ignores key order (jsonb doesn't keep it). */
function sameValue(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const aKeys = Object.keys(a).filter((key) => (a as Record<string, unknown>)[key] !== undefined);
  const bKeys = Object.keys(b).filter((key) => (b as Record<string, unknown>)[key] !== undefined);
  if (aKeys.length !== bKeys.length) return false;
  return aKeys.every((key) =>
    sameValue((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key])
  );
}

function round1(value: number) {
  return Math.round(value * 10) / 10;
}
