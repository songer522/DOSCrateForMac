# Themes: Standard and DOS

Date: 2026-10-28. Status: design approved in chat by the owner, spec awaiting review.

## 1. Goal

Add a theme choice to DOSCrate. **Standard** is today's UI, unchanged. **DOS**, the default (owner decision 2026-10-28, after the first device test), gives the library window the look of an early-1990s DOS graphical shell: a VGA-blue desktop, grey beveled panels, chunky 3D icon buttons and a pixel font (owner reference: a German DOS "Programmanager"-style shell screenshot). The DOS theme is our own design in that genre, not a copy of any specific product.

## 2. Owner decisions

| Question | Decision |
|---|---|
| How deep | Skin the **library window** only. Menu bar, Settings window, import sheets, alerts, confirmation dialogs and file pickers stay native. Owner follow-up (2026-10-28): in DOS the library window also gets its own blue title bar with a [-] box that quits DOSCrate (like ⌘Q); the native title bar and traffic lights are hidden, and come back in Standard. |
| Font | Bundle a freely licensed VGA bitmap-style font: **PxPlus IBM VGA 8x16** from the int10h Ultimate Oldschool PC Font Pack (CC BY-SA 4.0), credited in the Licenses window. |
| Icons | **Pixelated SF Symbols**: drawn small in flat retro colors, scaled up with nearest-neighbor. No new art. |
| Architecture | Approach 1: theme tokens plus a second library layout for DOS (below). |

## 3. Behavior

- Settings › General gets a **Theme** picker: *DOS* (default), *Standard*. Stored in `UserDefaults` under `appTheme` through `Preferences`, like the other settings. Unknown or missing values read as DOS.
- Changing the theme applies live to the open library window. No restart. A running game, an import in progress, a removal in progress and the current selection, filter, search, sort, grid/list mode and inspector visibility all survive the switch.
- The DOS theme uses one fixed palette in both light and dark mode.
- Every action available in Standard is available in DOS with the same behavior: Play (double-click and context menu), Stop, Show in Finder, Favorite, Recreate Game Info, Remove (single and batch, same confirmation dialogs and messages), Delete key removal, ⌘-click / ⇧-click / ⌘A selection, drag-and-drop import, Import… file picker, collections (select, rename, remove), search, sort, grid/list toggle, inspector toggle, Settings, the fix flows (`pendingFix`), status bar states (import progress with Cancel, library scan, duplicate check, removal progress, controller indicator).

## 4. Architecture

### 4.1 Theme model

- `enum AppTheme: String, CaseIterable { case standard, dos }` with `displayName`, in `App/Preferences.swift` next to the other preference enums. `Preferences.appTheme` persists it.
- `App/Theme/` (new folder) holds the DOS building blocks, each small and independent:
  - `RetroPalette`: named colors. Desktop VGA blue `#0000AA`, panel grey `#C0C0C0`, bevel light `#FFFFFF`, bevel dark `#808080`, shadow `#000000`, title/highlight blue `#0000AA` with white text, selection text `#FFFFFF`, status/accents (VGA green `#00AA00`, red `#AA0000`, yellow `#FFFF55`, cyan `#55FFFF`). Exact values are design constants in one place.
  - `RetroFont`: registers the bundled TTF once at launch with `CTFontManagerRegisterFontsForURL` (process scope) and returns `Font.custom` at integer multiples of the font's 16 px design size (16, and 32 for headings is optional), so glyphs stay crisp. If registration fails, it falls back to `.system(.body, design: .monospaced)` and logs once; the app never fails because of the font.
  - `RetroBevel`: a view modifier drawing a raised or sunken 2 px bevel (light top/left, dark bottom/right, and the reverse for sunken).
  - `RetroButtonStyle`: `ButtonStyle` with a raised bevel that becomes sunken while pressed; disabled draws grey text. Two sizes: icon button (icon above a label, like the reference button bar) and text button.
  - `RetroPanel`: grey beveled container with an optional blue title strip (white pixel-font title).
  - `PixelSymbol`: renders an SF Symbol at a small point size (about 16 pt) into an image, then displays it scaled up ×2 with `.interpolation(.none)`, tinted with a palette color. Pure rendering helper; no assets.
  - `RetroTextFieldStyle`, `RetroToggleStyle` and a retro `Picker` look where SwiftUI allows (sunken white field, pixel font). Where a native control can't be styled, keep it native inside the retro panel.

### 4.2 Shared library behavior

`LibraryView` today owns the removal confirmation dialogs, the drop target, the file importer, the import sheets, the fix handler (`handle(_:)`), `requestRemoval` and the context menu factory. Move these into a shared piece (for example a `LibraryActions` view modifier plus a small struct for `menu(_:)` / `requestRemoval`) so both layouts use the same code. The Standard layout must render exactly as before; this step is a pure refactor and existing tests must pass unchanged.

`LibraryView.body` then picks the layout from `model.prefs.appTheme`: the current `NavigationSplitView` for Standard, `RetroLibraryView` for DOS, both wrapped in the shared actions modifier. View state that must survive a switch (`showsGrid` is already `@AppStorage`; `showsInspector` moves to `@AppStorage` or stays in `LibraryView` and is passed down as a binding) lives above the switch.

### 4.3 DOS library window (`App/Views/Retro/`)

Layout, top to bottom, all in the pixel font:

1. **Button bar** (grey panel): icon buttons *Import*, *Play* (plays the single selected game; disabled when the Standard Play would be), *Grid* / *List* (one toggle button showing the other mode), *Sort* (menu: Title, Year, Last Played, Play Time, check on current), *Details* (inspector toggle), *Settings* (`SettingsLink`). A sunken search field on the right, bound to `model.query.search`. Native window toolbar is hidden in DOS (`.toolbar(.hidden, for: .windowToolbar)` or equivalent); the native title bar is replaced by the DOS title bar (§2).
2. **Main row**, three columns:
   - **Left panel** (fixed ~180 pt, resizable not required): beveled list with *All Games*, *Recently Played*, *Favorites*, then *Collections* with the same rename/remove context menu and alerts as `SidebarView` (reuse its logic, don't duplicate the tag rewrites). Selected row: blue strip, white text.
   - **Desktop** (VGA blue, fills):
     - *Grid*: icon tiles in a `LazyVGrid` (adaptive, ~120 pt). Each tile: the cover (existing `CoverView` image, framed with a sunken bevel) and the title below in white pixel font, two lines max. Selected tiles: title on a blue-highlight background with a dotted (dashed 1 px) outline, as in the reference. Running: small green play marker; Starting…: yellow marker with "Starting…"; status Missing / Needs repair / Read-only as short colored tags under the title. Selection, ⌘/⇧-click, ⌘A, double-click Play and the context menu behave like `GameGridView`.
     - *List*: a beveled table with the same columns as `GameListView` (Title with the same status markers, Year, Developer, Last Played, Play Time), a grey header row, white rows on the blue desktop or grey rows (implementer's choice, readable contrast), selection as blue strip with white text, same selection, context menu and double-click semantics. Sorting is by the Sort button (same as Standard, which has no clickable headers).
     - *Empty states*: "No Games Yet" / "No Matches" with the same wording as Standard, in a centered `RetroPanel`.
   - **Inspector** (when shown, 300–520 pt): a `RetroPanel` titled with the game title (or "No Game Selected" / "N Games Selected"), containing the existing `GameDetailView`. Inside it, apply the retro font, grey background (`.scrollContentBackground(.hidden)` on forms), and the retro button/toggle/text-field styles through the environment. Do not rewrite `GameDetailView`, `InfoTab`, `SettingsTab` or `AdvancedTab`; only add environment-driven styling hooks if a control needs one.
3. **Status bar** (sunken grey strip): the same states and texts as Standard's `statusBar`, with a retro progress bar (blue fill in a sunken trough), the controller indicator (pixel gamepad symbol plus label) and a Cancel text button when the import is cancellable. Shown only when Standard would show it.

### 4.4 Font and license

- Download the int10h Ultimate Oldschool PC Font Pack from `https://int10h.org/oldschool-pc-fonts/download/`, confirm its license file says CC BY-SA 4.0 (stop and ask if not), and add only `PxPlus_IBM_VGA_8x16.ttf` (or the pack's current name for the same face) as `App/Resources/Fonts/PxPlus_IBM_VGA_8x16.ttf`.
- Add the pack's license text as `App/Resources/Licenses/Fonts/PxPlus-IBM-VGA-CC-BY-SA-4.0.txt` with a one-line attribution header (font name, author VileR / int10h.org, source URL, "unmodified"). `scripts/embed-staging.sh` already copies `App/Resources/Licenses` into the bundle, so it shows in the Licenses window. Add one sentence to `LicensesView.notice` crediting the font.
- Make sure the TTF ends up in the app bundle's Resources (XcodeGen picks up `App/` sources; confirm the file is in the built `.app`).

## 5. Out of scope

Theming the Settings window, import sheets, alerts, confirmation dialogs, file pickers, or menus; custom pixel-art icons; more than two themes; per-game themes; sound effects; a DOS-styled DOSBox window.

## 6. Testing

**Testing:** simulator (unit tests below); device test on the Mac by the owner (§6.2).

### 6.1 Automated (`make generate test`, 0 warnings)

- `AppTheme`: default is `.dos`; round-trips through `Preferences`/`UserDefaults`; an unknown stored value reads as `.dos`.
- `RetroFont`: the bundled font file exists in the app bundle and registers; the font name resolves (`NSFont(name:size:)` non-nil) after registration; calling register twice is harmless.
- Layout selection: `LibraryView` (or a small pure helper it uses) picks the retro layout for `.dos` and the standard one for `.standard`.
- Shared actions refactor: existing `LibraryView` tests (removal messages, etc.) pass unchanged.
- Retro list/grid helpers that hold logic (status tag text, marker state for running/starting, sort-menu checkmark) get unit tests; pure drawing code does not need them.
- Smoke: `RetroLibraryView` builds its body with sample records in both grid and list modes without crashing (host the view in an `NSHostingView` in a test, as far as the existing test setup allows).

### 6.2 Owner device test (manual checklist, new "Themes" section)

1. Fresh install: DOS theme, with the DOS title bar; its [-] box quits DOSCrate.
2. Switch to Standard and back to DOS in Settings: library window restyles immediately; selection, filter, search, sort, grid/list and inspector state kept.
3. In DOS: grid and list both readable; pixel font crisp (not blurry); selection outline; context menu actions; double-click Play; Delete key removal with the same dialog; drag-and-drop import and Import… with progress and Cancel in the status bar; collection rename/remove; inspector edits save.
4. Switch themes while a game runs and while an import runs: nothing interrupted.
5. Light and dark mode: DOS palette unchanged.
6. Licenses window lists the font license.
7. Switch to Standard: native title bar and traffic lights back, UI identical to before the themes work.

## 7. Docs

- `docs/manual-test-checklist.md`: add the Themes section (§6.2).
- `docs/open-items.md`: under Planned features, note the theme system and what stays native in DOS (Settings, sheets, dialogs), as a possible later slice.
