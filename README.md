# Excel Coach

An ambient AI study coach for Excel and finance. It quietly watches your screen and listens to your lesson, then helps you **learn by doing** — it answers questions about whatever's on your screen, catches mistakes in your spreadsheet as you make them, runs adaptive practice drills, and builds worked examples + cheat sheets right inside Excel.

Built for self-studying finance (Breaking Into Wall Street / IB-style 3-statement modeling), but the practice engine works for any subject it watches you study.

> Bring your own OpenAI API key. Everything runs locally on your PC; your key stays in a local `.env` file and is never sent anywhere except OpenAI.

---

## Quick start (Windows 10/11)

### Easiest: one-line install (recommended)
1. Press the **Windows key**, type **PowerShell**, and press **Enter**.
2. Paste this and press **Enter**:
   ```
   irm https://raw.githubusercontent.com/jonahkazam-svg/excel-coach/main/quick-install.ps1 | iex
   ```
3. When asked, **paste your OpenAI API key** (get one at <https://platform.openai.com/api-keys>).

It downloads everything, drops an **Excel Coach** icon on your Desktop, and launches. Run the same line again anytime to update.

*Prefer double-clicking?* Download **`Install Excel Coach.bat`** from this repo and run it — same result.

### Or set it up by hand
1. **Download** this repo — **Code → Download ZIP**, then unzip (or `git clone`).
2. **Double-click `Start Coach.bat`** — on first run it asks for your OpenAI API key, then launches.

Then open Excel and start working — click the bar's buttons or just ask. To stop it, click the **✕** on the bar.

---

## What it does

A floating bar gives you, one click each:

- **Assist** — answers your question, or reads your screen + Excel if the box is empty. Streams the answer as it types.
- **Kick-start** — a nudge to get moving on the current sheet (the next concrete step, not the answer).
- **Why this cell** — explains the reasoning + the reusable rule behind the cell your cursor is on.
- **Check my sheet** — a deep audit of every formula against the goal, with exact fixes.
- **Cheat sheet** — drops a compact step-by-step reference card to the right of your work.
- **Demo + practice** — builds a new tab with a fully worked example on the left and a blank, highlighted practice version on the right, then checks your answers.
- **Run-through** — an adaptive drill that gets harder as you get things right and gives fresh variations when you slip.
- **Flashcards / Practice** — spaced-repetition review.

It also watches in the background and flags spreadsheet mistakes as you make them.

---

## Requirements

- **Windows 10 or 11.**
- An **OpenAI API key** (pay-as-you-go; the default "fast" model is `gpt-5-mini`, which keeps everyday use cheap).
- **Microsoft Excel** (for the Excel-specific features). The coach also helps with quizzes/exercises in a browser or other windows.

The WebView2 runtime needed for the UI ships with the app (in `tools/webview2`).

---

## Optional: full-fidelity screen capture

The coach reads your screen so it can help with image-based content (e.g. a screenshot of a financial statement pasted into Excel). Windows Defender sometimes blocks screen-capture code by default. If you want the sharpest capture and the most reliable background watcher, run **`ENABLE COACH (run once before demo).bat`** once **as Administrator** — it adds this folder to Defender's exclusions. This is optional; the coach works without it.

---

## Changing settings

Run **`tools\Set OpenAI key.bat`** any time to update your key. For model/voice/mic overrides, copy **`.env.example`** to **`.env`** and edit it (see the comments in that file).

---

## Privacy & cost

- **Local-first.** The app runs on your machine. Your study content, progress, and `.env` (with your key) stay local and are git-ignored — they are never committed or uploaded.
- **Your key, your bill.** API calls go directly from your PC to OpenAI using your key. Costs scale with use; the fast tier is inexpensive, and "Check my sheet" / "Explain in detail" use a stronger (pricier) model only when you ask for them.

---

## Troubleshooting

- **Nothing happens / no bar:** double-click `Start Coach.bat` again (it clears any stuck instance and restarts cleanly).
- **"No key" / it exits:** run `tools\Set OpenAI key.bat` and paste a valid key (starts with `sk-`).
- **Answers seem to ignore your sheet while you're typing in a cell:** press Enter/Esc to leave edit mode first (Excel blocks reads mid-edit).

---

*Not affiliated with OpenAI or Microsoft. Provided as-is.*
