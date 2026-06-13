# Excel-Coach Improvement Loop

Run this with `/loop`. Each firing = one improvement iteration. Self-pace with ScheduleWakeup.

## Mission
Make the **existing** excel-coach basics work *excellently* — reliable, polished, genuinely helpful — so Jonah can demo it to the **head of 22C** (his IB fellowship program) and it just works. Every iteration leaves the tool more solid than the last.

**NOT now:** flashcards, a practice/spaced-repetition system, or any big new feature. Those come later (a few days out). This loop hardens what already exists. If you think of a new feature, write it to the backlog — don't build it.

## Autonomous mode (Jonah away, from 2026-06-13 eve)
Jonah handed off: run the loop unattended, make every existing feature as useful/helpful/polished as possible, **make all assumptions yourself** (don't wait to ask). Because he's away there is NO live session to protect — so **relaunch + drive-verify freely** (the constraint about not relaunching mid-study is suspended while he's away; just check he hasn't returned by watching for new user messages). Bias to: verify a feature actually works end-to-end with the drive channel, SEE the result (screenshot Excel via computer-use, don't trust cell properties alone), fix what's weak, make it look polished. Small, verified commits.

## Feature verification sweep (work through these; fix anything weak)
Drive each via `%TEMP%\xc_cmd.txt` with Excel open, then read logs / screenshot the result:
- `act:guide` path — Guide overview + step-by-step: does it paint the big picture then give what/where/how/why proactively, no spam, advance cleanly? (just rebuilt — watch for slug jitter / over-firing)
- `act:cheat` — cheat sheet: process-first, formatted, columns sized+capped (verify by screenshot), fails honestly if Excel closed.
- `act:why` — cell explanation: scoped, teaches the why.
- `act:kick` — get-going hint.
- `act:audit` — deep sheet check.
- teach demo (Run-Demo) + drill (Make-Drill) — build correctly, formatted, columns sized, and **fail honestly when Excel is closed** (still TODO — only cheat does this).
- watcher error-catching — catches real errors fast, no same-cell re-nag (the 20s cooldown is too short).
- formatting — blue inputs / bold totals / styled header / sized columns; SCREENSHOT to judge, don't trust properties.

## What already exists (don't rebuild)
A live ambient coach: `tools/watch.ps1` (4 threads: UI tick / audio worker / Excel watcher / TTS) + `tools/curriculum.ps1` (Excel ops, formatting, memory engine) + `tools/ui/strip.html` (Cluely strip). Features: silent mistake-watching, Kick / Audit / **Why** (cell explanation) / **Cheat Sheet** / Teach demo / Drill / Hands / IB formatting / "hey coach" chat / Notes / company ledger. Obsidian vault in `Coaching/`.

## Each iteration — do these in order
1. **Orient.** Read the memory `excel-coach-spectator` and `excel-coach-project`. Tail `%TEMP%\xc_watcher.log` and `%TEMP%\xc_hands.log`. `git log --oneline -10`. Decide: is the coach open (see Instance check), what's flaky, what's the highest-value fix right now?
2. **Pick ONE thing** (reliability bug > correctness > polish > tiny feature). Use the Backlog below, but let the logs override it — a real bug the logs reveal beats a planned item.
3. **Implement carefully** (see Constraints). Keep changes small and focused.
4. **Verify before commit** — parse gate is mandatory (see Verify). Then verify it *actually works*: use the **Drive channel** to trigger the feature on the running coach and read the result. Don't rely on Jonah clicking.
5. **Commit** — small, clear message, co-author line.
6. **Record** — append a one-line dated note to the `excel-coach-spectator` memory (what changed, what's next). Update the Backlog here if priorities shifted.
7. **Pace** — ScheduleWakeup for the next iteration (see Pace).

## Hard constraints — NON-NEGOTIABLE (hard-won; breaking these breaks the tool)
- **ASCII-only, PowerShell 5.1.** No non-ASCII chars ever.
- **watch.ps1 has 3 single-quoted here-strings** (`$work` 73-655, `$xlWork`, `$ttsWork`) — code inside must parse standalone. Functions Run-Demo / Make-Drill / Make-CheatSheet / Invoke-XlAction live in `$work`.
- **Never run `watch.ps1 -TestAsync` or relaunch while Jonah is mid-study without reason** — it resets his session/strip. Test via the Drive channel. If a relaunch is truly needed: kill cleanly, relaunch detached via bash, verify it came up, tell him.
- **Excel COM is flaky:** reads rejected during cell-edit; numeric writes MUST use `$cell.Formula=$val` (Value2=[double] is flaky). `$sync.demoActive` guards the watcher during builds.
- **Never touch the student's own cells.** Builds/formatting only on coach-written cells. Features must *fail honestly* (clear message), never fake success.
- **Don't add big new features** (flashcards/practice) — backlog them.

## Verify (mandatory pre-commit gate)
PowerShell, per file:
```
$src=[IO.File]::ReadAllText($p)
$bad=0; for($i=0;$i -lt $src.Length;$i++){ if([int]$src[$i] -gt 127){ $bad++ } }
$e=$null; [void][System.Management.Automation.PSParser]::Tokenize($src,[ref]$e)   # outer
# then each here-string: regex (?s)\$work=@'\r?\n(.*?)\r?\n'@  -> PSParser the inner text
```
Require: `non-ascii=0`, `parse-errors=0` for the outer file AND all 3 here-strings. For strip.html JS: `node --check` the extracted `<script>`.

## Drive channel (how you test/demo features without Jonah clicking)
The running coach's UI tick watches `%TEMP%\xc_cmd.txt`. Write one line (UTF8 **no BOM**), it dispatches + deletes:
- `act:cheat` / `act:why` / `act:audit` / `act:kick` / `act:hands` / `act:teach` -> Handle-Act (button)
- `ask:<text>` or a bare line -> Handle-Ask (typed question)
Then read `%TEMP%\xc_hands.log` (builds) and `%TEMP%\xc_watcher.log` (verdicts) to confirm what happened. **Excel must be open** or builds fail honestly.

## Instance / health check
- Coach alive = count **ffmpeg `watch_seg`** procs (1 = healthy). Do NOT count powershell procs — your own check command contains `watch.ps1` and self-inflates.
- Watcher healthy = `xc_watcher.log` last write < 3 min (heartbeats every 2 min). Alive process + stale log = **hung** (a real bug to fix).
- Relaunch recipe: kill `powershell.exe` where CommandLine has `-File` + `watch.ps1` and PID != $PID, kill `watch_seg` ffmpeg, then bash `nohup powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File tools/watch.ps1 >/dev/null 2>&1 &`, then verify ffmpeg=1.

## Quality bar = "demo-ready"
- Every feature works reliably OR fails with a clear, honest message.
- Coach catches real errors fast (7-20s), stays silent otherwise, never nags the same unfixed cell repeatedly.
- Builds (cheat sheet / teach / drill) look polished — IB formatting + styled title + header.
- Coach does what's asked **however phrased**, and knows its own capabilities.
- No silent deaths — a hung watcher self-heals.

## Done this session (2026-06-13) — verify they stay working
- Guide mode: big-picture overview + proactive step-by-step (what/where/how/why), stable-slug advancement, lenient parser, observability logging.
- Formatting: structure reaches cheat sheets (Apply-XlOps -> Polish), styled title + shaded header, column sizing fixed (autofit OWN cols only, capped 45, student cols untouched), stray ";" gone.
- Drive channel (`%TEMP%\xc_cmd.txt`), cheat-sheet fails honestly when Excel closed, cheat sheet now process-first.

## Backlog (reprioritize freely; logs override)
- [reliability] **fail-honestly on Run-Demo + Make-Drill** — Excel-open check + reflect real result, like Make-CheatSheet (highest: a feature that fakes success is the worst look).
- [reliability] **Watcher hang-detection** — watchdog only restarts a CRASHED runspace, not a HUNG one (blocked COM read stays State=Running). Add heartbeat-liveness: watcher stamps `$sync` each loop; tick force-restarts if no stamp > ~3 min.
- [noise] **Same-issue nudge suppression** — the 20s cooldown re-nags an unfixed cell (~40s repeats seen live); suppress until that cell's value changes or a few minutes pass.
- [quality] **Tune Guide** from the logs — watch for slug jitter (false advancement), over-firing, or guidance that's too long/short; make sure the overview fires once and the steps track real progress.
- [quality] **Fix the struggling Teach worked-example** build if it still chokes — read its log.
- [polish] **3-dot (...) options popup** for the toggles (hands/teach/format/guide/mute/sound) — declutter the strip + give Guide a visible toggle.
- [polish] cheat/build long cells **wrap-text** instead of truncating at width 45.
- [correctness] **Capability-aware routing** — any phrasing routes to the right feature, not brittle exact-phrase regex.
- Keep discovering via logs + drive-channel testing + screenshots.

## Pace & surfacing
- **Self-pace** with ScheduleWakeup. Coach open + Jonah studying -> watch the logs + do small safe improvements + drive-test. Coach idle / Jonah away -> do offline reliability + polish that doesn't need his live Excel (code, parse-verify, commit; defer drive-tests).
- **Surface to Jonah only** when: a decision is needed, a milestone lands, something broke, or he asks. Otherwise work quietly and keep committing.
- **Stop** when the quality bar is met and the backlog is empty, or when Jonah says stop.
