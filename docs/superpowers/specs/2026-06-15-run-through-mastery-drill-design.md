# Run-through Mastery Drill - Final Design (v1 locked)

> Supersedes the earlier draft of this file. Reflects the multi-lens design pass
> (2026-06-15) plus Jonah's locked decisions. ASCII only.

## One-breath pitch
Open the **Run-through** from the `...` menu and you are immediately doing a warm,
easy question in the pill - no topic to pick, no count to choose. Answer it, get an
instant verdict, press **Enter**, get the next one. It is one continuous, adaptive
retrieval drill that walks the course from atoms (define EBITDA, classify a line as
operating/investing/financing) up to short multi-step calcs (a 3-line CFO, a 2-step
PV), serving the thing you are weakest on, re-testing every miss right away with
fresh numbers, and counting only your wins. Run it in 10-20 minute sittings across
the days before the fellowship. Exactly the ask: bit-by-bit snippets, press Enter,
wrong -> similar with different numbers, run through every type until you have them
down.

## Locked decisions (Jonah, 2026-06-15)
1. **v1 scope = pill MC loop AND the Excel calc loop.** The first ship includes both
   the multiple-choice pill questions and the Excel Workout-sheet calculations (with
   a single Check button). ~3-4 days.
2. **Entry point = a "Run-through" item in the `...` overflow menu** (alongside
   Flashcards and Excel exercise). No new strip chip.
3. **No focus mode.** The ambient coach keeps watching and speaking during the drill.
   EXCEPTION (correctness, not silencing): while a live drill Excel exercise is on
   the Workout sheet, suppress only the ambient coach's auto demo/guide *writes into
   the Workout answer cells* so it cannot hand over the answer. Its voice/commentary
   stay on.
4. **Silent + typed for v1.** Click/keyboard only; spoken prompts and answer-aloud
   come later.

## What already exists (build ON these; do not redesign)
- `runthrough.ps1`: RT state model (per-topic `{ level, streak, attempts, correct,
  mastered[], lastSeen }`), `RT-LoadState`/`RT-SaveState` (data/runthrough-state.json),
  `Get-RTTopics`. Excel engine: `Make-Exercise(topicId,level)`, `RT-NormalizeExercise`,
  `RT-CellMatch`, `RT-SetCell` (type-stable cell write), `RT-RenderExcel(ex,xl)` ->
  Workout sheet + answer-cell list, `Grade-ExcelExercise(ex,xl)` -> `{correct,perCell,
  worked}`.
- `perf.ps1`: `Record-Answer(topicId,name,correct)`, `Get-PerfSummary`, `Get-WeakTopics(n)`.
- `practice.ps1`: SM-2 deck (`Get-DueCards`, `Rate-Card`, `New-Quiz`), cards carry topicId.
- `deck.ps1` + `data/deck.json`: 257 cards / 57 topics (incl. 35 MC quiz cards).
- The flashcard practice view in `panel.html` (review + MC quiz verdict + "Explain it
  simpler" + end-of-session perf summary).
- The shipped one-shot "Excel exercise" toggle (`Start-Workout`/`Check-Workout`) -
  LEFT UNTOUCHED; the run-through is a separate session that reuses the pure primitives.

## The session (lifecycle + state machine)
One continuous, endless, adaptive session. No fixed count, no "take a break?" prompt.
Durable mastery in `data/runthrough-state.json`; the in-memory `$script:rtSession`
(`active, state, cur, curCells, topicId, level, retry, solidThisSitting,
climbedThisSitting[]`) is ephemeral. If the coach restarts mid-session, the drill
resumes from durable state with a fresh PICK (stated behavior, not a bug).

States:
- **IDLE** -> (`act:runthrough`) -> **Start-RunThrough**: set `rtSession.active`, draw
  the pill with warm framing, go to PICK.
- **PICK**: `RT-PickNext` -> `{topicId, level}`. First 2-3 items of a sitting are easy
  wins (lowest-level must-tier) - the guaranteed on-ramp.
- **GENERATE**: `Make-Exercise(topicId, level)` synchronously; pill shows "setting
  up...". On `$null` -> FALLBACK to a matching deck card for that topic, else a
  friendly "connection hiccup - here's another one" and retry a different topic. Never
  dead-ends.
- **PRESENT**: route on `surface`. `pill` -> prompt + MC choice buttons + persistent
  header + "Explain this". `excel` -> `RT-RenderExcel` writes the Workout sheet
  (guarded so the ambient coach will not fill it), pill shows prompt + the always-
  visible **Check** button. State -> awaitPill / awaitExcel. A live hint
  ("press Enter for the next one") is always visible so silence never reads as broken.
- **WAIT**: pill = a choice tap (or Enter on the highlighted choice). excel = Check or
  Enter. Idle does nothing (retrieval is untimed - no penalty, no nag).
- **GRADE**: pill -> `Grade-PillExercise` (MC exact match; numeric one-offs via
  `RT-CellMatch`). excel -> existing `Grade-ExcelExercise`.
- **RECORD**: `RT-RecordResult(topicId, level, correct)` updates streak/level/solid +
  saves; AND `Record-Answer` (perf.ps1) logs the same result, so both files agree.
- **REVEAL + BRANCH**: correct -> "Solid - locked in", tick the solid counter only if
  it crossed. wrong -> "Here's how it works" + the worked solution immediately (for
  excel, also fill the correct values into the answer cells so the build is seen done);
  set `retry=true`. Never a red X or the word "wrong".
- **NEXT (Enter)**: retry -> serve the similar item (same topic+level, NEW numbers via
  a per-attempt nonce injected into the prompt; Make-Exercise runs at temp 0, so
  without a nonce a retry regenerates the SAME numbers and breaks the loop). else ->
  PICK.
- **EXIT** (close/Esc/`act:close`): `Stop-RunThrough` clears `rtSession.active`, shows
  the end card (items done, topics newly solid, X/57, the 6 named areas green/yellow/
  grey, "come back tomorrow to lock these in"), persists.

## The ladder (two surfaces, capped at L2 for the window)
- **L1 ATOM** - one fact / one classification / one number. Pill, MC. Max scaffold.
- **L2 COMBINE** - a short 2-4 step calc with structure given (CFO = NI + D&A - dAR +
  dAP; PV in two steps). Excel Workout sheet + Check button.
Surface is mechanical: definition/classification domains -> pill; calc/statement
domains at L2 -> Excel. **L3 sections and L4 full builds are DEFERRED** - self-graded
whole statements are where the model's arithmetic marks a CORRECT answer wrong, the
worst failure for an anxious beginner. Full builds, if wanted, get hand-authored
templates later.

## Mastery + retry rules
- A topic+level is **SOLID** after two correct in a row at that level (NOT counting the
  consolidating post-miss retry). Solid -> bump level, capped at L2 and capped at +1
  per sitting.
- A topic is **DONE** when solid at its ceiling (L2 for calc topics, L1 for pure
  definitions/classifications).
- **MISS**: streak=0; show the worked solution; on Enter serve a fresh SIMILAR item
  (same topic+level, new numbers). This back-to-back re-derive is the one deliberate
  massing; everything else interleaves.
- **SECOND miss in a row**: do NOT drop the level (reads as punishment). Add more
  scaffold at the same level, flag weak via `Record-Answer`, interleave away.
- **COMPLETION (v1)**: in-state only. End-card headline "areas: N of 6 solid" and
  "foundations X / 57"; "fellowship-ready" when must-tier foundations are solid. No
  cross-sitting clock in v1.

## Next-item selection (the 4-rule picker)
`RT-PickNext`, in order, never repeating the just-served topic unless mid-retry:
1. On-ramp: first 2-3 items of a sitting = easiest unseen must-tier topics.
2. Any UNSEEN topic, must-tier first, then should, then nice (coverage-first
   calibration pass).
3. Any topic `Get-WeakTopics` (perf.ps1) flags weak, served one level lower to rebuild
   the floor (this is what makes it "know about Jonah" from run 2+).
4. Else lowest streak / least-recently-seen.
Honest framing: run 1 is mostly calibration (Get-WeakTopics needs attempts>=2 &
acc<0.6); it gets smarter run 2+. Spacing / tier-weight / prereq-gating are separate,
individually-testable increments AFTER the loop is loved - not v1.

## Pill vs Excel; the pill as tracker
PILL owns recall: all definitions, classifications, one-number L1s - all MC in v1.
EXCEL Workout sheet owns L2 calcs. The pill is ALWAYS the scoreboard + controller -
even during an Excel exercise it shows the header (topic, area, "solid: N", Now/Next)
plus the Check button. `RT-RenderExcel` writes ONLY the reused "Workout" sheet, never
Jonah's own cells.

## The felt flow
Snippet -> tap/answer -> instant verdict -> Enter -> next, hand never leaving the
keyboard. The solid counter only ever goes UP (a miss never costs progress). A miss is
"here's how" then a fresh one you nail seconds later. Micro-celebration when a topic
locks ("SOLID: Present Value"); a bigger one when an area finishes. The opening is an
easy win with warm framing, never "0/57"; X/57 and "fellowship-ready" live on the end
card only.

## Known consideration to watch
With no focus mode, the ambient coach stays active during the drill. We suppress only
its writes into the Workout answer cells (so it cannot give away a calc answer). Its
voice/commentary remain on by choice; if that proves noisy, a full focus flag
(`$sync.rtFocus` on the existing watcher guards + TTS skip) is a small later add.
