# HMI430 GUI Redesign — Design Spec

## Overview

Redesign of the AegisTec+ greenhouse controller GUI running on the HMI430 (480x272px resistive touchscreen). Goals: modern look and feel with high contrast for sunlight readability, improved usability for gloved operators, and a clean architecture that supports future feature additions (schedules, theme switching).

## Architecture

Static PNG backgrounds handle all visual polish (drop shadows, gradients, rounded corners, panel dividers). Dynamic elements are layered on top: text overlays via `#HMI Print()`, rotated/swapped images via `#HMI DrawImage()`, and invisible touch zones via `#HMI ButtonEvent2()`.

### Screen Lifecycle

Each screen transition is managed by the framework (`uiframework.spt`). When `UIsNewScreen` is set, the framework calls `UIsubReset` (which calls `#HMI Reset()` to clear all buttons, images, and text) before branching to the new screen's entry point. Screens never need to call `Reset()` themselves — the framework handles it.

Button and image IDs are **per-screen**. Since `Reset()` clears all managed objects on screen change, IDs 0-29 are available fresh on each screen.

### Initialization

On power-on, register the connect event handler and check touchscreen calibration:

```spt
#HMI ConnectEvent( UIsubConnectEvent )
```

`UIsubConnectEvent` handles backlight state changes (return to main screen on wake) and power-on touch calibration. Based on `ui_utils.spt` from the SPLat examples.

### Button State Model

All `ButtonEvent2` callbacks fire on any press event. The handler calls `UIsubGetButton` to read the press state from the X register:

| State | Value | Meaning |
|-------|-------|---------|
| `UIkBTNShortRelease` | 0 | Finger lifted after short press |
| `UIkBTNPressed` | 1 | Finger just touched |
| `UIkBtnLongRelease` | 2 | Finger lifted after long hold |
| `UIkBtnHeld` | 3 | Finger still held (repeats) |

Standard pattern for navigation buttons (short press only):
```spt
_evConfig:
   GoSub      UIsubGetButton
   GoIfXne    UIkBTNShortRelease,Return
   LoadX      UIkScreenConfig
   Goto       UIsubSetScreen
```

For the weather panel (long press only):
```spt
_evWeather:
   GoSub      UIsubGetButton
   GoIfXne    UIkBtnLongRelease,Return
   LoadX      UIkScreenWeatherSetup
   Goto       UIsubSetScreen
```

### Cooperative Multitasking

SPLat is cooperatively scheduled. Long chains of HMI draw calls can starve other tasks. Add `YieldTask` / `YieldTask` pairs (duplicated for 2-byte alignment) between groups of update subroutines in the main loop.

### Rendering Layers (per screen)

| Layer | Z-depth | Content | Updates |
|-------|---------|---------|---------|
| Background | 0 | Full-screen PNG with all static visual elements | Load once per screen |
| Equipment icons | 1 | Individual PNGs per hardware slot, swapped on state change | On state change |
| Override borders | 2 | Orange outline PNGs overlaid on equipment in manual override | Show/hide on state change |
| Gauge needle | 3 | 40x120px needle PNG, rotated via `ro:f(*fAngle)` | On temperature change |
| Dynamic text | — | `SetBounds` / `Cls()` / `Print()` for numeric values | On value change |
| Touch zones | — | Invisible `ButtonEvent2` regions | Load once per screen |

### Text Update Pattern

Following SPLat's official example (`ui_home.spt`):

```spt
GoSub          UIsubDrawDefaults
#HMI           SetBounds( x:45px, y:52px, w:75px, h:30px )
#HMI           Cls()
#HMI           Print( "62\xB0""F" )
#HMI           SetBounds()
```

Each text region must sit over a solid-color area in the background PNG so `Cls()` cleanly erases it with the current background color.

**Color constants** (exact values tuned to match background PNG):
```spt
HUEkPanelBg       #EQU  'FFF5F5F5    ; weather/hardware panel background (light theme)
HUEkCenterBg      #EQU  'FFFFFFFF    ; center gauge area background
HUEkHeaderBg      #EQU  'FFE8E8E8    ; top bar background
HUEkAlertBg       #EQU  'FFE04040    ; alert banner background
HUEkBottomBarBg   #EQU  'FFDDDDDD    ; bottom bar background
```

`UIsubDrawDefaults` sets: font = `propnormal.fon`, foreground = `HUEkBlack`, background = `HUEkTransparent`, bounds = full screen.

### Gauge Needle Rotation

Following `gauge.spt`:

```spt
; Initial placement with pivot point
#HMI DrawImage( id:0, x:240px, y:155px, i:"needle_40x120.png", z:3, ox:20, oy:100 )

; Update — rotate in-place on same id (no flicker)
#HMI DrawImage( id:0, i:"needle_40x120.png", ro:f(*fNeedleAngle) )
```

**Gauge parameters:**
- Range: 0°F to 120°F
- Arc span: ~257 degrees (matching SPLat gauge example)
- Start angle: 0° (needle pointing left at 0°F)
- End angle: -257° (needle pointing right at 120°F)

**Angle calculation in SPLat float instructions:**
```spt
fRecallW    fTemperature          ; load current temp (e.g. 78.0)
fLoadQ      120.0                 ; max temp on gauge
fDiv                              ; normalize to 0.0-1.0
fLoadQ      -257.0                ; arc span in degrees
fMul                              ; convert to angle
fStore      fNeedleAngle          ; save for DrawImage ro:
```

Pivot point (`ox:`, `oy:`) tuned on-device. For the 40x120 needle, `ox:20` is horizontal center; `oy:` is set to the rotation axis (fat end of needle).

### Hardware Icon State Swapping

Each equipment slot has a fixed `DrawImage` id. State changes swap the image file:

```spt
#HMI DrawImage( id:1, i:"left_vent_opening.png" )    ; state changed
#HMI DrawImage( id:8, i:"override_border.png" )       ; show override
#HMI DrawImage( id:8, i:"override_clear.png" )        ; hide (same size, fully transparent)
```

## Screen Framework

Based on SPLat's `ui_framework` example. `BranchM` + `Target` table dispatches screens by ID. `UIsubSetScreen` handles navigation with a 3-deep back stack.

### Screen Map

| ID | Screen | Entry |
|----|--------|-------|
| 0 | Main (home) | Default on boot, back target |
| 1 | Hardware override | Main → hardware panel tap |
| 2 | Temp range setup | Main → gauge tap |
| 3 | Weather station setup | Main → weather panel long press |
| 4 | Config | Main → Config button |
| 5 | Alerts | Main → alert banner tap |
| 6 | Settings | Main → Settings button |
| 7 | Schedules | TBD (from Config or Settings) |

### Screen Loop Pattern

Every screen follows the same structure:

```spt
UIscreenXxx:
   ; declare buttons (ButtonEvent2)
   ; draw background (DrawImage)
   ; draw initial dynamic elements
_XxxLoop:
   Pause      10
   GoIfST     UIsNewScreen,UIDoNewScreen
   ; update dynamic values (only on change)
   Goto       _XxxLoop
```

## Main Screen Layout

### Touch Zones (7 buttons)

| ID | Region | Bounds (approx) | Action |
|----|--------|-----------------|--------|
| 0 | Zone name | 140,0 → 340,28 | Short press → switch zone |
| 1 | Weather panel | 0,28 → 120,238 | Long press → weather setup |
| 2 | Center gauge | 120,28 → 360,238 | Short press → temp range setup |
| 3 | Hardware panel | 360,28 → 480,238 | Short press → hardware override |
| 4 | Config button | 0,238 → 80,272 | Short press → config screen |
| 5 | Alert banner | 80,238 → 400,272 | Short press → alerts screen |
| 6 | Settings button | 400,238 → 480,272 | Short press → settings screen |

### Dynamic Text Regions

| Region | Approx bounds | Font | Bg color |
|--------|--------------|------|----------|
| Weather temp | 45,52 → 120,82 | propbold35 | Panel bg |
| Weather humidity | 45,85 → 120,110 | propbold35 | Panel bg |
| Weather wind | 45,118 → 120,143 | prop20 | Panel bg |
| Weather rain | 45,148 → 120,170 | prop20 | Panel bg |
| Gauge temp readout | 185,180 → 295,215 | propbold70 | Center bg |
| Gauge RH readout | 200,218 → 280,240 | prop25 | Center bg |
| Alert text | 95,252 → 385,270 | prop20 | Alert red |
| Zone name | 160,4 → 320,24 | propbold35 | Header bg |

### Managed Images (main screen)

| ID | Purpose |
|----|---------|
| 0 | Gauge needle (rotated) |
| 1 | Left vent icon |
| 2 | Roof vent icon |
| 3 | Right curtain icon |
| 4 | Shade/LDEP curtain icon |
| 5 | Cooling fan icon |
| 6 | HAF fan icon |
| 7 | Heater icon |
| 8+ | Override border overlays |

~10 managed images, well within the 30 limit.

### Main Screen Update Loop

```spt
UIscreenMain:
   #HMI    DrawImage( x:0px, y:0px, i:"main_bg.png", z:0 )
   ; ... hardware icons id:1-7 ...
   ; ... ButtonEvent2 id:0-6 ...
   ; ... initial text + gauge ...

_MainLoop:
   Pause      10
   GoIfST     UIsNewScreen,UIDoNewScreen
   GoSub      _MainUpdateTemp
   GoSub      _MainUpdateHumidity
   GoSub      _MainUpdateWind
   GoSub      _MainUpdateRain
   YieldTask
   YieldTask
   GoSub      _MainUpdateGauge
   GoSub      _MainUpdateHardware
   GoSub      _MainUpdateAlert
   Goto       _MainLoop
```

Only redraw values that changed (compare stored vs new). Gauge needle rotation is a single `DrawImage` call. Hardware icons swap only on state transitions.

## Image Assets

### Existing (in `C:\Users\nathan\Pictures\UI concepts\HMI430 backgrounds and icons\`)

- `New HMI430 Test Screen 1.png` — main screen background (needs bottom bar + hardware grid completion)
- `needle_40x120.png` — gauge needle
- `AdvanSync Logo for 4.3 inch touchscreen.png` — logo (baked into background)
- Weather icons: `Temp Icon.png`, `Humidity Icon.png`, `Wind Speed Icon.png`, `Rain Icon.png`
- Connectivity: `WiFi Bars.png`, `Radio Bars.png`
- Curtain set: left curtain (open/closing/closed/opening), roof vent (open/closing/closed/opening), right curtain set
- Fans/heaters: `Cooling On Icon.png`, `HAF On Icon.png`, `HAF Off Icon.png`, `Heat On Icon.png`, `LDEP Icon.png`
- Small icons: `Roof Vent Icon 30x30.png`, `Right Curtain Icon 30x30.png`

### Still Needed

- Left vent icon set (open/closing/closed/opening)
- Shade curtain icon (distinct from LDEP)
- Override border overlay (orange 34x34 outline, transparent center)
- Completed main screen background with bottom bar (Config, alert, Settings) and hardware grid area
- Dark theme background variant
- `override_clear.png` — 34x34 fully transparent PNG (same dimensions as override border, for hiding it)
- Gauge face as separate PNG if not baked into background

### Tools

Assets created in Paint.NET (.pdn source files alongside exported PNGs).

## Constraints

| Constraint | Value |
|-----------|-------|
| Screen resolution | 480x272 px |
| Max managed buttons per screen | 30 (IDs 0-29) |
| Max managed images per screen | 30 |
| Touch type | Resistive (glove-friendly, large targets) |
| Fonts available | prop20-210, propbold35/70, mono35-120, ledseg35, times 20-75 |
| Color format | `'AARRGGBB` hex literal |
| Port 0 | HMI display serial — DO NOT use from event handlers |
| YieldTask | Must duplicate for 2-byte alignment (Patch A handles in `__HMI_event_task`) |
| Compiler bugs | Patches A, B, C applied automatically by `splat_build.js` |

## Build & Test Cycle

1. Edit `.spt` source files
2. Compile: `node splat_build.js _build.b1d` → `_build.b1n`
3. Flash: `MtpCopy.exe _build.b1n` (HMI must be powered on)
4. Wait for reboot (~5s)
5. Test with booper: press touch zones, capture MTP screenshots, verify screen state
6. Iterate

## Implementation Order

1. **Main screen static** — background PNG + touch zones + text regions with hardcoded values
2. **Dynamic text** — wire up `Cls()`/`Print()` update loop with simulated sensor values
3. **Gauge rotation** — needle angle math + `DrawImage(ro:)` updates
4. **Hardware icons** — state-driven image swapping
5. **Navigation** — wire touch zones to stub sub-screens (colored rectangles with back buttons)
6. **Sub-screens** — build out one at a time (hardware override first, then config, settings, etc.)
7. **Theme switching** — dark theme background + color constants swap
8. **Schedules** — new feature screen, linked to temp ranges and curtain deployments

## Sub-Screen Sketches

Detailed layouts will be designed when each screen is implemented. Estimates for resource usage:

### Screen 1: Hardware Override
Full-screen view of all equipment with toggle controls. Each equipment item shows current state (icon + label) and has an Auto/Manual toggle button.
- **Buttons**: ~12 (back button + auto/manual toggle per equipment slot + possible timeout selector)
- **Images**: ~8 (state icons for each equipment)
- **Key interaction**: Tap a toggle to switch between Auto and Manual Override. Manual override should show a timeout countdown.

### Screen 2: Temp Range Setup
Setpoint entry for day/night temperature ranges. The gauge face shows the current temp with adjustable low/high markers.
- **Buttons**: ~8 (back, day/night toggle, +/- for low setpoint, +/- for high setpoint, save)
- **Images**: ~2 (gauge face + needle)
- **Key interaction**: +/- buttons adjust setpoints. Changes saved to NV memory on confirm.

### Screen 3: Weather Station Setup
Configure weather station input sources and calibration offsets.
- **Buttons**: ~6 (back, input source selector, calibration +/-, save)
- **Images**: ~1 (background)

### Screen 4: Config
System configuration — zone names, equipment assignment, schedule links.
- **Buttons**: ~10 (back, menu items for sub-categories)
- **Images**: ~1 (background)

### Screen 5: Alerts
Alert history list with timestamps. Scrollable if more than fit on screen.
- **Buttons**: ~4 (back, scroll up/down, clear alerts)
- **Images**: ~1 (background)

### Screen 6: Settings
Display settings (brightness, theme), network, date/time.
- **Buttons**: ~8 (back, brightness +/-, theme toggle, date/time entry, network)
- **Images**: ~1 (background)

### Screen 7: Schedules
Time-based rules linked to temperature ranges and curtain deployments. Future feature — designed when other screens are complete.
- **Buttons**: ~10-15 estimated
- **Images**: ~1 (background)

All screens are well within the 30-button and 30-image limits.

## Planned Source Files

Build descriptor (`_build.b1d`) file order:

```
config.spt          ; hardware constants, color constants, font aliases
permmem.spt         ; permanent memory (flash) variable absolutes
variables.spt       ; byte/float/semaphore definitions
launch.spt          ; power-on, init, launch tasks
helpers.spt         ; shared utility subroutines
ui_utils.spt        ; button state helpers (UIsubGetButton, UIsubConnectEvent)
ui_common.spt       ; colors, fonts, reset, defaults
uiframework.spt     ; screen switcher (BranchM/Target, UIsubSetScreen)
ui.spt              ; screen ID constants, branch table
ui_main.spt         ; main screen (home)
ui_hardware.spt     ; hardware override screen
ui_temp_range.spt   ; temperature range setup
ui_weather.spt      ; weather station setup
ui_config.spt       ; config screen
ui_alerts.spt       ; alerts screen
ui_settings.spt     ; settings screen
ui_schedules.spt    ; schedules (future)
outputs.spt         ; output relay control
temperature.spt     ; temperature sensor reading
wind.spt            ; wind speed sensor
fans.spt            ; fan control logic
heaters.spt         ; heater control
curtains.spt        ; curtain/vent control
nvem_defaults.spt   ; non-volatile memory defaults
serial.spt          ; serial port output
gateway_comms.spt   ; gateway/network communications
```

## Future Considerations

- Light/dark theme switching based on ambient light or time of day
- Schedule system linking time ranges to temperature setpoints and curtain deployments
- Second zone support (zone switch via title bar tap)
