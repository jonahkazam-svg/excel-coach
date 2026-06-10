# Cluely-Style UI Design Spec for the excel-coach Strip

Goal: make our always-on-top WinForms "strip" look and feel like Cluely's desktop
overlay, while staying inside our hard constraints (PowerShell 5.1, WinForms only,
ASCII-only source, no capture-hiding/stealth).

This doc has three parts:

- **(A)** What Cluely actually looks like, with sources.
- **(B)** A concrete recreation design for our strip (exact RGB, sizes, layout, type).
- **(C)** Draft ASCII-only PowerShell 5.1 / WinForms code for the key visual pieces.

---

## (A) What Cluely's UI actually looks like

### Overall aesthetic

Cluely is an Electron desktop overlay (macOS + Windows) that floats above
everything else. The window is a **transparent, frameless, always-on-top** Electron
window (`transparent: true`, `frame: false`, `alwaysOnTop: true`, `skipTaskbar: true`,
`resizable: false`), so only the rounded UI "card" is visible — there is no OS window
chrome. It sits near the **top-center / top-right** of the screen and is fully
**draggable** so you can park it where you are looking.

The look is: **minimal, very dark (near-black), glassy, heavily rounded, low-contrast
chrome with a single blue accent.** It reads as a small frosted "card" or, when idle,
a compact **pill**.

Sources:
- Reverse-engineering writeup (confirms the Electron window flags / transparency):
  https://prathit.vercel.app/blog/reverse-engineering-cluely
- Cheap-cluely clone description ("translucent always-on-top overlay"):
  https://github.com/nwx77/cheap-cluely
- Dupple review (overall design / top-right placement / draggable):
  https://dupple.com/tools/cluely

### The bar / pill

- Idle state is a **compact pill** (Cluely changelog, Oct 29 2025, v1.81.0:
  "Active sessions now display as a pill for better visibility and quick access").
- Dec 10 2025 (v1.88.7): "A simplified widget designed to focus on AI meeting
  assistance. Less invasive, one click AI help" — i.e. the trend is *fewer*
  controls, one primary action.
- Nov 6 2025 (v1.88.3): the widget exposes a small set of toggles directly —
  "Toggle your undetectability and active mode directly from the Cluely widget.
  The **eye icon** toggles undetectability." So the bar carries small icon toggles
  (eye = visibility, plus mode/active).
- A **recording timer** is shown on the bar while listening (`00:00 Recording`).
- A **mode indicator** ("Smart") appears on the bar.

Source (changelog, all quotes above): https://docs.cluely.com/changelog

### Controls / labels on the bar

From the live cluely.com marketing UI, the visible labels/affordances are:

- **"Assist"** — the primary button, triggered by **Cmd/Ctrl + Enter**, shown on the
  bar as the hint **`⌘↵ for Assist`**.
- **"Ask a question, or Ask about your screen or conversation"** — the input
  placeholder text.
- **"What should I say?"** — a quick-suggestion chip.
- **"Follow-up questions"** and **"Recap"** — secondary quick actions.
- A recording timer + a "Smart" mode tag.

Source: https://cluely.com/ (hero/product UI). Keyboard shortcuts also confirmed by the
BitDegree review: `Ctrl+Enter` to ask about screen, `Ctrl+Shift+Enter` for chat —
https://www.bitdegree.org/ai/cluely-ai-review

### The answer / response panel

- Triggering Assist **expands a panel below the bar** with the AI answer.
- The panel is **expandable/collapsible** to minimize screen obstruction, and the
  answer **streams in line-by-line** (typewriter) rather than appearing all at once.
- Content is rich text / markdown (headings, lists, code blocks for the coding
  examples Cluely shows in its demo).

Sources:
- cluely.com (answer panel + streaming demo)
- Streaming behavior confirmed in a clone issue explicitly replicating Cluely:
  "the UI should start rendering the response line by line ... [like cluely]" —
  https://github.com/sohzm/cheating-daddy/issues/47

### Concrete colors / radius / type (from the closest open-source clones)

cluely.com itself ships no public stylesheet for the overlay, but the most popular
open-source Cluely clones replicate the exact look and **do** expose hard values.
`sohzm/cheating-daddy` (an Electron Cluely clone) defines this design-token set,
which is an excellent match for the "near-black + one blue accent + Inter" Cluely
aesthetic:

```
--bg-app:        #0A0A0A   /* window / answer body            */
--bg-surface:    #111111   /* header bar background           */
--bg-elevated:   #191919   /* inputs, key caps, code blocks   */
--bg-hover:      #1F1F1F   /* button hover                    */
--text-primary:  #F5F5F5
--text-secondary:#999999
--text-muted:    #555555
--border:        #222222
--border-strong: #333333
--accent:        #3B82F6   /* blue primary action             */
--accent-hover:  #2563EB
--success:       #22C55E
--warning:       #D4A017
--danger:        #EF4444
--font: 'Inter', -apple-system, system-ui, sans-serif
--font-mono: 'SF Mono','Menlo','Monaco','Consolas', monospace
--radius-sm: 4px  --radius-md: 8px  --radius-lg: 12px
window border-radius: 12px; window border: 1px solid #222222
header padding: 8px 16px; header font-size: 14px; gap: 8px
icon button size: 18px; key-cap: 11px mono on #191919, radius 3px
response font-size: 15px; line-height: 1.6
```

Source (design tokens / CSS):
- https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/index.html
- https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/components/app/AppHeader.js
- https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/components/views/AssistantView.js

**Takeaways that define the Cluely look:**
1. Background is **near-black, not mid-gray** (#0A0A0A–#191919), darker than our
   current strip (RGB 24,26,32 = #181A20).
2. **One** saturated accent only: blue **#3B82F6** (very close to our current
   56,120,236 = #3878EC — keep it, just nudge slightly).
3. **Heavy rounding** (window 12px; we should go further on the pill — see B).
4. **Hairline, low-contrast borders** (#222 over near-black), not the relatively
   bright 58,64,78 we use now.
5. **Inter** typeface; mono **key-caps** for shortcut hints.
6. **Glass:** the real app gets translucency from Electron transparency + the OS
   compositor blurring whatever is behind the rounded card. We can only approximate
   this in WinForms (see B/C) via form opacity + a faux frosted gradient.

---

## (B) Recreation design for our strip

Our strip is a borderless rounded WinForms form (region via `GraphicsPath`, border
drawn in `Paint`). We keep that architecture and restyle it to the Cluely palette,
add a real pill idle state, and add a separate expandable answer panel form.

### Palette (exact RGB for `[System.Drawing.Color]::FromArgb`)

| Token            | Hex      | RGB           | Use                                   |
|------------------|----------|---------------|---------------------------------------|
| bg-app           | #0A0A0A  | 10, 10, 10    | answer panel body, deepest bg         |
| bg-surface       | #121316  | 18, 19, 22    | strip/pill background (top)           |
| bg-surface-2     | #17181C  | 23, 24, 28    | strip background (bottom, gradient)   |
| bg-elevated      | #1C1D22  | 28, 29, 34    | Ask box, key-caps, code blocks        |
| bg-hover         | #26272D  | 38, 39, 45    | button hover                          |
| text-primary     | #F2F3F5  | 242, 243, 245 | primary text                          |
| text-secondary   | #9A9CA3  | 154, 156, 163 | secondary text / placeholder          |
| text-muted       | #5A5C63  | 90, 92, 99    | muted hints / shortcut text           |
| border           | #2A2C33  | 42, 44, 51    | hairline border (1px)                 |
| border-strong    | #3A3D45  | 58, 61, 69    | dividers, focus ring base             |
| accent           | #3B82F6  | 59, 130, 246  | primary action (Ask/Assist)           |
| accent-hover     | #2F6FE0  | 47, 111, 224  | accent hover                          |
| status-on        | #22C55E  | 34, 197, 94   | status dot (listening/ready)          |
| status-warn      | #D4A017  | 212, 160, 23  | status dot (busy)                     |
| danger           | #EF4444  | 239, 68, 68   | stop/clear                            |

Notes vs current strip:
- Darken bg from 24,26,32 to ~18,19,22 (top) / 23,24,28 (bottom) for the near-black
  Cluely feel, applied as a subtle vertical gradient (top slightly lighter).
- Soften the border from 58,64,78 to **42,44,51** (hairline, low contrast).
- Keep accent blue, nudge to the exact Cluely **59,130,246**.

### Dimensions, rounding, opacity

- **Pill (idle):** 188 x 40, corner radius **20** (full pill), single row.
  Contents: status dot + "Ask" hint + `Ctrl+Enter` key-cap.
- **Strip (expanded controls):** **600 x 80**, corner radius **18** (slightly more
  than current 16 to match Cluely's softer card), two rows.
- **Answer panel:** width **600** (matches strip), height auto up to **~420**,
  corner radius **16**, anchored directly under the strip with an **8px** gap.
- **Opacity:** form `Opacity = 0.96` for the strip/pill (subtle see-through that
  reads as "glass" without hurting legibility), `0.97` for the answer panel.
  Do **not** go below ~0.92 — text gets muddy and there is no real backdrop blur
  in WinForms to compensate.
- **Drag:** whole strip draggable (mouse-down anywhere not on a control), like Cluely.

### Layout

Pill (idle):
```
[ (*) Ask                          Ctrl+Enter ]
  dot  secondary text                 key-cap
```

Strip (active), two rows, 600x80:
```
Row 1 (controls):
  ( * )   [glyph] [glyph] [glyph] [glyph]        [ ? ]  [ pin ]
  status   four icon buttons (Segoe MDL2)         help   note
Row 2 (input):
  [ Ask about your screen or session...            ] ( ->/Assist )
   bg-elevated rounded Ask box (placeholder)         accent button
```
- Icon buttons: 30x30, radius 8, transparent bg, glyph in text-secondary, hover bg
  = bg-hover and glyph -> text-primary (matches Cluely's quiet icon toggles).
- Status dot: 9px filled circle, status-on when listening, status-warn when busy.
- Ask box: bg-elevated, 1px border, radius 10, placeholder in text-secondary,
  focus border -> accent.
- Primary "Assist" button: accent fill, white glyph (arrow / Send), radius 10.

Answer panel:
```
+--------------------------------------------------------------+
| Answer                                   00:14   [copy] [x]  |  <- header row
|--------------------------------------------------------------|
|  streamed markdown text ...                                  |  <- scrollable body
|  - bullets, code blocks on bg-elevated                       |
+--------------------------------------------------------------+
```
- Header: 32px tall, bg-surface, text-secondary labels, a mono timer, a copy icon,
  a close (x). 1px bottom divider in `border`.
- Body: bg-app (#0A0A0A), text-primary at 14px, line-height ~1.5, 16px padding,
  vertical scroll, code/`pre` blocks on bg-elevated with radius 8.
- Streaming: append text on a timer to mimic Cluely's line-by-line reveal.

### Typography

- Primary UI font: **Segoe UI** (closest universally-available stand-in for Inter on
  Windows; Inter usually is not installed). Sizes: bar text 10–11pt, Ask box 10pt,
  answer body 11pt (~14–15px).
- Shortcut key-caps: **Consolas** (mono), 8.5–9pt, on bg-elevated, radius 4.
- Glyphs: **Segoe MDL2 Assets**, referenced ASCII-safe via `[char]0xNNNN`.

Useful MDL2 glyphs (all expressed as `[char]0xNNNN` to keep source ASCII-only):
- Microphone / listen: `0xE720`
- Camera / screen capture: `0xE722`  (or Screenshot `0xE7B3`)
- Send / Assist arrow: `0xE724`  (or `0xE72A` forward)
- Settings gear: `0xE713`
- Help "?": `0xE897`  (or `0xE11B`)
- Pin / note: `0xE718` (pin) or `0xE70B` (edit)
- Eye (show/hide, Cluely-style): `0xE7B3` is screenshot; eye is `0xE890` (RedEye `0xE7B3`? use **`0xE890`** View / **`0xE8FF`** hide). Verify on target machine.
- Close X: `0xE711`
- Copy: `0xE8C8`

(If a glyph renders as a box on your build of Segoe MDL2, swap to a nearby code from
the same font — the codepoints above are the common set on Win10/11.)

---

## (C) Draft PowerShell 5.1 / WinForms code (ASCII-only)

All snippets are ASCII-only and PS 5.1 compatible. Glyphs use `[char]0xNNNN`.
These are building blocks, not a full app — wire them into the existing strip.

### C.0 Palette + rounded-region helpers

```powershell
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Palette (Cluely-style) ---
$Palette = @{
    BgApp        = [System.Drawing.Color]::FromArgb(10,10,10)
    BgSurface    = [System.Drawing.Color]::FromArgb(18,19,22)
    BgSurface2   = [System.Drawing.Color]::FromArgb(23,24,28)
    BgElevated   = [System.Drawing.Color]::FromArgb(28,29,34)
    BgHover      = [System.Drawing.Color]::FromArgb(38,39,45)
    TextPrimary  = [System.Drawing.Color]::FromArgb(242,243,245)
    TextSecondary= [System.Drawing.Color]::FromArgb(154,156,163)
    TextMuted    = [System.Drawing.Color]::FromArgb(90,92,99)
    Border       = [System.Drawing.Color]::FromArgb(42,44,51)
    BorderStrong = [System.Drawing.Color]::FromArgb(58,61,69)
    Accent       = [System.Drawing.Color]::FromArgb(59,130,246)
    AccentHover  = [System.Drawing.Color]::FromArgb(47,111,224)
    StatusOn     = [System.Drawing.Color]::FromArgb(34,197,94)
    StatusWarn   = [System.Drawing.Color]::FromArgb(212,160,23)
    Danger       = [System.Drawing.Color]::FromArgb(239,68,68)
}

# Build a rounded-rectangle GraphicsPath (reused for region + border paint)
function New-RoundedPath {
    param([int]$W, [int]$H, [int]$R)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc(0,        0,        $d, $d, 180, 90)   # top-left
    $path.AddArc($W-$d,    0,        $d, $d, 270, 90)   # top-right
    $path.AddArc($W-$d,    $H-$d,    $d, $d,   0, 90)   # bottom-right
    $path.AddArc(0,        $H-$d,    $d, $d,  90, 90)   # bottom-left
    $path.CloseFigure()
    return $path
}

# Apply a rounded region to any control/form
function Set-RoundedRegion {
    param($Control, [int]$R)
    $p = New-RoundedPath -W $Control.Width -H $Control.Height -R $R
    $Control.Region = New-Object System.Drawing.Region($p)
    $p.Dispose()
}
```

### C.1 The strip / pill form setup (borderless, rounded, draggable, glassy)

```powershell
function New-StripForm {
    param([int]$W = 600, [int]$H = 80, [int]$R = 18)

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.Width  = $W
    $f.Height = $H
    $f.BackColor = $Palette.BgSurface
    # Faux "glass": slight see-through. WinForms has no real backdrop blur,
    # so we stay high enough to keep text crisp.
    $f.Opacity = 0.96

    # Park bottom-center of the working area (our strip lives at the bottom).
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Left = $wa.Left + [int](($wa.Width - $W) / 2)
    $f.Top  = $wa.Bottom - $H - 24

    Set-RoundedRegion -Control $f -R $R

    # --- Painted background gradient + hairline border (the "card") ---
    $f.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode     = 'AntiAlias'
        $g.PixelOffsetMode   = 'HighQuality'
        $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)

        # Vertical gradient: top slightly lighter -> bottom darker (subtle depth)
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, $Palette.BgSurface, $Palette.BgSurface2, 90)
        $path = New-RoundedPath -W $s.Width -H $s.Height -R 18
        $g.FillPath($lg, $path)
        $lg.Dispose()

        # Hairline 1px border just inside the edge
        $pen = New-Object System.Drawing.Pen($Palette.Border, 1)
        $bpath = New-RoundedPath -W ($s.Width - 1) -H ($s.Height - 1) -R 18
        $g.DrawPath($pen, $bpath)
        $pen.Dispose(); $path.Dispose(); $bpath.Dispose()

        # Optional 1px top inner highlight for a faint "glass" edge
        $hl = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::FromArgb(22, 255, 255, 255), 1)
        $g.DrawLine($hl, 18, 1, $s.Width - 18, 1)
        $hl.Dispose()
    })

    # --- Drag anywhere on the card ---
    $script:drag = $false
    $script:dragOff = New-Object System.Drawing.Point(0,0)
    $down = {
        param($s,$e)
        if ($e.Button -eq 'Left') {
            $script:drag = $true
            $script:dragOff = $e.Location
        }
    }
    $move = {
        param($s,$e)
        if ($script:drag) {
            $f.Left += ($e.X - $script:dragOff.X)
            $f.Top  += ($e.Y - $script:dragOff.Y)
        }
    }
    $up = { param($s,$e) $script:drag = $false }
    $f.Add_MouseDown($down); $f.Add_MouseMove($move); $f.Add_MouseUp($up)

    return $f
}
```

### C.2 Translucency / "glass" approach that works in WinForms

WinForms cannot do a true backdrop blur (that needs DWM/WPF/`DwmEnableBlurBehind`
or per-pixel layered windows). Two practical, supported approaches:

1. **Form.Opacity (recommended, simplest).** Set `$f.Opacity = 0.96`. The whole form
   becomes uniformly translucent. Combined with the near-black gradient and a faint
   white top highlight, this reads convincingly as a dark glass card. Keep >= 0.92.

2. **Faux frosted gradient (already in C.1).** A vertical near-black gradient plus a
   1px translucent-white top edge mimics the light catch on real glass. This is what
   sells the look more than raw opacity does.

Optional advanced (only if you want a real blur behind the card on Win10/11):
`DwmEnableBlurBehind` / the undocumented `accent-policy` (`SetWindowCompositionAttribute`)
can blur what is behind a layered window. It works but is finicky from PS 5.1 and
varies by Windows build. Recommended: ship with Opacity + faux gradient first; treat
DWM blur as a later enhancement.

```powershell
# Minimal DWM blur-behind (optional; may be a no-op on some builds).
# Safe to skip - the Opacity + gradient look is the primary plan.
$dwmSig = @'
using System;
using System.Runtime.InteropServices;
public static class Dwm {
    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS { public int l, r, t, b; }
    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
}
'@
# Add-Type -TypeDefinition $dwmSig -ErrorAction SilentlyContinue
# $m = New-Object Dwm+MARGINS; $m.l=-1;$m.r=-1;$m.t=-1;$m.b=-1
# [Dwm]::DwmExtendFrameIntoClientArea($f.Handle, [ref]$m) | Out-Null
```

### C.3 Reusable styled controls (icon button, accent button, Ask box, status dot)

```powershell
# Quiet icon button (Segoe MDL2 glyph). Glyph passed as a [char].
function New-IconButton {
    param([char]$Glyph, [int]$X, [int]$Y, [int]$Size = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = [string]$Glyph
    $b.Font      = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
    $b.Width = $Size; $b.Height = $Size
    $b.Left = $X; $b.Top = $Y
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Palette.BgSurface
    $b.ForeColor = $Palette.TextSecondary
    $b.TabStop = $false
    Set-RoundedRegion -Control $b -R 8
    $b.Add_MouseEnter({ $this.BackColor = $Palette.BgHover;   $this.ForeColor = $Palette.TextPrimary })
    $b.Add_MouseLeave({ $this.BackColor = $Palette.BgSurface; $this.ForeColor = $Palette.TextSecondary })
    return $b
}

# Primary "Assist"/Send button (accent fill, white glyph)
function New-AccentButton {
    param([char]$Glyph, [int]$X, [int]$Y, [int]$W = 44, [int]$H = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = [string]$Glyph
    $b.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 12)
    $b.Width = $W; $b.Height = $H; $b.Left = $X; $b.Top = $Y
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Palette.Accent
    $b.ForeColor = [System.Drawing.Color]::White
    Set-RoundedRegion -Control $b -R 10
    $b.Add_MouseEnter({ $this.BackColor = $Palette.AccentHover })
    $b.Add_MouseLeave({ $this.BackColor = $Palette.Accent })
    return $b
}

# Ask input box (dark, rounded look via a hosting panel + borderless TextBox)
function New-AskBox {
    param([int]$X, [int]$Y, [int]$W, [int]$H = 30, [string]$Placeholder = 'Ask about your screen or session...')
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = $X; $panel.Top = $Y; $panel.Width = $W; $panel.Height = $H
    $panel.BackColor = $Palette.BgElevated
    Set-RoundedRegion -Control $panel -R 10
    $panel.Add_Paint({
        param($s,$e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen($Palette.Border, 1)
        $bp = New-RoundedPath -W ($s.Width-1) -H ($s.Height-1) -R 10
        $e.Graphics.DrawPath($pen, $bp); $pen.Dispose(); $bp.Dispose()
    })

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.BackColor = $Palette.BgElevated
    $tb.ForeColor = $Palette.TextSecondary   # placeholder color until focused
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $tb.Left = 10; $tb.Top = [int](($H-16)/2); $tb.Width = $W - 20
    $tb.Text = $Placeholder
    $tb.Tag  = 'placeholder'
    $tb.Add_GotFocus({
        if ($this.Tag -eq 'placeholder') {
            $this.Text = ''; $this.Tag = ''; $this.ForeColor = $Palette.TextPrimary
        }
    })
    $tb.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text = $Placeholder; $this.Tag = 'placeholder'
            $this.ForeColor = $Palette.TextSecondary
        }
    })
    $panel.Controls.Add($tb)
    return $panel
}

# Status dot (owner-drawn 9px circle on a tiny panel)
function New-StatusDot {
    param([int]$X, [int]$Y)
    $p = New-Object System.Windows.Forms.Panel
    $p.Left = $X; $p.Top = $Y; $p.Width = 12; $p.Height = 12
    $p.BackColor = $Palette.BgSurface
    $p.Tag = $Palette.StatusOn   # change Tag + Invalidate() to recolor
    $p.Add_Paint({
        param($s,$e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $br = New-Object System.Drawing.SolidBrush($s.Tag)
        $e.Graphics.FillEllipse($br, 2, 2, 8, 8)
        $br.Dispose()
    })
    return $p
}
```

### C.4 Mono shortcut key-cap (the `Ctrl+Enter` chip Cluely shows)

```powershell
function New-KeyCap {
    param([string]$Text, [int]$X, [int]$Y)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $lbl.ForeColor = $Palette.TextMuted
    $lbl.BackColor = $Palette.BgElevated
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.AutoSize = $false
    $lbl.Height = 18
    $lbl.Width  = 8 + ($Text.Length * 7)
    $lbl.Left = $X; $lbl.Top = $Y
    Set-RoundedRegion -Control $lbl -R 4
    return $lbl
}
# Usage: $cap = New-KeyCap -Text 'Ctrl+Enter' -X 500 -Y 12
```

### C.5 The expandable answer panel (separate rounded form, streamed text)

```powershell
function New-AnswerPanel {
    param($Owner, [int]$W = 600)

    $a = New-Object System.Windows.Forms.Form
    $a.FormBorderStyle = 'None'
    $a.StartPosition   = 'Manual'
    $a.ShowInTaskbar   = $false
    $a.TopMost         = $true
    $a.Width  = $W
    $a.Height = 260            # grows with content up to ~420
    $a.BackColor = $Palette.BgApp
    $a.Opacity   = 0.97
    Set-RoundedRegion -Control $a -R 16

    $a.Add_Paint({
        param($s,$e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen($Palette.Border, 1)
        $bp = New-RoundedPath -W ($s.Width-1) -H ($s.Height-1) -R 16
        $e.Graphics.DrawPath($pen, $bp); $pen.Dispose(); $bp.Dispose()
    })

    # Header row: label + timer + copy + close
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Dock = 'Top'; $hdr.Height = 32; $hdr.BackColor = $Palette.BgSurface
    $hdr.Add_Paint({
        param($s,$e)
        $pen = New-Object System.Drawing.Pen($Palette.Border, 1)
        $e.Graphics.DrawLine($pen, 0, $s.Height-1, $s.Width, $s.Height-1)
        $pen.Dispose()
    })
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Answer'; $title.AutoSize = $true
    $title.ForeColor = $Palette.TextSecondary
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $title.Left = 12; $title.Top = 8
    $hdr.Controls.Add($title)

    $close = New-IconButton -Glyph ([char]0xE711) -X ($W-34) -Y 1 -Size 30
    $close.BackColor = $Palette.BgSurface
    $close.Add_Click({ $a.Hide() })
    $hdr.Controls.Add($close)

    # Body: scrollable rich-ish text (RichTextBox keeps it simple + scrollable)
    $body = New-Object System.Windows.Forms.RichTextBox
    $body.Dock = 'Fill'
    $body.BorderStyle = 'None'
    $body.BackColor = $Palette.BgApp
    $body.ForeColor = $Palette.TextPrimary
    $body.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $body.ReadOnly = $true
    $body.Multiline = $true
    $body.WordWrap = $true

    $a.Controls.Add($body)
    $a.Controls.Add($hdr)

    # Position under the owner strip with an 8px gap
    $reposition = {
        $a.Left = $Owner.Left
        $a.Top  = $Owner.Bottom + 8
    }
    & $reposition
    $Owner.Add_LocationChanged($reposition)

    # Expose helpers on the form's Tag for the caller
    $a | Add-Member -NotePropertyName Body -NotePropertyValue $body -Force
    return $a
}

# --- Streaming (line-by-line typewriter, like Cluely) ---
function Start-AnswerStream {
    param($Panel, [string]$FullText, [int]$ChunkMs = 18)
    $Panel.Body.Clear()
    $script:streamIdx = 0
    $script:streamText = $FullText
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = $ChunkMs
    $t.Add_Tick({
        if ($script:streamIdx -lt $script:streamText.Length) {
            # reveal a few chars per tick for a smooth stream
            $end = [Math]::Min($script:streamIdx + 3, $script:streamText.Length)
            $Panel.Body.AppendText($script:streamText.Substring($script:streamIdx, $end - $script:streamIdx))
            $script:streamIdx = $end
        } else {
            $t.Stop(); $t.Dispose()
        }
    })
    $Panel.Show()
    $t.Start()
}
```

### C.6 Wiring example (assemble a strip)

```powershell
$strip = New-StripForm -W 600 -H 80 -R 18

# Row 1
$dot   = New-StatusDot -X 16 -Y 16
$btnMic = New-IconButton -Glyph ([char]0xE720) -X 40  -Y 10   # listen
$btnCap = New-IconButton -Glyph ([char]0xE722) -X 76  -Y 10   # screen
$btnSet = New-IconButton -Glyph ([char]0xE713) -X 112 -Y 10   # settings
$btnEye = New-IconButton -Glyph ([char]0xE890) -X 148 -Y 10   # show/hide
$btnHelp= New-IconButton -Glyph ([char]0xE897) -X 520 -Y 10   # ?
$btnPin = New-IconButton -Glyph ([char]0xE718) -X 556 -Y 10   # note pin

# Row 2
$ask   = New-AskBox -X 16 -Y 46 -W 520 -H 28
$send  = New-AccentButton -Glyph ([char]0xE724) -X 544 -Y 46 -W 40 -H 28

$strip.Controls.AddRange(@($dot,$btnMic,$btnCap,$btnSet,$btnEye,$btnHelp,$btnPin,$ask,$send))

# Answer panel + demo stream on send
$answer = New-AnswerPanel -Owner $strip -W 600
$send.Add_Click({
    Start-AnswerStream -Panel $answer -FullText "Here is the answer, streamed line by line like Cluely..."
})

[System.Windows.Forms.Application]::Run($strip)
```

---

## Implementation notes / gotchas

- **Region after resize:** every time you change a form/control's `Width`/`Height`,
  recompute its `Region` (call `Set-RoundedRegion` again) or the rounded corners go
  stale. For the answer panel that grows with content, re-run it on resize.
- **`Opacity` is whole-form:** it dims text too. Don't stack low opacity with a very
  dark bg or text gets muddy. 0.96 strip / 0.97 panel is the sweet spot.
- **No real blur:** if a reviewer expects literal frosted blur, set expectations — the
  faux gradient + opacity is the WinForms-honest version. DWM blur (C.2) is optional.
- **MDL2 glyph fallback:** confirm each `0xNNNN` renders on the target Win build; swap
  any that show as a box. Keep all glyphs as `[char]0xNNNN` to preserve ASCII source.
- **Keep the single-accent rule:** resist adding more colors. Cluely's whole identity
  is near-black + one blue. Use `status-on/warn/danger` only on the tiny status dot
  and the stop action.
- **Pill <-> strip transition:** start as the 188x40 pill; on focus/hotkey, animate
  (or just swap) to the 600x80 strip. A simple `Width/Height` tween over a few timer
  ticks is enough; remember to refresh the region each tick.

---

## Sources

- Cluely official site (UI labels, Assist, answer panel, shortcuts): https://cluely.com/
- Cluely changelog (pill, simplified widget, eye/undetectability toggle, command dialog): https://docs.cluely.com/changelog
- BitDegree review (shortcuts Ctrl+Enter / Ctrl+Shift+Enter, overlay behavior): https://www.bitdegree.org/ai/cluely-ai-review
- Dupple review (top-right placement, draggable, minimal floating bar): https://dupple.com/tools/cluely
- Reverse-engineering writeup (Electron transparent/frameless/always-on-top flags): https://prathit.vercel.app/blog/reverse-engineering-cluely
- cheap-cluely (translucent always-on-top overlay description): https://github.com/nwx77/cheap-cluely
- sohzm/cheating-daddy (open-source clone; concrete dark palette, radius, type tokens):
  - https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/index.html
  - https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/components/app/AppHeader.js
  - https://raw.githubusercontent.com/sohzm/cheating-daddy/master/src/components/views/AssistantView.js
- cheating-daddy issue #47 (confirms line-by-line streaming "like cluely"): https://github.com/sohzm/cheating-daddy/issues/47
