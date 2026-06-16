# Run-through Mastery Drill - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An adaptive, full-coverage drill that generates fresh exercises per curriculum topic, routes each to the pill (definitions/classification) or an Excel Workout sheet (calc/build), climbs an L1->L4 difficulty ladder, and tracks mastery across all 57 topics.

**Architecture:** A new dot-sourced `runthrough.ps1` holds the controller, the AI exercise generator, the grader, and the mastery tracker. watch.ps1 wires the entry + the pill/Excel surfaces + the Check button via the existing panel ($wvP) and Make-Drill/Get-XlBook machinery. State persists in `data/runthrough-state.json`. SM-2 (practice.ps1) supplies adaptivity. Built in 4 slices so a usable pill drill ships first.

**Tech Stack:** PowerShell 5.1 (ASCII-only, here-string parse-gate), WebView2 panel (panel.html JS), OpenAI API via curl (gpt-4o-mini for generation), JSON state files. Verification = `tools/tests.ps1` assertions + drive-channel (`%TEMP%\xc_cmd.txt`) live checks.

**Hard rules (every task):** ASCII-only; after any watch.ps1 edit run the parse-gate (outer + 3 here-strings) AND `tools/tests.ps1` (must stay green); node --check any panel/strip JS; never write the student's own cells - only the Workout sheet; commit after each task.

---

## PHASE 1 - Pill run-through (usable first slice)
Definitions + classification + one-number answers, fully in the pill. No Excel yet.

### Task 1: runthrough.ps1 skeleton + state model
**Files:** Create `tools/runthrough.ps1`; Modify `tools/tests.ps1`

- [ ] **Step 1** Create `tools/runthrough.ps1` with: a state path helper (`<repo>/data/runthrough-state.json` via `$PSScriptRoot` parent), `RT-LoadState`/`RT-SaveState` (UTF-8 no BOM; tolerant of missing/corrupt -> fresh `@{ topics=@{}; updatedAt='' }`), and `Get-RTState` returning the parsed object. Per-topic record shape: `{ level=1; streak=0; attempts=0; correct=0; mastered=@(); lastSeen='' }`.
- [ ] **Step 2** Add `Get-RTTopics` -> returns the 57 curriculum topics via `Get-Curriculum` (id/name/category), each merged with its state (default record if unseen).
- [ ] **Step 3** Add to `tools/tests.ps1` a "Run-through" section: dot-source runthrough.ps1; assert `Get-Command` exists for RT-LoadState/RT-SaveState/Get-RTState/Get-RTTopics; assert a fresh state round-trips (save then load equals); assert Get-RTTopics count == Get-Curriculum count.
- [ ] **Step 4** Run `tools/tests.ps1` -> all green (now includes Run-through asserts). Parse-gate runthrough.ps1 (ascii=0, parse=0).
- [ ] **Step 5** Commit: `feat(runthrough): state model + topic merge + tests`

### Task 2: Make-Exercise (AI generator, pill surface)
**Files:** Modify `tools/runthrough.ps1`; Modify `tools/tests.ps1`

- [ ] **Step 1** Add `Make-Exercise($topicId,$level)`: build a gpt-4o-mini chat call (match deck.ps1's curl pattern + DECK_MODEL env, key from .env) whose system prompt demands a STRICT JSON object: `{ id, topicId, level, surface, prompt, answer, choices, worked }` where for Phase 1 `surface='pill'`, plus the topic name/category as context and the level meaning (L1 atom: one definition/classification/one-number). Ask it to show its work in `worked`. Parse the JSON robustly (strip code fences); on failure return `$null`.
- [ ] **Step 2** Add `RT-NormalizeExercise($obj,$topicId,$level)` - coerces fields to strings/ints, generates an id if missing (`rt-<topicId>-<level>-<rand-from-prompt>`), ensures `choices` is an array (may be empty), `answer` present.
- [ ] **Step 3** tests.ps1: add a pure-logic test of `RT-NormalizeExercise` on a hand-built object (no API): asserts surface in {pill,excel}, required fields present, choices is an array. (Do NOT call the API in tests.)
- [ ] **Step 4** Run tests.ps1 green; parse-gate.
- [ ] **Step 5** Commit: `feat(runthrough): AI exercise generator (pill) + normalize + test`

### Task 3: Grade-Exercise (pill answers)
**Files:** Modify `tools/runthrough.ps1`; Modify `tools/tests.ps1`

- [ ] **Step 1** Add `Grade-Exercise($exercise,$studentAnswer)` -> `{ correct=[bool]; expected; worked }`. Rules: if `choices` non-empty (MC) -> correct when the chosen index/text matches `answer`; elseif the answer is numeric -> parse both, correct within tolerance (abs diff <= 0.01 or 0.5% of expected); else (free text/definition) -> for Phase 1 use a lenient compare (normalized lowercase contains the key answer terms); leave a hook `RT-JudgeText` for a later AI judge.
- [ ] **Step 2** tests.ps1: numeric (20 vs 20.0 -> correct; 20 vs 25 -> wrong), MC (choice 1 vs answer 1 -> correct), text (contains key term -> correct). All offline.
- [ ] **Step 3** Run tests.ps1 green; parse-gate.
- [ ] **Step 4** Commit: `feat(runthrough): grader (numeric/MC/text) + tests`

### Task 4: Controller + mastery transitions
**Files:** Modify `tools/runthrough.ps1`; Modify `tools/tests.ps1`

- [ ] **Step 1** Add `RT-PickNext` -> choose the next topic: unseen topics first, then lowest-mastery/most-overdue (reuse the SM-2 idea: a topic is "due" by lastSeen+interval-by-streak), at that topic's current level. Return `{topicId, level}`.
- [ ] **Step 2** Add `RT-RecordResult($topicId,$level,$correct)` -> updates state: correct -> streak++, attempts++, correct++; streak>=2 -> add level to `mastered`, reset streak, bump `level` (cap 4); wrong -> streak=0, attempts++, schedule sooner. Save state. Return the updated record.
- [ ] **Step 3** Add `Get-RTProgress` -> `{ masteredTopics; totalTopics; level1Done; ... }` for the scoreboard ("X / 57").
- [ ] **Step 4** tests.ps1: two correct in a row at L1 -> mastered contains 1, level becomes 2, streak 0; one wrong -> streak 0, attempts up. Progress count reflects mastered topics.
- [ ] **Step 5** Run tests.ps1 green; parse-gate. Commit: `feat(runthrough): controller pick/record/progress + tests`

### Task 5: Pill UI - exercise surface + scoreboard + Check
**Files:** Modify `tools/ui/panel.html`

- [ ] **Step 1** Add `XC.openExercise(payloadJson)` to the panel: payload `{ topicName, level, progress, prompt, choices, surface, mode }`. Renders the prompt; for MC -> choice buttons; for typed -> an input + a "Check / I'm done" button; shows the scoreboard line ("Topic - L<level> - <progress> solid"). Reuse the dark-glass styling + the existing practice view container.
- [ ] **Step 2** Add `XC.showExerciseResult({correct, worked, expected})` -> shows correct/incorrect + the worked solution + a "Next" button.
- [ ] **Step 3** Callbacks via the existing post() bridge: choice click -> `{type:'panel', k:'runthrough', action:'answer', answer:<index>}`; typed Check -> `{action:'answer', answer:<text>}`; Next -> `{action:'next'}`; close -> `{action:'close'}`.
- [ ] **Step 4** `node --check` the panel script -> PARSE OK. Commit: `feat(panel): run-through exercise surface + scoreboard + Check`

### Task 6: Wire it in watch.ps1 (pill flow end-to-end)
**Files:** Modify `tools/watch.ps1`; Modify `tools/ui/strip.html`

- [ ] **Step 1** Dot-source runthrough.ps1 near the other modules (line ~38, try-caught).
- [ ] **Step 2** Add main-scope session state `$script:rtCur=$null` (current exercise) and functions: `Start-RunThrough` (pick next -> Make-Exercise in a worker-safe way -> store $script:rtCur -> JS XC.openExercise), `Show-RTResult`, `RT-Next`. Generation is slow (API) -> run Make-Exercise via the existing worker pattern (set a $sync flag the $work thread fulfills) OR call directly with a "Generating..." state; pick the worker path to avoid freezing the tick.
- [ ] **Step 3** Add Handle-Act case `'runthrough' { Start-RunThrough }`.
- [ ] **Step 4** Extend the $wvP handler `'panel'` branch: if `$m.k -eq 'runthrough'` -> `Handle-RunThrough $m.action $m.answer`. Handle-RunThrough: on 'answer' -> Grade-Exercise($script:rtCur,$answer) -> RT-RecordResult -> JS XC.showExerciseResult; on 'next' -> Start-RunThrough; on 'close' -> hide panel.
- [ ] **Step 5** strip.html: add a "Run-through" chip (data-k='runthrough') styled like the others (mind bar width / overflow menu).
- [ ] **Step 6** Parse-gate (outer + 3 here-strings) + tests.ps1 green + node --check strip. Commit: `feat(runthrough): wire pill flow into watch.ps1 + strip chip`

### Task 7: Phase-1 live verification
- [ ] **Step 1** Relaunch the coach (safe window). Drive `act:runthrough` via `%TEMP%\xc_cmd.txt`; confirm the panel shows an exercise + scoreboard (screenshot/logs).
- [ ] **Step 2** Answer right -> result + Next advances; answer wrong -> worked solution shown. Confirm `data/runthrough-state.json` updates (streak/mastered).
- [ ] **Step 3** Note results in the spectator memory + commit any fixes. Commit: `chore(runthrough): phase 1 verified`

---

## PHASE 2 - Excel surface (calc/build)
### Task 8: Make-Exercise excel layout
Extend Make-Exercise so a level/topic that is a calculation returns `surface='excel'` with `layout = { title, given=[{label,value,cell}], answerCells=[{label,cell,expected}] }` (deterministic expected from the given inputs). Add normalize + tests for the excel shape. Commit.

### Task 9: Workout sheet renderer (reuse Make-Drill)
Add `RT-RenderExcel($exercise)` that writes the layout into a reused "Workout (Run-through)" sheet via the Make-Drill/Get-XlBook path (labels + given values + blank highlighted answer cells); never touch the student's cells. Track the answer cell addresses in `$script:rtCur`. The pill shows the prompt + Check. Commit + live-verify a build.

### Task 10: Excel grading on Check
Extend Handle-RunThrough: on 'answer' for an excel exercise, read the answer cells via Read-ExcelLive/Get-XlBook, compare each to `expected` (tolerant). Wrong -> worked solution in pill + fill the correct values into the answer cells (demo) before the next. Tests for the cell compare on a fixture. Commit + live-verify.

---

## PHASE 3 - Ladder + coverage scoreboard
### Task 11: Level meanings in the generator
Give Make-Exercise explicit L1-L4 definitions per category so L3/L4 produce sections/whole statements; bias surface to excel for L2+. Tests for level->surface expectations. Commit.

### Task 12: Mastery map UI
Panel scoreboard view: "Foundations X / 57", per-statement readiness (cash flow / DCF / ...), current streak; a "what's next" line. Driven by Get-RTProgress. node --check + live-verify. Commit.

---

## PHASE 4 - Adaptivity + polish
### Task 13: AI text judge
Implement RT-JudgeText (a cheap mini call) for free-text/definition grading; fall back to the keyword compare offline. Commit.

### Task 14: Pre-generate next exercise
While the student works the current one, generate the next in the worker so advancing is instant. Commit.

### Task 15: Coverage + regression tests
tests.ps1: every topic reachable; "done" requires all foundations mastered; exercise schema/grader/mastery all asserted. Final parse-gate + suite green. Commit.

---

## Self-Review (done)
- **Spec coverage:** two surfaces (T5-6 pill, T8-10 excel), AI gen anchored to topic (T2), full coverage map (T1,T4,T12), L1-L4 ladder (T11), Check-to-grade (T6,T10), miss->worked-then-similar (T6,T10), SM-2 adaptivity (T4,T13-14). All mapped.
- **Placeholders:** none - each task names files + the function contracts + the verification.
- **Consistency:** exercise object `{id,topicId,level,surface,prompt,answer,choices,worked,layout}` used uniformly; `RT-*`/`Make-Exercise`/`Grade-Exercise`/`Start-RunThrough`/`Handle-RunThrough` names consistent across tasks.
- **Slice value:** Phase 1 alone = a working pill mastery drill.
