; ===========================================================================
;  Excel Coach - Inno Setup installer script
;  File: installer\excel-coach.iss
; ---------------------------------------------------------------------------
;  WHAT THIS BUILDS
;    A per-user (no-admin) installer that drops Excel Coach into
;    %LOCALAPPDATA%\ExcelCoach, wires up a launcher, the WebView2 runtime
;    bootstrapper, ffmpeg, the PowerShell tools, and the curriculum content,
;    then creates Start-menu (and optional desktop) shortcuts.
;
;  PREREQUISITES (to COMPILE this script)
;    1. Inno Setup 6 (https://jrsoftware.org/isdl.php). Earlier majors will not
;       accept some of the directives below.
;    2. The payload binaries that are NOT in the git repo. Place these in
;       installer\payload\ BEFORE compiling (see "PAYLOAD" below).
;
;  PAYLOAD - drop these into installer\payload\ before you compile:
;    - ffmpeg.exe
;        A static Windows build of ffmpeg (used to capture/encode mic audio).
;        Get it from https://www.gyan.dev/ffmpeg/builds/ (the "essentials"
;        build) and copy ONLY ffmpeg.exe here.
;    - MicrosoftEdgeWebView2RuntimeInstaller.exe
;        The "Evergreen Bootstrapper" from
;        https://developer.microsoft.com/microsoft-edge/webview2/
;        (Download -> "Evergreen Bootstrapper"). The launcher runs it silently
;        on first launch if the runtime is missing.
;    - excel-coach.cmd
;        The launcher. This IS committed to the repo at installer\payload\,
;        so you only need to add the two binaries above.
;
;  HOW TO COMPILE
;    Option A (GUI):  open this file in the Inno Setup Compiler, press F9.
;    Option B (CLI):  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" excel-coach.iss
;    Output:          installer\Output\ExcelCoach-Setup.exe
;
;  VERSIONING
;    Bump MyAppVersion below for each release (it is also written to the
;    installed VERSION file by updater.ps1's release process). Keep it semver.
;
;  CODE SIGNING (recommended, not required)
;    An unsigned self-updating PowerShell app will trip SmartScreen/Defender on
;    other machines. Sign ExcelCoach-Setup.exe (and ideally the .cmd) with an
;    OV/EV code-signing certificate to reduce that friction. See installer
;    README.md for the signtool command.
; ===========================================================================

#define MyAppName "Excel Coach"
#define MyAppVersion "2.0.0"
#define MyAppPublisher "Jonah Kazam"
#define MyAppExeName "excel-coach.cmd"

; Repo root, relative to this .iss file (installer\ -> ..)
#define RepoRoot ".."

[Setup]
; AppId uniquely identifies this app for upgrades/uninstall. Do NOT change it
; once you have shipped - changing it makes Windows treat updates as a second,
; separate product.
AppId={{8E4C0B9A-2F1D-4E7B-9C33-2A7F6D0B1E55}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}

; Per-user install: no admin / no UAC prompt.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

DefaultDirName={localappdata}\ExcelCoach
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}

; Output
OutputDir=Output
OutputBaseFilename=ExcelCoach-Setup
Compression=lzma2
SolidCompression=yes

; Modern wizard
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Dirs]
; Runtime data dir for deck.json / review-state.json. Created empty; the app
; populates it on first run. uninsalwaysuninstall would nuke user state, so we
; leave it out and let the user's review history survive a reinstall/uninstall.
Name: "{app}\data"

[Files]
; -- The launcher (from payload) --------------------------------------------
Source: "payload\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; -- All PowerShell tools + UI + webview2 SDK (recursive) --------------------
;    This single line bundles tools\*.ps1 (watch.ps1, coach.ps1, transcribe.ps1,
;    curriculum.ps1, deck.ps1, practice.ps1, updater.ps1, setup.ps1), tools\ui\
;    (panel.html, strip.html), and tools\webview2\ (the 3 WebView2 SDK DLLs),
;    plus the helper .bat/.lnk files. recursesubdirs + createallsubdirs keeps
;    the folder layout intact.
Source: "{#RepoRoot}\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs createallsubdirs

; -- Curriculum content ------------------------------------------------------
;    The curriculum the coach teaches from. Curriculum.md is the canonical map;
;    we ship it under Coaching\ so paths the app expects line up. If you would
;    rather ship the whole Coaching\ folder, broaden this to "Coaching\*".
Source: "{#RepoRoot}\Coaching\Curriculum.md"; DestDir: "{app}\Coaching"; Flags: ignoreversion

; -- VERSION file ------------------------------------------------------------
;    Single-line semver consumed by updater.ps1. If a VERSION file does not yet
;    exist in the repo root, create one with the version string (e.g. 2.0.0)
;    before compiling, or this line will fail. (skipifsourcedoesntexist lets the
;    build proceed without it, but updater.ps1 then has no local version.)
Source: "{#RepoRoot}\VERSION"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; -- ffmpeg (from payload) ---------------------------------------------------
Source: "payload\ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion

; -- WebView2 runtime bootstrapper (from payload) ---------------------------
;    Kept in the install dir so the launcher can run it silently on first run
;    if the Evergreen runtime is not already present on the machine.
Source: "payload\MicrosoftEdgeWebView2RuntimeInstaller.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start-menu shortcut
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
; Optional desktop shortcut (governed by the desktopicon task above)
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Offer to launch the coach when the installer finishes. nowait so the wizard
; closes cleanly; the .cmd handles WebView2 install + first-run setup itself.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up the empty data dir scaffolding on uninstall. We intentionally do NOT
; force-delete user content (.env, review-state.json) - leave those to the user.
Type: dirifempty; Name: "{app}\data"
