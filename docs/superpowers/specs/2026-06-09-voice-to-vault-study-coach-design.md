# Voice-to-Vault Study Coach — Design

**Date:** 2026-06-09
**Owner:** Jonah
**Status:** Approved (capture-first scope; audio + screen + course audio)

## Goal

While learning Excel and financials (Breaking Into Wall Street course), Jonah's study sessions are captured three ways — his spoken narration, his on-screen work, and the course video's instructor audio — into his Obsidian vault as per-session records. These are later used to train him: quizzes, flashcards, and weakness reports generated from his own sessions.

## The core insight that shaped this design

The valuable signal is **intentional capture during a study session** — what Jonah says, what's on his screen, and what the instructor explains. Ambient always-on capture (mic or screen) is low-signal, noisy, and privacy-heavy. So **all capture is session-scoped — start when you sit down, stop when done — never always-on.**

Two kinds of material, worth separating:
- **The lesson** — what the instructor teaches (captured via course-video audio + screenshots of the video).
- **Jonah's practice** — him doing it, narrating, fumbling (mic + screenshots of his Excel). *This is the gold for training him — it's unique to him.*

Capture is a **buy** problem (audio plugin + screen tool + audio-routing tool). The custom value is the **coach**, built later against *real* sessions. So: **capture first, build the coach after ~1–2 weeks.** The #1 risk is whether the habit sticks, not code.

We **do not build a vision pipeline** and **do not run continuous video-AI.** Screenshots are saved locally during sessions (free); the coach (Claude) reads them on demand when it runs — vision cost is paid only when coaching, never passively. Likewise, we do not "watch videos live" — the course already contains that info; we just capture its audio + frames.

## Architecture: two layers

### Layer 1 — Capture (off-the-shelf / "buy")

**A. Jonah's voice (mic) — Phase 0**
- **Whisper** Obsidian plugin (nikdanilov). Record / pause / resume / stop = the study-session model. On stop, sends audio to **OpenAI** Whisper (~$0.36/hr), writes a transcript note + audio file to a vault folder.
- **Auto-cleanup:** plugin LLM post-processing strips filler, formats to clean markdown.
- **Spoken topic tag:** start each session by saying the topic ("Today: XLOOKUP and error handling"); post-processing lifts it into the note title + a `topic:` field — this is what makes the coach good later.

**B. Screen — Phase 0**
- **ShareX** (Windows) / `screencapture` or a timer app (Mac). **Both** a ~60s timer (hands-off baseline) and a hotkey (key moments).
- **Privacy guardrail:** capture **only the Excel / course window** (or one monitor), never the full desktop. Images stay **local** until the coach is run.
- **Where:** `AI-Tips-Vault/Sessions/_screenshots/`, datetime-stamped; correlated to the transcript by timestamp.

**C. Course/instructor audio — Phase 0.5 (fast-follow, not blocking the start)**
- The plugin records the **mic**, not desktop audio — so the instructor isn't captured by default.
- **Tool:** **VoiceMeeter** (free, VB-Audio) mixes Jonah's mic + the video's desktop audio into one virtual feed; set that feed as the default input the Whisper plugin records. Result: **one combined session transcript** (Jonah + instructor). (VB-CABLE alone suffices if only desktop audio is ever needed; VoiceMeeter is for mixing both.)
- **Why a fast-follow:** audio routing is the fiddliest setup; sequencing it second keeps the habit starting this week. Guided live (GUI config).
- **Merged transcript is acceptable;** if speaker mixing proves too muddy, separating into two tracks is a possible later refinement.
- **Personal-study use only** — captured course content stays in the private vault, not redistributed.

**Session output (per session):** transcript note in `Sessions/` (auto-titled, dated, topic-tagged) · audio file · timestamped screenshots in `_screenshots/` · (after 0.5) instructor audio folded into the transcript.

### Layer 2 — Coach (custom / "build", deferred)

One engine — read a session's transcript (Jonah + instructor) **and** its screenshots (vision), model coverage and gaps — three output modes, run as a Claude Code command (e.g. `/coach`):
- **`quiz`** — interactive active recall in Claude Code (built first; highest ROI).
- **`flashcards`** — Q/A pairs into `AI-Tips-Vault/Flashcards/`, scheduled by the **Spaced Repetition** plugin (free buy).
- **`report`** — weekly "weak spot + 10-minute drill," reusing the existing **struggle-tip** skill / `struggle-log.md`.

Three outputs of one engine, not three builds. Screenshots + instructor audio make every mode concrete (quiz off the actual model and what the instructor taught; flashcards of the real formula; report on where the screen/words show you struggling).

## Data flow

1. Study session → narrate (mic) + screen captured (timer+hotkey) + (0.5) instructor audio mixed in → transcript note in `Sessions/`, audio file, timestamped images in `_screenshots/`.
2. (Later) `/coach` reads a session's transcript + images → quizzes / flashcards / reports.
3. Review: quizzes interactively; flashcards in Obsidian on a spaced schedule; reports weekly via struggle-tip.

## Sequencing

- **Phase 0 — now (this spec's implementation scope):** mic (Whisper plugin, OpenAI) + screen (ShareX, window-only, timer+hotkey) + `Sessions/` structure + session template + test session. Habit starts. *(Screen must be live from day one — past sessions can't be re-captured.)*
- **Phase 0.5 — immediate fast-follow:** instructor audio via VoiceMeeter, guided live.
- **Phase 1 — after ~1–2 weeks of real sessions:** build `/coach quiz`. Own spec + plan.
- **Phase 2:** `flashcards` (+ Spaced Repetition plugin). **Phase 3:** `report`.

## Project layout

`C:\Users\jonah\Projects\excel-coach\` — git-tracked. Holds this spec, the Phase-0 setup guide + session template, and (later) the `/coach` skill. Vault stays at `C:\Users\jonah\AI-Tips-Vault\`.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Capture trigger | Session-based start/stop (all modes) | Clean per-session unit; avoids always-on noise |
| Transcription | Cloud Whisper, **OpenAI** | Easiest, accurate, ~$0.36/hr; same on Win + Mac |
| Build vs buy | Buy capture, build coach | Tools nail capture; coach has no off-the-shelf equivalent |
| Screen capture | Yes; both ~60s timer + hotkey | Modeling is visual; hands-off baseline + curated moments |
| Screen tool / privacy | ShareX (Win) / screencapture (Mac); window-only, local until coached | Free interval+hotkey+autosave; never grabs email/brokerage; no passive vision cost |
| Course videos | Capture instructor audio (not live video-AI) | Visuals already in screenshots; instructor's words are the valuable add; live video-AI is costly/redundant |
| Course-audio method | VoiceMeeter mix → Whisper plugin, **Phase 0.5** | Reuses the plugin; one transcript; sequenced second so routing setup doesn't block the start |
| Coach modes | Quiz + flashcards + reports | Three outputs of one engine; tutor skipped |
| Scope now | Capture only | Coach is better built on real data; habit is the real risk |

## Non-goals (YAGNI)

- No always-on / background mic **or screen**.
- No custom audio/screen-recording daemon.
- No continuous / passive vision analysis; no live "AI watches the video."
- No conversational-tutor mode.
- No coach build until Phase 0 has produced real sessions.

## Success criteria

- **Phase 0:** Jonah sits down, hits record, narrates while ShareX captures his Excel window; on stop he finds a clean topic-tagged transcript **and** correlated timestamped screenshots for that session — no manual cleanup. Habit sustained ~1–2 weeks.
- **Phase 0.5:** the instructor's spoken explanation appears in the session transcript alongside Jonah's.
- **Overall (later):** the coach's quizzes/flashcards/reports clearly target what Jonah actually studied and struggled with, grounded in his words, the instructor's words, and his screen.

## Risks & mitigations

- **Habit doesn't stick** → capture-first window tests it cheaply before any coach investment.
- **Audio-routing complexity** → sequenced as Phase 0.5, guided live; never blocks the Phase 0 start.
- **Screen/audio privacy** → window-only screen capture; all media stays local until the coach is explicitly run; session-scoped, never always-on.
- **Vision cost (coach phase)** → images analyzed on demand only; dedupe near-identical frames / lean on hotkey shots; tune at Phase 1.
- **Merged transcript muddiness** → acceptable for coaching; two-track separation is a later option if needed.
- **Course content / copyright** → personal-study use, stored locally in a private vault, not redistributed.
- **Transcripts messy / Storage / Tool unmaintained** → post-processing + topic tag keep notes clean; media is a few MB/session; all outputs are plain files (markdown/audio/images) — nothing locked in, capture tools are swappable without touching the coach.
