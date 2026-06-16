# Run-through Mastery Drill - Implementation Plan (v1, locked)

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax.
> Reflects the final spec `docs/superpowers/specs/2026-06-15-run-through-mastery-drill-design.md`
> and Jonah's locked decisions (Excel calcs IN v1, `...`-menu entry, no focus mode,
> silent/typed). ASCII only, PowerShell 5.1.

**Goal:** A continuous, adaptive drill (`...` menu -> "Run-through") that serves
bit-by-bit MC questions in the pill and L2 calc exercises in the Excel Workout sheet,
press-Enter to advance, wrong -> same concept with new numbers, mastery tracked across
all 57 topics, only-counts-up scoreboard.

**Architecture:** A thin state machine in `watch.ps1` (`$script:rtSession`) drives the
already-built pure primitives (`Make-Exercise`, `RT-RenderExcel`, `Grade-ExcelExercise`,
`RT-CellMatch`, RT state, `perf.ps1`). New library functions go in `runthrough.ps1`
(safe to build in isolation + unit-test). The pill surface is new `XC.*` methods in
`panel.html`. Entry is a `...`-menu item posting `act:runthrough`.

**Hard rules (every task):** ASCII-only; after any `watch.ps1` edit run the parse-gate
(outer + 3 here-strings) AND `tools/tests.ps1` (must stay green); `node --check` any
panel/strip JS; never write the student's own cells (only the Workout sheet); commit
after each task. Do NOT touch `Start-Workout`/`Check-Workout` (the shipped toggle).

**Build partition (avoid watch.ps1 races):** Phase A = `runthrough.ps1` + `tests.ps1`
only (agent-safe, offline-testable). Phases B/C = `panel.html`, `strip.html`,
`watch.ps1` done single-threaded by the main session. No parallel edits to `watch.ps1`.

---

## PHASE A - runthrough.ps1 controller library (offline, unit-tested)

### Task A1: Grade-PillExercise
**Files:** Modify `tools/runthrough.ps1`, `tools/tests.ps1`
- [ ] `Grade-PillExercise($exercise, $answer)` -> `@{ correct=[bool]; expected; worked }`.
  Rules: if `choices` non-empty (MC) -> correct when `$answer` (int index, or the
  chosen text) matches `$exercise.answer` (index or text); elseif `$exercise.answer`
  is numeric -> `RT-CellMatch $answer $exercise.answer`; else -> `$false` for now (typed
  free-text is deferred to the AI judge; v1 pill items are MC). `worked` = `$exercise.worked`.
- [ ] tests.ps1 (offline): MC index match -> correct; MC wrong index -> wrong; numeric
  one-off (20 vs 20.0) -> correct; non-MC text -> not correct (deferred).
- [ ] Parse-gate runthrough.ps1; run tests.ps1 green. Commit `feat(runthrough): pill grader + tests`.

### Task A2: RT-RecordResult (mastery transitions)
**Files:** Modify `tools/runthrough.ps1`, `tools/tests.ps1`
- [ ] `RT-RecordResult($topicId, $level, $correct, $isRetry)` -> updates RT state and
  returns `@{ rec; becameSolid=[bool]; bumpedLevel=[bool] }`. Rules: correct & not retry
  -> streak++; streak>=2 -> mark `level` in `mastered`, becameSolid=$true, reset streak,
  bump `level` capped at 2 (bumpedLevel=$true). correct & isRetry -> consolidate (do not
  advance streak toward promote; streak stays at 0 floor). wrong -> streak=0; attempts++.
  Always attempts++ / correct++ appropriately; set `lastSeen`; `RT-SaveState`.
- [ ] tests.ps1: two correct in a row at L1 -> becameSolid, level=2, streak 0; correct
  on a retry -> not becameSolid, level unchanged; one wrong -> streak 0, attempts up.
  (Round-trip with backup/restore of runthrough-state.json like the existing RT test.)
- [ ] Parse-gate; tests green. Commit `feat(runthrough): mastery transitions + tests`.

### Task A3: RT-PickNext (4-rule picker)
**Files:** Modify `tools/runthrough.ps1`, `tools/tests.ps1`
- [ ] `RT-PickNext($state, $itemsThisSitting, $lastTopicId)` -> `@{ topicId; level }`.
  Order: (1) first 3 items -> easiest unseen must-tier (`tier`-ordered) at level 1;
  (2) any unseen topic, must-tier first; (3) a `Get-WeakTopics` topic served one level
  below its current (min 1); (4) else lowest-streak / least-recently-seen. Never returns
  `$lastTopicId` unless it is the only option. Uses `Get-RTTopics` + `Get-WeakTopics`.
- [ ] tests.ps1 (offline, seeded state): fresh state -> returns an unseen must-tier topic
  at level 1; with a seeded weak topic -> it is eligible; never repeats lastTopicId when
  alternatives exist.
- [ ] Parse-gate; tests green. Commit `feat(runthrough): next-item picker + tests`.

### Task A4: Get-RTProgress (scoreboard)
**Files:** Modify `tools/runthrough.ps1`, `tools/tests.ps1`
- [ ] `Get-RTProgress` -> `@{ solid; total; areas=@(@{ name; solid; total; status }); }`
  where `total`=count of curriculum topics, `solid`=topics solid at ceiling, `areas`=
  the distinct `domain` values bucketed (status: green=all solid, yellow=some, grey=none).
- [ ] tests.ps1: total == Get-Curriculum count; areas non-empty; solid in 0..total.
- [ ] Parse-gate; tests green. Commit `feat(runthrough): progress scoreboard + tests`.

### Task A5: retry nonce in Make-Exercise
**Files:** Modify `tools/runthrough.ps1`, `tools/tests.ps1`
- [ ] Add optional `$nonce` param to `Make-Exercise($topicId,$level,$nonce)`; when set,
  append to the user prompt: "Variation token <nonce> - use DIFFERENT specific numbers
  than any previous version." (temp stays 0; the token forces different numbers on a
  retry.) Default `$nonce=''` (no behavior change). Plumb it through; no API call in tests.
- [ ] tests.ps1: calling `Make-Exercise` with a nonce does not throw at the param layer
  (guard: skip if no key). Parse-gate; tests green. Commit `feat(runthrough): retry nonce`.

---

## PHASE B - panel.html drill surface (node --check only)

### Task B1: XC.openExercise + header + MC/Excel render
**Files:** Modify `tools/ui/panel.html`
- [ ] Add a `#runthrough` view (reuse the dark-glass + practice-view styling): a
  persistent header (topic, area, "solid: N", Now -> Next), the prompt, and either MC
  choice buttons (pill) or the prompt + an always-visible **Check** button (excel), an
  "Explain this" button, and a always-visible hint line. `XC.openExercise(payloadJson)`:
  `{ topicName, area, solid, level, surface, prompt, choices, hint }`.
- [ ] `node --check` the panel JS -> PARSE OK. Commit `feat(panel): run-through exercise surface`.

### Task B2: XC.showExerciseResult + Enter-to-advance + callbacks
**Files:** Modify `tools/ui/panel.html`
- [ ] `XC.showExerciseResult({correct, worked, expected})` -> verdict ("Solid - locked
  in" / "Here's how it works" + worked), a "press Enter for the next one" affordance.
- [ ] Wire callbacks via `post()`: MC choice click -> `{type:'panel', k:'runthrough',
  action:'answer', answer:<index>}`; Check click -> `{action:'check'}`; Explain ->
  `{action:'explain'}`; Enter (extend the Escape-only keydown; when in #runthrough,
  Enter -> `{action:'next'}` after a verdict, or selects the highlighted choice) ;
  close/Esc -> `{action:'close'}`.
- [ ] `node --check`. Commit `feat(panel): run-through result + Enter-to-advance`.

### Task B3: XC.showRunEnd (end card)
**Files:** Modify `tools/ui/panel.html`
- [ ] `XC.showRunEnd(payload)` -> `{ items, newlySolid, solid, total, areas:[{name,status}] }`
  rendered as the end card (items done, topics locked, X/57, the 6 areas green/yellow/grey,
  "come back tomorrow"). `node --check`. Commit `feat(panel): run-through end card`.

---

## PHASE C - watch.ps1 controller + entry (single-threaded; parse-gate + suite each)

### Task C1: $script:rtSession + state-machine functions
**Files:** Modify `tools/watch.ps1`
- [ ] Init `$script:rtSession=@{ active=$false; state=''; cur=$null; topicId=''; level=1;
  retry=$false; items=0; newlySolid=0 }` near the other script state.
- [ ] Add `Start-RunThrough` (reset session, show panel, RT-Advance), `RT-Advance`
  (PICK via `RT-PickNext` using durable state + items count -> GENERATE via
  `Make-Exercise` with a nonce when retrying, fallback to a deck card on `$null` ->
  PRESENT), `RT-Present` (route surface: pill -> `XC.openExercise` with choices; excel ->
  `RT-RenderExcel` then `XC.openExercise` + Check), `RT-Submit($answer)` (GRADE via
  `Grade-PillExercise`/`Grade-ExcelExercise` -> `RT-RecordResult` + `Record-Answer` ->
  `XC.showExerciseResult`; on wrong set retry + for excel fill the answer cells),
  `RT-Next` (retry -> same topic/level new nonce; else RT-Advance), `Stop-RunThrough`
  (`XC.showRunEnd` via `Get-RTProgress`, clear active). Generation is synchronous with a
  "setting up..." state + DoEvents (same pattern as Start-Workout).
- [ ] Parse-gate (outer + 3 here-strings) + tests.ps1 green. Commit `feat(runthrough): watch.ps1 state machine`.

### Task C2: Handle-Act + panel routing
**Files:** Modify `tools/watch.ps1`
- [ ] Handle-Act `'runthrough' { Start-RunThrough }`.
- [ ] In the `$wvP` `'panel'` branch, route `$m.k -eq 'runthrough'` -> `Handle-RunThrough
  ([string]$m.action) $m.answer`: `answer`/`check` -> RT-Submit; `next` -> RT-Next;
  `explain` -> reuse the card-help/explain path; `close` -> Stop-RunThrough.
- [ ] Parse-gate + tests green. Commit `feat(runthrough): act + panel routing`.

### Task C3: Workout auto-fill suppression during a live drill
**Files:** Modify `tools/watch.ps1`
- [ ] While a drill EXCEL exercise is awaiting (`$script:rtSession.state -eq 'awaitExcel'`),
  set the existing `$sync.demoActive`-style guard (or a new `$sync.rtNoFill`) so the
  ambient guide/demo path will not write into the Workout answer cells. Clear it on
  submit/next/exit. (Voice/commentary stay on per the no-focus-mode decision.)
- [ ] Parse-gate + tests green. Commit `feat(runthrough): protect Workout answer cells`.

### Task C4: the "..." menu entry
**Files:** Modify `tools/ui/strip.html`, `tools/watch.ps1` (Apply-Strip height)
- [ ] Add a "Run-through" action row to `#menu` (top, above Flashcards) posting
  `{type:'act', k:'runthrough'}` + `setMenu(false)`; mirror the rowFlash structure +
  handler. Bump the Apply-Strip menu grow height for the extra row.
- [ ] `node --check` strip + parse-gate + tests green. Commit `feat(runthrough): ... menu entry`.

### Task C5: live verification + relaunch
- [ ] Relaunch the coach. Drive `act:runthrough`; confirm pill shows exercise #1 (easy
  win, no 0/57), answer right -> Solid + counter up, answer wrong -> worked solution then
  Enter gives a new-numbers item; an Excel L2 item renders given values + Check grades it;
  end card on close. Confirm `data/runthrough-state.json` updates.
- [ ] Note results in the spectator memory. Commit `chore(runthrough): v1 verified`.

---

## Deferred (post-v1, per the design)
- v2: worker-thread pre-generation (instant Enter), the 6-area progress map header,
  warm "welcome back" re-entry, seeding picks from the ambient coach's Struggle notes.
- v3: AI text judge for typed answers, full L1-L4 ladder + per-statement readiness +
  prereq gating, hand-authored L3/L4 templates, cross-sitting durability clock, optional
  full focus mode, optional voice prompts/answer-aloud.

## Self-review
- **Spec coverage:** session/state-machine (C1), pill MC (A1,B1-2), Excel calc + Check
  (C1,B1-2 reuse RT-RenderExcel/Grade-ExcelExercise), picker (A3), mastery+retry (A2,A5),
  scoreboard/end card (A4,B3), entry (C4), Workout protection (C3). All mapped.
- **Consistency:** `RT-PickNext`/`RT-RecordResult`/`Grade-PillExercise`/`Get-RTProgress`/
  `Start-RunThrough`/`Handle-RunThrough` names used uniformly; exercise object shape is
  the existing `{id,topicId,level,surface,prompt,answer,choices,worked,layout}`.
- **Race safety:** Phase A is isolated to runthrough.ps1/tests.ps1; B/C are
  single-threaded main-session edits to panel.html/strip.html/watch.ps1.
