# Run-through Mastery Drill - design spec

Date: 2026-06-15
Status: approved in brainstorming ("lets do it"), ready for implementation plan

## Goal
An adaptive, exhaustive drill that takes the student from single-concept atoms all
the way up to building a whole financial statement, covering EVERY topic in the
course, and keeps going until they have each one down. It learns where the student is
strong vs shaky and adapts. One coherent system across two surfaces (the pill and
Excel), driven by one mastery map.

## Core principles
- **AI-generated, fresh every time.** Each exercise is generated on the fly,
  parametrized (new numbers on every retry), and **anchored to a specific curriculum
  topic** so it can never drift off-course. (gpt-4o-mini batch model; never the live
  coach model.)
- **Full coverage.** The 57-node curriculum (`curriculum.ps1` / `Get-Curriculum`) is
  the master checklist. Every topic has a mastery state; the run-through is not "done"
  until all foundations are mastered and the integrated statements can be built.
- **Two surfaces, one brain.** Each generated exercise carries a `surface`:
  - **pill** - definitions, classifications (O/I/F, asset/liability), short
    written/conceptual, one-number answers. Answered in the panel (type or pick).
  - **excel** - calculations and builds. Laid out in a dedicated Excel "Workout"
    sheet; the student does the real work in cells.
  The pill is ALWAYS the scoreboard + controller (topic, level, progress, streak,
  feedback). For Excel exercises it also shows the prompt + a "Check / I'm done"
  button while the student works in the sheet.
- **Difficulty ladder (L1 -> L4).** Anchored per topic, and combining across topics:
  - L1 Atom - one value / one classification (compute one dAR; classify one item).
  - L2 Combine - a few linked steps (CFO = NI + Dep - dAR + dAP).
  - L3 Section - a whole section (all Operating Activities; a full PV schedule).
  - L4 Full build - integrate sections into a complete statement, building toward a
    linked 3-statement model.
  L1 leans on the pill; L2-L4 move into Excel; recall/definitions stay in the pill.
- **Loop:** Check to grade -> correct advances -> wrong shows the worked solution
  immediately (steps in the pill + the correct answer filled into Excel so it is seen
  done) then serves a fresh, similar problem (same topic/level, new numbers).
- **Adaptivity:** weak spots and never-seen topics first; mastered ones rarely;
  spaced-repetition (SM-2, `practice.ps1`) and the existing struggle profile resurface
  misses.

## Mastery model
- A topic+level is "down" after **two correct in a row** at that level.
- On a miss: show worked solution + immediately a similar problem (decision A). Miss
  the similar one too -> flag the topic weak and circle back later (SM-2 schedules it).
- Per-topic state: current level, attempts, correct streak, mastered levels, lastSeen.
- Overall progress surfaces in the pill: "Foundations X / 57" plus which statements
  are buildable (e.g., "Cash flow statement: ready / not yet").

## Architecture (reuses existing machinery)
New: a **run-through controller** + the **level ladder** + **surface routing**.
Reused:
- `Make-Drill` (watch.ps1) - lays a blank exercise into Excel; extend for levels +
  explicit answer-cell tracking.
- `Read-ExcelLive` / the Excel watcher - reads/grades the Excel answer cells.
- `curriculum.ps1` (`Get-Curriculum`) - the 57-topic coverage map.
- deck.ps1 / the existing AI-call pattern - exercise generation.
- `practice.ps1` (SM-2) - scheduling/adaptivity.
- panel.html practice view + `XC.openPractice` - the pill surface (extend for the
  scoreboard + Check button + worked-solution display).

### Components
1. **Run-through controller** (new `tools/runthrough.ps1`, dot-sourced): owns the
   session - picks the next (topic, level) from coverage + mastery + weak spots,
   requests an exercise, routes it to its surface, receives the answer, grades,
   updates mastery, advances. Holds session state in `$script:` vars.
2. **Exercise generator** (`Make-Exercise topicId level`): one AI call (mini) -> a JSON
   exercise object `{ id, topicId, level, surface, prompt, answer, layout }`. For
   `excel`, `layout` = labels + given inputs + which cells the student must fill +
   the expected value(s). For `pill`, `answer` = the correct value/choice (+ `choices`
   for MC). The prompt is shown to the student; the answer is held server-side for
   grading. The model is asked to show its work so the answer can be trusted.
3. **Surface renderers:**
   - pill: extend the practice panel - `XC.openExercise(payload)` renders the prompt,
     accepts a typed number / picked choice / "show answer", posts the answer back.
   - excel: write `layout` into a reused "Workout" sheet via the Make-Drill mechanics;
     the pill shows the prompt + a Check button.
4. **Grader** (`Grade-Exercise`): on Check (or pill submit), compares the student's
   answer to the held answer. pill: numeric -> tolerance compare; multiple-choice ->
   exact; free-text/definition -> a lenient AI judge (accepts correct phrasing
   variants). excel: read the tracked answer cells via Read-ExcelLive, compare to the
   expected value (tolerant on rounding). Returns correct/incorrect + the worked
   solution. (Definitions are posed as MC or short fill-in, never free self-rating, so
   every answer is objectively graded.)
5. **Mastery/coverage tracker** (`data/runthrough-state.json`): per-topic level/
   streak/mastered + overall. Drives the pill scoreboard. Shares the SM-2 engine for
   resurfacing.
6. **Entry + UI:** a "Run-through" entry (its own chip or in the overflow menu); the
   pill scoreboard (topic, level, X/57, streak) + the Check button + feedback/worked-
   solution panel. Drive-channel command `act:runthrough` for testing.

### Data flow (one exercise)
1. Student starts Run-through.
2. Controller picks (topic, level) - weakest/never-seen first, at the topic's current
   level.
3. `Make-Exercise` (AI) returns the exercise object for (topic, level).
4. Route by `surface`: render in the pill, or write into the Workout sheet + show the
   prompt + Check.
5. Student answers (pill) or works in Excel and presses Check.
6. `Grade-Exercise` compares -> correct / incorrect (+ worked solution).
7. correct -> streak++; two-in-a-row -> mark topic+level mastered; advance (next level
   or next topic). incorrect -> show worked solution (pill steps + fill Excel) ->
   serve a fresh similar exercise (same topic/level, new numbers).
8. Persist `runthrough-state.json`; update the scoreboard; repeat until all topics
   mastered or the student stops.

## Verification / tests (extend tools/tests.ps1)
- Exercise object schema (surface in {pill,excel}; required fields present per surface).
- Grader: numeric tolerance, MC exact, Excel-cell compare on a fixture.
- Mastery transitions (two-in-a-row -> mastered; miss resets streak + schedules return).
- Coverage: every curriculum topic is reachable; "done" requires all mastered.
- Parse-gate + ASCII on the new module; the run-through never edits the student's own
  cells (only the Workout sheet).

## Out of scope (this spec)
- Generalizing beyond the IB course: the coach learning an arbitrary subject by
  watching the student's lessons and auto-building the topic map/deck. The design keeps
  the topic map behind `Get-Curriculum` so it can be swapped for a learned one later,
  but that "learn any subject" arc is its own future spec.
- Accounts/multi-user sync, payments.

## Risks
- AI arithmetic errors in generated answers -> have the model show its work; for
  Excel, prefer exercises whose answer is a deterministic function of the given inputs
  so the grader can recompute rather than trust the model blindly.
- Excel COM fragility during layout/grading -> reuse the hardened Get-XlBook +
  Make-Drill path; only ever write the Workout sheet, never the student's cells.
- Latency per exercise (one mini call) -> acceptable (~1-2s); can pre-generate the next
  exercise while the student works on the current one.
