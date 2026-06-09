# Excel Coach — Study Vault

Your dedicated vault for learning Excel + financials (Breaking Into Wall Street).
**Separate from `AI-Tips-Vault` on purpose** — its own self-contained thing.

## ▶️ Run a study session
1. Open **Obsidian** (this vault) and **ShareX**.
2. **Start screen capture:** ShareX → **Tools → Auto capture** → choose **Fullscreen** (or drag a box over Excel) → **Start**. Grabs a shot every **30 seconds**.
3. **Start voice:** click the **mic icon** in Obsidian (or press `Alt+Q`). **Say your topic first** — e.g. *"Today: XLOOKUP and error handling."*
4. Study, and **narrate what you're doing** out loud.
5. **Stop both** when done: `Alt+Q` (voice → transcript saves to `Sessions/`), and ShareX Auto capture → **Stop**.

Result: a transcript note in `Sessions/` + timestamped screenshots in `Sessions/_screenshots/`.

Quick grab anytime: **Print Screen** = full screen, **Alt+Print Screen** = active window.

## Status — Phase 0 (capture)
- 🎙️ Voice → transcript: **working**
- 🖼️ Screen capture (ShareX — 30s timer + hotkeys, saves locally, uploads hard-disabled): **working**
- 🔊 Course/instructor audio (VoiceMeeter mix): **not set up yet** — optional Phase 0.5

## What goes where
- `Sessions/` — study-session transcripts (your voice). Auto-created by the Whisper plugin.
- `Sessions/_screenshots/` — screenshots (ShareX), in month subfolders like `2026-06/`.
- `Flashcards/` — *(later)* spaced-repetition cards from the coach.
- `docs/` — the design spec.
- `coach/` — *(later)* the `/coach` tool (quizzes, flashcards, weakness reports).

## The coach (later)
After ~1–2 weeks of real sessions, we build `/coach` to turn these into quizzes, flashcards, and weakness reports.
Full plan: `docs/superpowers/specs/2026-06-09-voice-to-vault-study-coach-design.md`

## Privacy
Your sessions, screenshots, and Obsidian/ShareX settings (including your OpenAI key) stay on your machine and are kept out of git.
