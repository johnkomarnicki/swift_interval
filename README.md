# Interval Run

A personal iPhone interval timer for 5K training. You set an optional warm-up, the intervals for one round, the number of rounds and an optional cool-down. A round is either one work and one rest interval, or a **custom pattern** of work and rest steps (for example: jog 1:30, walk 1:30, jog 3:00, walk 3:00, twice). During the workout the app beeps in the last 5 seconds of every interval and plays a longer tone at each switch. This works with the phone locked, with music playing, and with the silent switch on.

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

The app is now on your home screen as **Interval Run**. You can unplug the phone and use it normally.

---

## How to reinstall (every 7 days)

> **With a free Apple ID, apps you install this way stop opening after 7 days.** This is an Apple limit. Your saved workouts are kept. A paid Apple Developer account ($99/year) extends this to one year.

When the app stops opening:

1. Plug in the iPhone and open `IntervalRun.xcodeproj`.
2. Pick your iPhone in the device menu at the top.
3. Press **▶︎**.

That's all. If Xcode says your signing certificate is invalid, go to **Signing & Capabilities** and re-select your Personal Team.

---

## Run the unit tests

In Xcode, choose any iPhone simulator in the device menu and press **⌘U**. Or from Terminal:

```sh
xcodebuild test -project IntervalRun.xcodeproj -scheme IntervalRun \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tests cover how segments are built (warm-up and cool-down on and off, skip last rest on and off, zero rest), total-time math, where the engine is at any time, pause, resume and skip, and when every beep is due (including intervals of 5 seconds or less).

---

## Manual test checklist (on your phone)

A short test workout makes these quick. For example: no warm-up, **work 0:20, rest 0:10, 3 rounds**, cool-down 0:15.

- [ ] **Countdown and switch:** Start it. In the last 5 seconds of each interval you hear short beeps, and at each switch you hear a longer, higher tone. At the very end you hear three rising tones.
  - Note: the countdown beep that would land on an interval's first second is replaced by the switch tone. So a 5-second interval beeps at 4-3-2-1, not 5-4-3-2-1.
- [ ] **Screen locked:** Start a workout, press the side button to lock, and put the phone in your pocket. Beeps keep coming on time for the whole workout.
- [ ] **With music:** Play something in Spotify or Apple Music, then start a workout in Interval Run. Music keeps playing. It dips for a few seconds around each switch while the beeps play, then comes back up. It never stops.
- [ ] **Silent switch:** Flip the ring/silent switch to silent (or turn on silent mode with the Action button). Beeps still play.
- [ ] **Pause, resume, skip:** Pause mid-interval and wait 10 seconds. No beeps play while paused. Resume, and the countdown picks up where it stopped, with beeps on time. Tap Skip, and you hear the switch tone straight away and the next countdown is on time.
- [ ] **Long workout accuracy:** Run the sample 24-minute workout, or any workout of 30 minutes or more, next to a stopwatch. Near the end, beeps still land exactly on the second shown on screen.
- [ ] **Music back to normal:** When the workout ends, or when you end it early with ✕ → End Workout, your music returns to full volume.
- [ ] **Back from background:** During a workout, switch to another app for a while, then come back. The screen immediately shows the right phase and time.
- [ ] **Custom pattern:** Create a workout, switch Intervals to **Custom pattern**, and build Work 0:20 → Rest 0:10 → Work 0:30 → Rest 0:10 with 2 rounds. The player steps through all four in order, twice. "Round X of 2" is correct, and with "Skip rest after last round" on, the final rest is skipped.
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
    CuePlanner.swift            When every beep/tone plays and when to duck music
    AudioCueScheduler.swift     Audio session, tone generation, exact-time playback
    WorkoutSession.swift        Ties engine + audio + screen refresh together for the player
  Views/                        SwiftUI screens
  Support/                      Time formatting, settings keys, phase colors
IntervalRunTests/               XCTest unit tests
Config/Info.plist               Background audio mode
```

**Timing:** `WorkoutEngine` never counts timer ticks. It stores when the workout started, how long it has been paused and how much time Skip jumped over, then calculates the position from the real clock. The player screen redraws 10 times a second, but each redraw just asks the engine where things are. Because of this, the screen is correct after the app has been in the background.

**Beeps on time:** every beep is generated as a sine wave and queued on an `AVAudioPlayerNode` at an exact sample position, tied to the device's host clock. They are queued on start, resume and skip. The audio hardware plays them on schedule, so there is no drift even if the app is busy or the screen is locked.

**Background and music:** the audio session uses `.playback` (plays on silent) with `.mixWithOthers` (doesn't stop your music). The audio engine runs for the whole workout, which is what keeps iOS from suspending the app when locked. iOS only lowers other apps' audio when a session is activated with `.duckOthers`, and only restores it when the session is deactivated. So the app briefly turns the session off and on about 0.35 s before each group of beeps and again about 0.4 s after. When the workout ends, the session is deactivated with `.notifyOthersOnDeactivation` so music returns to full volume.

**Ideas for later:** a Lock Screen Live Activity could read `WorkoutSession.status`. Workout history could save a record when `WorkoutSession.isFinished` becomes true.
