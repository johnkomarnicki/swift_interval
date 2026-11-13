// Training plan types and helpers shared by the Edge Functions that write plans
// (`generate-program` builds one, `review-program` revises one). Pure, so it can
// be unit tested with `deno test`.

export const DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;
export type Day = (typeof DAYS)[number];

// ---------------------------------------------------------------------------
// Output format pieces. Claude's response is constrained to JSON schemas built
// from these; the numeric limits are enforced afterwards by `normalizeWorkout`
// (schemas can't express them).
// ---------------------------------------------------------------------------

export const WORKOUT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["warm_up_seconds", "steps", "rounds", "skip_last_rest", "cool_down_seconds"],
  properties: {
    warm_up_seconds: { type: "integer", description: "0 for no warm-up. Usually a 3-5 minute brisk walk." },
    steps: {
      type: "array",
      description:
        "One round, in order. 'work' is running at the effort in the description; 'rest' is walking or very easy jogging. An easy or long run is a single work step.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["phase", "seconds"],
        properties: {
          phase: { type: "string", enum: ["work", "rest"] },
          seconds: { type: "integer", description: "10 to 3599" },
        },
      },
    },
    rounds: { type: "integer", description: "How many times the steps repeat, 1 to 50." },
    skip_last_rest: { type: "boolean", description: "Drop trailing rest steps in the final round. Usually true." },
    cool_down_seconds: { type: "integer", description: "0 for no cool-down. Usually a 3-5 minute walk." },
  },
} as const;

/** One week of a plan, as Claude writes it (no ids or dates; those are computed). */
export const WEEK_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["week", "focus", "sessions"],
  properties: {
    week: { type: "integer" },
    focus: { type: "string", description: "A few words, e.g. 'Build to 10 minutes running'." },
    sessions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["day", "kind", "title", "description", "workout"],
        properties: {
          day: { type: "string", enum: DAYS },
          kind: { type: "string", enum: ["run_walk", "easy", "intervals", "tempo", "long", "time_trial"] },
          title: { type: "string", description: "At most 30 characters, e.g. 'Intervals 6 × 1:30'." },
          description: {
            type: "string",
            description: "1-2 sentences of coaching: the effort to aim for (and a target pace per mile when there's pace data), and why.",
          },
          workout: WORKOUT_SCHEMA,
        },
      },
    },
  },
} as const;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type RawWorkout = {
  warm_up_seconds: number;
  steps: { phase: "work" | "rest"; seconds: number }[];
  rounds: number;
  skip_last_rest: boolean;
  cool_down_seconds: number;
};
export type RawSession = { day: Day; kind: string; title: string; description: string; workout: RawWorkout };

/** One interval of a recorded run (`workout_records.intervals`, the app's `IntervalResult`). */
export type RecordedInterval = {
  phase: string;
  round?: number | null;
  /** Planned length; missing on records saved before it was uploaded. */
  plannedSeconds?: number | null;
  activeSeconds: number;
  meters?: number | null;
  heartRate?: { average: number; max: number; end: number } | null;
};

/** A session as stored in `programs.plan`: id `w{week}-{day}`, date yyyy-MM-dd. */
export type PlanSession = RawSession & { id: string; date: string };
export type PlanWeek = { week: number; focus: string; sessions: PlanSession[] };
export type Plan = { title: string; summary: string; start_date: string; weeks: PlanWeek[] };

/** Heart rate over a run, in beats per minute. Empty when none was recorded. */
export type HeartRateSummary = {
  work_avg_hr?: number | null;
  max_hr?: number;
  rest_recovery_bpm?: number | null;
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/** Clamps a workout to what the app can play; null if it has no work step. */
export function normalizeWorkout(workout: RawWorkout | undefined): RawWorkout | null {
  if (!workout) return null;
  const steps = (workout.steps ?? [])
    .filter((step) => (step.phase === "work" || step.phase === "rest") && step.seconds >= 1)
    .slice(0, 20)
    .map((step) => ({ phase: step.phase, seconds: clamp(Math.round(step.seconds), 1, 3599) }));
  if (!steps.some((step) => step.phase === "work")) return null;
  return {
    warm_up_seconds: clamp(Math.round(workout.warm_up_seconds ?? 0), 0, 3599),
    steps,
    rounds: clamp(Math.round(workout.rounds ?? 1), 1, 50),
    skip_last_rest: workout.skip_last_rest ?? true,
    cool_down_seconds: clamp(Math.round(workout.cool_down_seconds ?? 0), 0, 3599),
  };
}

/** Heart rate over a run's intervals, when it was recorded. */
export function heartRateSummary(intervals: RecordedInterval[]): HeartRateSummary {
  const measured = intervals.filter((i) => i.heartRate && i.activeSeconds >= 0.5);
  if (measured.length === 0) return {};
  const work = measured.filter((i) => i.phase === "work");
  const workSeconds = work.reduce((sum, i) => sum + i.activeSeconds, 0);
  const drops: number[] = [];
  intervals.forEach((rest, index) => {
    const before = intervals[index - 1];
    if (rest.phase === "rest" && rest.heartRate && before?.phase === "work" && before.heartRate) {
      drops.push(before.heartRate.end - rest.heartRate.end);
    }
  });
  return {
    work_avg_hr: workSeconds > 0
      ? Math.round(work.reduce((sum, i) => sum + i.heartRate!.average * i.activeSeconds, 0) / workSeconds)
      : null,
    max_hr: Math.max(...measured.map((i) => i.heartRate!.max)),
    rest_recovery_bpm: drops.length > 0 ? Math.round(drops.reduce((a, b) => a + b, 0) / drops.length) : null,
  };
}

// ---------------------------------------------------------------------------
// Helpers. Dates are UTC midnights standing for calendar days.
// ---------------------------------------------------------------------------

export function parseDate(value: string | undefined | null): Date | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function mondayOf(date: Date) {
  return addDays(date, -((date.getUTCDay() + 6) % 7));
}

export function addDays(date: Date, days: number) {
  const result = new Date(date);
  result.setUTCDate(result.getUTCDate() + days);
  return result;
}

export function isoDate(date: Date) {
  return date.toISOString().slice(0, 10);
}

export function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, Number.isFinite(value) ? value : min));
}

export function round2(value: number) {
  return Math.round(value * 100) / 100;
}

/** Minutes:seconds per mile. */
export function pace(seconds: number, meters: number) {
  const perMile = Math.round(seconds / (meters / 1609.344));
  return `${Math.floor(perMile / 60)}:${String(perMile % 60).padStart(2, "0")}`;
}
