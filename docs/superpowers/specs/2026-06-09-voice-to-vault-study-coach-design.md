# Voice-to-Vault Study Coach — Design

**Date:** 2026-06-09
**Owner:** Jonah
**Status:** Approved (capture-first scope; audio + screen)

## Goal

While learning Excel and financials (Breaking Into Wall Street course), Jonah narrates what he's doing out loud *and* his on-screen work is captured. Both land in his Obsidian vault as per-session records, and are later used to train him — via quizzes, flashcards, and weakness reports generated from his own sessions.

## The core insight that shaped this design

The valuable signal is **intentional capture of reasoning and work during a study session** — spoken ("I'm using SUMIF here because I only want rows where region = West") and visual (the DCF tab he just built, the formula in the cell he fumbled). Ambient, always-on capture (mic or screen) produces low-signal, noisy, privacy-heavy data that makes a weak coach. So **both audio and screen are session-scoped** — start when you sit down to learn, stop when done — **never always-on.**

Capture is a **solved / buy problem** (audio plugin + screen-capture tool). The custom value is the **coach**, and it's far better built against *real* sessions than guesses. So: **capture first (audio + screen), build the coach after ~1–2 weeks of real sessions.** The #1 risk is whether the habit sticks, not code — capturing first tests that cheaply.

A key cost decision falls out of this: **we do not build a vision pipeline.** Screenshots are just saved locally during sessions (free). The coach (Claude) reads those images directly when it runs — so vision cost is paid *only when coaching*, never passively.

## Architecture: two layers

### Layer 1 — Capture (audio + screen) — off-the-shelf / "buy"

**Audio:**
- **Whisper** Obsidian plugin (nikdanilov). Record / pause / resume / stop = the study-session model. On stop, sends audio to cloud Whisper, writes a transcript note + audio file into a vault folder.
- **Provider:** cloud Whisper — **Groq** to start (cheaper, often free within tier limits) or **OpenAI** (simplest, ~$0.36/hr). Same plugin either way. *(OPEN: Jonah to confirm Groq vs OpenAI.)*
- **Auto-cleanup:** plugin LLM post-processing strips filler and formats to clean markdown.
- **Spoken topic tag:** each session starts by saying the topic ("Today: XLOOKUP and error handling"); post-processing lifts it into the note title + a `topic:` field. This is what makes the coach good later.

**Screen:**
- **Tool:** **ShareX** on Windows (auto-capture at interval + custom hotkeys + auto-save to folder, free/open source). On Mac, built-in `screencapture` on a timer or a small app (e.g. Timed Screenshot).
- **Trigger:** **both** — a ~60s timer for a hands-off baseline *plus* a hotkey for "definitely capture this" key moments.
- **Privacy guardrail:** capture **only the Excel / course window** (or a single monitor), never the full desktop — so it can't grab email, brokerage, passwords, etc. Images stay **local** in the vault until the coach is run.
- **Where images land:** `AI-Tips-Vault/Sessions/_screenshots/` with datetime-stamped filenames (date subfolders via the capture tool's filename pattern).
- **Correlation:** screenshots tie to a transcript by **timestamp** (both share the session's time window); the coach groups "this session's" audio + images by time.

**Session output (per session):**
- Transcript note in `AI-Tips-Vault/Sessions/` (auto-titled, dated, topic-tagged).
- Audio file (plugin).
- Timestamped screenshots in `Sessions/_screenshots/`.

### Layer 2 — Coach (custom / "build", deferred)

One engine — read a session's transcript **and** its screenshots (vision), model coverage and gaps — with three output modes, run as a Claude Code command (e.g. `/coach`):

- **`quiz`** — active recall, interactive in Claude Code: asks, Jonah answers, grades and corrects. (Built first; highest ROI.)
- **`flashcards`** — extracts Q/A pairs into cards under `AI-Tips-Vault/Flashcards/`, reviewed on a schedule by the **Spaced Repetition** Obsidian plugin (free buy).
- **`report`** — weekly "weak spot + 10-minute drill," reusing the existing **struggle-tip** skill / `struggle-log.md`.

Three outputs of one engine, not three builds. The screenshots make every mode more concrete (quiz off the actual model you built; flashcards of the real formula; report on what the screen shows you struggling with).

## Data flow

1. Study session → narrate (Whisper plugin) + screen captured (ShareX/timer+hotkey) → transcript note in `Sessions/`, audio file, timestamped images in `Sessions/_screenshots/`.
2. (Later) `/coach` reads a session's transcript + images → generates quizzes / flashcards / reports.
3. Review: quizzes interactively in Claude Code; flashcards in Obsidian on a spaced schedule; reports weekly via struggle-tip.

## Sequencing

- **Phase 0 — now (this spec's implementation scope):** stand up Layer 1, **audio + screen**. Get an API key; install + configure the Whisper plugin; install + configure ShareX (window-only capture, ~60s timer + hotkey, save to `_screenshots/`); create the `Sessions/` structure + a session note template; run a test session; confirm transcript + screenshots come out clean and correlate. Jonah starts the daily habit. *(Screen capture must be live from day one — past sessions can't be re-screenshotted.)*
- **Phase 1 — after ~1–2 weeks of real sessions:** build `/coach quiz` (reads transcript + images). Own spec + plan.
- **Phase 2:** `flashcards` (+ Spaced Repetition plugin). **Phase 3:** `report`.

## Project layout

`C:\Users\jonah\Projects\excel-coach\` — git-tracked. Holds this spec, the Phase-0 setup guide + session template, and (later) the `/coach` skill. Vault stays at `C:\Users\jonah\AI-Tips-Vault\`.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Capture trigger (audio) | Session-based start/stop | Clean per-session unit; avoids always-on noise |
| Transcription | Cloud Whisper | Easiest, accurate, trivial cost; same on Win + Mac |
| Provider | Groq first, OpenAI fallback (OPEN) | Cheaper/free-tier for the same plugin |
| Build vs buy | Buy capture, build coach | Plugins/tools nail capture; coach has no off-the-shelf equivalent |
| Add screen capture | Yes — financial modeling is visual | A screenshot of the model beats narrating every cell |
| Screen trigger | Both: ~60s timer + hotkey | Hands-off baseline + curated key moments |
| Screen tool | ShareX (Win) / screencapture (Mac) | Free, interval + hotkey + auto-save to folder |
| Screen privacy | Window/monitor-only, local until coached | Never grabs email/brokerage; no passive vision cost |
| Coach modes | Quiz + flashcards + reports | Three outputs of one engine; tutor skipped |
| Scope now | Capture only (audio + screen) | Coach is better built on real data; habit is the real risk |

## Non-goals (YAGNI)

- No always-on / background microphone **or screen monitoring**.
- No custom audio-recording or screen-recording daemon.
- No continuous / passive vision analysis (coach reads images on demand only).
- No conversational-tutor mode.
- No coach build until Phase 0 has produced real sessions.

## Success criteria

- **Phase 0:** Jonah sits down, hits record, narrates while ShareX captures his Excel window; on stop he finds, for that session, a clean topic-tagged transcript note **and** a set of timestamped screenshots in the vault — correlated, no manual cleanup. Habit sustained ~1–2 weeks.
- **Overall (later):** the coach's quizzes/flashcards/reports clearly target what Jonah actually studied and struggled with, grounded in both his words and his screen.

## Risks & mitigations

- **Habit doesn't stick** → capture-first window tests it cheaply before any coach investment.
- **Screen privacy** → window/monitor-only capture; images stay local until the coach is explicitly run; session-scoped, never always-on.
- **Vision cost (coach phase)** → images analyzed only on demand when coaching; dedupe near-identical frames and/or lean on hotkey-curated shots; tune at Phase 1.
- **Transcripts messy** → plugin LLM post-processing + spoken topic tag keep notes clean from day one.
- **Storage** → ~a few MB of images per session; trivial.
- **Capture tool unmaintained** → outputs are plain markdown + audio + image files in the vault; nothing locked in; capture tools are swappable without touching the coach.
