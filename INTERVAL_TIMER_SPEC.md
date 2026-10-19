# Interval Run Timer: Build Spec

> **For Claude Code:** This file describes a personal iPhone app I want you to build. Read the whole thing, then make a short plan before you write any code. I'm not a professional iOS developer, so explain each Xcode step I need to do myself (signing, installing on my phone) in plain language.

---

## 1. What this is

I'm a runner training for a 5K with interval workouts. I want a simple iPhone app where I set up:

- an optional **warm-up**
- a **work** interval (running)
- a **rest** interval (walking or recovery)
- how many **rounds** of work + rest
- an optional **cool-down**

Then I press Start and the app runs the whole workout, **beeping during the last 5 seconds of every interval** so I know a switch is coming without looking at my phone.

This app is for me only. It will not go on the App Store.

---

## 2. Tech decisions (already made)

| Area | Choice |
|---|---|
| Platform | Native iOS app, iPhone only, portrait only |
| Language / UI | Swift + SwiftUI |
| Minimum iOS | iOS 17 |
| Storage | SwiftData (on the phone only, no accounts, no cloud) |
| Audio | AVFoundation (`AVAudioSession` + `AVAudioPlayer` or `AVAudioEngine`) |
| Third-party libraries | None. Use Apple frameworks only. |
| Build machine | My Mac (Xcode) |

---

## 3. Features (v1)

### 3.1 Workout builder

Fields:

- **Name** (text, e.g. "Week 3: 6 x 90s / 60s")
- **Warm-up**: on/off toggle + duration
- **Work interval**: duration (required)
- **Rest interval**: duration (required, can be 0)
- **Rounds**: whole number, 1 to 50
- **Skip rest after the last round**: toggle, default **on** (so the last work interval goes straight into the cool-down)
- **Cool-down**: on/off toggle + duration

Duration entry: minutes + seconds pickers (0 to 59 min, 0 to 59 sec). Minimum interval length is 1 second.

Show a live **total workout time** at the bottom of the builder as the user edits.

### 3.2 Saved workouts

- Home screen lists saved workouts: name, a one-line summary (e.g. "5:00 warm-up · 6 × 1:30 / 1:00 · 5:00 cool-down"), and total time.
- Tap a workout to see it and press **Start**.
- Swipe to delete. Long press or an Edit button to edit. Option to **Duplicate**.
- "+" button to create a new workout.
- Ship with one sample workout so the list isn't empty on first launch.

### 3.3 Workout player (the main screen while running)

Must be readable at arm's length while running:

- **Current phase** in large text: WARM-UP / WORK / REST / COOL-DOWN
- **Time left in this interval**, very large (the biggest thing on screen)
- **Round X of Y** (during work and rest)
- **Total time remaining** for the whole workout, smaller
- **Background color changes by phase** so I can tell at a glance (e.g. work = strong orange/red, rest = green or blue, warm-up and cool-down = neutral). Keep good text contrast.
- What's **next** (e.g. "Next: REST 1:00"), small

Controls (big, easy to hit):

- **Pause / Resume**
- **Skip** to next interval
- **End workout** (with a confirm step so I don't end it by accident)

Keep the screen awake while the player is open (`isIdleTimerDisabled = true`), and turn it back off when the workout ends or the player closes.

At the end: a simple "Workout complete" screen with total time, then back to home.

### 3.4 Audio countdown (the most important feature)

- In the **last 5 seconds** of every interval (warm-up, work, rest, cool-down), play a **short beep** at 5, 4, 3, 2, and 1 seconds left.
- When the interval switches, play a **longer, different tone** so the change is unmistakable.
- At the very end of the workout, play a distinct **finish sound** (e.g. three quick tones).
- If an interval is 5 seconds or shorter, only beep for the seconds that exist.
- Beeps must be **on time**. Schedule them against the clock, not by counting timer ticks, so they don't drift over a 30+ minute workout.
- Generate the tones in code (simple sine waves) or bundle tiny `.caf`/`.wav` files. No downloads.

**These must work while:**

1. **The phone is locked** and in my pocket or armband.
2. **I'm listening to music or a podcast** in another app (Spotify, Apple Music, Podcasts). The beeps should **briefly lower (duck) my music**, play, then let it return to normal. My music must never be stopped.
3. **The ring/silent switch is on silent.** Use the `.playback` audio category so beeps still play.

Audio session setup to start from (adjust if needed):

- Category `.playback`, options `.mixWithOthers` + `.duckOthers`
- Enable the **Audio** background mode in Signing & Capabilities so the app keeps running when locked
- Only activate the audio session during a workout; deactivate it (with `.notifyOthersOnDeactivation`) when the workout ends so my music returns to full volume

### 3.5 Settings (small)

- Beep volume slider (relative to system volume)
- Test sound button
- Toggle: vibrate with each countdown beep (default off)

---

## 4. Timing rules (please follow these exactly)

- Store the workout as an ordered list of segments, e.g. `[warmUp 300s, work 90s, rest 60s, work 90s, rest 60s, ..., work 90s, coolDown 300s]`.
- Track progress using a **start timestamp + accumulated paused time**, and compute "where am I" from the real clock. Don't rely on a `Timer` firing every second to count down; that drifts and stops when the app is suspended.
- On resume from pause, shift the schedule by the paused duration.
- If the app comes back to the foreground after being in the background, the screen should immediately show the correct phase and time.
- Skip jumps to the start of the next segment and reschedules the beeps.

---

## 5. Out of scope for v1 (don't build these yet)

- Apple Watch app
- GPS, distance, or pace
- HealthKit
- Spoken voice prompts
- iCloud sync or accounts
- Workout history / logs

Nice ideas for later (just keep the code clean enough to add them): Lock Screen Live Activity showing time left, workout history, Apple Watch.

---

## 6. Suggested project structure

```
IntervalRun/
  IntervalRunApp.swift
  Models/
    Workout.swift          // SwiftData model
    Segment.swift          // phase type + duration, built from Workout
  Engine/
    WorkoutEngine.swift    // clock-based state: current segment, time left, pause/skip
    AudioCueScheduler.swift// audio session + scheduled beeps
  Views/
    WorkoutListView.swift
    WorkoutEditorView.swift
    WorkoutDetailView.swift
    PlayerView.swift
    CompleteView.swift
    SettingsView.swift
  Resources/
    (tone files if not generated in code)
```

Keep the timing logic (`WorkoutEngine`) separate from the UI so it can be unit tested.

---

## 7. Tests I want

**Unit tests (XCTest):**

- Segment list is built correctly with warm-up/cool-down on and off, and with "skip last rest" on and off.
- Total time math is correct.
- Given a start time and "now," the engine reports the right segment and time left.
- Pause/resume shifts timing correctly.
- Beep times are generated correctly, including intervals shorter than 5 seconds.

**Manual test checklist (walk me through these on my phone):**

- [ ] Beeps at 5-4-3-2-1 and a longer tone at each switch
- [ ] Works with the screen locked for a full workout
- [ ] Works with Spotify or Apple Music playing: music ducks for beeps, then comes back, and never stops
- [ ] Works with the silent switch on
- [ ] Pause, resume, and skip all keep the beeps in sync
- [ ] After a 30-minute workout, beeps are still on the exact second
- [ ] Music returns to full volume after the workout ends

---

## 8. Getting it on my iPhone

Please guide me step by step through:

1. Creating the Xcode project (or open the one you generate).
2. Signing in with my Apple ID under Xcode → Settings → Accounts, and picking my "Personal Team" for signing.
3. Turning on **Developer Mode** on my iPhone (Settings → Privacy & Security → Developer Mode) and trusting my Mac.
4. Building and running on my phone over a cable.

**Note:** With a free Apple ID, apps installed this way expire after 7 days and I'll need to re-run from Xcode. A paid Apple Developer account ($99/year) extends that to a year. Remind me of this, and keep a short "how to reinstall" section in the project README.

---

## 9. Definition of done

- I can create, save, edit, duplicate, and delete workouts.
- I can run a full workout with warm-up, rounds, and cool-down.
- Countdown beeps fire on time in the last 5 seconds of every interval, with the phone locked, with my music playing, and on silent.
- Unit tests pass.
- The app is installed and running on my iPhone.
