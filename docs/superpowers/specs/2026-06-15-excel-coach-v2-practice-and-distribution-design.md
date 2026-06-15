# excel-coach v2 - Practice System + Distribution (design spec)

Date: 2026-06-15
Status: approved by Jonah ("Yes do it"), ready for implementation

## Goal
Grow excel-coach from a personal live-coaching tool into (1) a real practice/testing
system and (2) a distributable Windows product other people can install with their own
API keys and that auto-updates when Jonah ships changes. Mac is explicitly future work.

## Architecture principle (non-negotiable)
`watch.ps1` is already a large, fragile file (ASCII-only, PowerShell 5.1, three
single-quoted here-strings, mandatory parse-gate before every commit). ALL new
functionality lives in NEW modules that `watch.ps1` dot-sources near the top
(alongside `curriculum.ps1`):

- `tools/deck.ps1`     - content engine (build/query the flashcard deck)
- `tools/practice.ps1` - spaced-repetition (SM-2) + quiz engine
- `tools/updater.ps1`  - version check + self-update
- `tools/setup.ps1`    - first-run bring-your-own-key setup
- `installer/excel-coach.iss` - Inno Setup installer script

This keeps parallel agents on disjoint files, preserves the parse-gate discipline, and
is simply better architecture. `watch.ps1` gets only a few wiring lines (dot-source +
button dispatch), which the integration owner (main thread) edits carefully.

All new `.ps1` files MUST be ASCII-only and pass `[PSParser]::Tokenize` with zero errors
before commit. All new JSON is written UTF-8 (no BOM).

---

## Phase 1 - Practice system

### Module: tools/deck.ps1 (content engine)
Generates a structured deck from the existing 57-node curriculum (`curriculum.ps1`
nodes / `Curriculum.md`) using the model, caches it to `data/deck.json`.

Public functions:
- `Build-Deck [-Force]` - for each curriculum topic, call the model to produce cards;
  write `data/deck.json`. No-op if deck.json already exists unless `-Force`.
- `Get-Deck` - load and return deck.json as a PS object (cached in-process).
- `Get-TopicCards($topicId)` - return the cards array for one topic.

`data/deck.json` schema:
```
{
  "version": 1,
  "generatedAt": "<ISO8601>",
  "topics": [
    { "id": "<curriculum-node-id>", "name": "...", "category": "...",
      "cards": [
        { "id": "<topic>-<n>", "type": "flashcard|definition|formula",
          "front": "...", "back": "...",
          "choices": ["...","...","...","..."],   // present only for quiz-able cards
          "answer": 0 }                            // index into choices; omit if none
      ] }
  ]
}
```
Generation prompt requirements: concise IB-accurate cards; formulas as plain text;
4 plausible choices for quiz-able cards with exactly one correct `answer` index.

### Module: tools/practice.ps1 (SRS + quiz)
SM-2 spaced repetition over the deck. Review state in `data/review-state.json`.

Public functions:
- `Get-DueCards([int]$limit=20)` - cards whose `due` <= now (new cards seeded as due).
- `Rate-Card($cardId,[int]$quality)` - quality 0..5; apply SM-2; persist.
- `New-Quiz($topicId,[int]$n=10)` - build an n-question multiple-choice quiz from the
  deck's quiz-able cards for that topic.
- `Get-PracticeStats` - { dueCount, totalCards, streakDays, weakTopics[] }. weakTopics
  feeds the existing struggle profile (Consolidate-WeakPoints / Build-StruggleProfile).

`data/review-state.json` schema:
```
{ "cards": { "<cardId>": { "ease": 2.5, "intervalDays": 0, "due": "<ISO>",
                            "reps": 0, "lapses": 0, "lastRated": "<ISO>" } },
  "history": [ { "cardId": "...", "quality": 4, "at": "<ISO>" } ],
  "streakDays": 0, "lastStudied": "<ISO>" }
```
SM-2 rules: ease starts 2.5, floor 1.3. If quality < 3: reps=0, intervalDays=1, lapses++.
Else: reps==0 -> 1 day; reps==1 -> 6 days; else round(intervalDays*ease).
ease += 0.1 - (5-quality)*(0.08 + (5-quality)*0.02); clamp >= 1.3. due = now + intervalDays.

### UI (integration owner)
- New "Practice" chip on the strip -> opens a practice view in the existing WebView2
  panel (`panel.html`): flashcard review (show front -> reveal back -> rate 1..4),
  multiple-choice quiz mode, and a "N cards due today" indicator.
- Reuses existing panel plumbing; no new window.

### Excel-exercise generator (integration owner)
Extend the existing Teach/Drill build functions so a "Practice in Excel" action takes a
`topicId`, builds a fresh fill-in exercise in Excel for that topic, then checks answers
(the existing drill/check flow already does the building + checking; this makes it
topic-driven from the deck instead of freeform).

---

## Phase 2 - Distribution + auto-update

### Module: tools/setup.ps1 (first-run, bring-your-own-key)
Public functions:
- `Test-FirstRun` - true if `.env` is missing OPENAI_API_KEY.
- `Invoke-Setup` - prompt the user (WebView2 form, console fallback) for their own
  OPENAI_API_KEY + mic device; validate the key with a cheap test API call; write `.env`
  (UTF-8 no BOM). Never bundle or transmit a key anywhere but their local `.env`.

### Module: tools/updater.ps1 (self-update)
Local version lives in `VERSION` (single line, semver). Public functions:
- `Check-Update` - GET the version manifest (HTTPS URL from config); return
  `{ updateAvailable, latestVersion, url, sha256, notes }`.
- `Apply-Update` - download the bundle to a temp dir, verify SHA-256 against the
  manifest, then atomically swap in the new files while PRESERVING `.env` and
  `data/review-state.json` (and `data/deck.json` unless the manifest bumps it), then
  relaunch. Roll back on any failure.

Manifest schema (hosted on Jonah's GitHub Releases):
```
{ "version": "1.2.0", "url": "https://.../excel-coach-1.2.0.zip",
  "sha256": "<hex>", "notes": "..." }
```
Security: HTTPS only; SHA-256 mandatory; only the configured release host is trusted;
never execute downloaded code without a verified checksum.

### Installer: installer/excel-coach.iss (Inno Setup)
Bundles: `tools/*.ps1`, `tools/ui/*`, `curriculum.*`, `data/deck.json`, `ffmpeg.exe`,
the WebView2 bootstrapper, `VERSION`, and a launcher `.cmd`/shortcut. Installs to
`{localappdata}\ExcelCoach`. Creates a Start-menu shortcut. On first launch the launcher
runs `setup.ps1` if `Test-FirstRun`. Chosen over PS2EXE (AV false-positives) and over an
Electron/Tauri rewrite (too large a lift now). Code-signing the installer is recommended
to reduce SmartScreen/Defender friction (cert ~$200/yr) - flagged, not required for v2.

---

## Integration points (main thread owns these; fragile files)
1. `watch.ps1`: dot-source deck.ps1/practice.ps1/updater.ps1/setup.ps1 near the
   curriculum dot-source; add the "Practice" strip button + Handle-Act case; call
   `Check-Update` on launch (non-blocking, behind a config flag); make Make-Drill
   topic-aware.
2. `tools/ui/strip.html`: add the Practice chip (mind the strip button budget / bar
   width - widen in Apply-Strip if needed).
3. `tools/ui/panel.html`: practice view (card review + quiz).

## Build order & parallelism
- PARALLEL (new files, no shared-file edits) -> fan out to agents now:
  deck.ps1, practice.ps1, updater.ps1, setup.ps1, installer/excel-coach.iss.
  Each: build against the contracts above, ASCII-only, self parse-verify, do NOT touch
  git, return a short report.
- SERIAL (after modules land) -> main thread: watch.ps1 wiring, panel/strip UI, the
  topic-aware Make-Drill. These touch fragile existing files and need the parse-gate.

## Risks
1. AV false-positives on a self-updating PowerShell app (Defender/SmartScreen on other
   machines). Mitigate with code-signing; plan for it.
2. Auto-update is a supply-chain surface -> HTTPS + mandatory SHA-256 + single trusted
   release host.
3. Parallel agents must respect ASCII + parse-gate or integration breaks.

## Out of scope (v2)
Mac/cross-platform port (would be a Tauri/Electron rewrite), accounts/sync/server-side
state, payments. Each is a future sub-project with its own spec.
