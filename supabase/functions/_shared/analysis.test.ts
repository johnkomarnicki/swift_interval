// deno test supabase/functions/review-program/analysis.test.ts

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import type { Day, Plan, PlanSession, PlanWeek, RawSession, RawWorkout, RecordedInterval } from "./plan.ts";
import {
  changedTail,
  doneSessionIds,
  FADE_EASY_MAX_PCT,
  FADE_TOO_HARD_PCT,
  GOOD_RECOVERY_BPM,
  INCOMPLETE_PCT,
  LOW_RECOVERY_BPM,
  type MergeOptions,
  mergeRevision,
  missedSessions,
  type RecordRow,
  runSignals,
  type RunSignals,
  trend,
  TREND_RUNS,
} from "./analysis.ts";

// ---------------------------------------------------------------------------
// Fixtures: a 6-week plan starting Monday 2026-10-05, sessions Tue/Thu/Sat.
// "Today" is Thursday 2026-10-22, in week 3.
// ---------------------------------------------------------------------------

const DAY_OFFSET: Record<Day, number> = { mon: 0, tue: 1, wed: 2, thu: 3, fri: 4, sat: 5, sun: 6 };

function workout(workSeconds: number, rounds = 1, restSeconds = 0): RawWorkout {
  return {
    warm_up_seconds: 300,
    steps: restSeconds > 0
      ? [{ phase: "work", seconds: workSeconds }, { phase: "rest", seconds: restSeconds }]
      : [{ phase: "work", seconds: workSeconds }],
    rounds,
    skip_last_rest: true,
    cool_down_seconds: 300,
  };
}

function session(week: number, day: Day, title: string, seconds = 1200): PlanSession {
  const date = new Date(Date.UTC(2026, 9, 5 + (week - 1) * 7 + DAY_OFFSET[day]));
  return {
    id: `w${week}-${day}`,
    day,
    date: date.toISOString().slice(0, 10),
    kind: "easy",
    title,
    description: "Conversational effort.",
    workout: workout(seconds),
  };
}

function makePlan(weeks = 6): Plan {
  return {
    title: "8-week 5K builder",
    summary: "Builds to 30 minutes.",
    start_date: "2026-10-05",
    weeks: Array.from({ length: weeks }, (_, i) => ({
      week: i + 1,
      focus: `Week ${i + 1}`,
      sessions: (["tue", "thu", "sat"] as Day[]).map((day) => session(i + 1, day, `Easy ${i + 1}${day}`)),
    })),
  };
}

const TODAY = new Date("2026-10-22T00:00:00Z");
const DONE = new Set(["w1-tue", "w1-thu", "w1-sat", "w2-tue", "w2-sat", "w3-tue"]);

function options(overrides: Partial<MergeOptions> = {}): MergeOptions {
  return { done: DONE, today: TODAY, trainingDays: ["tue", "thu", "sat"], raceDate: null, ...overrides };
}

/** A revised week as Claude would send it (no ids or dates). */
function revisedWeek(week: number, days: Day[], title = "Revised", seconds = 900) {
  return {
    week,
    focus: `Revised ${week}`,
    sessions: days.map((day): RawSession => ({
      day,
      kind: "easy",
      title: `${title} ${week}${day}`,
      description: "Easier.",
      workout: workout(seconds),
    })),
  };
}

function weekOf(plan: Plan, number: number): PlanWeek {
  return plan.weeks.find((week) => week.week === number)!;
}

// ---------------------------------------------------------------------------
// mergeRevision
// ---------------------------------------------------------------------------

Deno.test("weeks before the first revised week stay exactly as they are", () => {
  const plan = makePlan();
  const merged = mergeRevision(plan, [revisedWeek(4, ["tue", "thu", "sat"])], options());
  assertEquals(merged.weeks.slice(0, 3), plan.weeks.slice(0, 3));
  assert(merged.weeks[0] === plan.weeks[0]);
  assertEquals(weekOf(merged, 4).sessions.map((s) => s.title), ["Revised 4tue", "Revised 4thu", "Revised 4sat"]);
  assertEquals(weekOf(merged, 4).focus, "Revised 4");
  assertEquals(merged.title, plan.title);
  assertEquals(merged.start_date, plan.start_date);
});

Deno.test("done and past sessions are kept and revised sessions clashing with them are dropped", () => {
  const plan = makePlan();
  // Week 3: Tue is done, Wed is before today, Thu is today, Sat is ahead.
  const merged = mergeRevision(plan, [revisedWeek(3, ["tue", "wed", "thu", "sat"])], options({ trainingDays: null }));
  const week3 = weekOf(merged, 3);
  assertEquals(week3.sessions.map((s) => s.id), ["w3-tue", "w3-thu", "w3-sat"]);
  assertEquals(week3.sessions[0], plan.weeks[2].sessions[0]);
  assertEquals(week3.sessions[1].title, "Revised 3thu");
  assertEquals(week3.sessions[2].title, "Revised 3sat");
});

Deno.test("missed sessions before today stay in the plan", () => {
  const plan = makePlan();
  // w2-thu was missed; revising week 2 is ignored (it's before the current week), but a
  // missed session in the current week would also be kept as it is.
  const merged = mergeRevision(plan, [revisedWeek(2, ["thu"]), revisedWeek(3, ["thu"])], options());
  assertEquals(merged.weeks[1], plan.weeks[1]);
  const planWithMissed = makePlan();
  const doneOnlyTue = new Set(["w1-tue"]);
  const again = mergeRevision(
    planWithMissed,
    [revisedWeek(3, ["tue", "thu"])],
    options({ done: doneOnlyTue }),
  );
  // w3-tue (2026-10-20) wasn't done but is before today, so it stays.
  assertEquals(weekOf(again, 3).sessions[0], planWithMissed.weeks[2].sessions[0]);
});

Deno.test("only the runner's training days are scheduled", () => {
  const plan = makePlan();
  const revised = [revisedWeek(4, ["mon", "tue", "fri", "sat"])];
  const merged = mergeRevision(plan, revised, options());
  assertEquals(weekOf(merged, 4).sessions.map((s) => s.day), ["tue", "sat"]);

  const anyDay = mergeRevision(plan, revised, options({ trainingDays: null }));
  assertEquals(weekOf(anyDay, 4).sessions.map((s) => s.day), ["mon", "tue", "fri", "sat"]);
  const emptyDays = mergeRevision(plan, revised, options({ trainingDays: [] }));
  assertEquals(weekOf(emptyDays, 4).sessions.length, 4);
});

Deno.test("workouts are clamped like generate-program and unplayable ones dropped", () => {
  const plan = makePlan();
  const week = revisedWeek(4, ["tue", "thu", "sat"]);
  week.sessions[0].workout = { ...workout(5000), rounds: 99, warm_up_seconds: -10 };
  week.sessions[0].title = "x".repeat(80);
  week.sessions[1].workout = { ...workout(600), steps: [{ phase: "rest", seconds: 600 }] };
  const merged = mergeRevision(plan, [week], options());
  const sessions = weekOf(merged, 4).sessions;
  assertEquals(sessions.map((s) => s.day), ["tue", "sat"]);
  assertEquals(sessions[0].workout.steps[0].seconds, 3599);
  assertEquals(sessions[0].workout.rounds, 50);
  assertEquals(sessions[0].workout.warm_up_seconds, 0);
  assertEquals(sessions[0].title.length, 60);
});

Deno.test("ids and dates are recomputed and there's one session per day", () => {
  const plan = makePlan();
  const week = revisedWeek(4, ["sat", "tue", "tue"]);
  // As if Claude (or a tampered proposal) sent its own ids and dates.
  Object.assign(week.sessions[0], { id: "bogus", date: "2030-01-01" });
  week.sessions[2].title = "Second Tuesday";
  const merged = mergeRevision(plan, [week], options());
  assertEquals(
    weekOf(merged, 4).sessions.map((s) => [s.id, s.date, s.title]),
    [["w4-tue", "2026-10-27", "Revised 4tue"], ["w4-sat", "2026-10-31", "Revised 4sat"]],
  );
});

Deno.test("weeks after the first revised week that Claude didn't send keep their sessions", () => {
  const plan = makePlan();
  const merged = mergeRevision(plan, [revisedWeek(4, ["tue"])], options());
  assertEquals(merged.weeks.length, 6);
  assertEquals(merged.weeks.slice(4), plan.weeks.slice(4));
});

Deno.test("with a race date there are no weeks after race week", () => {
  const plan = makePlan();
  // Race on Thursday 2026-11-05: week 5.
  const revised = [4, 5, 6, 7].map((n) => revisedWeek(n, ["tue", "sat"]));
  const merged = mergeRevision(plan, revised, options({ raceDate: new Date("2026-11-05T00:00:00Z") }));
  assertEquals(merged.weeks.map((w) => w.week), [1, 2, 3, 4, 5]);
  // A race before today leaves nothing to change.
  assertThrows(() => mergeRevision(plan, revised, options({ raceDate: new Date("2026-10-12T00:00:00Z") })));
});

Deno.test("without a race date the plan grows by at most maxExtraWeeks and never past maxWeeks", () => {
  const plan = makePlan();
  const revised = [4, 5, 6, 7, 8, 9, 10].map((n) => revisedWeek(n, ["tue", "sat"]));
  assertEquals(mergeRevision(plan, revised, options()).weeks.length, 8);
  assertEquals(mergeRevision(plan, revised, options({ maxExtraWeeks: 4 })).weeks.length, 10);
  assertEquals(mergeRevision(plan, revised, options({ maxWeeks: 7 })).weeks.length, 7);
  const long = makePlan(16);
  assertEquals(mergeRevision(long, [revisedWeek(17, ["tue"]), revisedWeek(16, ["tue"])], options()).weeks.length, 16);
});

Deno.test("a gap between the old end and new weeks becomes an empty week", () => {
  const plan = makePlan();
  const merged = mergeRevision(plan, [revisedWeek(8, ["tue"])], options());
  assertEquals(merged.weeks.map((w) => w.week), [1, 2, 3, 4, 5, 6, 7, 8]);
  assertEquals(weekOf(merged, 7), { week: 7, focus: "", sessions: [] });
});

Deno.test("revised weeks before the current week are ignored", () => {
  const plan = makePlan();
  const merged = mergeRevision(plan, [revisedWeek(1, ["tue"]), revisedWeek(2, ["thu"]), revisedWeek(4, ["tue"])], options());
  assertEquals(merged.weeks.slice(0, 3), plan.weeks.slice(0, 3));
  assertEquals(weekOf(merged, 4).sessions.map((s) => s.title), ["Revised 4tue"]);
  assertThrows(() => mergeRevision(plan, [revisedWeek(1, ["tue"]), revisedWeek(2, ["thu"])], options()));
});

Deno.test("throws when nothing valid is left", () => {
  const plan = makePlan();
  assertThrows(() => mergeRevision(plan, [], options()));
  assertThrows(() => mergeRevision(plan, [{ week: 2.5, focus: "", sessions: [] }], options()));
  // Every session on a non-training day: the changed weeks would have nothing to run.
  const offDays = [4, 5, 6].map((n) => revisedWeek(n, ["mon", "wed"]));
  assertThrows(() => mergeRevision(plan, offDays, options()), Error, "no sessions");
});

Deno.test("a revision that matches the plan returns it unchanged", () => {
  const plan = makePlan();
  const merged = mergeRevision(plan, plan.weeks.slice(3), options());
  assertEquals(merged, plan);
  assertEquals(changedTail(plan, merged), []);
});

Deno.test("a done session in a week after race week keeps that week", () => {
  const plan = makePlan();
  const done = new Set([...DONE, "w6-tue"]);
  const merged = mergeRevision(
    plan,
    [revisedWeek(4, ["tue", "thu"]), revisedWeek(5, ["tue"])],
    options({ done, raceDate: new Date("2026-11-05T00:00:00Z") }),
  );
  assertEquals(merged.weeks.length, 6);
  assertEquals(weekOf(merged, 6).sessions, [plan.weeks[5].sessions[0]]);
});

// ---------------------------------------------------------------------------
// Idempotence and changedTail
// ---------------------------------------------------------------------------

/** What a value looks like after a round trip through a jsonb column (keys reordered). */
function viaJsonb<T>(value: T): T {
  const sortKeys = (v: unknown): unknown =>
    Array.isArray(v)
      ? v.map(sortKeys)
      : v && typeof v === "object"
      ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => b.localeCompare(a)).map(([k, x]) => [k, sortKeys(x)]))
      : v;
  return sortKeys(JSON.parse(JSON.stringify(value))) as T;
}

Deno.test("merging a stored proposal's weeks into the same plan gives the same plan", () => {
  const cases: [string, ReturnType<typeof revisedWeek>[], Partial<MergeOptions>][] = [
    ["ease weeks 3-6", [3, 4, 5, 6].map((n) => revisedWeek(n, ["tue", "wed", "thu", "sat"])), { trainingDays: null }],
    ["unchanged first week", [makePlan().weeks[3], revisedWeek(5, ["tue"]), revisedWeek(6, ["sat"])], {}],
    ["extend", [4, 5, 6, 7, 8, 9].map((n) => revisedWeek(n, ["tue", "fri", "sat"])), {}],
    ["race cut", [4].map((n) => revisedWeek(n, ["tue"])), { raceDate: new Date("2026-11-05T00:00:00Z") }],
    ["race cut only", [makePlan().weeks[3]], { raceDate: new Date("2026-11-05T00:00:00Z") }],
  ];
  for (const [name, revised, overrides] of cases) {
    const plan = makePlan();
    const merged = mergeRevision(plan, revised, options(overrides));
    const proposal = viaJsonb(changedTail(plan, merged));
    assert(proposal.length > 0, name);
    const again = mergeRevision(viaJsonb(plan), proposal, options(overrides));
    assertEquals(viaJsonb(again), viaJsonb(merged), name);
    assertEquals(changedTail(plan, again).length, proposal.length, name);
  }
});

Deno.test("changedTail starts at the first week that differs", () => {
  const plan = makePlan();
  assertEquals(changedTail(plan, viaJsonb(plan)), []);

  const merged = mergeRevision(plan, [makePlan().weeks[3], revisedWeek(5, ["tue"])], options());
  assertEquals(changedTail(plan, merged).map((w) => w.week), [5, 6]);

  const longer = mergeRevision(plan, [revisedWeek(7, ["tue"])], options());
  assertEquals(changedTail(plan, longer).map((w) => w.week), [7]);

  const shorter = { ...plan, weeks: plan.weeks.slice(0, 4) };
  assertEquals(changedTail(plan, shorter).map((w) => w.week), [4]);
});

// ---------------------------------------------------------------------------
// runSignals
// ---------------------------------------------------------------------------

/** 5-minute warm-up, 6 × (90 s work / 2 min rest) with the last rest skipped, 5-minute cool-down. */
function intervalRun(): RecordedInterval[] {
  const reps = [
    { meters: 310, hr: 150 },
    { meters: 305, hr: 155 },
    { meters: 300, hr: 160 },
    { meters: 295, hr: 163 },
    { meters: 280, hr: 166 },
    { meters: 270, hr: 170 },
  ];
  const restEnds = [130, 137, 143, 148, 152];
  const intervals: RecordedInterval[] = [
    { phase: "warmUp", plannedSeconds: 300, activeSeconds: 300, meters: 600, heartRate: { average: 110, max: 125, end: 120 } },
  ];
  reps.forEach((rep, i) => {
    intervals.push({
      phase: "work",
      round: i + 1,
      plannedSeconds: 90,
      activeSeconds: 90,
      meters: rep.meters,
      heartRate: { average: rep.hr, max: rep.hr + 8, end: rep.hr + 5 },
    });
    if (i < restEnds.length) {
      intervals.push({
        phase: "rest",
        round: i + 1,
        plannedSeconds: 120,
        activeSeconds: 120,
        meters: 180,
        heartRate: { average: rep.hr - 15, max: rep.hr + 5, end: restEnds[i] },
      });
    }
  });
  intervals.push({ phase: "coolDown", plannedSeconds: 300, activeSeconds: 300, meters: 550, heartRate: { average: 130, max: 150, end: 115 } });
  return intervals;
}

function record(intervals: RecordedInterval[], overrides: Partial<RecordRow> = {}): RecordRow {
  return {
    id: "r1",
    name: "Intervals 6 × 1:30",
    started_at: "2026-10-20T07:12:00Z",
    completed: true,
    active_time: intervals.reduce((sum, i) => sum + i.activeSeconds, 0),
    total_meters: intervals.some((i) => i.meters != null) ? intervals.reduce((sum, i) => sum + (i.meters ?? 0), 0) : null,
    intervals,
    program_session_id: "w3-tue",
    effort: "hard",
    ...overrides,
  };
}

Deno.test("runSignals on an interval run with GPS and heart rate", () => {
  assertEquals(runSignals(record(intervalRun())), {
    date: "2026-10-20",
    workout: "Intervals 6 × 1:30",
    session_id: "w3-tue",
    completed: true,
    effort: "hard",
    planned_work_minutes: 9,
    actual_work_minutes: 9,
    completion_pct: 100,
    skipped_work_intervals: 0,
    work_pace_per_mile: "8:14", // 540 s over 1760 m
    first_rep_pace: "7:47",
    last_rep_pace: "8:56",
    // 6 reps, so first third (615 m) vs last third (550 m), both in 180 s.
    pace_fade_pct: 11.8,
    work_avg_hr: 161,
    max_hr: 178,
    hr_drift_bpm: 20,
    rest_recovery_bpm: 22, // drops of 25, 23, 22, 20, 19
  });
});

Deno.test("runSignals compares first and last rep when there are few reps", () => {
  const intervals = intervalRun().filter((i) => !(i.phase === "work" && (i.round ?? 0) > 3));
  const signals = runSignals(record(intervals));
  // 310 m vs 300 m in 90 s each.
  assertEquals(signals.pace_fade_pct, 3.3);
  assertEquals(signals.first_rep_pace, "7:47");
  assertEquals(signals.last_rep_pace, "8:03");
});

Deno.test("runSignals on a run cut short counts skipped and short reps", () => {
  const intervals = intervalRun().map((i) => {
    if (i.phase !== "work") return i;
    if (i.round === 4) return { ...i, activeSeconds: 40, meters: 120 };
    if ((i.round ?? 0) > 4) return { ...i, activeSeconds: 0, meters: null, heartRate: null };
    return i;
  });
  const signals = runSignals(record(intervals, { completed: false, effort: "too_hard" }));
  assertEquals(signals.skipped_work_intervals, 3);
  assertEquals(signals.planned_work_minutes, 9);
  assertEquals(signals.actual_work_minutes, 5.2); // 3 × 90 s + 40 s
  assertEquals(signals.completion_pct, 57);
  assertEquals(signals.completed, false);
});

Deno.test("runSignals on a run with no GPS or heart rate", () => {
  const intervals = intervalRun().map((i) => ({ ...i, meters: null, heartRate: null }));
  const signals = runSignals(record(intervals, { effort: null }));
  assertEquals(signals.completion_pct, 100);
  assertEquals(signals.planned_work_minutes, 9);
  assertEquals(signals.work_pace_per_mile, null);
  assertEquals(signals.first_rep_pace, null);
  assertEquals(signals.last_rep_pace, null);
  assertEquals(signals.pace_fade_pct, null);
  assertEquals(signals.work_avg_hr, null);
  assertEquals(signals.max_hr, null);
  assertEquals(signals.hr_drift_bpm, null);
  assertEquals(signals.rest_recovery_bpm, null);
  assertEquals(signals.effort, null);
});

Deno.test("runSignals on an older record without planned lengths, and an easy run", () => {
  const intervals: RecordedInterval[] = [{ phase: "work", activeSeconds: 1500, meters: 4000 }];
  const signals = runSignals(record(intervals, { effort: "easy" }));
  assertEquals(signals.completion_pct, 100);
  assertEquals(signals.planned_work_minutes, 25);
  assertEquals(signals.first_rep_pace, "10:04");
  assertEquals(signals.last_rep_pace, null);
  assertEquals(signals.pace_fade_pct, null);
  assertEquals(runSignals(record([])).completion_pct, 100);
  assertEquals(runSignals(record([], { completed: false })).completion_pct, 0);
});

// ---------------------------------------------------------------------------
// trend
// ---------------------------------------------------------------------------

function signals(overrides: Partial<RunSignals> = {}): RunSignals {
  return {
    date: "2026-10-20",
    workout: "Easy run",
    session_id: "w3-tue",
    completed: true,
    effort: "just_right",
    planned_work_minutes: 20,
    actual_work_minutes: 20,
    completion_pct: 100,
    skipped_work_intervals: 0,
    work_pace_per_mile: "10:00",
    first_rep_pace: "10:00",
    last_rep_pace: "10:10",
    pace_fade_pct: 1.7,
    work_avg_hr: 150,
    max_hr: 165,
    hr_drift_bpm: 5,
    rest_recovery_bpm: 30,
    ...overrides,
  };
}

const counts = (runs: RunSignals[]) => {
  const t = trend(runs);
  return [t.too_hard_count, t.too_easy_count, t.incomplete_count];
};

Deno.test("trend: a just-right run is neither too hard nor too easy", () => {
  const t = trend([signals()]);
  assertEquals([t.runs_considered, t.too_hard_count, t.too_easy_count, t.incomplete_count], [1, 0, 0, 0]);
  assert(t.notes.some((note) => note.includes("no trend yet")));
});

Deno.test("trend: too-hard thresholds", () => {
  assertEquals(counts([signals({ effort: "hard" })]), [1, 0, 0]);
  assertEquals(counts([signals({ effort: "too_hard" })]), [1, 0, 0]);
  assertEquals(counts([signals({ completed: false })]), [1, 0, 1]);
  assertEquals(counts([signals({ completion_pct: INCOMPLETE_PCT })]), [0, 0, 0]);
  assertEquals(counts([signals({ completion_pct: INCOMPLETE_PCT - 1 })]), [1, 0, 1]);
  assertEquals(counts([signals({ pace_fade_pct: FADE_TOO_HARD_PCT })]), [0, 0, 0]);
  assertEquals(counts([signals({ pace_fade_pct: FADE_TOO_HARD_PCT + 0.1 })]), [1, 0, 0]);
  assertEquals(counts([signals({ rest_recovery_bpm: LOW_RECOVERY_BPM })]), [0, 0, 0]);
  assertEquals(counts([signals({ rest_recovery_bpm: LOW_RECOVERY_BPM - 1 })]), [1, 0, 0]);
});

Deno.test("trend: too-easy needs easy effort, a full run, no fade and good recovery", () => {
  assertEquals(counts([signals({ effort: "easy" })]), [0, 1, 0]);
  assertEquals(counts([signals({ effort: "easy", rest_recovery_bpm: null, pace_fade_pct: null })]), [0, 1, 0]);
  assertEquals(counts([signals({ effort: "easy", pace_fade_pct: FADE_EASY_MAX_PCT })]), [0, 1, 0]);
  assertEquals(counts([signals({ effort: "easy", pace_fade_pct: FADE_EASY_MAX_PCT + 0.1 })]), [0, 0, 0]);
  assertEquals(counts([signals({ effort: "easy", rest_recovery_bpm: GOOD_RECOVERY_BPM - 1 })]), [0, 0, 0]);
  assertEquals(counts([signals({ effort: "easy", completion_pct: 80 })]), [1, 0, 1]);
  assertEquals(counts([signals({ effort: null })]), [0, 0, 0]);
});

Deno.test("trend: notes describe the pattern and streaks", () => {
  const t = trend([
    signals({ effort: "too_hard", pace_fade_pct: 12, rest_recovery_bpm: 15 }),
    signals({ effort: "hard", completed: false, completion_pct: 60, skipped_work_intervals: 2 }),
    signals({ effort: "just_right" }),
  ]);
  assertEquals([t.runs_considered, t.too_hard_count, t.too_easy_count, t.incomplete_count], [3, 2, 0, 1]);
  assertEquals(t.notes, [
    "Rated 2 of the last 3 runs hard or too hard (1 too hard).",
    "Did less than 90% of the planned running, or stopped early, in 1 of the last 3 runs.",
    "Skipped or cut short work intervals in 1 of the last 3 runs.",
    "Slowed by more than 8% from the first reps to the last in 1 of the last 3 runs.",
    "Heart rate dropped less than 20 bpm during rests in 1 of the last 3 runs.",
    "The last 2 runs in a row looked too hard.",
  ]);

  const easy = trend([signals({ effort: "easy" }), signals({ effort: "easy" })]);
  assertEquals(easy.notes, ["Rated both recent runs easy.", "The last 2 runs in a row looked too easy."]);

  const fine = trend([signals(), signals()]);
  assertEquals(fine.notes, ["No sign the plan is too hard or too easy across both recent runs."]);
  assertEquals(trend([]).runs_considered, 0);
});

Deno.test("trend: only the newest runs count", () => {
  const runs = [...Array(TREND_RUNS).fill(signals()), signals({ effort: "too_hard" }), signals({ effort: "too_hard" })];
  const t = trend(runs);
  assertEquals(t.runs_considered, TREND_RUNS);
  assertEquals(t.too_hard_count, 0);
});

// ---------------------------------------------------------------------------
// Done and missed sessions
// ---------------------------------------------------------------------------

Deno.test("doneSessionIds counts completed runs linked to a session", () => {
  const rows = [
    record([], { program_session_id: "w1-tue" }),
    record([], { program_session_id: "w1-thu", completed: false }),
    record([], { program_session_id: null }),
    record([], { program_session_id: "w1-sat" }),
  ];
  assertEquals(doneSessionIds(rows), new Set(["w1-tue", "w1-sat"]));
});

Deno.test("missedSessions lists past sessions that weren't done", () => {
  const plan = makePlan();
  const done = new Set(["w1-tue", "w1-thu", "w1-sat", "w2-tue"]);
  assertEquals(missedSessions(plan, done, TODAY).map((s) => s.id), ["w2-thu", "w2-sat", "w3-tue"]);
  // Since a review on Saturday 2026-10-17: that day's session counts, earlier ones don't.
  assertEquals(
    missedSessions(plan, done, TODAY, new Date("2026-10-17T09:30:00Z")).map((s) => s.id),
    ["w2-sat", "w3-tue"],
  );
  assertEquals(missedSessions(plan, DONE, new Date("2026-10-05T00:00:00Z")), []);
});
