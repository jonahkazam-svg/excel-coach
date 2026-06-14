# Excel-Coach Improvement Loop

Run this with `/loop`. Each firing = one improvement iteration. Self-pace with ScheduleWakeup.

## Mission
Make the **existing** excel-coach basics work *excellently* — reliable, polished, genuinely helpful — so Jonah can demo it to the **head of 22C** (his IB fellowship program) and it just works. Every iteration leaves the tool more solid than the last.

**NOT now:** flashcards, a practice/spaced-repetition system, or any big new feature. Those come later (a few days out). This loop hardens what already exists. If you think of a new feature, write it to the backlog — don't build it.

## Autonomous mode (Jonah away, from 2026-06-13 eve)
Jonah handed off: run the loop unattended, make every existing feature as useful/helpful/polished as possible, **make all assumptions yourself** (don't wait to ask). Because he's away there is NO live session to protect — so **relaunch + drive-verify freely** (the constraint about not relaunching mid-study is suspended while he's away; just check he hasn't returned by watching for new user messages). EXCEPTION: if the coach process is DOWN and ended abruptly while the machine is still up (he closed it for the night), do NOT keep force-relaunching it — that fights his close. Do code-only items (parse + reason + unit-test verified), commit them for his next launch, and resume drive-verification once the coach is running again. Bias to: verify a feature actually works end-to-end with the drive channel, SEE the result (screenshot Excel via computer-use, don't trust cell properties alone), fix what's weak, make it look polished. Small, verified commits.

## STATUS (iter 15, 2026-06-14 6:35pm, Jonah re-engaged, coach RELAUNCHED - all fixes live)
Jonah is back; asked to run the loop every 10 min and improve every feature. The coach had been running STALE 10:17am code (none of the day's 14 fixes live). This iteration: shipped wrap-text for long capped-column labels (iter 15), then relaunched with Excel closed (safe window) so all 15 fixes are now LIVE and verified healthy (watcher up 18:35). Cron now every 10 min (job fbeb9703). REMAINING items need real usage / visual sign-off (masked strip) or are risky-blind: listening-indicator look, 3-dot menu, fractions/KaTeX, capability routing, watcher hang-recovery. Next: drive-verify wrap-text + formatting on a real build (his, or a self-driven one once a workbook is open), then work the backlog.

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
- **responsiveness** — time every drive cmd -> answer using log timestamps (xc_ask.log / xc_hands.log / xc_watcher.log). Targets: Why/Kick < 10s (measured 6-9s), cheat < 30s, guide step < 20s; flag anything slow (Audit measured > 2.5 min = the open bug). The coach must FEEL fast and snappy.

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
- [FIXED 2026-06-14, commit e572cff] ~~Audit returned nothing~~ — was reasoning_effort high + 2800 cap + --max-time 150 -> reasoning ate the budget / curl timed out -> silent. Now medium effort + 4500 cap + --max-time 220 + honest empty-handling. Verified: returns in ~20s with a full line-by-line recompute. (Watch it stays fast/reliable.)
- [FIXED 2026-06-14, commit 9b24b0c] ~~fail-honestly on Run-Demo + Make-Drill~~ — both now do the early Excel-open check before the model call (all 3 build fns consistent). Goes live next relaunch.
- [SHIPPED 2026-06-14, commit 64c718c - NOT YET LIVE, next relaunch] ~~Watcher hang-detection~~ — watcher now stamps `$sync.wHB` each loop; tick force-restarts if still Running but no stamp > 5 min, with a 3-min cooldown so it can't thrash, reusing the proven restart path (best-effort BeginStop + logs WATCHDOG). Gating logic unit-tested (4-min stale = no, 6-min = yes, recent-cooldown = no, 20-min real hang = yes). Can't induce a real COM hang to test the restart end-to-end; the restart code itself is the existing State-based path.
- [FIXED 2026-06-14, commit f5a5a71] ~~Same-issue nudge re-nag~~ — same issue (shared cell ref) now waits 180s before re-nagging; new issue still 20s; resets on fix. Unit-tested. (Goes live next relaunch.)
- [quality] **Tune Guide** from the logs — watch for slug jitter (false advancement), over-firing, or guidance that's too long/short; make sure the overview fires once and the steps track real progress.
- [quality] **Fix the struggling Teach worked-example** build if it still chokes — read its log.
- [polish] **3-dot (...) options popup** for the toggles (hands/teach/format/guide/mute/sound) — declutter the strip + give Guide a visible toggle.
- [SHIPPED 2026-06-14, commit 2b58208] ~~cheat/build long cells wrap-text~~ - capped columns now wrap-text the build's OWN cells + auto-fit those rows; student cells untouched. Parse-verified, live. NEEDS visual confirm on a real build (screenshot Excel once a workbook is open).
- [correctness] **Capability-aware routing** — any phrasing routes to the right feature, not brittle exact-phrase regex.
- [BUILT 2026-06-14, commit d24d717 - NEEDS JONAH'S VISUAL SIGN-OFF] **"Is it listening?" indicator** — green pulsing "Listening" label + green VU bars while in a "hey coach" conversation (driven by $sync.chatOn). Built additively (no status-machine touch), logic-verified, but the LOOK is unconfirmed (strip masked). On relaunch: say "hey coach", confirm the green cue appears at the right time; tune if it should also fire for one-off "coach, ..." asks or look different.
- [PARTIAL 2026-06-14, commit a3c91bc] **Panel answer formatting** — markdown TABLES now render as styled HTML tables in the pill + answers nudged to use them (Node-verified). STILL TODO (bigger lift, needs Jonah's eyes): stacked fractions / real math via KaTeX or MathJax, and judging the live look once he relaunches.
- [responsiveness] make the whole thing FEEL fast — snappy acks, no long silent waits; investigate any feature measured slow.
- Keep discovering via logs + drive-channel testing + screenshots.

## Pace & surfacing
- **Self-pace** with ScheduleWakeup. Coach open + Jonah studying -> watch the logs + do small safe improvements + drive-test. Coach idle / Jonah away -> do offline reliability + polish that doesn't need his live Excel (code, parse-verify, commit; defer drive-tests).
- **Surface to Jonah only** when: a decision is needed, a milestone lands, something broke, or he asks. Otherwise work quietly and keep committing.
- **Stop** when the quality bar is met and the backlog is empty, or when Jonah says stop.
