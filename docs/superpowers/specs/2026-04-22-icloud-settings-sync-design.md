# iCloud Settings Sync — Design

Status: approved 2026-04-22.

## 1. Goal & non-goals

**Goal.** Sync Diriger's user-editable settings across the user's Macs via iCloud, so that routing rules and keyboard-shortcut bindings set on one Mac appear on another Mac signed into the same iCloud account. Build the sync layer so that adding a new synced setting in the future is a one-line registration.

**In scope for initial release:**

- Routing rules (`RuleStore`).
- Per-profile keyboard shortcut bindings (the `KeyboardShortcuts` library's entries).
- An opt-in Settings toggle ("Sync settings via iCloud"), off by default.
- A per-key last-modified-wins merge.
- A one-time local migration from profile-directory-keyed storage to profile-email-keyed storage.
- Apple Developer portal / entitlements / signing changes documented in `iCloud.md` at repo root.

**Out of scope:**

- Per-machine settings that do not meaningfully sync: "Launch at login" (`SMAppService`), default-browser role (`LSSetDefaultHandlerForURLScheme`), accessibility permission.
- CloudKit, iCloud Drive / document syncing, or any server-side schema. We use `NSUbiquitousKeyValueStore` only.
- Conflict-free merging of concurrent edits to the same array (e.g., two Macs each adding a rule at the same instant). Per-key last-write-wins is the accepted behavior.

## 2. Approach

Use `NSUbiquitousKeyValueStore` (KVS). All synced data fits trivially under KVS limits (1 MB total, 1 MB per value, 1024 keys).

Each synced UserDefaults key has a companion `mtime` (epoch seconds) stored in a shared metadata map `_diriger_sync_metadata` in both UserDefaults and KVS. Reconcile per key: whichever side has the newer `mtime` wins; if one side is absent, the other side wins (absent < any mtime).

## 3. Architecture & data model

### 3.1 New types

**`SyncedDefaults`** — `@MainActor`, accessed via `SyncedDefaults.shared`. Owns:

- Registration of synced keys.
- The `icloud_sync_enabled` toggle state.
- The `_diriger_sync_metadata` map (mtimes).
- Mirroring UserDefaults ↔ KVS in both directions.
- Observing external writes: `NSUbiquitousKeyValueStoreDidChangeExternallyNotification` for cloud-side changes, and KVO on `UserDefaults.standard` for library-owned keys that we do not write ourselves (e.g., `KeyboardShortcuts`).
- Running the one-time directory → email migration.
- Posting an internal notification (`SyncedDefaults.keyDidChangeRemotelyNotification`) when a cloud-originated write lands locally, so in-memory stores (`RuleStore`) can reload.

**`SyncedKey`** — a value identifying one synced key:

```swift
struct SyncedKey: Hashable {
    let name: String             // UserDefaults key
    let ownedByApp: Bool         // true => owner calls didWriteLocally; false => we KVO UserDefaults
}
```

Convenience factories: `.routingRules`, `.profileShortcut(for: ProfileIdentity)`.

**`ProfileIdentity`** — the indirection that survives profile-directory differences across machines:

```swift
enum ProfileIdentity: Hashable, Codable {
    case email(String)           // preferred; stable across machines
    case directory(String)       // fallback for profiles with no signed-in Google account
}
```

Resolver (on `ChromeProfileService` or a small extension):

```swift
func directoryName(for identity: ProfileIdentity, in profiles: [ChromeProfile]) -> String?
```

Used at read time by `RuleEngine` (to find the target profile for a rule) and by `ProfileManager.registerShortcuts` (to bind shortcuts to the right local profile).

### 3.2 Type changes to existing code

- `RoutingRule.profileDirectory: String` → `RoutingRule.profileIdentity: ProfileIdentity`. `Codable` migration handled in a custom `init(from:)`: if the decoded payload has `profileIdentity`, use it; otherwise decode the legacy `profileDirectory` string into `.directory(name)` and rely on the one-time migration to upgrade it to `.email(...)` where possible.
- `KeyboardShortcuts.Name.forProfile` now takes a `ProfileIdentity` and produces `profile_shortcut_<email-or-dir>` under the hood. Old `profile_<directoryName>` keys are re-registered during migration and deleted.
- `RuleStore.persist()` calls `SyncedDefaults.shared.didWriteLocally(.routingRules)` after writing to UserDefaults.
- `ProfileManager.registerShortcuts()` resolves `ProfileIdentity` → local `directoryName` using the current profiles list; shortcuts for identities that don't resolve locally are simply not bound (dormant, preserved in storage).

### 3.3 Storage layout

| Location | Key | Contents |
|---|---|---|
| UserDefaults + KVS | `routing_rules` | JSON-encoded `[RoutingRule]` with `profileIdentity` |
| UserDefaults + KVS | `profile_shortcut_<email-or-dir>` | `KeyboardShortcuts` library's encoded shortcut |
| UserDefaults + KVS | `_diriger_sync_metadata` | `[String: Double]` — mtime epoch seconds per synced key |
| UserDefaults only | `icloud_sync_enabled` | `Bool` — the Settings toggle, per-machine |
| UserDefaults only | `sync_schema_version` | `Int` — migration cursor |

### 3.4 One-time local migration (runs once, regardless of whether iCloud sync is enabled)

Guarded by `sync_schema_version`. Target version: `1`.

1. Decode existing `routing_rules`. For each rule:
   - Parse legacy `profileDirectory` string.
   - If a current Chrome profile exists with that directory name **and** has a non-empty `email`, rewrite to `.email(profile.email)`.
   - Otherwise, rewrite to `.directory(profileDirectory)`.
   - Re-encode and save.
2. Enumerate UserDefaults for keys matching `profile_<directoryName>` (the old shortcut-binding key format). For each:
   - If the directory maps to a Chrome profile with an email, re-register the binding via the `KeyboardShortcuts` library under `profile_shortcut_<email>`, then remove the old key.
   - Else, rename to `profile_shortcut_<directoryName>` (keeping the same payload) and remove the old key.
3. Set `sync_schema_version = 1`.

Migration is idempotent. It runs during `AppDelegate` startup as an `await`ed task that directly calls `ChromeProfileService.loadProfiles()` once to build the directory → email map, independent of `ProfileManager`. `ProfileManager.registerShortcuts` is sequenced to run after migration completes.

## 4. Sync lifecycle & data flow

### 4.1 Startup

1. Run schema migration if `sync_schema_version < 1`.
2. Build `SyncedDefaults.shared`, which reads `icloud_sync_enabled` from UserDefaults.
3. Stores register their synced keys:
   - `RuleStore.init` → `SyncedDefaults.shared.register(.routingRules, ownedByApp: true)`
   - `ProfileManager.loadProfiles` → for each profile, `SyncedDefaults.shared.register(.profileShortcut(for: identity), ownedByApp: false)` (the `KeyboardShortcuts` library owns those writes).
4. If sync is **off**: `SyncedDefaults` is inert. No KVS traffic, no observers installed.
5. If sync is **on**: call `NSUbiquitousKeyValueStore.default.synchronize()`, install the external-change observer, install KVO on the library-owned keys, run a reconcile pass.

### 4.2 Reconcile pass

Triggers: enabling the toggle, `NSUbiquitousKeyValueStoreDidChangeExternally` notification, `NSApplication.didBecomeActiveNotification`.

For every registered key:

| Local mtime | Cloud mtime | Action |
|---|---|---|
| present | absent | push local value + mtime to KVS |
| absent | present | pull cloud value + mtime to UserDefaults; post `keyDidChangeRemotely` |
| present, newer | present, older | push local value + mtime to KVS |
| present, older | present, newer | pull cloud value + mtime to UserDefaults; post `keyDidChangeRemotely` |
| equal or both absent | — | no-op |

### 4.3 Write path (local edit)

1. The owning store writes the value into UserDefaults as today (`RuleStore.persist`, or the `KeyboardShortcuts` library writing directly).
2. `SyncedDefaults` learns of the write:
   - For app-owned keys: explicit `didWriteLocally(key)` call from the store.
   - For library-owned keys: UserDefaults KVO callback.
3. If sync is enabled: `localMtime = Date().timeIntervalSince1970`; value + updated metadata map are written to KVS. Debounced with a 500 ms trailing-edge timer so a burst of edits coalesces into one KVS write.

### 4.4 Read path (remote edit)

1. KVS fires `didChangeExternally` with the set of changed keys (plus `_diriger_sync_metadata`).
2. For each changed registered key, reconcile as in 4.2.
3. When cloud wins, `SyncedDefaults` writes the new value into UserDefaults, updates local mtime, and posts `keyDidChangeRemotely(forKey:)`.
4. `RuleStore` observes the notification and reloads its in-memory `rules` from UserDefaults, triggering SwiftUI updates via `@Observable`.
5. Shortcut bindings are re-read by the `KeyboardShortcuts` library from UserDefaults on demand; `ProfileManager.registerShortcuts` is re-invoked in response to the notification so new bindings become active.

### 4.5 Enable / disable transitions

- **Off → On:** run the reconcile pass immediately. No confirmation dialog. If the user is not signed into iCloud, the toggle goes on but `SyncedDefaults` stays effectively inert (KVS calls are no-ops). The Settings UI shows a subtle "iCloud is not signed in" note.
- **On → Off:** stop observing, stop mirroring. UserDefaults retains last-known values. KVS is left untouched — another Mac may still be syncing.

### 4.6 Failure modes

| Failure | Handling |
|---|---|
| User not signed into iCloud | `FileManager.default.ubiquityIdentityToken == nil` → show "iCloud is not signed in" in Settings under the toggle. Toggle still works; sync is dormant until sign-in. |
| Entitlement missing (ad-hoc build) | KVS calls silently no-op. Logged once. No user-facing error. |
| KVS quota exceeded | Logged via `Log`. Not surfaced to the user — hitting a 1 MB quota means something is wrong in our code. |
| Clock skew between Macs | Accepted limitation. Last-write-wins by wall clock. Documented in README. |
| Profile with no signed-in Google account (no email) | Falls back to `.directory(name)`. Works on one machine; mapping to another machine is best-effort (if both have a profile with the same directory name). |

## 5. Settings UI changes

A new section at the top of `SettingsView` (before "General"), titled **"iCloud"**:

- `Toggle("Sync settings via iCloud", isOn: ...)` — wired to `SyncedDefaults.shared.isEnabled`.
- Caption beneath the toggle: "Syncs routing rules and profile shortcuts across your Macs. Rules and shortcuts are identified by Chrome profile email."
- Status line (conditional):
  - `Not signed into iCloud` in red when `ubiquityIdentityToken == nil` and toggle is on.
  - Last-sync timestamp ("Last synced 2 minutes ago") when toggle is on and signed in. Updated whenever a reconcile pass completes.
  - Nothing when toggle is off.

No other UI changes. The existing "General", "Profile Shortcuts", "Link Handling", and "Routing Rules" sections work unchanged because sync is transparent from their perspective.

## 6. Developer-portal / entitlements / signing changes

Documented in detail in `iCloud.md` at the repo root. Summary:

- Register `tech.inkhorn.diriger` as an **Explicit App ID** on developer.apple.com with **iCloud** capability checked (Key-Value Storage; no CloudKit containers required).
- Update `Resources/Diriger.entitlements`:
  - `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)tech.inkhorn.diriger` (expands to `3YS4G5GH27.tech.inkhorn.diriger`).
- `scripts/build-app.sh` already signs with `--entitlements`; no script change needed beyond the entitlements file.
- Notarization remains unchanged; the notary service accepts Developer ID-signed apps with the iCloud KVS entitlement.
- Verify on a signed build:
  - `codesign -d --entitlements - Diriger.app` shows the KVS identifier.
  - The app appears in System Settings → Apple ID → iCloud → Apps Using iCloud (visible once the first KVS read/write has occurred).

## 7. Testing strategy

### 7.1 Unit tests (XCTest, add a test target to `Package.swift`)

- `SyncedDefaults` reconcile truth table (all six rows in 4.2).
- Debounced write path coalesces a burst into one KVS write (use a fake clock + fake KVS).
- One-time migration: legacy rules with a matching profile directory + email migrate to `.email(...)`; rules with no matching profile migrate to `.directory(...)`; migration is idempotent on re-run.
- `ProfileIdentity` codec: backwards-compat decoding of old `profileDirectory` payloads produces `.directory(...)`.
- `directoryName(for: identity, in: profiles)` resolver: email hit, email miss, directory fallback, no match.

### 7.2 Manual end-to-end test plan

Two Macs (or one Mac + iCloud web reset) signed into the same Apple ID.

1. **First-enable from populated Mac:** Mac A has rules + shortcuts, Mac B is empty. Enable on A, then on B. Verify B's rules and shortcuts match A's.
2. **Edit propagation:** with both toggles on, add a rule on A; verify it appears on B within ~10 seconds (KVS latency). Edit a shortcut on B; verify it appears on A.
3. **Identity resilience:** create the same email profile in different directory-name slots on A vs B. Verify a rule bound to that profile on A routes correctly on B.
4. **Disable preserves local state:** turn off sync on B. Rules/shortcuts remain. Add a new rule on A; verify it does not appear on B (sync is off). Re-enable on B; verify the new rule arrives.
5. **Not signed into iCloud:** sign out of iCloud on Mac B. Enable the toggle. Verify "Not signed into iCloud" appears and no crash occurs.

## 8. Risks & open items

- **Clock skew** between Macs can cause a "stale" edit to appear to win. Accepted. Documented in README.
- **KeyboardShortcuts library internals** — we rely on the library reading its values from `UserDefaults.standard` on demand. If a future version caches in memory, our KVO-triggered reloads will need to call an explicit "refresh from defaults" API. Guard: compile-time version lock to `2.x`.
- **First-launch migration running before profiles are loaded** — `ChromeProfileService.loadProfiles` is async; the migration needs an awaitable version that loads profiles once to build the directory → email map. If profiles cannot be loaded (Chrome never launched), migration leaves rules as `.directory(...)`; a subsequent launch with Chrome present re-runs the migration (schema-version stays at 0 if any rule remained in `.directory` fallback purely due to profile-lookup failure). Simpler alternative: always bump `sync_schema_version` on first run; accept that profiles created after migration won't be retroactively re-identified. We will use the simpler alternative.
