# Excel-Coach Improvement Loop

Run this with `/loop`. Each firing = one improvement iteration. Self-pace with ScheduleWakeup.

## Mission
Make the **existing** excel-coach basics work *excellently* — reliable, polished, genuinely helpful — so Jonah can demo it to the **head of 22C** (his IB fellowship program) and it just works. Every iteration leaves the tool more solid than the last.

**NOT now:** flashcards, a practice/spaced-repetition system, or any big new feature. Those come later. This loop hardens what already exists. If you think of a new feature, write it to the backlog — don't build it.

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

## Backlog (reprioritize freely; logs override)
- [reliability] **Watcher hang-detection** — watchdog only restarts a CRASHED runspace, not a HUNG one (blocked COM read stays State=Running). Add heartbeat-liveness: watcher stamps `$sync` each loop; tick force-restarts if no stamp > ~3 min.
- [correctness] **Capability-aware routing** — features fire on brittle exact-phrase regex; make any phrasing route to the right feature (cheat/why/teach/hands/drill). The coach should understand what it can do.
- [reliability] Apply the **fail-honestly** pattern (Excel-open check + real Apply-XlOps result) to **Run-Demo and Make-Drill** like Make-CheatSheet already does.
- [quality] **Fix the struggling Teach worked-example** build — read its log, find why it chokes, make it reliable.
- [polish] **3-dot (...) options popup** holding the toggles (hands/teach/format/mute/sound), to declutter the strip and fix overflow properly.
- [noise] Extend **same-issue nudge suppression** — don't re-nag an unfixed cell every ~20s; wait until that cell changes or a few minutes pass.
- [polish] Verify **formatting** looks good on real builds (drive a cheat sheet with Excel open); tune colors/structure.
- Keep discovering via logs + drive-channel testing.

## Pace & surfacing
- **Self-pace** with ScheduleWakeup. Coach open + Jonah studying -> watch the logs + do small safe improvements + drive-test. Coach idle / Jonah away -> do offline reliability + polish that doesn't need his live Excel (code, parse-verify, commit; defer drive-tests).
- **Surface to Jonah only** when: a decision is needed, a milestone lands, something broke, or he asks. Otherwise work quietly and keep committing.
- **Stop** when the quality bar is met and the backlog is empty, or when Jonah says stop.
