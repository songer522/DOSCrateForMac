# DOSCrate — Controller Support (slice A) Design Spec

- **Date:** 2026-10-27
- **Status:** Draft, awaiting owner review
- **Parent spec:** `2026-10-27-doscrate-design.md`

## 1. Intent

**What the owner decided**

- Goal C: play keyboard-only DOS games with a gamepad using a sensible default map, and later offer real PC-joystick emulation per game. This spec covers **slice A only**: the default keyboard map.
- Approach: a built-in layout table per controller model, chosen at Play from the connected gamepad (option 1 of three; the others were DOSCrate injecting keystrokes itself, or only guiding users to Staging's mapper).
- A global "Use game controllers" switch in Settings, default on.
- Supported controllers: Xbox Series (USB and Bluetooth), PS5 DualSense (USB and Bluetooth), Steam Controller 2026 model (USB and its wireless puck). The Nintendo Switch 2 Pro controller is out of scope: Staging's SDL can't open it on macOS.

**Success criteria**

1. With one supported controller connected and the switch on, pressing Play in any game gives working d-pad, left stick, A/B/X/Y and Start as keyboard keys, with no setup.
2. The keyboard works exactly as before, with or without a controller.
3. With the switch off, or no controller connected, `launch.conf` is byte-for-byte what DOSCrate writes today.
4. A failure anywhere in controller handling never stops a game from launching.

## 2. Engine facts (device probe, 2026-10-27)

Probed with the bundled DOSBox Staging 0.83.0 (SDL 2.32.10) on the owner's Mac, binding keys in Staging's mapper (`--startmapper`; Ctrl+F1 did not reach the app) and reading the saved file.

**Mapper file format.** One line per event: the event name, then each binding as a quoted string.

```
key_up "stick_0 button 11" "key 82"
key_enter "stick_0 axis 5 1" "key 40"
```

- Keyboard bindings are `"key <SDL scancode>"`, optionally followed by `mod1`–`mod3`.
- Controller bindings are `"stick_<n> button <i>"`, `"stick_<n> axis <i> <0|1>"` (0 = negative direction, 1 = positive) or `"stick_<n> hat <i> <v>"`. No controller produced a hat.
- Indices are **raw SDL joystick indices** for that device, not SDL game-controller names. They differ between models and collide (button 11 is d-pad up on Xbox Bluetooth and d-pad down on Steam), so no single map serves all controllers.
- Staging detected every supported controller and named it in its log (`MAPPER: Initialised <name> with N axes, M buttons, and 0 hat(s)`). The Steam Controller works with Steam not running.
- `joysticktype = hidden`: "Prevent DOS from seeing the joystick(s), but enable them for mapping." This keeps DOS games from also seeing a PC joystick while the gamepad sends keys.

**Layouts.** Three layouts cover every supported connection:

| Control | standard | steam | xbox-usb |
|---|---|---|---|
| Used by | Xbox Bluetooth ("Xbox Series X Controller"), DualSense USB and Bluetooth ("DualSense Wireless Controller") | Steam Controller USB ("Steam Controller") and puck ("Steam Controller Puck") | Xbox USB ("Controller") |
| A / Cross | button 0 | button 4 | button 0 |
| B / Circle | button 1 | button 5 | button 1 |
| X / Square | button 2 | button 9 | button 6 |
| Y / Triangle | button 3 | button 10 | button 7 |
| Start / Menu / Options | button 6 | button 7 | button 3 |
| D-pad up / down / left / right | buttons 11 / 12 / 13 / 14 | buttons 14 / 11 / 12 / 13 | buttons 11 / 8 / 9 / 10 |
| Left stick left / right | axis 0 0 / axis 0 1 | axis 0 0 / axis 0 1 | axis 0 0 / axis 0 1 |
| Left stick up / down | axis 1 0 / axis 1 1 | axis 1 1 / axis 1 0 | axis 1 1 / axis 1 0 |
| Left / right trigger | axis 4 1 / axis 5 1 | button 17 / button 24 | button 14 / button 17 |

The vertical stick axis is inverted on the wired Xbox and on the Steam Controller. The 2026-10-28 device test confirmed stick up on all three layouts; steam was fixed from the probed guess after that test. Triggers are unbound in slice A but recorded for slice C.

**HID identity.** `hidutil list` shows the Steam puck as vendor `0x28de`, product `0x1304`, transport USB, product "Steam Controller Puck", with usage page 1 / usage 2 (not the gamepad usage 5). The Switch 2 Pro shows as vendor `0x057e`, product `0x2069`, "Pro Controller", usage 1/5, but Staging logs "No joysticks found". The wired Xbox shows as vendor `0x045e`, product `0x0b12`, transport USB, product "Controller", usage 1/5. Raw probe files and notes are in `controller-probe-2026-10-27/`.

## 3. Default map

| Control | Key |
|---|---|
| D-pad and left stick | arrow keys |
| A | Left Ctrl |
| B | Left Alt |
| X | Space |
| Y | Enter |
| Start | Esc |

Triggers, shoulders, the right stick and other buttons stay unbound.

## 4. Architecture

All new logic lives in `DOSCrateKit` and is pure and unit-tested; the app only detects devices and holds the switch.

**ConfigKit**

- `ControllerLayout`: enum `standard`, `steam`, `xboxUSB`, each with a constant table from logical control (`a`, `b`, `x`, `y`, `start`, `dpadUp`…, `stickLeft`…) to its binding string (`"stick_0 button 11"`).
- `ControllerMap.render(layout:) -> String`: starts from a bundled template and appends each logical control's binding string to the `key_…` line of its key from §3. Output is the full mapper file.
- The template is `controller-template.map`, a ConfigKit resource: the file Staging 0.83.0 saves with no controller bindings (the keyboard part of the probe files). Loading a mapper file replaces Staging's defaults rather than adding to them, so the template must be complete.
- `LaunchConfigBuilder.build` gains `controllerMap: URL?`. When set, it adds, as the **lowest** layer (below global curated settings), `[sdl] mapperfile = <path>` and `[joystick] joysticktype = hidden`. Global raw overrides and a game's `override.conf` can still replace them.

**LauncherKit**

- `GamepadInfo`: vendor ID, product ID, transport, product name, primary usage page and usage.
- `LayoutSelector.select(_ devices: [GamepadInfo]) -> ControllerLayout?`, in order:
  1. Drop devices Staging can't open (Nintendo `0x057e` / `0x2069`).
  2. Valve `0x28de` (any usage) → `steam`.
  3. Microsoft `0x045e` with transport `USB` and a controller usage (page 1, usage 4, 5 or 8) → `xboxUSB` (Bluetooth Xbox falls through to `standard`; Microsoft keyboards and mice are ignored).
  4. Any other device with usage page 1 and usage 4 (joystick), 5 (gamepad) or 8 (multi-axis) → `standard`.
  5. Otherwise `nil`.
  With several candidates, the first in this priority order wins.
- `GlobalConfig` gains `controllerLayout: ControllerLayout?` (nil = off or no controller).
- `LaunchPlanner.plan`: when `controllerLayout` is set, writes `ControllerMap.render` to `<crate>/.cache/controller.map` (atomic, like `launch.conf`) and passes its URL to the builder. If the write fails, it logs and builds without `controllerMap`. `generatedConfigPreview` uses the same layout input, so the Advanced tab shows the lines Play will use.

**App**

- `GamepadDetector`: an IOKit `IOHIDManager` snapshot of connected HID devices, mapped to `[GamepadInfo]`. It is called once per Play; no hot-plug monitoring. On error it returns `[]`.
- `Preferences.useControllers: Bool`, `UserDefaults` key `useControllers`, default `true`.
- `PreferencesView`: a "Use game controllers" toggle with the caption "Maps the d-pad, left stick, A/B/X/Y and Start to keyboard keys."
- `Preferences.globalConfig` sets `controllerLayout` to `LayoutSelector.select(GamepadDetector.snapshot())` when `useControllers` is on, otherwise `nil`.

## 5. Error handling

- HID enumeration fails → no controller lines; launch continues.
- `controller.map` can't be written (read-only or full card) → logged, no controller lines; launch continues.
- No dialog for either case: the game is still playable with the keyboard.

## 6. Known limits (slice A)

- Only one controller is mapped, as `stick_0`. With two controllers connected, the one DOSCrate picks may not be the one Staging numbers 0.
- Saving in Staging's mapper during a game writes to `.cache/controller.map`, which is overwritten at the next Play. Per-game customisation comes with the Controller tab.
- No PC-joystick emulation (slice C) and no per-game Controller tab.
- Unknown controllers get the standard layout, which may be wrong for them.
- Controllers connected after Play are ignored until the next Play.

## 7. Testing

**Simulator (unit tests)**

- `LayoutSelector`: each probed device → its layout; the Switch 2 Pro dropped; unknown gamepad → `standard`; non-gamepad device → `nil`; priority with several devices.
- `ControllerMap.render`: each layout's binding strings land on the right `key_…` lines; every template line not touched is unchanged; output parses as one event per line.
- `LaunchConfigBuilder`: with `controllerMap`, `launch.conf` has `mapperfile` and `joysticktype = hidden`; global raw `joysticktype = auto` overrides it; without it, output is identical to today's.
- `LaunchPlanner`: writes `controller.map` next to `launch.conf`; a write failure still produces a plan without controller lines.
- `Preferences`: `useControllers` defaults to true and persists.

**Device test** on the Mac, with the switch on, one controller at a time, for each of Xbox USB, Xbox Bluetooth, DualSense USB, DualSense Bluetooth and Steam puck:

1. Left stick up and down move in the right direction (verifies the to-verify rows of §2).
2. D-pad, stick left/right, A/B/X/Y and Start send the keys in §3, checked in a keyboard game from the library.
3. The keyboard still works alongside.

Plus: one launch of a game from `/Volumes/MicroSD 1TB/dos` (a `mapperfile` path with a space); one launch with the switch off (no controller); one launch with the Switch 2 Pro and an Xbox both connected (the Xbox is mapped).
