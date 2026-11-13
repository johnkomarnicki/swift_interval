// What the MCP tools say about a runner's data: one run, a stretch of runs, and
// where a plan stands. No I/O, so it's covered by `summaries.test.ts`. The run
// numbers come from the coach's analysis (`runSignals`, `trend`), so Claude and
// the in-app coach read a run the same way.

import { doneSessionIds, type RecordRow, runSignals, trend } from "../_shared/analysis.ts";
import { addDays, heartRateSummary, isoDate, mondayOf, pace, parseDate, type Plan } from "../_shared/plan.ts";

const METERS_PER_MILE = 1609.344;

/** A row of `workout_records` as the MCP tools load it. */
export type RunRow = RecordRow & {
  total_time: number;
  program_id: string | null;
  activity: "run" | "walk" | null;
};

/** Interval workouts have no `activity`; free runs and walks do. */
export function runKind(row: Pick<RunRow, "activity">) {
  return row.activity ?? "interval";
}

function round1(value: number) {
  return Math.round(value * 10) / 10;
}

function miles(meters: number | null | undefined) {
  return meters ? Math.round((meters / METERS_PER_MILE) * 100) / 100 : null;
}

/** Below this a whole-run pace is GPS noise. */
const MIN_PACE_METERS = 200;

/** One run, compact enough to list dozens of them. */
export function runSummary(row: RunRow) {
  const kind = runKind(row);
  const heartRate = heartRateSummary(row.intervals ?? []);
  const summary: Record<string, unknown> = {
    id: row.id,
    started_at: row.started_at,
    name: row.name,
    kind,
    completed: row.completed,
    effort: row.effort,
    active_minutes: round1(row.active_time / 60),
    total_minutes: round1(row.total_time / 60),
    distance_miles: miles(row.total_meters),
    avg_pace_per_mile: (row.total_meters ?? 0) > MIN_PACE_METERS ? pace(row.active_time, row.total_meters!) : null,
    avg_hr: heartRate.work_avg_hr ?? null,
    max_hr: heartRate.max_hr ?? null,
    program_id: row.program_id,
    program_session_id: row.program_session_id,
  };
  if (kind === "interval" && (row.intervals ?? []).some((i) => i.phase === "work")) {
    const signals = runSignals(row);
    summary.intervals = {
      planned_work_minutes: signals.planned_work_minutes,
      actual_work_minutes: signals.actual_work_minutes,
      completion_pct: signals.completion_pct,
      skipped_work_intervals: signals.skipped_work_intervals,
      work_pace_per_mile: signals.work_pace_per_mile,
      first_rep_pace: signals.first_rep_pace,
      last_rep_pace: signals.last_rep_pace,
      pace_fade_pct: signals.pace_fade_pct,
      hr_drift_bpm: signals.hr_drift_bpm,
      rest_recovery_bpm: signals.rest_recovery_bpm,
    };
  }
  return summary;
}

/** One run with every interval, for a close look. */
export function runDetail(row: RunRow) {
  return {
    ...runSummary(row),
    interval_log: (row.intervals ?? []).map((i) => ({
      phase: i.phase,
      round: i.round ?? null,
      planned_seconds: i.plannedSeconds ?? null,
      active_seconds: Math.round(i.activeSeconds),
      distance_miles: miles(i.meters),
      pace_per_mile: (i.meters ?? 0) > 50 ? pace(i.activeSeconds, i.meters!) : null,
      heart_rate: i.heartRate ?? null,
    })),
  };
}

type Totals = { runs: number; meters: number; active_seconds: number };

function addTo(totals: Totals, row: Pick<RunRow, "total_meters" | "active_time">) {
  totals.runs += 1;
  totals.meters += row.total_meters ?? 0;
  totals.active_seconds += row.active_time;
}

function totalsOut(totals: Totals) {
  return {
    runs: totals.runs,
    distance_miles: miles(totals.meters) ?? 0,
    active_minutes: Math.round(totals.active_seconds / 60),
  };
}

/** Totals for the runs between `from` and `to` (yyyy-MM-dd, inclusive), by kind and by week (Monday to Sunday). */
export function periodSummary(
  rows: Pick<RunRow, "started_at" | "completed" | "total_meters" | "active_time" | "activity" | "effort">[],
  from: string,
  to: string,
) {
  const all: Totals = { runs: 0, meters: 0, active_seconds: 0 };
  const byKind = new Map<string, Totals>();
  const byWeek = new Map<string, Totals>();
  const efforts: Record<string, number> = {};
  let pacedMeters = 0;
  let pacedSeconds = 0;
  let longest: (typeof rows)[number] | null = null;

  for (const row of rows) {
    addTo(all, row);
    const kind = runKind(row);
    if (!byKind.has(kind)) byKind.set(kind, { runs: 0, meters: 0, active_seconds: 0 });
    addTo(byKind.get(kind)!, row);
    const week = isoDate(mondayOf(parseDate(row.started_at.slice(0, 10))!));
    if (!byWeek.has(week)) byWeek.set(week, { runs: 0, meters: 0, active_seconds: 0 });
    addTo(byWeek.get(week)!, row);
    if (row.effort) efforts[row.effort] = (efforts[row.effort] ?? 0) + 1;
    if ((row.total_meters ?? 0) > MIN_PACE_METERS) {
      pacedMeters += row.total_meters!;
      pacedSeconds += row.active_time;
    }
    if ((row.total_meters ?? 0) > (longest?.total_meters ?? 0)) longest = row;
  }

  // Every week in the range, so weeks off show up as zeros.
  const weeks = [];
  const start = parseDate(from);
  const end = parseDate(to);
  if (start && end) {
    for (let week = mondayOf(start); week <= end; week = addDays(week, 7)) {
      const key = isoDate(week);
      weeks.push({ week_of: key, ...totalsOut(byWeek.get(key) ?? { runs: 0, meters: 0, active_seconds: 0 }) });
    }
  }

  return {
    from,
    to,
    ...totalsOut(all),
    completed_runs: rows.filter((row) => row.completed).length,
    avg_pace_per_mile: pacedMeters > MIN_PACE_METERS ? pace(pacedSeconds, pacedMeters) : null,
    longest_run: longest
      ? { date: longest.started_at.slice(0, 10), distance_miles: miles(longest.total_meters), active_minutes: round1(longest.active_time / 60) }
      : null,
    effort_ratings: efforts,
    by_kind: Object.fromEntries([...byKind].map(([kind, totals]) => [kind, totalsOut(totals)])),
    weeks,
  };
}

/** A plan with each session marked done, missed, today or upcoming, plus how training is going. */
export function planStatus(plan: Plan, records: RunRow[], today: Date) {
  const done = doneSessionIds(records);
  const todayText = isoDate(today);
  const status = (id: string, date: string) =>
    done.has(id) ? "done" : date < todayText ? "missed" : date === todayText ? "today" : "upcoming";

  const sessions = plan.weeks.flatMap((week) => week.sessions);
  const counts = { done: 0, missed: 0, today: 0, upcoming: 0 };
  for (const session of sessions) counts[status(session.id, session.date)] += 1;

  // Week n starts on start_date + 7(n − 1) days; null before the plan starts or after it ends.
  const start = parseDate(plan.start_date);
  const weekIndex = start ? Math.floor(Math.round((today.getTime() - start.getTime()) / 86_400_000) / 7) + 1 : 0;
  const currentWeek = plan.weeks.some((week) => week.week === weekIndex) ? weekIndex : null;
  const next = sessions
    .filter((s) => !done.has(s.id) && s.date >= todayText)
    .sort((a, b) => a.date.localeCompare(b.date))[0] ?? null;
  const signals = records
    .filter((record) => record.program_session_id)
    .sort((a, b) => b.started_at.localeCompare(a.started_at))
    .map(runSignals);

  return {
    title: plan.title,
    summary: plan.summary,
    start_date: plan.start_date,
    today: todayText,
    current_week: currentWeek,
    total_weeks: plan.weeks.length,
    sessions: { total: sessions.length, ...counts },
    next_session: next,
    trend: trend(signals),
    weeks: plan.weeks.map((week) => ({
      week: week.week,
      focus: week.focus,
      sessions: week.sessions.map((session) => ({
        id: session.id,
        date: session.date,
        status: status(session.id, session.date),
        kind: session.kind,
        title: session.title,
        description: session.description,
        workout: session.workout,
      })),
    })),
  };
}
