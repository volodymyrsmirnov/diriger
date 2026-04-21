# Link Picker & Default Browser — Design

## Goal

When Diriger is registered as the macOS default browser, clicking a link in any app should open a compact, chrome-less picker at the cursor that lets the user route the URL to the Chrome profile of their choice (or copy / cancel).

## Decisions (Q&A log)

1. **Profile order in picker** — alphabetical by `directoryName` (matches menu bar & settings).
2. **URL schemes handled** — `http` and `https` only.
3. **Window placement** — centered on the cursor, nudged inward to stay fully on the display that contains the cursor.
4. **Initial selection** — always the first profile (index 0).
5. **Overflow** — cap the picker at 10 profiles (`KeyboardShortcuts.Name.maxSlots`). Profiles beyond the 10th are not shown in the picker.
6. **Dismissal** — `Esc`, outside click, or focus loss all dismiss the picker without opening the URL. Cmd+C is the only way to save the link.
7. **Default-browser toggle** — Settings toggle; ON calls `LSSetDefaultHandlerForURLScheme` for `http` + `https` (triggers macOS confirmation sheet); OFF unclaims the role. A subtitle shows the current system default handler. No attempt to "restore previous."
8. **URL rendering in picker** — full URL string, middle-ellipsis truncation at a fixed max width, matching the reference screenshot.
9. **Cancel behavior** — dropping the link is fine. No fallback browser, no implicit copy.
10. **Opening the URL** — `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` with `configuration.arguments = ["--profile-directory=<dir>"]`, URL passed via `urls:`. Works whether Chrome is running or not; no Accessibility API required.
11. **Visual style** — borderless `NSPanel` (`.nonactivatingPanel`), `NSVisualEffectView` backing (`.hudWindow` material), rounded corners, system shadow.

## Architecture

```
Sources/Diriger/
├── DefaultBrowserService.swift   (new)  — LaunchServices register/query/unregister
├── LinkPickerController.swift    (new)  — receives URL events, owns panel lifecycle
├── LinkPickerPanel.swift         (new)  — NSPanel subclass + SwiftUI content view
├── DirigerApp.swift              (edit) — NSApplicationDelegateAdaptor, Apple Event handler
├── SettingsView.swift            (edit) — "Default Browser" section
├── ChromeLauncher.swift          (edit) — static openURL(_:in:)
└── Resources/Info.plist          (edit) — CFBundleURLTypes, LSHandlerRank
```

## Data flow

```
macOS link click
      │
      ▼
GetURLEvent → AppDelegate handler → LinkPickerController.present(url)
      │
      ▼
LinkPickerController
  - reads cursor position (NSEvent.mouseLocation)
  - takes first 10 profiles (alphabetical)
  - creates or reuses LinkPickerPanel
      │
      ▼
LinkPickerPanel.show(at: cursorPoint, profiles: [...], url: url)
  - nudges frame into screen.visibleFrame
  - becomes key
  - installs global mouse-down monitor
      │
      ▼
Key/mouse handling inside panel:
  - ←/→: cycle selection (wraps)
  - 1..9/0: select index i (0 = 10th slot)
  - Enter: ChromeLauncher.openURL(url, in: selected); hide
  - Click on profile tile: same as Enter for that tile
  - Cmd+C: NSPasteboard.general writes url.absoluteString; hide
  - Esc / outside click / resignKey: hide (URL dropped)
```

## Components

### DefaultBrowserService (new)
Static helpers; no state:
- `isDefaultBrowser() -> Bool` — reads `LSCopyDefaultHandlerForURLScheme("http")` and compares to our bundle identifier.
- `currentDefaultHandlerBundleID() -> String?` — for display.
- `currentDefaultHandlerDisplayName() -> String?` — resolves via `NSWorkspace.urlForApplication(withBundleIdentifier:)` → `FileManager.displayName`.
- `register()` — calls `LSSetDefaultHandlerForURLScheme` for both `http` and `https` with our bundle id.
- `unregister()` — best-effort: set both schemes to Safari (`com.apple.Safari`) if present, else any other registered `http` handler. Documented as "hand back to another browser."

### LinkPickerController (new)
`@MainActor` class, injected with `ProfileManager`:
- `present(_ url: URL)` — called from the AppDelegate Apple Event handler.
- Owns a lazily-created `LinkPickerPanel` (reuses across invocations).
- Hides the panel on completion/dismissal.

### LinkPickerPanel (new)
- `NSPanel` subclass:
  - `styleMask = [.borderless, .nonactivatingPanel]`
  - `isFloatingPanel = true`
  - `level = .popUpMenu`
  - `backgroundColor = .clear`
  - Overrides `canBecomeKey = true`, `canBecomeMain = false`.
  - `contentView` is an `NSVisualEffectView` (material `.hudWindow`, blending `.behindWindow`) wrapping an `NSHostingView` for the SwiftUI content.
  - Corner radius 14 via `contentView.wantsLayer = true; layer.cornerRadius = 14; layer.masksToBounds = true`.
- Overrides `keyDown(with:)` to route events:
  - `53` (Esc) → controller.cancel
  - `36`/`76` (Return/Enter) → controller.openSelected
  - `123` (Left) → selection -= 1 (wrap)
  - `124` (Right) → selection += 1 (wrap)
  - `8` with `.command` (Cmd+C) → controller.copyURL
  - `18`..`26` (digits 1..9) → selection = index
  - `29` (digit 0) → selection = 9 (the 10th slot)
- A global `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` closure dismisses when a click lands outside the panel frame. Also observes `NSWindow.didResignKeyNotification` for the same effect.

SwiftUI content (`LinkPickerView`):
- Horizontal `HStack` of up to 10 `ProfileTile` views.
- Below the tiles: small footer with "Press ⏎ or N to open in NAME — Email" and the truncated URL.
- Middle-ellipsis truncation implemented manually (SwiftUI `.truncationMode(.middle)` works for single-line text views).
- Binding: `@Binding var selection: Int`.

`ProfileTile`:
- Small top number label ("1", "2", …).
- Large rounded-square profile picture (reuses `ChromeProfileService.profilePicturePath`). Same circular image helper as `MenuBarView`, but rendered as rounded square at ~56pt.
- Profile short code label under the image (first 4 letters of display name, uppercased — matches the reference screenshot "PERS", "PEAK").
- Selected state: 2pt rounded border around the image, subtle glow.
- Click gesture → controller.open(index).

### ChromeLauncher.openURL (new static func)
```swift
static func openURL(_ url: URL, in profile: ChromeProfile) {
    guard let chromeURL = ChromeProfileService.chromeURL() else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = ["--profile-directory=\(profile.directoryName)"]
    NSWorkspace.shared.open([url], withApplicationAt: chromeURL, configuration: config)
}
```
No Accessibility permission prompt; works whether Chrome is running or not.

### DirigerApp wiring
- Add `@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate`.
- `AppDelegate` (nested or sibling):
  - On `applicationWillFinishLaunching(_:)`: register for `GetURLEvent`:
    ```swift
    NSAppleEventManager.shared().setEventHandler(
        self, andSelector: #selector(handleURL(event:replyEvent:)),
        forEventClass: AEEventClass(kInternetEventClass),
        andEventID: AEEventID(kAEGetURL))
    ```
  - On `applicationShouldTerminateAfterLastWindowClosed`: returns `false` (already effectively the case — no regular windows).
  - `handleURL` parses `keyDirectObject` and calls `LinkPickerController.present(url)`.
- `ProfileManager` and `LinkPickerController` are owned by the `DirigerApp` struct and passed into the delegate via a shared singleton reference set in `init`.

### SettingsView edits
New section **"Default Browser"** added before "General":
- Toggle: **Enable links selection**. Binding uses `DefaultBrowserService.isDefaultBrowser()` / `.register()` / `.unregister()`.
- Caption under toggle: "Current default: <display name>" (live refreshed via `onAppear` + a `Timer` or `NotificationCenter` observer on `NSWorkspace.didActivateApplicationNotification`).
- Note line: "Turning this off hands the default role back to another installed browser."

### Info.plist edits
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>Web URL</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>http</string>
      <string>https</string>
    </array>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
  </dict>
</array>
```

## Edge cases & error handling

- **No Chrome installed** — picker still shows (populated from cached Local State if any); clicking a tile just no-ops silently. SettingsView already displays "No Chrome profiles found" when empty.
- **Zero profiles** — if `profiles.prefix(10)` is empty at present-time, `LinkPickerController` falls through and does nothing (URL is dropped). Rare; users of Diriger necessarily have profiles.
- **Malformed URL event** — missing `keyDirectObject` or bad URL → drop silently.
- **Multi-monitor / fractional scaling** — use the `NSScreen` containing the cursor, clamp to `visibleFrame` (accounts for menu bar & Dock).
- **Rapid double-click causes two events** — reuse panel; second invocation replaces URL and re-centers on cursor.
- **User unchecks the toggle while picker open** — not a realistic race; ignored.

## Testing

Swift-package sources, no unit-test target currently. Manual verification checklist (to live in plan):

1. Build and install; toggle "Enable links selection" — macOS prompts, confirm.
2. Click a link in Slack / Mail — picker appears under cursor.
3. Verify keybindings: Esc, Cmd+C, Enter, ← →, 1–9, 0.
4. Click a tile → opens in that profile; Chrome running and not-running.
5. Multi-monitor: click a link with cursor on secondary display — picker opens there.
6. Near screen edges: picker nudges inward.
7. Click outside picker → dismisses.
8. Toggle off — default handler reverts to Safari or prior browser.

## Non-goals

- No reorder UI for picker tiles (uses alphabetical order).
- No last-used memory (always highlights first tile).
- No support for `mailto:`, `file://`, or other schemes.
- No fallback browser concept when user cancels.
- No analytics / usage tracking.
