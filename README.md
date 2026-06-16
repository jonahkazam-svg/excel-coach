# Excel Coach

An ambient, on-screen study coach for Windows. It listens to your lesson, watches
your screen, and helps you drill the material with flashcards, multiple-choice
quizzes, and live fill-in-the-blank Excel exercises - all in a small floating
strip that stays out of your way.

Excel Coach uses **your own** OpenAI API key. The key is stored only on your PC
(in a local `.env` file) and is never sent anywhere except OpenAI.

---

## Install (one line)

Open **Windows PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/jonahkazam-svg/excel-coach/main/install.ps1 | iex
```

That single command will:

1. Download the latest release and verify it.
2. Install the WebView2 runtime and ffmpeg if they are missing.
3. Ask for your OpenAI API key and your microphone (first run only).
4. Add an **Excel Coach** shortcut to your Start menu and launch it.

You will need an OpenAI API key - get one at
<https://platform.openai.com/api-keys>.

---

## Using it

- Launch from the **Excel Coach** Start-menu shortcut any time.
- A thin strip appears at the top of your screen. Open the menu for:
  - **Flashcards** - review cards, with an expand/simplify button when stuck.
  - **Run-through** - an adaptive drill that quizzes you bit by bit and retries
    what you miss until it is solid.
  - **Excel** - generates a fill-in exercise on a fresh worksheet, then checks
    your answers and marks the wrong cells with the correct calculation.
- It only coaches the material in **your course scope** (see below).

## Course scope

`data\scope.json` controls which topics the coach will teach and quiz you on:

```json
{ "domains": ["Accounting", "3-Stmt Modeling", "Excel"] }
```

Only topics in those domains are used - so it never drifts into material you have
not covered. Edit this file to widen or narrow what it drills. An empty list
(`{ "domains": [] }`) means no restriction.

## Updates

Excel Coach checks GitHub Releases on launch and updates itself automatically.
Your API key, course scope, and progress are always preserved across updates.

---

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in).
- Microsoft Excel (for the Excel exercises).
- An OpenAI API key.

## Privacy

- Your API key lives only in `<install>\.env` on your machine.
- Your captured notes, recordings, and study progress stay local and are never
  uploaded anywhere.

## For maintainers

To cut a new release (requires the GitHub CLI `gh`, authenticated):

```powershell
# from the repo root
. .\tools\release.ps1
Publish-Release -Version 2.1.0 -Notes "What changed"
```

This builds `dist\excel-coach-<version>.zip` + `dist\latest.json`, then creates
the GitHub release. The next time any user launches, they update automatically.
