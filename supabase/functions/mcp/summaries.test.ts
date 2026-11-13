// deno test supabase/functions/mcp/summaries.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import type { Plan, RecordedInterval } from "../_shared/plan.ts";
import { periodSummary, planStatus, runDetail, type RunRow, runSummary } from "./summaries.ts";

const MILE = 1609.344;

function run(overrides: Partial<RunRow> = {}): RunRow {
  return {
    id: "r1",
    name: "Run 1 / Walk 1",
    started_at: "2026-10-20T07:00:00Z",
    completed: true,
    total_time: 1800,
    active_time: 1800,
    total_meters: 3 * MILE,
    intervals: [],
    program_id: null,
    program_session_id: null,
    effort: null,
    activity: null,
    ...overrides,
  };
}

function rep(phase: string, seconds: number, meters: number | null, extra: Partial<RecordedInterval> = {}): RecordedInterval {
  return { phase, plannedSeconds: seconds, activeSeconds: seconds, meters, ...extra };
}

Deno.test("a free run has pace and distance but no interval breakdown", () => {
  const summary = runSummary(run({ activity: "run", total_meters: 2 * MILE, active_time: 1200 }));
  assertEquals(summary.kind, "run");
  assertEquals(summary.distance_miles, 2);
  assertEquals(summary.avg_pace_per_mile, "10:00");
  assertEquals(summary.intervals, undefined);
});

Deno.test("an interval run reports completion, pace fade and heart rate", () => {
  const hr = (average: number) => ({ average, max: average + 5, end: average });
  const summary = runSummary(run({
    intervals: [
      rep("warmup", 300, 600),
      rep("work", 120, 400, { heartRate: hr(150) }),
      rep("rest", 60, 100, { heartRate: hr(125) }),
      rep("work", 120, 360, { heartRate: hr(160) }),
    ],
  }));
  const intervals = summary.intervals as Record<string, unknown>;
  assertEquals(intervals.completion_pct, 100);
  assertEquals(intervals.planned_work_minutes, 4);
  assertEquals(intervals.first_rep_pace, "8:03");
  assertEquals(intervals.last_rep_pace, "8:56");
  assertEquals(summary.max_hr, 165);
});

Deno.test("a run with no distance has no pace", () => {
  const summary = runSummary(run({ total_meters: null }));
  assertEquals(summary.distance_miles, null);
  assertEquals(summary.avg_pace_per_mile, null);
});

Deno.test("the detail lists every interval with its pace", () => {
  const detail = runDetail(run({ intervals: [rep("work", 480, MILE)] }));
  assertEquals(detail.interval_log, [{
    phase: "work",
    round: null,
    planned_seconds: 480,
    active_seconds: 480,
    distance_miles: 1,
    pace_per_mile: "8:00",
    heart_rate: null,
  }]);
});

Deno.test("period totals cover every week in range, including empty ones", () => {
  const summary = periodSummary(
    [
      run({ started_at: "2026-10-06T07:00:00Z", total_meters: 3 * MILE, active_time: 1800, effort: "easy" }),
      run({ started_at: "2026-10-08T07:00:00Z", total_meters: 5 * MILE, active_time: 3000, activity: "run" }),
      run({ started_at: "2026-10-22T07:00:00Z", total_meters: null, active_time: 600, completed: false, activity: "walk" }),
    ],
    "2026-10-05",
    "2026-10-25",
  );
  assertEquals(summary.runs, 3);
  assertEquals(summary.completed_runs, 2);
  assertEquals(summary.distance_miles, 8);
  assertEquals(summary.avg_pace_per_mile, "10:00");
  assertEquals(summary.longest_run, { date: "2026-10-08", distance_miles: 5, active_minutes: 50 });
  assertEquals(summary.effort_ratings, { easy: 1 });
  assertEquals(Object.keys(summary.by_kind).sort(), ["interval", "run", "walk"]);
  assertEquals(summary.weeks.map((w) => [w.week_of, w.runs]), [
    ["2026-10-05", 2],
    ["2026-10-12", 0],
    ["2026-10-19", 1],
  ]);
});

// A 3-week plan starting Monday 2026-10-05, sessions Tue/Thu. Today is Thursday 2026-10-15.
const workout = {
  warm_up_seconds: 300,
  steps: [{ phase: "work" as const, seconds: 60 }, { phase: "rest" as const, seconds: 90 }],
  rounds: 6,
  skip_last_rest: true,
  cool_down_seconds: 300,
};
const plan: Plan = {
  title: "Couch to 5K",
  summary: "Build to 30 minutes of running.",
  start_date: "2026-10-05",
  weeks: [1, 2, 3].map((week) => ({
    week,
    focus: `Week ${week}`,
    sessions: [
      { day: "tue" as const, offset: 1 },
      { day: "thu" as const, offset: 3 },
    ].map(({ day, offset }) => ({
      id: `w${week}-${day}`,
      date: `2026-10-${String(5 + (week - 1) * 7 + offset).padStart(2, "0")}`,
      day,
      kind: "intervals",
      title: "Run/walk",
      description: "",
      workout,
    })),
  })),
};

Deno.test("plan sessions are marked done, missed, today and upcoming", () => {
  const records = [
    run({ id: "a", program_session_id: "w1-tue", started_at: "2026-10-06T07:00:00Z" }),
    run({ id: "b", program_session_id: "w1-thu", started_at: "2026-10-08T07:00:00Z" }),
    run({ id: "c", program_session_id: "w2-tue", started_at: "2026-10-13T07:00:00Z", completed: false }),
  ];
  const status = planStatus(plan, records, new Date("2026-10-15T00:00:00Z"));
  assertEquals(status.current_week, 2);
  assertEquals(status.sessions, { total: 6, done: 2, missed: 1, today: 1, upcoming: 2 });
  assertEquals(status.next_session?.id, "w2-thu");
  assertEquals(status.trend.runs_considered, 3);
  assertEquals(status.weeks[1].sessions.map((s) => s.status), ["missed", "today"]);
});

Deno.test("there's no current week before the plan starts", () => {
  const status = planStatus(plan, [], new Date("2026-10-01T00:00:00Z"));
  assertEquals(status.current_week, null);
  assertEquals(status.next_session?.id, "w1-tue");
});
