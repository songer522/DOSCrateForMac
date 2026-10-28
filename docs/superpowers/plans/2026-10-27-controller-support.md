# Controller Support (slice A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A connected gamepad sends keyboard keys in every game through a generated Staging mapper file, chosen per controller model, behind a Settings switch.

**Architecture:** Pure logic in `DOSCrateKit`: `ControllerLayout` and `ControllerMap` (ConfigKit) turn a layout into a full mapper file; `LayoutSelector` (LauncherKit) picks the layout from HID device info; `LaunchPlanner` writes `.cache/controller.map` and `LaunchConfigBuilder` adds `mapperfile` and `joysticktype = hidden` as the lowest layer. The app reads HID devices through IOKit at Play and holds the switch.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing, IOKit `IOHIDManager`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-27-controller-support-design.md` (probe evidence in `docs/superpowers/specs/controller-probe-2026-10-27/`).

## Global Constraints

- macOS 15+, arm64, Swift 6 language mode; package tests build with `-warnings-as-errors`.
- Gate per task: `make generate test` exits 0; `grep -c warning: build/test.log build/swift-test.log` both 0; `git diff --check` clean. Run suites one at a time.
- With the switch off or no supported controller, `launch.conf` is byte-for-byte what DOSCrate writes today.
- A controller failure never blocks Play and never shows a dialog.
- Default map (spec §3): d-pad and left stick → arrows, A → Left Ctrl, B → Left Alt, X → Space, Y → Enter, Start → Esc. Nothing else bound.
- Settings copy, exactly: toggle "Use game controllers", caption "Maps the d-pad, left stick, A/B/X/Y and Start to keyboard keys."
- Commit only on `songer522/controller-support`.

## Review Focus

1. Library path with a space (`/Volumes/MicroSD 1TB/dos`): `mapperfile` must be written unquoted and whole. Test in Task 2.
2. A user's own `mapperfile` or `joysticktype` in global raw overrides must win over ours. Test in Task 2.
3. `.cache/` missing or not writable at Play: launch still succeeds without controller lines. Test in Task 4.
4. Steam puck reports usage 1/2 (mouse), not gamepad, and must still select `steam`; a plain mouse or keyboard must select nothing. Test in Task 3.
5. Switch 2 Pro plus a supported controller: the supported one is chosen. Test in Task 3.

---

### Task 1: Layouts and mapper file rendering

**Files:**
- Create: `Packages/DOSCrateKit/Sources/ConfigKit/ControllerLayout.swift`
- Create: `Packages/DOSCrateKit/Sources/ConfigKit/ControllerMap.swift`
- Create: `Packages/DOSCrateKit/Sources/ConfigKit/ControllerTemplate.swift`
- Test: `Packages/DOSCrateKit/Tests/ConfigKitTests/ControllerMapTests.swift`

**Interfaces:**
- Produces:
  - `public enum ControllerLayout: String, Sendable, CaseIterable { case standard, steam, xboxUSB }`
  - `public enum LogicalControl: Sendable, CaseIterable { case a, b, x, y, start, dpadUp, dpadDown, dpadLeft, dpadRight, stickUp, stickDown, stickLeft, stickRight }`
  - `extension ControllerLayout { public func binding(_ c: LogicalControl) -> String }` returning e.g. `"stick_0 button 11"` (no surrounding quotes)
  - `public enum ControllerMap { public static func render(_ layout: ControllerLayout) -> String }`

- [ ] **Step 1: Write the failing tests** (`@testable import ConfigKit`, since `ControllerTemplate` is internal)

```swift
@Suite struct ControllerMapTests {
    @Test func standardBindings() {
        let l = ControllerLayout.standard
        #expect(l.binding(.a) == "stick_0 button 0"); #expect(l.binding(.start) == "stick_0 button 6")
        #expect(l.binding(.dpadDown) == "stick_0 button 12"); #expect(l.binding(.stickUp) == "stick_0 axis 1 0")
    }
    @Test func steamBindings() {
        let l = ControllerLayout.steam
        #expect(l.binding(.a) == "stick_0 button 4"); #expect(l.binding(.x) == "stick_0 button 9")
        #expect(l.binding(.y) == "stick_0 button 10"); #expect(l.binding(.start) == "stick_0 button 7")
        #expect(l.binding(.dpadUp) == "stick_0 button 14"); #expect(l.binding(.dpadDown) == "stick_0 button 11")
    }
    @Test func xboxUSBBindings() {
        let l = ControllerLayout.xboxUSB
        #expect(l.binding(.x) == "stick_0 button 6"); #expect(l.binding(.start) == "stick_0 button 3")
        #expect(l.binding(.dpadDown) == "stick_0 button 8")
        #expect(l.binding(.stickUp) == "stick_0 axis 1 1"); #expect(l.binding(.stickDown) == "stick_0 axis 1 0")
    }
    @Test func renderAppendsToKeyLines() {
        let lines = ControllerMap.render(.standard).split(separator: "\n").map(String.init)
        let up = lines.first { $0.hasPrefix("key_up ") }!
        #expect(up.contains("\"key 82\"") && up.contains("\"stick_0 button 11\"") && up.contains("\"stick_0 axis 1 0\""))
        #expect(lines.first { $0.hasPrefix("key_lctrl ") }!.contains("\"stick_0 button 0\""))
        #expect(lines.first { $0.hasPrefix("key_lalt ") }!.contains("\"stick_0 button 1\""))
        #expect(lines.first { $0.hasPrefix("key_esc ") }!.contains("\"stick_0 button 6\""))
    }
    @Test(arguments: ControllerLayout.allCases) func untouchedLinesUnchanged(_ l: ControllerLayout) {
        let touched: Set = ["key_up", "key_down", "key_left", "key_right", "key_lctrl", "key_lalt", "key_space", "key_enter", "key_esc"]
        let tpl = ControllerTemplate.text.split(separator: "\n", omittingEmptySubsequences: false)
        let out = ControllerMap.render(l).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(tpl.count == out.count)
        for (t, o) in zip(tpl, out) where !touched.contains(String(t.split(separator: " ").first ?? "")) { #expect(t == o) }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/DOSCrateKit --filter ControllerMapTests`
Expected: FAIL, `ControllerLayout` not found.

- [ ] **Step 3: Add `ControllerTemplate.text`**

`enum ControllerTemplate { static let text: String }` (internal), a raw multi-line string literal whose content is the output of:

```bash
sed -E '/^key_/ s/ "stick_0 [^"]*"//g' docs/superpowers/specs/controller-probe-2026-10-27/probe-dualsense.map
```

Keep trailing spaces exactly as Staging writes them. Add a header comment naming the source file and Staging 0.83.0.

- [ ] **Step 4: Implement `ControllerLayout.binding(_:)` and `ControllerMap.render(_:)`**

Tables from spec §2. Key for each control: a → `key_lctrl`, b → `key_lalt`, x → `key_space`, y → `key_enter`, start → `key_esc`, dpad/stick up/down/left/right → `key_up`/`key_down`/`key_left`/`key_right`. `render` appends ` "<binding>"` to the matching line (after the existing bindings, before the trailing space) for every `LogicalControl`; all other lines are untouched.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path Packages/DOSCrateKit --filter ControllerMapTests`
Expected: PASS.

- [ ] **Step 6: Commit** — `feat: controller layouts and mapper file rendering`

---

### Task 2: Controller lines in the launch config

**Files:**
- Modify: `Packages/DOSCrateKit/Sources/ConfigKit/LaunchConfigBuilder.swift`
- Test: `Packages/DOSCrateKit/Tests/ConfigKitTests/LaunchConfigBuilderControllerTests.swift`

**Interfaces:**
- Consumes: `ControllerLayout` (Task 1).
- Produces:
  - `GlobalConfig.controllerLayout: ControllerLayout?` (default `nil`, new trailing init parameter `controllerLayout: ControllerLayout? = nil`)
  - `LaunchConfigBuilder.build(game:cDrive:media:global:controllerMap: URL? = nil)`

- [ ] **Step 1: Write the failing tests** (use the existing ConfigKit test fixtures for `game`/`cDrive`)

```swift
@Test func controllerLinesAdded() throws {
    let map = URL(filePath: "/Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map")
    let doc = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: GlobalConfig(), controllerMap: map)
    #expect(doc.value("sdl", "mapperfile") == "/Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map")
    #expect(doc.value("joystick", "joysticktype") == "hidden")
    #expect(doc.render().contains("mapperfile = /Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map\n"))
}
@Test func rawOverridesWin() throws {
    let g = GlobalConfig(rawOverrides: "[joystick]\njoysticktype = auto\n[sdl]\nmapperfile = mine.map\n")
    let doc = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: g, controllerMap: URL(filePath: "/x/controller.map"))
    #expect(doc.value("joystick", "joysticktype") == "auto"); #expect(doc.value("sdl", "mapperfile") == "mine.map")
}
@Test func noControllerMapUnchanged() throws {
    let a = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: GlobalConfig())
    #expect(!a.render().contains("mapperfile")); #expect(!a.render().contains("joysticktype"))
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/DOSCrateKit --filter LaunchConfigBuilderControllerTests`; expected FAIL (extra argument `controllerMap`).

- [ ] **Step 3: Implement.** In `build`, when `controllerMap` is non-nil, start from a `ConfigDocument` with `set("sdl", "mapperfile", controllerMap.path)` and `set("joystick", "joysticktype", "hidden")`, then merge the existing layers on top in their current order. Update the doc comment's layer list. Add `controllerLayout` to `GlobalConfig`.

- [ ] **Step 4: Run to verify pass**, then the whole ConfigKit suite (`--filter ConfigKitTests`): all PASS, existing tests untouched.

- [ ] **Step 5: Commit** — `feat: add controller mapper lines as the lowest config layer`

---

### Task 3: Layout selection from HID devices

**Files:**
- Create: `Packages/DOSCrateKit/Sources/LauncherKit/LayoutSelector.swift`
- Test: `Packages/DOSCrateKit/Tests/LauncherKitTests/LayoutSelectorTests.swift`

**Interfaces:**
- Consumes: `ControllerLayout` (Task 1).
- Produces:
  - `public struct GamepadInfo: Equatable, Sendable { public var vendorID: Int; public var productID: Int; public var transport: String; public var product: String; public var usagePage: Int; public var usage: Int; public init(...) }` (memberwise public init, all parameters)
  - `public enum LayoutSelector { public static func select(_ devices: [GamepadInfo]) -> ControllerLayout? }`

- [ ] **Step 1: Write the failing tests** (values from spec §2; the Xbox Bluetooth, DualSense, mouse and keyboard product IDs are illustrative)

```swift
let xboxUSB = GamepadInfo(vendorID: 0x045e, productID: 0x0b12, transport: "USB", product: "Controller", usagePage: 1, usage: 5)
let xboxBT = GamepadInfo(vendorID: 0x045e, productID: 0x0b13, transport: "Bluetooth", product: "Xbox Wireless Controller", usagePage: 1, usage: 5)
let dualSense = GamepadInfo(vendorID: 0x054c, productID: 0x0ce6, transport: "Bluetooth", product: "DualSense Wireless Controller", usagePage: 1, usage: 5)
let puck = GamepadInfo(vendorID: 0x28de, productID: 0x1304, transport: "USB", product: "Steam Controller Puck", usagePage: 1, usage: 2)
let switch2 = GamepadInfo(vendorID: 0x057e, productID: 0x2069, transport: "USB", product: "Pro Controller", usagePage: 1, usage: 5)
let mouse = GamepadInfo(vendorID: 0x05ac, productID: 0x0269, transport: "USB", product: "Magic Mouse", usagePage: 1, usage: 2)
let keyboard = GamepadInfo(vendorID: 0x05ac, productID: 0x0342, transport: "SPI", product: "Apple Internal Keyboard", usagePage: 1, usage: 6)

@Test func picksLayouts() {
    #expect(LayoutSelector.select([xboxUSB]) == .xboxUSB)
    #expect(LayoutSelector.select([xboxBT]) == .standard)
    #expect(LayoutSelector.select([dualSense]) == .standard)
    #expect(LayoutSelector.select([puck]) == .steam)
}
@Test func ignoresUnusable() {
    #expect(LayoutSelector.select([switch2]) == nil)
    #expect(LayoutSelector.select([mouse, keyboard]) == nil)
    #expect(LayoutSelector.select([]) == nil)
}
@Test func switch2WithXbox() { #expect(LayoutSelector.select([switch2, xboxBT]) == .standard) }
@Test func priority() {
    #expect(LayoutSelector.select([dualSense, puck]) == .steam)
    #expect(LayoutSelector.select([dualSense, xboxUSB]) == .xboxUSB)
}
@Test func joystickAndMultiAxisAreStandard() {
    var j = dualSense; j.vendorID = 0x1234; j.usage = 4; #expect(LayoutSelector.select([j]) == .standard)
    j.usage = 8; #expect(LayoutSelector.select([j]) == .standard)
}
```

- [ ] **Step 2: Run to verify failure** — `--filter LayoutSelectorTests`; expected FAIL.

- [ ] **Step 3: Implement `select`** with the order from spec §4: drop `0x057e`/`0x2069`; any `0x28de` → `.steam`; `0x045e` with transport `"USB"` → `.xboxUSB`; usage page 1 with usage 4, 5 or 8 → `.standard`; else `nil`. The priority is by rule, not by device order.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `feat: pick controller layout from HID devices`

---

### Task 4: LaunchPlanner writes controller.map

**Files:**
- Modify: `Packages/DOSCrateKit/Sources/LauncherKit/LaunchPlanner.swift`
- Test: `Packages/DOSCrateKit/Tests/LauncherKitTests/LaunchPlannerTests.swift` (add tests; reuse `Fixture`)

**Interfaces:**
- Consumes: `GlobalConfig.controllerLayout`, `ControllerMap.render`, `build(..., controllerMap:)`.
- Produces: unchanged `plan(...)` and `generatedConfigPreview(...)` signatures; file `<crate>/.cache/controller.map`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func writesControllerMap() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.touch("GAME.EXE"); let r = f.record(executable: "GAME.EXE", exitWhenDone: false)
    let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
    _ = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(controllerLayout: .steam), dosbox: f.dosbox, io: f.io)
    let map = f.crate.appending(path: ".cache/controller.map")
    #expect(try String(contentsOf: map, encoding: .utf8) == ControllerMap.render(.steam))
    let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
    #expect(conf.contains("mapperfile = \(map.path)\n")); #expect(conf.contains("joysticktype = hidden\n"))
}
@Test func noLayoutNoMap() throws {
    // same setup with GlobalConfig(): no .cache/controller.map exists; launch.conf has no "mapperfile" or "joysticktype"
}
@Test func unwritableMapStillLaunches() throws {
    // same setup with .steam, but first create a directory at .cache/controller.map so the write fails;
    // plan succeeds and launch.conf contains no "mapperfile"
}
@Test func previewShowsControllerLines() throws {
    // generatedConfigPreview with GlobalConfig(controllerLayout: .standard) contains "joysticktype = hidden"
    // and does not create controller.map
}
```

Write the three commented tests fully in the file's existing style.

- [ ] **Step 2: Run to verify failure** — `--filter LaunchPlannerTests`; expected FAIL.

- [ ] **Step 3: Implement.** `render` gains `controllerMap: URL?` and passes it through. In `plan`, after the logs directory exists: if `global.controllerLayout` is set, write `ControllerMap.render(layout)` atomically to `io.cacheURL(crate)/controller.map`; on success pass that URL, on any thrown error pass `nil` (no rethrow). `generatedConfigPreview` passes the same URL when the layout is set, without writing.

- [ ] **Step 4: Run to verify pass**, then the full package suite: all PASS.

- [ ] **Step 5: Commit** — `feat: write controller.map at launch`

---

### Task 5: App detection, Settings switch and wiring

**Files:**
- Create: `App/GamepadDetector.swift`
- Modify: `App/Preferences.swift` (key, property, init)
- Modify: `App/Views/PreferencesView.swift` (General form)
- Modify: `App/AppModel.swift:249` (Play) and `App/Views/AdvancedTab.swift:60` (preview)
- Test: `AppTests/SettingsBindingTests.swift` (add)

**Interfaces:**
- Consumes: `GamepadInfo`, `LayoutSelector.select`, `GlobalConfig.controllerLayout`.
- Produces:
  - `enum GamepadDetector { static func snapshot() -> [GamepadInfo] }`
  - `Preferences.useControllers: Bool` (key `useControllers`, default `true`)
  - `Preferences.launchConfig(gamepads: [GamepadInfo]) -> GlobalConfig`: `globalConfig` with `controllerLayout = useControllers ? LayoutSelector.select(gamepads) : nil`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func useControllersDefaultsOnAndPersists() {
    let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
    let p = Preferences(defaults: d); #expect(p.useControllers)
    p.useControllers = false; #expect(!Preferences(defaults: d).useControllers)
}
@Test func launchConfigRespectsSwitch() {
    let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
    let p = Preferences(defaults: d)
    let pad = GamepadInfo(vendorID: 0x054c, productID: 0x0ce6, transport: "USB", product: "DualSense Wireless Controller", usagePage: 1, usage: 5)
    #expect(p.launchConfig(gamepads: [pad]).controllerLayout == .standard)
    p.useControllers = false; #expect(p.launchConfig(gamepads: [pad]).controllerLayout == nil)
}
```

- [ ] **Step 2: Run to verify failure** — `make generate test`; expected FAIL in AppTests.

- [ ] **Step 3: Implement `Preferences.useControllers` and `launchConfig(gamepads:)`.**

- [ ] **Step 4: Implement `GamepadDetector.snapshot()`.** `IOHIDManagerCreate`, `IOHIDManagerSetDeviceMatching(manager, nil)`, `IOHIDManagerCopyDevices`; for each device read `kIOHIDVendorIDKey`, `kIOHIDProductIDKey`, `kIOHIDTransportKey`, `kIOHIDProductKey`, `kIOHIDPrimaryUsagePageKey`, `kIOHIDPrimaryUsageKey` (missing → 0 or ""). No `IOHIDManagerOpen`, no run-loop scheduling. Any failure returns `[]`. The app is not sandboxed (`App/DOSCrate.entitlements` is empty), so no entitlement is needed.

- [ ] **Step 5: Wire it.** Play (`AppModel.swift:249`) and the Advanced preview use `prefs.launchConfig(gamepads: GamepadDetector.snapshot())` instead of `prefs.globalConfig`. Add the toggle with the exact copy from Global Constraints to the General form in `PreferencesView`.

- [ ] **Step 6: Run the gate** — `make generate test` rc 0, zero warnings, `git diff --check` clean.

- [ ] **Step 7: Commit** — `feat: detect gamepads at Play and add the controllers switch`

---

### Task 6: Device test and docs (owner and coordinator)

**Files:**
- Modify: `docs/manual-test-checklist.md` (new "Controllers" section)
- Modify: `docs/open-items.md` (move controller slice A out of planned; record results and anything deferred)
- Modify: spec §2 table if stick-up differs

- [ ] **Step 1:** Add the device checks from spec §7 to `manual-test-checklist.md`.
- [ ] **Step 2:** Build into a fresh `build/appN`; the owner runs the checks for Xbox USB, Xbox Bluetooth, DualSense USB, DualSense Bluetooth and Steam puck, stick-up first, plus the SD-card launch, the switch-off launch and Switch 2 Pro + Xbox.
- [ ] **Step 3:** If stick-up is inverted on a layout, fix that layout's `stickUp`/`stickDown` and its test in Task 1's files, rerun the gate.
- [ ] **Step 4:** Update `open-items.md` and commit — `docs: controller device test results`.
