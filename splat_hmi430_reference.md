# SPLat Programming Reference — HMI430

> Sourced from Splatco SKB documentation (skb/3611, 617, 5597, 3595, 5605, 5561, 5563, 3576, 3585, 3600, 3601, 676) and reverse-engineering of existing project code.

---

## Hardware Overview

| Property | Value |
|----------|-------|
| Display | 480 × 272 pixels, color touch LCD |
| Physical size | 98 × 57 mm |
| USB | USB CDC — appears as COM port on PC (typically COM11) |
| Storage | 8 MB "Internal Storage" — accessible via MTP (like a phone) |
| Serial ports | Port 0 = HMI display protocol (do not repurpose); Port 1 = separate UART |

---

## Source File Structure

SPLat programs are split across multiple `.spt` files combined by a build descriptor (`.b1d`).

### Segments (in order)

```spt
CONSTSEG      ; Constants (EQU definitions)
MEQUSEG       ; Permanent memory absolutes
DEF_SEM       ; Semaphore definitions
DEF_BYTE      ; Byte variable definitions
DEF_FLOAT     ; Float variable definitions
POWERONSEG    ; Runs once at power-on (PermRecall etc.)
INITSEG       ; Module initialization, task launches
LAUNCHSEG     ; RunTaskSForever (must be ONEONLY)
CODESEG       ; All task and subroutine code
NVEM0DATA     ; Non-volatile memory defaults
```

### Build descriptor (`.b1d`)

Lists source files in order. Segments are merged across files.

```
CONSTSEG
CODESEG
NVEM0DATA
#---
config.spt
helpers.spt
ui_test.spt
nvem_defaults.spt
serial.spt
```

### Compile and flash

```bash
node splat_build.js _build.b1d    # produces _build.b1n + _build.lst
./MtpCopy.exe _build.b1n          # flashes to device via MTP
```

---

## Control Flow Instructions

| Instruction | Description |
|-------------|-------------|
| `GoSub label` | Call subroutine |
| `Return` | Return from subroutine |
| `GoTo label` | Unconditional jump |
| `Branch condition, label` | Conditional jump |
| `Pause N` | Delay N milliseconds |
| `YieldTask` | Yield execution to other tasks (must duplicate for 2-byte alignment) |
| `LaunchTask taskLabel` | Start a concurrent task |
| `RunTaskSForever` | Loop all tasks forever (goes in LAUNCHSEG) |
| `ClrInstCount` | Reset instruction counter (avoids watchdog timeout on long inits) |

### Task pattern

```spt
INITSEG
    LaunchTask uiTask

LAUNCHSEG
    RunTaskSForever

CODESEG
uiTask:
    YieldTask
    YieldTask        ; duplicate required for 2-byte instructions
uiTask_draw:
    GoSub drawScreen
    YieldTask
    YieldTask
uiTask_idle:
    Pause 500
    GoTo uiTask_idle
```

---

## HMI Display Instructions

All display instructions use the `#HMI` pragma prefix.

### Reset / Clear

```spt
#HMI Reset(b:0)
```
Clears the entire screen and removes all buttons and images. Must be called before redrawing. `b:0` = clear to background color.

```spt
#HMI Cls()
```
Clears text within current bounds only. Does **not** affect buttons or images.

---

### SetColours — system-wide color defaults

```spt
#HMI SetColours(f:ForegroundColor, b:BackgroundColor)
```

Sets default colors used by `Print()` and `ButtonEvent2()`. Either parameter may be omitted.

**Color format:** `'AARRGGBB` (hex literal with leading apostrophe)

| Color | Value |
|-------|-------|
| White | `'FFFFFFFF` |
| Black | `'FF000000` |
| Dark grey | `'FF404040` |
| Medium grey | `'FF808080` |
| Transparent | `'00000000` |
| Red | `'FFFF0000` |
| Green | `'FF00FF00` |
| Blue | `'FF0000FF` |

Named constants (`HUEkXxx`) may also be available depending on firmware version.

---

### SetFont

```spt
#HMI SetFont(f:"fontfile.fon")
```

Selects the active font for subsequent `Print()` calls. Font files must be in the device's Internal Storage. Available in this project's `hmi_assets/`:

| File | Description |
|------|-------------|
| `sysdefault.fon` | System default |
| `small.fon` | Small proportional |
| `prop20.fon`, `prop25.fon`, `prop35.fon`, `prop70.fon`, `prop210.fon` | Proportional fonts at various sizes |
| `propbold35.fon`, `propbold70.fon` | Bold proportional |
| `propnormal.fon` | Normal proportional |
| `normalbold.fon` | Normal bold |
| `mono35.fon`, `mono50.fon`, `mono60.fon`, `mono120.fon` | Monospace fonts |
| `large.fon`, `largebold.fon` | Large fonts |
| `ledseg35.fon` | LED segment style |
| `times_20.fon`, `times_50.fon`, `times_75.fon` | Times-style serif |

---

### SetBounds / SetCursor

```spt
#HMI SetBounds(x:col, y:row, w:cols, h:rows)   ; set text bounding box
#HMI SetBounds()                                 ; reset to full screen
#HMI SetCursor(x:col, y:row)                    ; position within bounds
```

Coordinates are in character units (based on current font). Negative values are relative to right/bottom edge. `px` suffix for pixel coordinates.

---

### Print

```spt
#HMI Print("text", variable, "more text")
```

Prints text at current cursor position using current font and colors.

| Escape | Effect |
|--------|--------|
| `\\C` | Center horizontally |
| `\\R` | Right-align |
| `\\RR` | Resume right-align on current line |
| `\\r` | Carriage return |
| `\\n` | Line feed |

Variable formatting: `b(=x)` = byte register x, `f(=w,3,1)` = float w with 3 digits 1 decimal.

---

### ButtonEvent2 — touch button

```spt
#HMI ButtonEvent2(
    id:N,           ; optional: 0–29, required to update button later
    x:Xpx,          ; top-left X (pixel coords with 'px' suffix)
    y:Ypx,          ; top-left Y
    w:Wpx,          ; width
    h:Hpx,          ; height
    t:"label",      ; button text
    rb:color,       ; resting background color (default from SetColours)
    pb:color,       ; pressed background color
    ev:handlerLabel ; subroutine called on touch
)
```

**Key behaviors:**
- Calling `ButtonEvent2` with the same `id` **updates** the existing button (text, color, handler) — does not create a duplicate.
- `#HMI Reset()` clears all buttons; they must be fully re-declared after Reset.
- Buttons respond to any touch within their rectangle.
- `rb:` sets the background when not pressed; `pb:` sets it while being pressed.

**Example — initial definition:**
```spt
#HMI ButtonEvent2(id:1, x:0px, y:0px, w:160px, h:91px, t:"Zone 0,0", ev:onZone00)
```

**Example — update on press (turn white):**
```spt
onZone00:
    #HMI ButtonEvent2(id:1, x:0px, y:0px, w:160px, h:91px, t:"P:0,0", rb:'FFFFFFFF, ev:onZone00)
    Return
```

---

### DrawImage — display PNG

```spt
#HMI DrawImage(
    id:N,           ; optional: 0–29 for managed image (allows later update)
    x:Xpx,          ; top-left X
    y:Ypx,          ; top-left Y
    i:"file.png",   ; filename in Internal Storage (max 32 chars, .png or .dif)
    z:zindex,       ; optional: z-depth, default 64
    ro:degrees,     ; optional: rotation (positive = anti-clockwise)
    ox:Xpx, oy:Ypx, ; optional: rotation origin
    a:alpha         ; optional: 0=transparent, 128=50%, 255=opaque
)
```

**Key behaviors:**
- Up to 30 images can be active simultaneously (managed objects auto-redrawn when overlapped).
- `#HMI Reset()` clears all images.
- Image files must be manually placed in Internal Storage via MTP — SPLat cannot write files.

**Example:**
```spt
#HMI DrawImage(x:70px, y:35px, i:"white.png")
```

---

### HBar — horizontal bar graph

```spt
#HMI HBar(x:Xpx, y:Ypx, w:Wpx, h:Hpx, v:normalizedValue)
```

Draws a horizontal bar. `v:` ranges 0.0 (empty) to 1.0 (full). Colors from `SetColours()`.

---

## Serial Communication

```spt
IIPrintText portN, 'hexByte      ; send single hex byte to port N
iiPrintText portN, "string"      ; send ASCII string to port N
```

| Port | Function |
|------|----------|
| 0 | HMI display protocol — USB CDC (COM11 on PC). **Do NOT repurpose.** |
| 1 | Secondary UART (physical TX/RX pins on board) |

> **CRITICAL:** Any `Port(N)` or `IIPrintText`/`iiPrintText` call can corrupt the Port 0 HMI display serial timing. Do not call serial instructions from within button event handlers. Only call from a dedicated task with careful timing if at all.

---

## Non-Volatile Memory (NVEM)

```spt
; In NVEM0DATA segment — define storage:
nv_myVar:  NV0Byte    ; 1 byte of non-volatile storage

; In CODESEG — access:
NVSetPage 0           ; select NVEM page 0
NVSetPtr nv_myVar     ; point to variable
; read/write via RAM operations
```

NVEM persists across power cycles. Currently not used in the touch test phase.

---

## File System

The HMI430 exposes its 8 MB internal storage as a USB MTP (Media Transfer Protocol) device — it appears in Windows Explorer like a phone or camera.

### Folder structure

| Folder | Contents |
|--------|----------|
| `Internal Storage/` | User images (`.png`), fonts (`.fon`), screenshot files (`sshot*.png`) |
| `System Firmware/` | Firmware update files (`.srec`) and compiled programs (`.b1n`) |

### Placing assets

Drag and drop `.png` and `.fon` files to "Internal Storage" via Windows Explorer. SPLat cannot write to storage programmatically.

### Screenshot mechanism

1. Connect device via USB
2. Open Windows Explorer → navigate to device → Internal Storage
3. Copy `sshot000.png` to your PC (or use `Shell.Application` from PowerShell)
4. The device firmware captures the current screen and writes it to the file as it transfers
5. The device renames the next screenshot file to `sshot001.png`, then `sshot002.png`, etc.
6. Result: a clean 480×272 pixel PNG of exactly what's on screen

**PowerShell (automated):**
```powershell
$shell = New-Object -ComObject Shell.Application
$device = $shell.NameSpace(17).Items() |
          Where-Object { $_.Name -match 'AegisTec|SPLat|HMI' } | Select-Object -First 1
$storage = $shell.NameSpace($device.Path).Items() |
           Where-Object { $_.Name -match 'Internal Storage' } | Select-Object -First 1
$sshot = $shell.NameSpace($storage.Path).Items() |
         Where-Object { $_.Name -match '^sshot\d+\.png$' } | Select-Object -First 1
$shell.NameSpace("C:\output\").CopyHere($sshot)   # triggers screenshot
```

---

## This Project: HMI430 Touch Test Screen

### Screen layout (`ui_test.spt`)

480×272 display divided into a 3×3 touch zone grid:

```
Col:    0          1          2
     (0–159px)  (160–319px) (320–479px)
Row 0  [Zone 0,0] [Zone 1,0] [Zone 2,0]   y: 0–90px
Row 1  [Zone 0,1] [Zone 1,1] [Zone 2,1]   y: 91–181px
Row 2  [Zone 0,2] [Zone 1,2] [Zone 2,2]   y: 182–271px
```

### CNC coordinate mapping (from `config.spt` — unverified, calibration needed)

```
Col 0: screen px 0–159    → CNC X 107–138
Col 1: screen px 160–319  → CNC X  76–107
Col 2: screen px 320–479  → CNC X  45–76

Row 0: screen py 0–90     → CNC Y -77 to -60
Row 1: screen py 91–181   → CNC Y -60 to -43
Row 2: screen py 182–271  → CNC Y -43 to -26
```

Note: Col 0 maps to **larger** CNC X (right side when standing at machine front). Screen is mounted rotated 180° relative to camera; `RotateFlip(Rotate180FlipNone)` corrects raw captures.

### Booper constraints

- Diameter: 4.5 mm ≈ 22 px at ~4.9 px/mm
- Touch depth (Z): −14 mm (registered), never exceed −16 mm
- Retract between moves: −4 mm (10 mm clearance above touch depth)
- Full retract (XY travel): Z = 0

---

## Known Issues / Gotchas

| Issue | Cause | Workaround |
|-------|-------|------------|
| `Port(N)` corrupts display | Port 0 used by HMI display; any serial call interferes with timing | Avoid all serial output from event handlers |
| OCR returns empty | Windows OCR fails on thresholded camera images (reason unclear) | Use MTP screenshot + brightness detection instead |
| Camera NV12 artifacts | Default video stream is NV12 (YUV 4:2:0); pixelated | Switch to MJPG via `SetMediaStreamPropertiesAsync` |
| Windows OCR 4MP limit | Images >4MP get rescaled, text becomes unreadable | Per-button crop at native res + 4× scale = 2.3MP |
| `ButtonEvent2` 2-byte `YieldTask` | 2-byte instructions not patched by Patch B | Duplicate `YieldTask` lines manually |
| `$variable:` syntax in bash | Bash eats `$` before PowerShell sees it | Always write `.ps1` file, run with `powershell -File` |
| COM port fallback hits HMI | CH340 not found → fallback list grabs COM11 (HMI USB CDC) → GRBL commands sent to HMI display | Never fall back to other ports; require CH340 detection explicitly |
| `calibrate_adaptive.ps1` X runaway | `ApplyMappingCorrection` pushes `xOrigin` unboundedly; zoomed regions near screen x=0 map to CNC X > 160mm | Add bounds checking; clamp xOrigin; or use fixed-position approach instead |
| `calibrate_zones.ps1` 0/30 hits | Script assumes 10×6 checkerboard at 44px pitch but firmware has 6×5 grid at 80px pitch — positions don't match | Always match press positions to the actual flashed firmware layout |

---

## CNC-to-Screen Calibration Progress

### Status: BLOCKED — CNC controller board dead, needs replacement

The GRBL controller board (CH340 USB-serial) failed as of 2026-03-09. It does not enumerate on USB after power cycling. The pendant screen is completely dark. The board needs physical replacement. When a new board is installed, it will need GRBL reflashed and the machine re-homed. GRBL settings to restore: `$3=2` (Y inverted), `$130/$131/$132` for travel limits, G54 offset, startup blocks (`$N0`, `$N1`).

### Confirmed calibration values

| Parameter | Value | Source |
|-----------|-------|--------|
| `xOrigin` | 138.0 | From `config.spt` — NOT yet verified by calibration |
| `xScale` | 93.0 / 479.0 (≈0.1941 mm/px) | From `config.spt` — NOT yet verified |
| `yOrigin` | −81.0 | Confirmed by `find_offset.ps1` scan (−4mm correction from original −77) |
| `yScale` | 51.0 / 271.0 (≈0.1882 mm/px) | From `config.spt` — NOT yet verified |
| Touch Z | −14.0 mm | Confirmed: reliably registers presses |
| Hover Z | −4.0 mm | Safe for inter-button moves within screen area |

### Evidence: `offset_scan.csv`

`find_offset.ps1` pressed a 7×7 grid (±6mm, 2mm steps) around btn17 at screen center (242,154), predicted CNC (91.01, −48.02) using old yOrigin=−77:

- Steps 1–12 (within ±4mm of predicted): brightness 97.8 (no hit)
- Step 13 (dx=0, dy=−4, CNC Y=−52.02): brightness 255 — **first hit**
- Steps 13–49 (≥4mm from center): all brightness 255 (buttons stay white once pressed)
- First hit at dy=−4 confirms yOrigin should be −81 (not −77)

### Current firmware on device: `ui_test.spt`

6×5 grid of 30 buttons (last generated by `calibrate_adaptive.ps1`):

- 6 columns, each 80px wide: left edges at x=0, 80, 160, 240, 320, 400
- 5 rows, heights 54/55/54/55/54: top edges at y=0, 54, 109, 163, 218
- Button centers: x = 40, 120, 200, 280, 360, 440 / y = 27, 81, 136, 190, 245
- All buttons dark grey (`'FF404040`) except btn15 which is medium grey (`'FFA0A0A0`)
- On press: button turns white (`'FFFFFFFF`) and stays white (toggle, not momentary)

### Ready-to-run script: `calibrate_grid.ps1`

Written and tested (build+flash succeeded, but CNC board died before presses). This script:

1. **Pre-flight bounds check** on all 30 CNC positions before any movement
2. Builds and flashes `ui_test.spt` firmware (ensures known state)
3. **No `$H` homing** — assumes machine already at 0,0,0
4. **Requires CH340 explicitly** — will not fall back to other COM ports
5. Moves to first button at full retract (Z=0), then lowers to hover (Z=−4)
6. Takes **baseline screenshot** before first press
7. Presses each of 30 buttons at hover height (Z=−4 between moves within screen area)
8. Takes **per-press MTP screenshot** — detects which new button turned white
9. Reports HIT (correct), WRONG (offset analysis with px/mm error), or MISS
10. Full retract and return home at end

CNC position ranges: X 52.57–130.23 mm, Y −75.92 to −34.89 mm (all within safe limits).

```
powershell -ExecutionPolicy Bypass -File C:/claude/hmi430/calibrate_grid.ps1
```

### Next steps when CNC board is replaced

1. Flash GRBL to new board, restore settings ($3=2, travel limits, startup blocks)
2. Home the machine manually or with `$H`
3. Verify CH340 shows up: `Get-PnpDevice | Where FriendlyName -match 'CH340'`
4. Run `calibrate_grid.ps1` — it will build, flash, press all 30 buttons, report results
5. If all 30 correct: calibration complete, values confirmed
6. If systematic offset: adjust `xOrigin`/`yOrigin` in `calibrate_grid.ps1` and re-run
7. If scale error (offset grows toward edges): adjust `xScale`/`yScale`
