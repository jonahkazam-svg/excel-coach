# Voice-to-Vault Study Coach — Design

**Date:** 2026-06-09
**Owner:** Jonah
**Status:** Approved (capture-first scope)

## Goal

While learning Excel and financials, Jonah narrates what he's doing out loud. That narration is captured as text into his Obsidian vault, and is later used to train him — via quizzes, flashcards, and weakness reports generated from his own sessions.

## The core insight that shaped this design

The valuable signal is **intentional narration of reasoning** ("I'm using SUMIF here because I only want rows where region = West"), not ambient audio. A truly always-on mic produces low-signal, noisy notes that make a weak coach later. So capture is **session-based** (start when you sit down to learn, stop when done), not always-on.

The capture half is a **solved problem** — a mature Obsidian plugin does it. The custom value is the **coach**, and the coach is dramatically better when built against *real* transcripts rather than guesses. Therefore: **capture first, build the coach after ~1–2 weeks of real sessions.** The #1 risk is not code — it's whether the narrating habit sticks. Capturing first tests that for almost no cost.

## Architecture: two layers

### Layer 1 — Capture (off-the-shelf / "buy")

- **Tool:** the **Whisper** Obsidian community plugin (by nikdanilov). Record / pause / resume / stop maps natively to the study-session model. On stop, it sends audio to a cloud Whisper API and writes a note (plus the audio file) into a chosen vault folder.
- **Provider:** cloud Whisper. **Groq** to start (significantly cheaper than OpenAI, often free within tier limits — confirm current limits at setup); **OpenAI** as the simplest fallback (~$0.36 per hour of audio). Both use the same plugin; this is purely a provider choice, not a re-litigation of cloud-vs-local.
- **Output location:** `AI-Tips-Vault/Sessions/` — one note per session, auto-titled and dated.
- **Auto-cleanup:** the plugin's optional LLM post-processing strips filler words and formats the transcript to clean markdown, so the coach's raw material is already decent.
- **Light metadata (the key enabler):** each session starts by saying the topic aloud ("Today: XLOOKUP and error handling"); post-processing lifts that into the note title and a `topic:` field. This tagging is what makes the coach good later.
- **Prerequisite:** a cloud API key (Groq or OpenAI). ~5-minute signup. This is step 0.

### Layer 2 — Coach (custom / "build", deferred)

One engine — read `Sessions/`, model what was covered and what was fumbled — with three output modes, run as a Claude Code command (e.g. `/coach`):

- **`quiz`** — active recall, interactive in Claude Code: it asks, Jonah answers, it grades and corrects. (Highest learning ROI; built first.)
- **`flashcards`** — extracts Q/A pairs into cards under `AI-Tips-Vault/Flashcards/`, reviewed on a schedule by the **Spaced Repetition** Obsidian plugin (another free buy) so daily review happens inside Obsidian.
- **`report`** — weekly "here's your weak spot + a 10-minute drill," reusing the existing **struggle-tip** skill / `struggle-log.md` infrastructure.

These three are three *outputs of one engine*, not three separate builds — the shared core is "read sessions → understand coverage and gaps."

## Data flow

1. Study → narrate → Whisper plugin → cleaned transcript note in `AI-Tips-Vault/Sessions/`.
2. (Later) `/coach` reads `Sessions/` → generates quizzes / flashcards / reports.
3. Review happens: quizzes interactively in Claude Code; flashcards in Obsidian on a spaced schedule; reports weekly via the struggle-tip system.

## Sequencing

- **Phase 0 — now (this spec's implementation scope):** stand up Layer 1. Get an API key, install + configure the Whisper plugin, create the `Sessions/` folder and a session note template, run a test session, confirm the note looks good. Jonah starts the daily habit immediately.
- **Phase 1 — after ~1–2 weeks of real sessions:** build `/coach quiz`. (Own spec + plan.)
- **Phase 2:** `flashcards` (+ install Spaced Repetition plugin). **Phase 3:** `report`.

## Project layout

`C:\Users\jonah\Projects\excel-coach\` — git-tracked. Holds this spec, the Phase-0 setup guide and session template, and (later) the `/coach` skill. The vault itself stays at `C:\Users\jonah\AI-Tips-Vault\`.

## Decisions log (the forks chosen during brainstorming)

| Decision | Choice | Why |
|---|---|---|
| Capture trigger | Session-based (start/stop) | Frictionless once started; clean per-session unit; avoids always-on noise |
| Transcription | Cloud Whisper | Easiest, best accuracy, trivial cost; works identically on Windows + Mac |
| Build vs buy | Buy capture, build coach | A maintained plugin nails capture; the coach is the part with no off-the-shelf equivalent |
| Coach modes | Quiz + flashcards + weakness reports | All three are outputs of one engine; conversational tutor skipped (least structured) |
| Scope now | Capture only | Coach is far better built against real transcripts; habit is the real risk to test first |
| Provider | Groq first, OpenAI fallback | Cheaper/free-tier for the same plugin |

## Non-goals (YAGNI)

- No always-on / background microphone.
- No custom audio-recording daemon.
- No conversational-tutor mode (open a chat manually if wanted).
- No coach build until Phase 0 has produced real sessions.

## Success criteria

- **Phase 0:** Jonah can sit down, hit record, narrate a study session, stop, and find a clean, topic-tagged transcript note in `AI-Tips-Vault/Sessions/` — with no manual cleanup needed. Habit sustained for ~1–2 weeks.
- **Overall (later):** the coach produces quizzes/flashcards/reports that Jonah finds genuinely target what he actually studied and struggled with.

## Risks & mitigations

- **Habit doesn't stick** → capture-first window tests this cheaply before any coach investment.
- **Transcripts too messy for the coach** → plugin LLM post-processing + spoken topic tag keep notes clean and structured from day one.
- **API cost creeps** → Groq free tier first; cost is ~$0.36/hr even on OpenAI; monitor after the first week.
- **Plugin becomes unmaintained** → notes are plain markdown + audio files in the vault; nothing is locked in, and capture can be swapped to an alternative (Scribe, NeuroVox) without touching the coach.
