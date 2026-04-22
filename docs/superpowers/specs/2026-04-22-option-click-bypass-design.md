# Option-click rules bypass

## Problem

When another app opens an `http(s)` URL and a routing rule matches, Diriger sends the link straight to the bound profile. There is no way to opt out for a single click — users who occasionally want the picker for an otherwise-matched URL must temporarily disable or delete the rule.

## Goal

Holding the Option key while clicking a link in another app bypasses rule evaluation and shows the picker. Releasing Option and clicking again returns to normal rule-driven routing. No UI, no settings, no visual change to the picker.

## Approach

In `AppDelegate.handleURL` (`Sources/Diriger/DirigerApp.swift`), read `NSEvent.modifierFlags` at the moment the Apple Event arrives. If `.option` is set, skip `RuleEngine.firstMatch` and call `linkPicker.present(url:)` directly.

### Why this works

`NSEvent.modifierFlags` is a class property that returns the live system-wide modifier state from the HID layer. It does not require the calling app to be frontmost or hold input focus, so a background menu-bar app can read it reliably. The Apple Event fires within tens of milliseconds of the click, well inside the window where the user is still physically holding Option.

The originating app (Slack, Mail, etc.) does not forward modifier state through LaunchServices, so reading the current modifier state in Diriger is the only available signal.

## Scope

- Only the Apple Event URL handler is affected.
- The menu-bar profile switcher and global keyboard shortcuts are unchanged.
- Only meaningful when Diriger is the default browser (same precondition as rules today).
- Option key is hardcoded. No Settings toggle, no alternate modifier, no configurability.
- The picker looks and behaves identically whether rules were bypassed or simply did not match.

## Change surface

One file, ~2 lines:

```swift
// Sources/Diriger/DirigerApp.swift, inside handleURL
let bypassRules = NSEvent.modifierFlags.contains(.option)
let matched = bypassRules ? nil : RuleEngine.firstMatch(
    in: ruleStore.rules,
    url: url,
    sourceBundleID: sourceBundleID,
    availableProfiles: profileManager.profiles
)
if let profile = matched { /* existing open path */ }
else { linkPicker.present(url: url) }
```

## Testing

Unit tests do not cover this: the behavior depends on a runtime read of system-wide modifier state. Verification is manual:

1. Build and install Diriger; ensure it is the default browser.
2. Add a rule that would match a known URL (e.g. `github.com` → some profile).
3. Click the URL in another app — confirm it opens in the rule's profile.
4. Option-click the same URL — confirm the picker appears at the cursor.
5. Click again without Option — confirm the rule takes effect again.
