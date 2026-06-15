# Excel Coach - Installer

Builds `ExcelCoach-Setup.exe`, a per-user (no-admin) Windows installer for Excel Coach.

## What gets installed

Everything lands in `%LOCALAPPDATA%\ExcelCoach` (no admin / no UAC):

- `excel-coach.cmd` - the launcher (WebView2 check -> first-run setup -> launch coach hidden)
- `tools\` - all PowerShell modules (`watch.ps1`, `coach.ps1`, `transcribe.ps1`, `curriculum.ps1`, `deck.ps1`, `practice.ps1`, `updater.ps1`, `setup.ps1`), the UI (`tools\ui\panel.html`, `tools\ui\strip.html`), and the WebView2 SDK DLLs (`tools\webview2\`)
- `Coaching\Curriculum.md` - the curriculum the coach teaches from
- `VERSION` - single-line semver consumed by `updater.ps1`
- `ffmpeg.exe` - mic capture/encode
- `MicrosoftEdgeWebView2RuntimeInstaller.exe` - WebView2 runtime bootstrapper (run silently on first launch if needed)
- `data\` - empty folder created for `deck.json` / `review-state.json` at runtime

## Prerequisites

1. **Inno Setup 6** - https://jrsoftware.org/isdl.php
2. **Payload binaries** (not in the repo) - drop these into `installer\payload\`:
   - `ffmpeg.exe` - static Windows build from https://www.gyan.dev/ffmpeg/builds/ ("essentials" build; copy only `ffmpeg.exe`)
   - `MicrosoftEdgeWebView2RuntimeInstaller.exe` - the "Evergreen Bootstrapper" from https://developer.microsoft.com/microsoft-edge/webview2/
   - `excel-coach.cmd` - already committed in `installer\payload\`, no action needed

The `installer\payload\` folder should contain exactly three files before you compile:
`excel-coach.cmd`, `ffmpeg.exe`, `MicrosoftEdgeWebView2RuntimeInstaller.exe`.

3. **VERSION file** - ensure a `VERSION` file exists in the repo root with the current semver (e.g. `2.0.0`). The `.iss` skips it if absent, but `updater.ps1` needs it at runtime.

## Build

GUI: open `installer\excel-coach.iss` in the Inno Setup Compiler and press **F9**.

CLI:

```
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\excel-coach.iss
```

Output: `installer\Output\ExcelCoach-Setup.exe`.

Bump `#define MyAppVersion` near the top of `excel-coach.iss` for each release (keep it in sync with the `VERSION` file).

## Code signing (recommended)

An unsigned, self-updating PowerShell app will trip **SmartScreen** and **Windows Defender**
on other people's machines (download warnings, "unknown publisher", possible quarantine).
Signing the installer with an OV or EV code-signing certificate (~$200/yr) sharply reduces
that friction. EV certs get SmartScreen reputation immediately; OV certs build it over time.

After building, sign the output (and ideally the `.cmd` inside the payload before building):

```
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 ^
  /a installer\Output\ExcelCoach-Setup.exe
```

Signing is flagged as recommended, not required, for v2.
