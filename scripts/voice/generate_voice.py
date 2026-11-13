#!/usr/bin/env python3
"""Records the coach's voice prompts with ElevenLabs.

Every spoken prompt in the app is built from the short clips listed below
(see IntervalRun/Engine/VoiceClips.swift for how they're joined). This script
asks ElevenLabs to say each one, converts it to AAC and saves it to
IntervalRun/Voice/<voice>/, where Xcode picks it up. Each voice in VOICES is a
choice under Settings → Coach voice. A prompt whose clips are missing falls back
to the iPhone's built-in voice, so the app works without them.

Setup: put your API key in scripts/voice/.env (not committed):
    ELEVENLABS_API_KEY=sk_...

Usage:
    python3 scripts/voice/generate_voice.py --list-voices
    python3 scripts/voice/generate_voice.py --preview <voice name or ElevenLabs ID>
    python3 scripts/voice/generate_voice.py                    # records missing clips for every voice
    python3 scripts/voice/generate_voice.py --voice brad       # just one voice
    python3 scripts/voice/generate_voice.py --force            # re-records everything
    python3 scripts/voice/generate_voice.py --only min-        # re-records clips starting with "min-"
    python3 scripts/voice/generate_voice.py --manifest         # only rewrites manifest.json

To add a voice: add it to VOICES here and to CoachVoice in the app, then run
the script for it. Needs macOS (uses afconvert and afplay). No Python packages required.
"""

import argparse
import array
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CLIP_DIR = REPO / "IntervalRun" / "Voice"
MANIFEST = HERE / "manifest.json"
ENV_FILE = HERE / ".env"

API = "https://api.elevenlabs.io/v1"
MODEL = "eleven_multilingual_v2"
# Steady delivery matters more than expressiveness: clips are joined together,
# so they should sound like one take.
VOICE_SETTINGS = {"stability": 0.6, "similarity_boost": 0.8, "style": 0.0, "use_speaker_boost": True, "speed": 1.0}
SEED = 7

# The coach voices: app name -> ElevenLabs voice ID (from the "Runwiser" collection).
# The names must match CoachVoice in IntervalRun/Engine/VoiceClips.swift.
VOICES = {
    "allison": "xctasy8XvGp2cVO9HL9k",  # Allison - Energetic, Clear and Bubbly
    "brad": "zCgijgIKIMkFHnzXcCva",  # Brad - Energetic, Rushed and Intense
}


def file_name(voice, clip):
    """Matches VoiceClips.fileName in the app."""
    return f"voice-{voice}-{clip}.m4a"

# Ranges the clips cover. Keep in sync with VoiceClips in the app.
INTERVALS_LEFT = range(1, 100)
WHOLE_MILES = range(0, 21)
PACE_MINUTES = range(1, 31)

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def words(n):
    """0-99 in words: 21 -> "twenty-one"."""
    if n < 20:
        return ONES[n]
    tens, ones = divmod(n, 10)
    return TENS[tens] + ("-" + ONES[ones] if ones else "")


def clips():
    """Every clip: (name, text, previous_text, next_text). The surrounding text
    isn't spoken; it tells ElevenLabs how the clip continues, so a fragment like
    "That was" doesn't end with a falling, end-of-sentence tone."""
    out = []

    def add(name, text, before=None, after=None):
        out.append({"name": name, "text": text, "previous_text": before, "next_text": after})

    # Countdown: one take, which the app cuts into its numbers (see save_countdown).
    add(COUNTDOWN, "Three... Two... One...", None, "Go!")

    add("halfway", "Halfway there.")

    # "Work. 5 intervals left" / "Rest. Last interval"
    add("phase-work", "Work.", None, "Five intervals left.")
    add("phase-rest", "Rest.", None, "Five intervals left.")
    add("phase-warm-up", "Warm-up.", None, "Five intervals left.")
    add("cool-down", "Cool-down.")
    # Said alone at a switch within a round: "Rest"
    add("work", "Work.")
    add("rest", "Rest.")
    add("left-1", "Last interval.", "Work.")
    for n in INTERVALS_LEFT:
        if n > 1:
            add(f"left-{n}", f"{words(n).capitalize()} intervals left.", "Work.")

    # "That was 0.21 miles." -> that-was, whole-0, point-21, miles
    add("that-was", "That was", None, "zero point two one miles.")
    for n in WHOLE_MILES:
        add(f"whole-{n}", words(n), "That was", "point two one miles.")
    for n in range(1, 10):
        add(f"point-{n}", f"point {ONES[n]}", "That was zero", "miles.")
    for n in range(1, 100):
        if n % 10:
            tens, ones = divmod(n, 10)
            add(f"point-{n:02d}", f"point {ONES[tens]} {ONES[ones]}", "That was zero", "miles.")
    add("mile", "mile.", "That was one")
    add("miles", "miles.", "That was zero point two one")

    # "8 minutes 15 per mile." -> min-8, sec-15 (or per-mile when the seconds are 0)
    add("pace", "Pace,", None, "eight minutes fifteen per mile.")
    for n in PACE_MINUTES:
        add(f"min-{n}", "one minute" if n == 1 else f"{words(n)} minutes", "That was zero point two one miles.", "fifteen per mile.")
    for n in range(1, 60):
        add(f"sec-{n}", f"{words(n)} per mile.", "eight minutes")
    add("per-mile", "per mile.", "eight minutes")
    return out


def load_env():
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def api_key():
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit(f"No API key. Add ELEVENLABS_API_KEY=... to {ENV_FILE.relative_to(REPO)} or export it.")
    return key


def request(method, path, body=None, query=""):
    url = f"{API}{path}{query}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"xi-api-key": api_key(), "Content-Type": "application/json"}
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data, headers, method=method), timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            if error.code in (429, 500, 502, 503) and attempt < 4:
                wait = 2 ** attempt * 2
                print(f"  ElevenLabs returned {error.code}, retrying in {wait}s")
                time.sleep(wait)
                continue
            sys.exit(f"ElevenLabs error {error.code}: {detail}")
        except urllib.error.URLError as error:
            if attempt < 4:
                time.sleep(2)
                continue
            sys.exit(f"Couldn't reach ElevenLabs: {error.reason}")


def speak(voice_id, text, before=None, after=None, seed=SEED):
    body = {"text": text, "model_id": MODEL, "voice_settings": VOICE_SETTINGS, "seed": seed}
    if before:
        body["previous_text"] = before
    if after:
        body["next_text"] = after
    return request("POST", f"/text-to-speech/{voice_id}", body, "?output_format=mp3_44100_128")


def save_as_aac(mp3, destination):
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "clip.mp3"
        source.write_bytes(mp3)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(source), str(destination)],
                       check=True, capture_output=True)


# The countdown. Matches VoiceClips.countdown* in the app: "Three", "Two" and
# "One" start (first reach 4% of the peak) exactly a second apart, and the app
# plays each from 0.09 s before that start for 0.85 s.
COUNTDOWN = "countdown"
COUNTDOWN_WORDS = 3
COUNTDOWN_LEAD = 0.2  # silence before "Three"
COUNTDOWN_LEAD_IN = 0.08  # up to this much quiet sound (the "th" of "three") is kept before a word
COUNTDOWN_TAIL = 0.15  # kept after each word's end, so it fades out naturally
COUNTDOWN_WORD_MAX = 0.65  # from a word's start to the end of its tail
COUNTDOWN_FADE = 0.03


def find_words(samples, rate):
    """(start, end, lead_in) sample positions of the words in a take, found by
    loudness in 10 ms windows. Quiet gaps shorter than 0.2 s are inside a word.
    `lead_in` is where quieter sound just before the start begins."""
    window = rate // 100
    levels = [max(map(abs, samples[i:i + window]), default=0) for i in range(0, len(samples), window)]
    threshold = 0.04 * max(levels)
    quiet = 0.01 * max(levels)
    runs = []
    for index, level in enumerate(levels):
        if level < threshold:
            continue
        if runs and index - runs[-1][1] < 20:
            runs[-1][1] = index + 1
        else:
            runs.append([index, index + 1])
    words = []
    for a, b in runs:
        if b - a < 6:
            continue  # a click or breath
        lead_in = a
        while lead_in > 0 and a - lead_in < COUNTDOWN_LEAD_IN * 100 and levels[lead_in - 1] >= quiet:
            lead_in -= 1
        words.append((a * window, min(b * window, len(samples)), max(0, (lead_in - 1) * window)))
    return words


def save_countdown(mp3, destination):
    """Saves the countdown take with each number moved to start exactly one
    second after the last, so the app can play them one per second and they
    still sound like one take. Returns False if the take doesn't have three
    clearly separate words."""
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "take.mp3"
        source.write_bytes(mp3)
        decoded = Path(tmp) / "take.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "1", str(source), str(decoded)],
                       check=True, capture_output=True)
        with wave.open(str(decoded)) as take:
            rate = take.getframerate()
            samples = array.array("h", take.readframes(take.getnframes()))
        if sys.byteorder == "big":
            samples.byteswap()

        words = find_words(samples, rate)
        if len(words) != COUNTDOWN_WORDS:
            print(f"  heard {len(words)} words instead of {COUNTDOWN_WORDS}")
            return False
        gridded = array.array("h", bytes(2 * int((COUNTDOWN_LEAD + COUNTDOWN_WORDS + 0.2) * rate)))
        for number, (start, end, first) in enumerate(words):
            next_first = words[number + 1][2] if number + 1 < len(words) else len(samples)
            last = min(end + int(COUNTDOWN_TAIL * rate), next_first, start + int(COUNTDOWN_WORD_MAX * rate))
            word = samples[first:last]
            fade = min(int(COUNTDOWN_FADE * rate), len(word))
            for i in range(fade):
                word[len(word) - fade + i] = int(word[len(word) - fade + i] * (fade - i) / fade)
            # The word's detected start lands exactly on its second.
            at = int((COUNTDOWN_LEAD + number) * rate) - (start - first)
            gridded[at:at + len(word)] = word
            print(f"  {['Three', 'Two', 'One'][number]}: {(end - start) / rate:.2f} s")

        if sys.byteorder == "big":
            gridded.byteswap()
        spaced = Path(tmp) / "countdown.wav"
        with wave.open(str(spaced), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(rate)
            out.writeframes(gridded.tobytes())
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(spaced), str(destination)],
                       check=True, capture_output=True)
    return True


def list_voices():
    voices = json.loads(request("GET", "/voices"))["voices"]
    for voice in sorted(voices, key=lambda v: v["name"]):
        labels = ", ".join(str(v) for v in (voice.get("labels") or {}).values())
        print(f"{voice['voice_id']}  {voice['name']:<24} {labels}")


def preview(voice_id):
    """Plays a few full prompts so a voice can be judged before recording everything."""
    lines = ["Work. Five intervals left.", "Halfway there.", "Three... Two... One...",
             "That was zero point two one miles. Eight minutes fifteen per mile."]
    with tempfile.TemporaryDirectory() as tmp:
        for i, line in enumerate(lines):
            path = Path(tmp) / f"{i}.mp3"
            path.write_bytes(speak(voice_id, line))
            print(f"  {line}")
            subprocess.run(["afplay", str(path)], check=False)


def write_manifest(all_clips):
    manifest = {"voices": VOICES, "clips": [{"name": c["name"], "text": c["text"]} for c in all_clips]}
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")


def record(voice, voice_id, all_clips, args):
    folder = CLIP_DIR / voice
    folder.mkdir(parents=True, exist_ok=True)
    todo = [c for c in all_clips
            if (not args.only or c["name"].startswith(args.only))
            and (args.force or args.only or not (folder / file_name(voice, c["name"])).exists())]
    characters = sum(len(c["text"]) for c in todo)
    print(f"{voice}: recording {len(todo)} of {len(all_clips)} clips (about {characters} characters)")
    for i, clip in enumerate(todo, 1):
        print(f"  [{i}/{len(todo)}] {clip['name']}: {clip['text']}")
        if clip["name"] == COUNTDOWN:
            # A take where the words run together can't be cut; try another seed.
            for seed in range(SEED, SEED + 5):
                mp3 = speak(voice_id, clip["text"], clip["previous_text"], clip["next_text"], seed)
                if save_countdown(mp3, folder / file_name(voice, clip["name"])):
                    break
            else:
                sys.exit(f"Couldn't get a {voice} countdown with three separate words. Try changing its text.")
            continue
        mp3 = speak(voice_id, clip["text"], clip["previous_text"], clip["next_text"])
        save_as_aac(mp3, folder / file_name(voice, clip["name"]))

    names = {file_name(voice, c["name"]) for c in all_clips}
    stale = sorted(p.name for p in folder.glob("*.m4a") if p.name not in names)
    if stale:
        print(f"  Not used by the app any more (safe to delete): {', '.join(stale)}")


def main():
    parser = argparse.ArgumentParser(description="Record the coach's voice prompts with ElevenLabs.")
    parser.add_argument("--voice", choices=sorted(VOICES), help="record just this voice (default: all)")
    parser.add_argument("--list-voices", action="store_true", help="list the voices on your ElevenLabs account")
    parser.add_argument("--preview", metavar="VOICE", help="play sample prompts in a voice (a name above or an ElevenLabs ID), without saving")
    parser.add_argument("--force", action="store_true", help="re-record clips that already exist")
    parser.add_argument("--only", help="only clips whose name starts with this")
    parser.add_argument("--manifest", action="store_true", help="only rewrite manifest.json")
    args = parser.parse_args()

    load_env()
    all_clips = clips()
    write_manifest(all_clips)
    if args.manifest:
        print(f"Wrote {MANIFEST.relative_to(REPO)} ({len(all_clips)} clips, {len(VOICES)} voices)")
        return
    if args.list_voices:
        list_voices()
        return
    if args.preview:
        preview(VOICES.get(args.preview, args.preview))
        return

    for voice in [args.voice] if args.voice else sorted(VOICES):
        record(voice, VOICES[voice], all_clips, args)
    print(f"Done. Clips are in {CLIP_DIR.relative_to(REPO)}/. Build the app to include them.")

if __name__ == "__main__":
    main()
