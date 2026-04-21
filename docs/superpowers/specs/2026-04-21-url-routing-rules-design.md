# URL Routing Rules — Design

## Goal

Allow users to define rules that immediately open a URL in a chosen Chrome profile, bypassing the link picker. Three rule kinds: Source (originating app), Domain (with wildcard), RegEx (full-URL).

## Decisions (Q&A log)

1. **Rule composition** — each rule is exactly one predicate. Compose by stacking rules.
2. **Ordering** — first-match-wins, user-ordered via drag-reorder in Settings.
3. **Domain semantics** — `*.example.com` matches the apex AND all subdomain depths. Non-wildcard pattern matches exactly. Host-only, case-insensitive.
4. **Source identity** — match by bundle identifier. Persist `{bundleID, lastKnownName}` so the UI stays readable if the app is uninstalled.
5. **RegEx** — unanchored, case-insensitive, evaluated against `url.absoluteString` via `NSRegularExpression`. Invalid patterns are saved but never match.
6. **No-match** — fall through to the existing link picker.
7. **Missing target profile** — rule is skipped silently; Settings shows a red "Profile missing" badge.
8. **Settings layout** — two tabs: **General** (profile hotkeys + Launch at Login) and **Profile Rules** (Default-Browser enable toggle + Rules section; Rules disabled when toggle is off).
9. **Per-rule enable toggle** — each rule has its own checkbox.
10. **Storage** — `UserDefaults.standard` JSON blob, same plist `KeyboardShortcuts` uses.

## Data model

```swift
enum RuleKind: String, Codable { case source, domain, regex }

struct RoutingRule: Identifiable, Codable, Hashable {
    let id: UUID
    var isEnabled: Bool
    var kind: RuleKind
    var pattern: String          // bundle ID | domain | regex
    var sourceName: String?      // cached label for .source
    var profileDirectory: String // target Chrome profile directoryName
}
```

Persisted as JSON under `UserDefaults.standard` key `routing_rules`.

## Components

| File | New? | Responsibility |
| --- | --- | --- |
| `RoutingRule.swift` | new | `RuleKind` + `RoutingRule`. |
| `RuleStore.swift` | new | `@Observable` class — load/persist, add/update/remove/move. |
| `RuleEngine.swift` | new | Pure `static func firstMatch(in:url:sourceBundleID:availableProfiles:) -> ChromeProfile?`. |
| `RulesTableView.swift` | new | SwiftUI section with `Table`, inline editors, validation, source picker. |
| `SettingsView.swift` | edit | `TabView` with "General" and "Profile Rules". |
| `DirigerApp.swift` | edit | Inject `RuleStore`; `AppDelegate.handleURL` resolves sender PID → bundle ID and consults `RuleEngine` before showing the picker. |
| `LinkPickerController.swift` | edit | `present(url:source:)` accepts optional source bundle ID (threaded through; not surfaced yet). |

## Evaluation

`RuleEngine.firstMatch` walks the rules top-to-bottom. For each rule:

- Skip if `isEnabled == false`.
- Skip if `profileDirectory` is not in `availableProfiles`.
- Match:
  - **source** — `sourceBundleID == rule.pattern`.
  - **domain** — lowercase `url.host` and `rule.pattern`. If pattern begins with `*.`, `suffix = pattern.dropFirst(2)`; match when `host == suffix || host.hasSuffix("." + suffix)`. Otherwise `host == pattern`.
  - **regex** — `NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])`. If construction throws, no match. Otherwise unanchored `.firstMatch(in: url.absoluteString, range: fullRange) != nil`.
- Return the matched rule's profile.

Returns `nil` if nothing matches.

## AppDelegate wiring

```swift
@objc
func handleURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: urlString) else { return }

    let sourcePID = event.attributeDescriptor(
        forKeyword: AEKeyword(keySenderPIDAttr)
    )?.int32Value
    let sourceBundleID = sourcePID.flatMap {
        NSRunningApplication(processIdentifier: pid_t($0))?.bundleIdentifier
    }

    Task { @MainActor in
        let services = AppServices.shared
        if let profile = RuleEngine.firstMatch(
            in: services.ruleStore.rules,
            url: url,
            sourceBundleID: sourceBundleID,
            availableProfiles: services.profileManager.profiles
        ) {
            ChromeLauncher.openURL(url, in: profile)
        } else {
            services.linkPicker.present(url: url, source: sourceBundleID)
        }
    }
}
```

## Settings UI

`SettingsView` becomes a `TabView`:

### General tab

Existing **Profiles** hotkeys list + **Launch at Login** toggle. No changes to behavior; the Default Browser section moves out.

### Profile Rules tab

- **Default Browser** section (moved here):
  - `Toggle("Enable links selection", isOn: $isDefaultBrowser)` with current-default subtitle.
- **Rules** section:
  - Wrapped in `.disabled(!isDefaultBrowser)`, faded opacity when disabled.
  - SwiftUI `Table<RoutingRule>` over `ruleStore.rules`:
    - `✓` column — per-rule `Toggle`.
    - **Kind** — segmented `Picker` with Source / Domain / RegEx.
    - **Pattern** — for Source, a read-only app-icon + name with a "Change…" button; for Domain/RegEx, `TextField` with inline validation icon.
    - **Profile** — `Picker` over `availableProfiles`. When `profileDirectory` is missing from the list, show a red `Text("Missing")` placeholder.
    - Drag handle (`.onMove`).
    - Trash button — removes the row.
  - `Button("+ Add rule")` appends a new rule (`kind = .domain`, empty pattern, first available profile).
- Source picker — `NSOpenPanel` with `allowedContentTypes = [.application]`; extracts `bundleIdentifier` + display name.
- Validation:
  - Domain: trim, lowercase; allow optional leading `*.`; reject other `*`, empty, or patterns with spaces.
  - RegEx: compile with `NSRegularExpression` on change; red `xmark.circle` + tooltip on failure.
  - Invalid rules persist (don't lose user typing) but never match.

## Edge cases

- **URL without host** (`javascript:`, malformed) — domain rules don't match; regex rules still evaluated.
- **Missing sender PID** — source rules don't match; others still evaluated.
- **Rule target profile removed from Chrome** — rule skipped; red badge in Settings.
- **Chrome not installed** — `ChromeLauncher.openURL` no-ops; URL dropped (rare).
- **Rule with empty pattern** — never matches.
- **Multiple matches** — first one wins; later rules in the list are ignored for that URL.

## Non-goals

- No "Create rule from this URL" action in the picker.
- No import/export of rules.
- No compound (AND) predicates.
- No "default profile if no rule matches" shortcut — no-match still goes to picker.
- No user-configurable case sensitivity for regex.

## Manual verification

1. Build & install. Open Settings — tabs appear, Default Browser moved to Profile Rules.
2. With "Enable links selection" off, the Rules section is greyed out.
3. Turn on. Add a Domain rule `*.github.com → Work`. Click a `github.com` link — opens in Work without picker.
4. Add a RegEx rule `/admin/ → Admin`. Click a URL containing `/admin/` — opens in Admin.
5. Add a Source rule for Slack → Work. Click a link in Slack that doesn't match the other rules — opens in Work.
6. Reorder rules; first-match-wins behavior observed.
7. Disable a rule via the checkbox — it no longer matches.
8. Delete the target Chrome profile directory entry (or pick a non-existent one) — rule shows red "Profile missing"; clicking a matching URL falls through to the picker.
9. Invalid regex shows inline error; rule doesn't fire.
