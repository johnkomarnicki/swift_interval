# Runwise

> **Publishing to the App Store:** everything for App Store Connect (listing copy, privacy answers, review notes and a release checklist) is in [`app-store/LISTING.md`](app-store/LISTING.md). The website is in `docs/`: the landing page (`index.html`), privacy policy and support page. It's plain static HTML with no build step. To host it on Vercel, import the repo, set **Root Directory** to `docs` and **Framework Preset** to "Other". `docs/vercel.json` turns on clean URLs, so `/privacy` works as well as `/privacy.html`. Once it has a domain, update the two URLs in `IntervalRun/Support/AppLinks.swift` and in App Store Connect to match.
>
> The project, target and bundle ID are still named `IntervalRun` on purpose. People never see those names, and changing the bundle ID would break Sign in with Apple and the Supabase sign-in setup.

A running coach and planner for iPhone: a training plan built around your week, routes for each run, and a voice that guides you through every session. Run/walk intervals are at its heart. You set an optional warm-up, the intervals for one round, the number of rounds and an optional cool-down. A round is either one work and one rest interval, or a **custom pattern** of work and rest steps (for example: jog 1:30, walk 1:30, jog 3:00, walk 3:00, twice). During the workout the app counts down the end of every interval (the last 3 seconds, spoken "three, two, one" or beeped) and plays a longer tone at each switch. Optional voice prompts say "Halfway there" in the middle of each work and rest interval, and how many intervals are left after each switch. These are all on by default and can be turned off in Settings.

It also tracks **distance in miles** for every interval, using GPS outdoors and the step counter when GPS is weak or you're on a treadmill. You see interval distance, pace and total distance while running. Optionally, after each work interval it says "That was 0.21 miles". The finish screen shows a per-interval breakdown, and every workout is saved in **History**. This works with the phone locked, with music playing, and with the silent switch on.

When GPS is on, the player shows a **live map** behind the timer: your position, the line you've run (solid) and your planned route if you picked one (dotted). It's a flat, north-up overview that follows you. The phase color stays on the top and bottom of the screen, so you can still tell run from walk at a glance. The map button on the player turns the map off (the plain color screen) and back on; the choice is remembered.

The **Free Run** tab is for runs and walks with no intervals. Pick Run or Walk and it starts a stopwatch with live distance and average pace. Pause any time, then tap Finish to save it to History. It uses the same GPS and step-counter tracking, judged minute by minute, so a stretch without GPS only falls back to the step counter for that stretch.

**Routes** (Plan tab → map icon) let you plan where you'll run. **Create for me** takes a start point (your location, or tap the map), a distance and a shape (loop or out & back), and offers three routes heading different ways, each measured along real roads and paths and rescaled to land close to the distance. With **Prefer parks & trails** on (the default), it looks up parks and trails nearby in Apple Maps and aims the routes through them, labelling each option with what it goes through. Or **Draw** your own: tap points on the map and each stretch follows roads and paths (Apple Maps walking directions), with Undo, Back to start and Out & back. A created route can be fine-tuned in Draw before saving. Every plan session has a Route section: it shows how far the session should take you (its time at your usual pace from recent runs) and suggests saved routes that fit. Free Run can use a route too.

- Swift + SwiftUI, iOS 17+, iPhone only, portrait
- SwiftData for storage (on the phone only)
- AVFoundation for audio. No third-party libraries.

---

## Install on your iPhone (first time)

You need a Mac with Xcode, your iPhone, and a USB cable.

### 1. Open the project
Double-click **`IntervalRun.xcodeproj`** in this folder. Xcode opens.

### 2. Sign in with your Apple ID
1. In the menu bar: **Xcode → Settings… → Accounts**.
2. Click **+** at the bottom left, choose **Apple ID**, and sign in.
3. When you're signed in, you'll see a team called **"Your Name (Personal Team)"**. Close the window.

### 3. Pick your team for signing
1. In the left sidebar, click the blue **IntervalRun** project icon at the very top.
2. Under **TARGETS**, select **IntervalRun**, then open the **Signing & Capabilities** tab.
3. Leave **Automatically manage signing** ticked.
4. In the **Team** dropdown, pick **Your Name (Personal Team)**.
5. If Xcode shows a red error saying the bundle identifier isn't available, change **Bundle Identifier** to something unique, such as `com.yourname.IntervalRun`.

The **Background Modes → Audio** capability is already set up in `Config/Info.plist`, so you don't need to add it. You'll see it listed on this tab.

### 4. Turn on Developer Mode on the iPhone
1. Plug the iPhone into the Mac with the cable. Unlock it.
2. If the phone asks **"Trust This Computer?"**, tap **Trust** and enter your passcode.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode** → turn it **on**. The phone restarts.
   - If you don't see Developer Mode, make sure the phone is plugged in and Xcode is open, then check again.
4. After the restart, confirm **Turn On** when asked.

### 5. Build and run
1. At the top of the Xcode window, click the device menu (next to the ▶︎ button) and choose **your iPhone**.
2. Press **▶︎** (or **⌘R**). The first build takes a minute.
3. The first time, the phone may say the developer isn't trusted. On the iPhone go to **Settings → General → VPN & Device Management**, tap your Apple ID under "Developer App", and tap **Trust**. Then press ▶︎ again.

The app is now on your home screen as **Runwise**. You can unplug the phone and use it normally.

### 6. Allow location and motion (for distance)
The first time you open a workout, the app asks for two permissions:
- **Location: tap "Allow While Using App".** That's enough for GPS to keep working with the screen locked during a workout. A blue location indicator shows while it's running.
- **Motion & Fitness: tap "Allow".** This lets the app use the step counter on a treadmill or when GPS is weak.

If you tapped "Don't Allow" by mistake, go to **iPhone Settings → Apps → Runwise** and turn on **Location** (While Using) and **Motion & Fitness**.

---

## How to reinstall

> **You now have the paid Apple Developer Program**, so an install from Xcode lasts a year, not 7 days. Make sure the paid team (not "Personal Team") is selected under Signing & Capabilities.

> **With a free Apple ID, apps you install this way stop opening after 7 days.** This is an Apple limit. Your saved workouts are kept. A paid Apple Developer account ($99/year) extends this to one year.

When the app stops opening:

1. Plug in the iPhone and open `IntervalRun.xcodeproj`.
2. Pick your iPhone in the device menu at the top.
3. Press **▶︎**.

That's all. If Xcode says your signing certificate is invalid, go to **Signing & Capabilities** and re-select your Personal Team.

---

## Accounts and AI training plans

You sign in with your email and a 6-digit code. After that, the app asks a few questions about your goal, fitness and schedule, and an AI coach (Claude) builds a week-by-week plan. Every session plays in the timer. Workouts, run history and the plan are backed up to your account, and everything still works offline.

**Backend (Supabase project "Runner.io", the app's former name):**
- `supabase/migrations/`: the tables (`profiles`, `workouts`, `workout_records`, `programs`). Row level security means each user can only see their own rows.
- `supabase/functions/generate-program/`: the server function that calls Claude. The Claude API key is stored as the Supabase secret `ANTHROPIC_API_KEY` and never ships in the app. Each user can build up to 5 plans a day.
- `supabase/functions/delete-account/`: permanently deletes the signed-in user's account (Settings → Delete account), which Apple requires. Deleting the account deletes all of its rows too. For Sign in with Apple accounts it also revokes the app's Apple tokens, as Apple requires. That needs a key from the Apple Developer portal: **Certificates, Identifiers & Profiles → Keys → +**, tick **Sign in with Apple**, configure it for the app's bundle ID, and download the `.p8` file. Then set the three secrets below. Without them, accounts are still deleted but the Apple revoke is skipped.
- `supabase/config.toml`: auth settings. Sign-in emails go through Resend, using the 6-digit-code template in `supabase/templates/`.

**Common commands** (run from this folder after `supabase login`):
```sh
supabase db push                                   # apply new migrations
supabase functions deploy generate-program --use-api
supabase functions deploy delete-account --use-api
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...  # replace the Claude key
supabase secrets set APPLE_TEAM_ID=357K42LM9L APPLE_KEY_ID=ABC123DEFG \
  APPLE_PRIVATE_KEY="$(cat AuthKey_ABC123DEFG.p8)"  # Sign in with Apple key, for account deletion
RESEND_API_KEY=re_... supabase config push         # push auth/email settings
```

**Limitations right now:**
- **Sign-in emails only reach the Resend account's own email address,** because they're sent from Resend's test address (`onboarding@resend.dev`). To let other people sign in, verify a domain in Resend and change `admin_email` in `supabase/config.toml`.
- **Google sign-in** is built in but switched off. It needs Google OAuth credentials; then flip `googleSignInEnabled` in `IntervalRun/Account/SupabaseConfig.swift`.
- **Sign in with Apple** is on. It needs the app signed with your paid Apple Developer team: Signing & Capabilities → Team, not "(Personal Team)". People who sign in with Apple don't need an email code, so they aren't affected by the Resend restriction above.

## Heart rate

Heart rate is optional. It's set up in **Settings → Heart rate**:

- **Heart rate monitor:** any standard Bluetooth heart rate monitor. That includes chest straps and armbands (Garmin, Polar, Wahoo, Coros…), and Garmin watches with Broadcast Heart Rate on (hold MENU, then Sensors & Accessories → Wrist Heart Rate; it can also be set to broadcast during activities). The app connects only during a run, and on the pairing screen. It shows live heart rate on the player and keeps recording with the screen locked.
- **Read from Apple Health:** used for an Apple Watch, AirPods Pro 3 or Powerbeats Pro 2. After a run with no Bluetooth readings, the app reads heart rate from Health. A watch often syncs a few minutes late, so recent runs saved without heart rate are filled in when the app comes back to the foreground. An Apple Watch only measures often enough when a workout is running on the watch, so start one there too.

Readings are matched to intervals by the real times each interval ran, which leaves pauses out. Each interval saves its average, max and last reading. The last readings give how much heart rate drops during each rest. If there's less than one reading per 20 seconds, nothing is saved, so the occasional background readings an Apple Watch takes aren't mistaken for real data. The summary shows on the finish screen and in History. It's also sent to Claude when building a plan (`work_avg_hr`, `max_hr`, `rest_recovery_bpm`), so plans ease off when runs are harder than they should be.

## The coach's voice (ElevenLabs)

Users choose who speaks under **Settings → Coach voice**: **Allison** (the default), **Brad**, or the **iPhone voice**. Allison and Brad are ElevenLabs voices from the "Runwiser" collection. Each one's prompts are built from 321 short clips in `IntervalRun/Voice/<voice>/`. The countdown is the exception: "Three… Two… One…" is recorded as one take, which the script spaces so each number starts exactly a second after the last, and which the app cuts back into its three numbers. Played a second apart they join up into the original take, so the count sounds smooth rather than like three separate words. A prompt with any clip missing uses the iPhone's built-in voice instead, so the app works either way. One voice uses about 5,700 characters to record. A paid ElevenLabs plan (Starter or higher) is needed, because the free plan doesn't allow commercial use.

To re-record, put your API key in `scripts/voice/.env` (it's git-ignored) as `ELEVENLABS_API_KEY=sk_...`. The key needs Text to Speech access, plus Voices: Read for `--list-voices`. Then run:

```sh
python3 scripts/voice/generate_voice.py                  # records any missing clips, for every voice
python3 scripts/voice/generate_voice.py --voice brad     # just one voice
python3 scripts/voice/generate_voice.py --only min-      # re-record one group of clips
python3 scripts/voice/generate_voice.py --force          # re-record everything
python3 scripts/voice/generate_voice.py --list-voices    # voices on your ElevenLabs account
python3 scripts/voice/generate_voice.py --preview <name or voice ID>   # hear sample prompts
```

**To add a voice:** add its name and ElevenLabs ID to `VOICES` in `scripts/voice/generate_voice.py`, and a matching case to `CoachVoice` in `IntervalRun/Engine/VoiceClips.swift`. Then run the script with `--voice <name>`.

**To add or change a phrase:** update the clip list in the script and `clipScript` in `VoiceClips.swift`, then run the script.

Unit tests fail if the script and the app disagree on voices or clip names.

## Run the unit tests

In Xcode, choose any iPhone simulator in the device menu and press **⌘U**. Or from Terminal:

```sh
xcodebuild test -project IntervalRun.xcodeproj -scheme IntervalRun \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tests cover how segments are built (warm-up and cool-down on and off, skip last rest on and off, zero rest), total-time math, where the engine is at any time, pause, resume and skip, and when every beep is due (including intervals of 3 seconds or less).

---

## Manual test checklist (on your phone)

A short test workout makes these quick. For example: no warm-up, **work 0:20, rest 0:10, 3 rounds**, cool-down 0:15.

- [ ] **Countdown and switch:** Start it. In the last 3 seconds of each interval you hear short beeps, and at each switch you hear a longer, higher tone. At the very end you hear three rising tones.
  - Note: the countdown beep that would land on an interval's first second is replaced by the switch tone. So a 3-second interval beeps at 2-1, not 3-2-1.
- [ ] **Voice prompts** (Settings → Voice, all on): Use work 0:30 / rest 0:20 for this one so every prompt has room. After the switch tone at the start of each round you hear "Work. 2 intervals left" ("Work. Last interval" in the final round), and "Rest" at each switch to rest. An interval means a whole round of work and rest, so the count goes down only when the next work starts. In the middle of each interval you hear "Halfway there". The last 3 seconds are spoken "three, two, one" right on the second instead of beeped, as one smooth count rather than three separate words. Turn each toggle off and check that prompt stops. With the countdown toggle off, the beeps come back.
- [ ] **Coach voice:** In Settings → Coach voice, pick each of Allison, Brad and iPhone voice. Each choice plays "two, one" in that voice. Start a workout and check that the prompts use the chosen voice, including the distance and pace after a work interval.
- [ ] **Heart rate monitor:** Settings → Heart rate monitor, pick your strap or broadcasting watch; live bpm shows next to it. Start a workout: the heart appears under TOTAL LEFT with live bpm, including after locking the screen for a minute. At the end, each interval shows "avg · max" and History shows heart rate and the drop during rests.
- [ ] **Apple Health heart rate:** Turn on Read from Apple Health and allow access. Do a workout with an Apple Watch workout running at the same time, with no Bluetooth monitor connected. The finish screen or History shows heart rate (it may take until you reopen the app).
- [ ] **Voice while locked and with music:** Repeat the screen-locked and music checks below with voice on. The prompts are on time and duck the music the same way the beeps do.
- [ ] **Distance outdoors (GPS):** Run a workout outside on a route you know the length of, such as a track (one lap in lane 1 is 0.25 mi). The player shows **GPS** under the distance. Interval distance, pace and total go up as you run, and distance stops counting while paused. On the finish screen, each interval has a distance and pace, and the total is within a few percent of the real distance.
- [ ] **Live map:** Start a workout outdoors with a route picked. The map fills the screen behind the timer, north up and following your blue dot, shows the route dotted and draws a solid line where you've run. The top and bottom change color with each phase. Pause, walk a few meters, resume: the line has a gap rather than a jump. Tap the map button: **Map off** (plain screen); the next workout opens the same way. In Settings → Distance → **Step counter only**, there's no map or Map button.
- [ ] **Distance with the screen locked:** Do the same with the phone locked in your pocket. When you unlock it at the end, the distances should look just as sensible.
- [ ] **Spoken distance and pace:** With **Say distance** and **Say pace after each work interval** on, you hear "That was 0.xx miles. 8 minutes 15 per mile." a couple of seconds into each rest, after the intervals-left prompt. The pace should match what the finish screen shows for that interval. Turn either toggle off and only the other part is said. Work intervals under 30 seconds get distance only.
- [ ] **Treadmill / step counter:** In Settings → Distance, pick **Step counter only** and run on a treadmill. The player shows **Step counter** and the distances are roughly in line with the treadmill's display. The step counter is usually within 5–10%, and it gets better after a few GPS runs as the iPhone learns your stride.
- [ ] **History:** Tap the clock button on the home screen. Every finished workout is listed with distance and time, and tapping one shows the interval breakdown. Ending a workout early with ✕ after at least a minute saves it as "Ended early". Swipe left to delete.
- [ ] **Screen locked:** Start a workout, press the side button to lock, and put the phone in your pocket. Beeps keep coming on time for the whole workout.
- [ ] **With music:** Play something in Spotify or Apple Music, then start a workout in Runwise. Music keeps playing. It dips for a few seconds around each switch while the beeps play, then comes back up. It never stops.
- [ ] **Silent switch:** Flip the ring/silent switch to silent (or turn on silent mode with the Action button). Beeps still play.
- [ ] **Pause, resume, skip:** Pause mid-interval and wait 10 seconds. No beeps play while paused. Resume, and the countdown picks up where it stopped, with beeps on time. Tap Skip, and you hear the switch tone straight away and the next countdown is on time.
- [ ] **Long workout accuracy:** Run the sample 24-minute workout, or any workout of 30 minutes or more, next to a stopwatch. Near the end, beeps still land exactly on the second shown on screen.
- [ ] **Music back to normal:** When the workout ends, or when you end it early with ✕ → End Workout, your music returns to full volume.
- [ ] **Back from background:** During a workout, switch to another app for a while, then come back. The screen immediately shows the right phase and time.
- [ ] **Custom pattern:** Create a workout, switch Intervals to **Custom pattern**, and build Work 0:20 → Rest 0:10 → Work 0:30 → Rest 0:10 with 2 rounds. The player steps through all four in order, twice. "Round X of 2" is correct, and with "Skip rest after last round" on, the final rest is skipped.
- [ ] **Sign in:** Enter your email, get the 6-digit code by email, and type it in. You land on the onboarding questions (first time) or the Plan tab.
- [ ] **Onboarding → plan:** Answer the questions and tap **Build my plan**. In about a minute the Plan tab shows your weeks, with "Up next" on your next training day.
- [ ] **Run a plan session:** Open a session, tap **Start**, and finish it. Back on the Plan tab it has a checkmark and the progress bar moves.
- [ ] **Backup:** Sign out (Settings → Sign out) and sign back in. Your workouts, history and plan all come back.
- [ ] **Delete account:** With a throwaway account, go to Settings → Delete account and confirm. Apple accounts are asked to confirm with Apple first. You land back on the sign-in screen, and signing in with the same email starts fresh at the onboarding questions.
- [ ] **Offline:** Turn on Airplane Mode. The plan, workouts and history are still there and runs still work; they upload when you're back online.
- [ ] **Settings:** The ⚙︎ button on the home screen opens Settings. **Test Sound** plays "beep, beep, TONE". The volume slider changes how loud the beeps are, and the vibrate toggle buzzes with each countdown beep.

If ducking behaves oddly with a particular music app, please note which app and what happened. That's the part that depends most on iOS behavior.

---

## How it works (for future changes)

```
IntervalRun/
  IntervalRunApp.swift          App entry, SwiftData container
  Models/
    Workout.swift               SwiftData model (what's saved)
    WorkoutPlan.swift           Plain struct: builds the segment list, totals, summary text
    Segment.swift               Phase (warm-up/work/rest/cool-down) + duration + round
  Engine/
    WorkoutEngine.swift         Clock-based timing: start time + paused time + skipped time
    CuePlanner.swift            When every beep/tone/voice prompt plays and when to duck music
    SpeechRenderer.swift        Gets voice prompts ready as audio: recorded clips, else the system voice
    VoiceClips.swift            Which ElevenLabs clips make up each prompt, and joins them
    HeartRateMonitor.swift      Bluetooth heart rate monitors: pairing, connection, readings
    HeartRateRecorder.swift     Apple Health reading, and adding heart rate to finished runs
    RunTimeline.swift           Real-time stretches the workout was running (for pauses/skips)
    DistanceAccumulator.swift   GPS distance per interval, with jitter/jump filtering
    DistanceTracker.swift       Drives GPS + step counter, picks the source per interval
    RunTrail.swift              The line actually run, for the player's live map
    LivePosition.swift          Runner's position for the live map
    AudioCueScheduler.swift     Audio session, tone generation, exact-time playback
    WorkoutSession.swift        Ties engine + audio + screen refresh together for the player
  Views/                        SwiftUI screens
  Support/                      Time formatting, settings keys, phase colors
IntervalRunTests/               XCTest unit tests
Config/Info.plist               Background audio mode
```

**Timing:** `WorkoutEngine` never counts timer ticks. It stores when the workout started, how long it has been paused and how much time Skip jumped over, then calculates the position from the real clock. The player screen redraws 10 times a second, but each redraw just asks the engine where things are. Because of this, the screen is correct after the app has been in the background.

**Beeps on time:** every beep is generated as a sine wave and queued on an `AVAudioPlayerNode` at an exact sample position, tied to the device's host clock. They are queued on start, resume and skip. The audio hardware plays them on schedule, so there is no drift even if the app is busy or the screen is locked.

**Voice prompts:** phrases aren't spoken live. `SpeechRenderer` gets each phrase ready ahead of time. It joins the recorded ElevenLabs clips (`VoiceClips`) when the app has them all, and otherwise renders the phrase with `AVSpeechSynthesizer.write`. It starts when you open a workout and finishes within a second or two. Then each phrase is queued on the audio clock just like a beep, so prompts are on time and work with the screen locked. If a spoken number isn't ready yet, a beep plays instead. When prompts would overlap, the countdown wins over intervals left, which wins over halfway.

**Distance:**
- **What counts:** GPS fixes are only counted while the workout is running.
- **Filtering:** fixes worse than 25 m accuracy are dropped. Moves smaller than the GPS accuracy are held back, so jitter while you stand still doesn't add phantom distance. Impossible jumps (faster than 12 m/s) are ignored.
- **Interval boundaries:** distance that straddles a boundary is split between the two intervals by time.
- **Choosing a source:** an interval uses GPS if it got at least one good fix every two seconds on average. Otherwise, when the workout ends, the app asks the step counter for exactly the real time ranges of that interval. `RunTimeline` tracks those ranges through pauses and skips.
- **History:** results are saved as `WorkoutRecord` in SwiftData.

**Background and music:** the audio session uses `.playback` (plays on silent) with `.mixWithOthers` (doesn't stop your music). The audio engine runs for the whole workout, which is what keeps iOS from suspending the app when locked. iOS only lowers other apps' audio when a session is activated with `.duckOthers`, and only restores it when the session is deactivated. So the app briefly turns the session off and on about 0.35 s before each group of beeps and again about 0.4 s after. When the workout ends, the session is deactivated with `.notifyOthersOnDeactivation` so music returns to full volume.

**Ideas for later:** a Lock Screen Live Activity could read `WorkoutSession.status`. Workout history could save a record when `WorkoutSession.isFinished` becomes true.
