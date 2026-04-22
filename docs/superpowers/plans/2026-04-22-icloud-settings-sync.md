# iCloud Settings Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Diriger's routing rules and per-profile keyboard shortcuts across the user's Macs via `NSUbiquitousKeyValueStore`, opt-in from Settings, identifying profiles by Chrome account email so bindings survive differences in `directoryName` across machines.

**Architecture:** A new `SyncedDefaults` singleton mirrors a registered set of UserDefaults keys to `NSUbiquitousKeyValueStore`. Each key carries a companion `mtime` in a shared metadata map; per-key last-write-wins. A one-time local migration rewrites the identity of existing rules/shortcuts from Chrome directory name to Chrome account email via a new `ProfileIdentity` enum. The opt-in toggle lives in `SettingsView`. Sync is transparent: when cloud writes arrive, `SyncedDefaults` updates `UserDefaults` and posts an internal notification that `RuleStore` and `ProfileManager` react to.

**Tech Stack:** Swift 6 / SwiftUI, macOS 14+, SPM, `NSUbiquitousKeyValueStore`, `UserDefaults` KVO, `os.Logger`, `KeyboardShortcuts` 2.x (existing dependency). Tests use XCTest.

---

## File Structure

New files:

- `Sources/Diriger/ProfileIdentity.swift` — `ProfileIdentity` enum, its `Codable` support, and helpers to resolve identity ↔ directory against a `[ChromeProfile]`.
- `Sources/Diriger/SyncedDefaults.swift` — `SyncedKey`, `SyncedDefaults`, the `KVSBackend` protocol, and `NSUbiquitousKeyValueStore` conformance. Also contains the internal notification names.
- `Sources/Diriger/SyncMigration.swift` — one-shot `migrateToIdentityKeying` function invoked at app startup.
- `Tests/DirigerTests/ProfileIdentityTests.swift`
- `Tests/DirigerTests/RoutingRuleMigrationTests.swift`
- `Tests/DirigerTests/SyncedDefaultsTests.swift`
- `Tests/DirigerTests/SyncMigrationTests.swift`

Modified files:

- `Package.swift` — add test target.
- `Resources/Diriger.entitlements` — add `com.apple.developer.ubiquity-kvstore-identifier`.
- `Sources/Diriger/RoutingRule.swift` — replace `profileDirectory` with `profileIdentity`; add backward-compatible `Codable`.
- `Sources/Diriger/RuleStore.swift` — notify `SyncedDefaults` on write; react to cloud-origin notifications.
- `Sources/Diriger/ShortcutNames.swift` — `forProfile(_ identity: ProfileIdentity)`.
- `Sources/Diriger/DirigerApp.swift` — run migration at startup, register shortcut keys with `SyncedDefaults`, resolve identity → local directory in `registerShortcuts`, react to notifications.
- `Sources/Diriger/RuleEngine.swift` — match rules by resolving `profileIdentity` through available profiles.
- `Sources/Diriger/RulesTableView.swift` — UI works in `ProfileIdentity` terms.
- `Sources/Diriger/SettingsView.swift` — add "iCloud" section with toggle and status.

---

## Task 1: Add XCTest target to the package with a smoke test

Adds a test target so every subsequent task can use TDD. Verifies `swift test` runs green on a trivial assertion.

**Files:**
- Modify: `Package.swift`
- Create: `Tests/DirigerTests/SmokeTests.swift`

- [ ] **Step 1: Add a failing smoke test**

Create `Tests/DirigerTests/SmokeTests.swift`:

```swift
import XCTest
@testable import Diriger

final class SmokeTests: XCTestCase {
    func test_ruleKindHasExpectedCases() {
        XCTAssertEqual(RuleKind.allCases.count, 3)
    }
}
```

(Original drafted assertion was `XCTAssertEqual(AppInfo.bundleID, "tech.inkhorn.diriger")`, but in the XCTest runner `Bundle.main.bundleIdentifier` returns `"com.apple.dt.xctest.tool"`, so `AppInfo.bundleID`'s `??` fallback never fires. Using `RuleKind.allCases.count == 3` keeps the smoke test host-environment independent while still exercising `@testable import Diriger`.)

- [ ] **Step 2: Run and confirm it fails to build**

Run: `swift test`
Expected: build failure — "no such target 'DirigerTests'" (the test target hasn't been declared yet).

- [ ] **Step 3: Declare the test target**

Update `Package.swift` to:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Diriger",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Diriger", targets: ["Diriger"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Diriger",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/Diriger"
        ),
        .testTarget(
            name: "DirigerTests",
            dependencies: ["Diriger"],
            path: "Tests/DirigerTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test`
Expected: `Test Suite 'SmokeTests' passed. Executed 1 test, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/DirigerTests/SmokeTests.swift
git commit -m "Add XCTest target with smoke test"
```

---

## Task 2: Add `ProfileIdentity` enum with Codable

A `ProfileIdentity` is the stable handle we'll store for rules and shortcut names instead of raw `directoryName`. Preferred form is `.email`; `.directory` is the fallback for Chrome profiles without a signed-in account. Its JSON codec is human-readable (`{"email":"a@b.com"}` or `{"directory":"Profile 1"}`) so stored JSON remains inspectable.

**Files:**
- Create: `Sources/Diriger/ProfileIdentity.swift`
- Create: `Tests/DirigerTests/ProfileIdentityTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/DirigerTests/ProfileIdentityTests.swift`:

```swift
import XCTest
@testable import Diriger

final class ProfileIdentityTests: XCTestCase {
    func test_encodesEmailCase() throws {
        let data = try JSONEncoder().encode(ProfileIdentity.email("a@b.com"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json, #"{"email":"a@b.com"}"#)
    }

    func test_encodesDirectoryCase() throws {
        let data = try JSONEncoder().encode(ProfileIdentity.directory("Profile 1"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json, #"{"directory":"Profile 1"}"#)
    }

    func test_decodesEmailCase() throws {
        let json = Data(#"{"email":"a@b.com"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileIdentity.self, from: json)
        XCTAssertEqual(decoded, .email("a@b.com"))
    }

    func test_decodesDirectoryCase() throws {
        let json = Data(#"{"directory":"Profile 1"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileIdentity.self, from: json)
        XCTAssertEqual(decoded, .directory("Profile 1"))
    }

    func test_decodeFailsOnEmptyObject() {
        let json = Data("{}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileIdentity.self, from: json))
    }

    func test_storageKeyIsUniquePerIdentity() {
        XCTAssertNotEqual(
            ProfileIdentity.email("a@b.com").storageKey,
            ProfileIdentity.directory("a@b.com").storageKey
        )
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter ProfileIdentityTests`
Expected: build failure — "cannot find 'ProfileIdentity' in scope".

- [ ] **Step 3: Implement `ProfileIdentity`**

Create `Sources/Diriger/ProfileIdentity.swift`:

```swift
import Foundation

enum ProfileIdentity: Hashable, Codable, Sendable {
    case email(String)
    case directory(String)

    private enum CodingKeys: String, CodingKey {
        case email
        case directory
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .email) {
            self = .email(value)
            return
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .directory) {
            self = .directory(value)
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "ProfileIdentity must have 'email' or 'directory'.")
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .email(let value):
            try container.encode(value, forKey: .email)
        case .directory(let value):
            try container.encode(value, forKey: .directory)
        }
    }

    /// String form safe to use as a suffix in UserDefaults/KVS keys.
    var storageKey: String {
        switch self {
        case .email(let value): return "email:\(value)"
        case .directory(let value): return "dir:\(value)"
        }
    }
}
```

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test --filter ProfileIdentityTests`
Expected: all six tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/ProfileIdentity.swift Tests/DirigerTests/ProfileIdentityTests.swift
git commit -m "Add ProfileIdentity enum with Codable"
```

---

## Task 3: Add identity ↔ directory resolvers on `ChromeProfile`

A resolver that turns a `ProfileIdentity` into the current local `directoryName` (or `nil` if the profile isn't present on this Mac), and the inverse — building an identity for a `ChromeProfile`, preferring `.email` when available.

**Files:**
- Create (append to): `Sources/Diriger/ProfileIdentity.swift`
- Modify: `Tests/DirigerTests/ProfileIdentityTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DirigerTests/ProfileIdentityTests.swift`:

```swift
final class ProfileIdentityResolverTests: XCTestCase {
    private func profile(_ dir: String, _ display: String, _ email: String = "") -> ChromeProfile {
        ChromeProfile(directoryName: dir, displayName: display, email: email)
    }

    func test_identityForProfilePrefersEmail() {
        let p = profile("Profile 1", "Jane", "jane@x.com")
        XCTAssertEqual(ProfileIdentity.forProfile(p), .email("jane@x.com"))
    }

    func test_identityForProfileFallsBackToDirectory() {
        let p = profile("Default", "Guest")
        XCTAssertEqual(ProfileIdentity.forProfile(p), .directory("Default"))
    }

    func test_resolveEmailToLocalDirectory() {
        let profiles = [
            profile("Profile 2", "Work", "work@x.com"),
            profile("Profile 1", "Home", "home@x.com")
        ]
        XCTAssertEqual(
            ProfileIdentity.email("work@x.com").directoryName(in: profiles),
            "Profile 2"
        )
    }

    func test_resolveEmailReturnsNilWhenNotPresent() {
        let profiles = [profile("Profile 1", "Home", "home@x.com")]
        XCTAssertNil(ProfileIdentity.email("other@x.com").directoryName(in: profiles))
    }

    func test_resolveDirectoryReturnsDirectoryWhenProfilePresent() {
        let profiles = [profile("Default", "Guest")]
        XCTAssertEqual(
            ProfileIdentity.directory("Default").directoryName(in: profiles),
            "Default"
        )
    }

    func test_resolveDirectoryReturnsNilWhenProfileAbsent() {
        let profiles = [profile("Default", "Guest")]
        XCTAssertNil(ProfileIdentity.directory("Missing").directoryName(in: profiles))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter ProfileIdentityResolverTests`
Expected: build failure on `ProfileIdentity.forProfile` / `.directoryName(in:)`.

- [ ] **Step 3: Implement resolvers**

Append to `Sources/Diriger/ProfileIdentity.swift`:

```swift
extension ProfileIdentity {
    static func forProfile(_ profile: ChromeProfile) -> ProfileIdentity {
        if !profile.email.isEmpty {
            return .email(profile.email)
        }
        return .directory(profile.directoryName)
    }

    func directoryName(in profiles: [ChromeProfile]) -> String? {
        switch self {
        case .email(let value):
            return profiles.first(where: { $0.email == value })?.directoryName
        case .directory(let value):
            return profiles.first(where: { $0.directoryName == value })?.directoryName
        }
    }
}
```

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test --filter ProfileIdentityResolverTests`
Expected: all six resolver tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/ProfileIdentity.swift Tests/DirigerTests/ProfileIdentityTests.swift
git commit -m "Add ProfileIdentity resolvers against ChromeProfile lists"
```

---

## Task 4: Migrate `RoutingRule` from `profileDirectory` to `profileIdentity`

`RoutingRule` stops storing a raw directory name. It stores a `ProfileIdentity`. The `Codable` decoder continues to accept the old `profileDirectory` field so existing persisted rules load into the new shape as `.directory(name)`. Later the one-time migration (Task 12) promotes eligible `.directory` to `.email`.

**Files:**
- Modify: `Sources/Diriger/RoutingRule.swift`
- Create: `Tests/DirigerTests/RoutingRuleMigrationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DirigerTests/RoutingRuleMigrationTests.swift`:

```swift
import XCTest
@testable import Diriger

final class RoutingRuleMigrationTests: XCTestCase {
    func test_decodesLegacyProfileDirectoryAsDirectoryIdentity() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com",
         "profileDirectory":"Profile 1"}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .directory("Profile 1"))
    }

    func test_decodesNewProfileIdentityField() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com",
         "profileIdentity":{"email":"jane@x.com"}}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .email("jane@x.com"))
    }

    func test_roundTripsProfileIdentity() throws {
        let rule = RoutingRule(
            id: UUID(),
            kind: .regex,
            pattern: "^https://mail\\.google\\.com/",
            profileIdentity: .email("jane@x.com")
        )
        let data = try JSONEncoder().encode(rule)
        let restored = try JSONDecoder().decode(RoutingRule.self, from: data)
        XCTAssertEqual(restored, rule)
    }

    func test_missingIdentityDecodesAsEmptyDirectory() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com"}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .directory(""))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter RoutingRuleMigrationTests`
Expected: build failure — `profileIdentity` not a member of `RoutingRule`.

- [ ] **Step 3: Replace `RoutingRule` with identity-keyed shape**

Overwrite `Sources/Diriger/RoutingRule.swift`:

```swift
import Foundation

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case source
    case domain
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .domain: return "Domain"
        case .regex: return "RegEx"
        }
    }
}

struct RoutingRule: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: RuleKind
    var pattern: String
    var sourceName: String?
    var profileIdentity: ProfileIdentity

    init(
        id: UUID = UUID(),
        kind: RuleKind = .domain,
        pattern: String = "",
        sourceName: String? = nil,
        profileIdentity: ProfileIdentity = .directory("")
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.sourceName = sourceName
        self.profileIdentity = profileIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pattern, sourceName
        case profileIdentity
        case profileDirectory  // legacy
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(RuleKind.self, forKey: .kind)
        self.pattern = try c.decode(String.self, forKey: .pattern)
        self.sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        if let identity = try c.decodeIfPresent(ProfileIdentity.self, forKey: .profileIdentity) {
            self.profileIdentity = identity
        } else {
            let legacy = (try c.decodeIfPresent(String.self, forKey: .profileDirectory)) ?? ""
            self.profileIdentity = .directory(legacy)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(pattern, forKey: .pattern)
        try c.encodeIfPresent(sourceName, forKey: .sourceName)
        try c.encode(profileIdentity, forKey: .profileIdentity)
    }
}
```

- [ ] **Step 4: Update `RuleEngine.firstMatch` to resolve identity**

Replace the `firstMatch` function body in `Sources/Diriger/RuleEngine.swift` (lines 4–20):

```swift
    static func firstMatch(
        in rules: [RoutingRule],
        url: URL,
        sourceBundleID: String?,
        availableProfiles: [ChromeProfile]
    ) -> ChromeProfile? {
        for rule in rules {
            guard let directory = rule.profileIdentity.directoryName(in: availableProfiles),
                  let profile = availableProfiles.first(where: { $0.directoryName == directory })
            else { continue }

            guard matches(rule: rule, url: url, sourceBundleID: sourceBundleID) else { continue }

            return profile
        }
        return nil
    }
```

- [ ] **Step 5: Update `RulesTableView` to operate in identity terms**

Apply these edits to `Sources/Diriger/RulesTableView.swift`:

Replace `appendRule()` and `addAfter(id:)` (lines 65–77):

```swift
    private func appendRule() {
        let identity = profileManager.profiles.first.map(ProfileIdentity.forProfile) ?? .directory("")
        store.add(RoutingRule(profileIdentity: identity))
    }

    private func addAfter(id: RoutingRule.ID) {
        guard let index = store.rules.firstIndex(where: { $0.id == id }) else {
            appendRule()
            return
        }
        let identity = profileManager.profiles.first.map(ProfileIdentity.forProfile) ?? .directory("")
        store.insert(RoutingRule(profileIdentity: identity), at: index + 1)
    }
```

Replace `RuleRow.profileMissing`, `profileMenu`, `profileLabel` (lines 91–189):

```swift
    private var isIdentityUnset: Bool {
        switch rule.profileIdentity {
        case .directory(let value): return value.isEmpty
        case .email(let value): return value.isEmpty
        }
    }

    private var profileMissing: Bool {
        !isIdentityUnset && rule.profileIdentity.directoryName(in: profiles) == nil
    }

    // ...body unchanged...

    private var profileMenu: some View {
        PillMenu(
            text: profileLabel,
            textColor: profileMissing ? .red : .primary,
            items: profiles.map { profile in
                PillMenuItem(title: profile.displayName) {
                    var copy = rule
                    copy.profileIdentity = ProfileIdentity.forProfile(profile)
                    onChange(copy)
                }
            }
        )
    }

    private var profileLabel: String {
        if let directory = rule.profileIdentity.directoryName(in: profiles),
           let profile = profiles.first(where: { $0.directoryName == directory }) {
            return profile.displayName
        }
        return isIdentityUnset ? "Select profile" : "Missing"
    }
```

(An empty-string identity — which is how freshly-created rules come out before the user picks a profile — must read as "unset" (neutral placeholder), not "missing on this Mac" (red). `isIdentityUnset` draws that distinction so `profileMissing` stays `false` until a real identity is assigned.)

(Apply surgically; leave the rest of `RuleRow` — body, buttons, pattern field — unchanged.)

- [ ] **Step 6: Run all tests**

Run: `swift test`
Expected: all tests pass (old + 4 new migration tests).

- [ ] **Step 7: Run a release build to confirm app compiles**

Run: `swift build`
Expected: exits 0 with no warnings related to the new types.

- [ ] **Step 8: Commit**

```bash
git add Sources/Diriger/RoutingRule.swift Sources/Diriger/RuleEngine.swift \
        Sources/Diriger/RulesTableView.swift Tests/DirigerTests/RoutingRuleMigrationTests.swift
git commit -m "Key routing rules by ProfileIdentity with legacy decoder"
```

---

## Task 5: Change `KeyboardShortcuts.Name.forProfile` to accept `ProfileIdentity`

Future shortcut registrations will use identity-derived names. The old `profile_<directoryName>` names stay readable until migration (Task 12) renames them.

**Files:**
- Modify: `Sources/Diriger/ShortcutNames.swift`
- Modify: `Sources/Diriger/DirigerApp.swift` (call site in `ProfileManager.registerShortcuts`)
- Modify: `Sources/Diriger/MenuBarView.swift` (`shortcutLabel(for:)` call site — same `.forProfile(ProfileIdentity.forProfile(profile))` replacement)

- [ ] **Step 1: Replace `ShortcutNames.swift`**

Overwrite `Sources/Diriger/ShortcutNames.swift`:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    private static let profilePrefix = "profile_shortcut_"
    static let maxSlots = 10

    static func forProfile(_ identity: ProfileIdentity) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("\(profilePrefix)\(identity.storageKey)")
    }
}
```

- [ ] **Step 2: Update `ProfileManager.registerShortcuts`**

In `Sources/Diriger/DirigerApp.swift`, replace the `registerShortcuts()` method of `ProfileManager` (lines 28–44):

```swift
    private func registerShortcuts() {
        KeyboardShortcuts.removeAllHandlers()

        for profile in profiles.prefix(KeyboardShortcuts.Name.maxSlots) {
            let identity = ProfileIdentity.forProfile(profile)
            let name = KeyboardShortcuts.Name.forProfile(identity)
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in
                    do {
                        try await ChromeLauncher.switchToProfile(profile)
                    } catch {
                        Log.chrome.error("switchToProfile failed: \(error.localizedDescription, privacy: .public)")
                        ErrorAlert.present(error)
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Update `SettingsView.profileShortcutsSection` binding**

In `Sources/Diriger/SettingsView.swift`, replace the `Recorder` line (line 99):

```swift
                        KeyboardShortcuts.Recorder(for: .forProfile(ProfileIdentity.forProfile(profile)))
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: compiles clean.

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: all prior tests still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/Diriger/ShortcutNames.swift Sources/Diriger/DirigerApp.swift Sources/Diriger/SettingsView.swift
git commit -m "Key shortcut names by ProfileIdentity"
```

---

## Task 6: Introduce `SyncedKey` and the KVS backend protocol

Defines the data types the sync layer operates on, plus a small protocol that lets tests substitute a fake for `NSUbiquitousKeyValueStore`. No behavior yet — pure types.

**Files:**
- Create: `Sources/Diriger/SyncedDefaults.swift`
- Create: `Tests/DirigerTests/SyncedDefaultsTests.swift`

- [ ] **Step 1: Write a failing smoke test**

Create `Tests/DirigerTests/SyncedDefaultsTests.swift`:

```swift
import XCTest
@testable import Diriger

final class SyncedKeyTests: XCTestCase {
    func test_routingRulesKeyIsAppOwned() {
        let key = SyncedKey.routingRules
        XCTAssertEqual(key.name, "routing_rules")
        XCTAssertTrue(key.ownedByApp)
    }

    func test_profileShortcutKeyIsLibraryOwned() {
        let key = SyncedKey.profileShortcut(for: .email("jane@x.com"))
        XCTAssertEqual(key.name, "KeyboardShortcuts_profile_shortcut_email:jane@x.com")
        XCTAssertFalse(key.ownedByApp)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter SyncedKeyTests`
Expected: build failure — `SyncedKey` not defined.

- [ ] **Step 3: Create `SyncedDefaults.swift` with the types only**

Create `Sources/Diriger/SyncedDefaults.swift`:

```swift
import Foundation
import KeyboardShortcuts

/// Identifies one UserDefaults key that is mirrored to iCloud KVS.
struct SyncedKey: Hashable, Sendable {
    let name: String
    let ownedByApp: Bool

    static let routingRules = SyncedKey(name: "routing_rules", ownedByApp: true)

    static func profileShortcut(for identity: ProfileIdentity) -> SyncedKey {
        let shortcutName = KeyboardShortcuts.Name.forProfile(identity).rawValue
        return SyncedKey(name: "KeyboardShortcuts_\(shortcutName)", ownedByApp: false)
    }
}

/// Protocol abstraction over `NSUbiquitousKeyValueStore` so tests can substitute a fake.
protocol KVSBackend: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KVSBackend {}
```

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test --filter SyncedKeyTests`
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Tests/DirigerTests/SyncedDefaultsTests.swift
git commit -m "Add SyncedKey and KVSBackend protocol"
```

---

## Task 7: `SyncedDefaults` reconcile logic (pure, no I/O)

Implements the per-key merge function from the spec §4.2 as a pure function, tested against a truth table. This is the heart of the sync behavior; keeping it pure keeps it testable.

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Tests/DirigerTests/SyncedDefaultsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DirigerTests/SyncedDefaultsTests.swift`:

```swift
final class ReconcileTests: XCTestCase {
    private let v1 = Data("v1".utf8)
    private let v2 = Data("v2".utf8)

    func test_bothAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(local: nil, cloud: nil),
            .noAction
        )
    }

    func test_localPresentCloudAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: nil
            ),
            .pushLocalToCloud
        )
    }

    func test_cloudPresentLocalAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: nil,
                cloud: .init(value: v1, mtime: 10)
            ),
            .pullCloudToLocal
        )
    }

    func test_localNewerThanCloud() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v2, mtime: 20),
                cloud: .init(value: v1, mtime: 10)
            ),
            .pushLocalToCloud
        )
    }

    func test_cloudNewerThanLocal() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: .init(value: v2, mtime: 20)
            ),
            .pullCloudToLocal
        )
    }

    func test_equalMtimesNoAction() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: .init(value: v2, mtime: 10)
            ),
            .noAction
        )
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter ReconcileTests`
Expected: build failure — `SyncedDefaults` not defined yet.

- [ ] **Step 3: Implement reconcile**

Append to `Sources/Diriger/SyncedDefaults.swift`:

```swift
enum SyncedDefaults {
    struct Entry: Equatable {
        let value: Data
        let mtime: Double
    }

    enum Decision: Equatable {
        case pushLocalToCloud
        case pullCloudToLocal
        case noAction
    }

    static func reconcile(local: Entry?, cloud: Entry?) -> Decision {
        switch (local, cloud) {
        case (nil, nil):
            return .noAction
        case (_?, nil):
            return .pushLocalToCloud
        case (nil, _?):
            return .pullCloudToLocal
        case (let l?, let c?):
            if l.mtime > c.mtime { return .pushLocalToCloud }
            if c.mtime > l.mtime { return .pullCloudToLocal }
            return .noAction
        }
    }
}
```

(Yes, `SyncedDefaults` starts as an `enum` namespace. We'll upgrade it to a class in Task 8 when we add state. This keeps Task 7 focused on the pure function.)

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test --filter ReconcileTests`
Expected: six reconcile tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Tests/DirigerTests/SyncedDefaultsTests.swift
git commit -m "Add pure reconcile decision function for SyncedDefaults"
```

---

## Task 8: `SyncedDefaults` as a stateful class with registration and manual reconcile

Turns `SyncedDefaults` into a real class backed by an injected `UserDefaults` and `KVSBackend`. Implements:
- `register(_ key: SyncedKey)` — adds a key to the tracked set.
- `reconcile(_ key: SyncedKey)` — uses the pure function + actual storage; writes the winner and updates both mtime maps.
- `isEnabled` / `setEnabled(_:)` — toggle state stored in UserDefaults under `icloud_sync_enabled`. When disabled, all operations are no-ops.

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Tests/DirigerTests/SyncedDefaultsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DirigerTests/SyncedDefaultsTests.swift`:

```swift
// FakeKVS — minimal in-memory implementation of KVSBackend.
@MainActor
final class FakeKVS: KVSBackend {
    var store: [String: Any] = [:]
    var syncCallCount = 0

    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    @discardableResult
    func synchronize() -> Bool { syncCallCount += 1; return true }
}

@MainActor
final class SyncedDefaultsInstanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var clock: Double = 100
    private var sut: SyncedDefaults!

    override func setUp() {
        super.setUp()
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock }
        )
    }

    func test_disabledByDefault() {
        XCTAssertFalse(sut.isEnabled)
    }

    func test_toggleIsPersisted() {
        sut.setEnabled(true)
        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "icloud_sync_enabled"))
        sut.setEnabled(false)
        XCTAssertFalse(sut.isEnabled)
    }

    func test_reconcile_localOnly_pushesWhenEnabled() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)  // stamps mtime
        sut.register(.routingRules)

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("local".utf8))
        let cloudMeta = kvs.store["_diriger_sync_metadata"] as? [String: Double]
        XCTAssertEqual(cloudMeta?["routing_rules"], 500)
    }

    func test_reconcile_cloudOnly_pullsWhenEnabled() {
        kvs.store["routing_rules"] = Data("cloud".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 800.0]
        sut.register(.routingRules)

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("cloud".utf8))
        let localMeta = defaults.dictionary(forKey: "_diriger_sync_metadata") as? [String: Double]
        XCTAssertEqual(localMeta?["routing_rules"], 800)
    }

    func test_reconcile_cloudNewer_overwritesLocal() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 100
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        kvs.store["routing_rules"] = Data("cloud".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 900.0]

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("cloud".utf8))
    }

    func test_disabled_isInert() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.reconcile(.routingRules)  // enabled == false

        XCTAssertNil(kvs.store["routing_rules"])
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter SyncedDefaultsInstanceTests`
Expected: build failure — `SyncedDefaults(local:cloud:clock:)` is not an initializer.

- [ ] **Step 3: Convert `SyncedDefaults` to a class**

In `Sources/Diriger/SyncedDefaults.swift`, replace the `enum SyncedDefaults { ... }` block (from Task 7) with:

```swift
@MainActor
final class SyncedDefaults {
    struct Entry: Equatable {
        let value: Data
        let mtime: Double
    }

    enum Decision: Equatable {
        case pushLocalToCloud
        case pullCloudToLocal
        case noAction
    }

    static let metadataKey = "_diriger_sync_metadata"
    static let toggleKey = "icloud_sync_enabled"

    private let local: UserDefaults
    private let cloud: KVSBackend
    private let clock: @Sendable () -> Double
    private var registered: Set<SyncedKey> = []

    init(
        local: UserDefaults = .standard,
        cloud: KVSBackend = NSUbiquitousKeyValueStore.default,
        clock: @Sendable @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.local = local
        self.cloud = cloud
        self.clock = clock
    }

    var isEnabled: Bool {
        local.bool(forKey: Self.toggleKey)
    }

    func setEnabled(_ enabled: Bool) {
        local.set(enabled, forKey: Self.toggleKey)
    }

    func register(_ key: SyncedKey) {
        registered.insert(key)
    }

    static func reconcile(local: Entry?, cloud: Entry?) -> Decision {
        switch (local, cloud) {
        case (nil, nil): return .noAction
        case (_?, nil): return .pushLocalToCloud
        case (nil, _?): return .pullCloudToLocal
        case (let l?, let c?):
            if l.mtime > c.mtime { return .pushLocalToCloud }
            if c.mtime > l.mtime { return .pullCloudToLocal }
            return .noAction
        }
    }

    func recordLocalWrite(_ key: SyncedKey) {
        var map = (local.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = clock()
        local.set(map, forKey: Self.metadataKey)
    }

    func reconcile(_ key: SyncedKey) {
        guard isEnabled else { return }

        let localEntry = readEntry(from: local, key: key)
        let cloudEntry = readEntry(from: cloud, key: key)

        switch Self.reconcile(local: localEntry, cloud: cloudEntry) {
        case .noAction:
            return
        case .pushLocalToCloud:
            guard let entry = localEntry else { return }
            write(entry: entry, to: cloud, key: key)
        case .pullCloudToLocal:
            guard let entry = cloudEntry else { return }
            write(entry: entry, to: local, key: key)
            NotificationCenter.default.post(
                name: Self.keyDidChangeRemotelyNotification,
                object: nil,
                userInfo: ["key": key.name]
            )
        }
    }

    static let keyDidChangeRemotelyNotification =
        Notification.Name("tech.inkhorn.diriger.SyncedDefaults.keyDidChangeRemotely")

    // MARK: - storage helpers

    private func readEntry(from defaults: UserDefaults, key: SyncedKey) -> Entry? {
        guard let value = defaults.data(forKey: key.name) else { return nil }
        let map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        let mtime = map[key.name] ?? 0
        return Entry(value: value, mtime: mtime)
    }

    private func readEntry(from cloud: KVSBackend, key: SyncedKey) -> Entry? {
        guard let value = cloud.object(forKey: key.name) as? Data else { return nil }
        let map = (cloud.object(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        let mtime = map[key.name] ?? 0
        return Entry(value: value, mtime: mtime)
    }

    private func write(entry: Entry, to defaults: UserDefaults, key: SyncedKey) {
        defaults.set(entry.value, forKey: key.name)
        var map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = entry.mtime
        defaults.set(map, forKey: Self.metadataKey)
    }

    private func write(entry: Entry, to cloud: KVSBackend, key: SyncedKey) {
        cloud.set(entry.value, forKey: key.name)
        var map = (cloud.object(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = entry.mtime
        cloud.set(map, forKey: Self.metadataKey)
    }
}
```

- [ ] **Step 4: Run tests and confirm pass**

Run: `swift test --filter SyncedDefaults`
Expected: all ReconcileTests still pass + five new SyncedDefaultsInstanceTests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Tests/DirigerTests/SyncedDefaultsTests.swift
git commit -m "Add SyncedDefaults class with per-key reconcile"
```

---

## Task 9: `SyncedDefaults` enable/disable, reconcileAll, and external-change observer

Adds the runtime glue: enabling the toggle runs `reconcileAll`, sets up the `NSUbiquitousKeyValueStore.didChangeExternallyNotification` observer and the `NSApplication.didBecomeActiveNotification` observer. Disabling removes them. All keyed off the registered set.

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Tests/DirigerTests/SyncedDefaultsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DirigerTests/SyncedDefaultsTests.swift`:

```swift
@MainActor
final class SyncedDefaultsLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var clock: Double = 100
    private var sut: SyncedDefaults!

    override func setUp() {
        super.setUp()
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock }
        )
    }

    func test_reconcileAll_visitsEveryRegisteredKey() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        defaults.set(Data("s".utf8), forKey: "KeyboardShortcuts_profile_shortcut_email:a@b.com")
        sut.recordLocalWrite(.profileShortcut(for: .email("a@b.com")))

        sut.register(.routingRules)
        sut.register(.profileShortcut(for: .email("a@b.com")))
        sut.setEnabled(true)

        sut.reconcileAll()

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("r".utf8))
        XCTAssertEqual(
            kvs.store["KeyboardShortcuts_profile_shortcut_email:a@b.com"] as? Data,
            Data("s".utf8)
        )
    }

    func test_enable_triggersReconcileAll() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.setEnabled(true)  // should reconcile

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("r".utf8))
    }

    func test_handleExternalChange_reconcilesOnlyChangedKeys() {
        defaults.set(Data("old".utf8), forKey: "routing_rules")
        clock = 100
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)
        sut.setEnabled(true)

        kvs.store["routing_rules"] = Data("new".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 900.0]

        sut.handleExternalChange(changedKeys: ["routing_rules"])

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("new".utf8))
    }

    func test_handleExternalChange_ignoresUnregisteredKeys() {
        sut.register(.routingRules)
        sut.setEnabled(true)
        kvs.store["unrelated"] = Data("x".utf8)

        sut.handleExternalChange(changedKeys: ["unrelated"])
        // Nothing to assert other than no crash and no unexpected writes.
        XCTAssertNil(defaults.data(forKey: "unrelated"))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter SyncedDefaultsLifecycleTests`
Expected: build failure — `reconcileAll`, `handleExternalChange` not defined.

- [ ] **Step 3: Add lifecycle methods and the enable hook**

Replace `SyncedDefaults.setEnabled(_:)` and add `reconcileAll` and `handleExternalChange`:

In `Sources/Diriger/SyncedDefaults.swift`, replace:

```swift
    func setEnabled(_ enabled: Bool) {
        local.set(enabled, forKey: Self.toggleKey)
    }
```

with:

```swift
    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        local.set(enabled, forKey: Self.toggleKey)
        if enabled, !wasEnabled {
            _ = cloud.synchronize()
            reconcileAll()
        }
    }

    func reconcileAll() {
        guard isEnabled else { return }
        for key in registered {
            reconcile(key)
        }
    }

    func handleExternalChange(changedKeys: [String]) {
        guard isEnabled else { return }
        for key in registered where changedKeys.contains(key.name) {
            reconcile(key)
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SyncedDefaults`
Expected: all tests pass, including four new lifecycle tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Tests/DirigerTests/SyncedDefaultsTests.swift
git commit -m "Add reconcileAll and external-change dispatch to SyncedDefaults"
```

---

## Task 10: Debounced write path + `NSUbiquitousKeyValueStore` change observer

Adds:
- `pushWrite(_ key: SyncedKey)` — 500 ms trailing-edge debounce, then `reconcile(key)`. Called after local writes.
- `attachNotifications()` / `detachNotifications()` — install/remove `NSUbiquitousKeyValueStore.didChangeExternallyNotification` and `NSApplication.didBecomeActiveNotification` observers. Called by `setEnabled`.

Debounce uses `DispatchWorkItem` against the main queue (we're on `@MainActor`).

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Tests/DirigerTests/SyncedDefaultsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/DirigerTests/SyncedDefaultsTests.swift`:

```swift
@MainActor
final class SyncedDefaultsDebounceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var clock: Double = 100
    private var sut: SyncedDefaults!

    override func setUp() {
        super.setUp()
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock },
            debounce: 0  // synchronous in tests
        )
        sut.register(.routingRules)
        sut.setEnabled(true)
    }

    func test_pushWrite_withZeroDebounceMirrorsImmediately() {
        defaults.set(Data("v".utf8), forKey: "routing_rules")
        clock = 200
        sut.recordLocalWrite(.routingRules)
        sut.pushWrite(.routingRules)

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("v".utf8))
    }

    func test_pushWrite_coalescesBurst() {
        // Switch to a non-zero debounce to exercise coalescing.
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock },
            debounce: 0.05
        )
        sut.register(.routingRules)
        sut.setEnabled(true)

        defaults.set(Data("a".utf8), forKey: "routing_rules")
        clock = 201; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)
        defaults.set(Data("b".utf8), forKey: "routing_rules")
        clock = 202; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)
        defaults.set(Data("c".utf8), forKey: "routing_rules")
        clock = 203; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)

        let exp = expectation(description: "debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("c".utf8))
        // Coalesced metadata reflects the last write's mtime.
        let meta = kvs.store["_diriger_sync_metadata"] as? [String: Double]
        XCTAssertEqual(meta?["routing_rules"], 203)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter SyncedDefaultsDebounceTests`
Expected: build failure — `init(local:cloud:clock:debounce:)` / `pushWrite` not defined.

- [ ] **Step 3: Add `debounce` parameter and `pushWrite`**

In `Sources/Diriger/SyncedDefaults.swift`, replace the existing initializer and add `pushWrite`:

Replace the existing `init`:

```swift
    private let debounce: TimeInterval
    private var pendingWork: [String: DispatchWorkItem] = [:]

    init(
        local: UserDefaults = .standard,
        cloud: KVSBackend = NSUbiquitousKeyValueStore.default,
        clock: @Sendable @escaping () -> Double = { Date().timeIntervalSince1970 },
        debounce: TimeInterval = 0.5
    ) {
        self.local = local
        self.cloud = cloud
        self.clock = clock
        self.debounce = debounce
    }
```

And add (new method, anywhere in the class):

```swift
    func pushWrite(_ key: SyncedKey) {
        guard isEnabled else { return }

        if debounce <= 0 {
            reconcile(key)
            return
        }

        pendingWork[key.name]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pendingWork[key.name] = nil
                self.reconcile(key)
            }
        }
        pendingWork[key.name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
```

- [ ] **Step 4: Attach notification observers**

Add these methods and update `setEnabled`:

```swift
    private var kvsObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

    private func attachNotifications() {
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
                self?.handleExternalChange(changedKeys: changed)
            }
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAll() }
        }
    }

    private func detachNotifications() {
        if let kvsObserver { NotificationCenter.default.removeObserver(kvsObserver) }
        if let appActiveObserver { NotificationCenter.default.removeObserver(appActiveObserver) }
        kvsObserver = nil
        appActiveObserver = nil
    }
```

Replace `setEnabled`:

```swift
    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        local.set(enabled, forKey: Self.toggleKey)
        switch (wasEnabled, enabled) {
        case (false, true):
            attachNotifications()
            _ = cloud.synchronize()
            reconcileAll()
        case (true, false):
            detachNotifications()
        default:
            break
        }
    }
```

Add `import AppKit` at the top of the file.

- [ ] **Step 5: Run tests**

Run: `swift test --filter SyncedDefaults`
Expected: all SyncedDefaults tests pass, including the two new debounce tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Tests/DirigerTests/SyncedDefaultsTests.swift
git commit -m "Add debounced write path and notification observers to SyncedDefaults"
```

---

## Task 11: `SyncedDefaults.shared` singleton and `RuleStore` integration

Wire `RuleStore` into the sync layer:
- Provide a `SyncedDefaults.shared` instance (constructed once, `@MainActor`).
- `RuleStore.persist()` calls `SyncedDefaults.shared.recordLocalWrite(.routingRules)` + `pushWrite(.routingRules)`.
- `RuleStore` observes `SyncedDefaults.keyDidChangeRemotelyNotification` and reloads in-memory `rules` from UserDefaults when `routing_rules` is reported.
- `RuleStore.init()` registers `.routingRules` with `SyncedDefaults.shared`.

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Sources/Diriger/RuleStore.swift`

- [ ] **Step 1: Add the singleton**

Append to `Sources/Diriger/SyncedDefaults.swift` (inside the class, or at the bottom):

```swift
extension SyncedDefaults {
    static let shared = SyncedDefaults()
}
```

- [ ] **Step 2: Update `RuleStore` to talk to `SyncedDefaults.shared`**

Replace `Sources/Diriger/RuleStore.swift`:

```swift
import Foundation

@MainActor
@Observable
final class RuleStore {
    static let defaultsKey = "routing_rules"

    private(set) var rules: [RoutingRule]
    private var remoteObserver: NSObjectProtocol?

    init() {
        self.rules = Self.load()
        SyncedDefaults.shared.register(.routingRules)
        remoteObserver = NotificationCenter.default.addObserver(
            forName: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard (note.userInfo?["key"] as? String) == Self.defaultsKey else { return }
                self?.reloadFromDefaults()
            }
        }
    }

    deinit {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
    }

    func add(_ rule: RoutingRule) {
        rules.append(rule)
        persist()
    }

    func insert(_ rule: RoutingRule, at index: Int) {
        let clamped = max(0, min(index, rules.count))
        rules.insert(rule, at: clamped)
        persist()
    }

    func update(_ rule: RoutingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persist()
    }

    func remove(id: RoutingRule.ID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func reloadFromDefaults() {
        rules = Self.load()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            SyncedDefaults.shared.recordLocalWrite(.routingRules)
            SyncedDefaults.shared.pushWrite(.routingRules)
        } catch {
            Log.rules.error("Failed to persist rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load() -> [RoutingRule] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([RoutingRule].self, from: data)
        } catch {
            Log.rules.error(
                "Failed to decode persisted rules; starting empty: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles clean.

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Sources/Diriger/RuleStore.swift
git commit -m "Wire RuleStore to SyncedDefaults"
```

---

## Task 12: Shortcut key KVO + `ProfileManager` registration and remote-reload

Shortcut keys are library-owned — `KeyboardShortcuts` writes to `UserDefaults.standard` directly. We observe those writes via KVO and forward to `SyncedDefaults`. On remote changes, `ProfileManager.registerShortcuts` is re-invoked so the library re-reads from UserDefaults.

**Files:**
- Modify: `Sources/Diriger/SyncedDefaults.swift`
- Modify: `Sources/Diriger/DirigerApp.swift`

- [ ] **Step 1: Add KVO-based observation for library-owned keys**

Append to `Sources/Diriger/SyncedDefaults.swift`:

```swift
extension SyncedDefaults {
    /// For library-owned keys we don't write ourselves (e.g., KeyboardShortcuts),
    /// install a KVO observer on the local UserDefaults so we can stamp mtime and push.
    func observeLibraryOwnedKey(_ key: SyncedKey) {
        precondition(!key.ownedByApp)
        let obs = DefaultsKVO(key: key.name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordLocalWrite(key)
                self.pushWrite(key)
            }
        }
        libraryObservers[key] = obs
    }

    func stopObservingLibraryOwnedKey(_ key: SyncedKey) {
        libraryObservers[key] = nil
    }
}

// Small KVO wrapper — lifetime tied to this object, which is stored in the dictionary above.
@MainActor
private final class DefaultsKVO: NSObject {
    private let key: String
    private let onChange: @MainActor () -> Void

    init(key: String, onChange: @escaping @MainActor () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath _: String?,
        of _: Any?,
        change _: [NSKeyValueChangeKey: Any]?,
        context _: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in self.onChange() }
    }
}
```

Add a `libraryObservers` property to `SyncedDefaults`:

```swift
    private var libraryObservers: [SyncedKey: DefaultsKVO] = [:]
```

- [ ] **Step 2: Update `ProfileManager` to register + react**

In `Sources/Diriger/DirigerApp.swift`, replace the `ProfileManager` class (lines 5–45):

```swift
@MainActor
@Observable
final class ProfileManager {
    var profiles: [ChromeProfile] = []

    private let watcher: ChromeLocalStateWatcher
    private var remoteObserver: NSObjectProtocol?
    private var registeredShortcutKeys: Set<SyncedKey> = []

    init() {
        let watcher = ChromeLocalStateWatcher()
        self.watcher = watcher
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.loadProfiles() }
        }
        Task { await loadProfiles() }
        watcher.start()

        remoteObserver = NotificationCenter.default.addObserver(
            forName: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let name = (note.userInfo?["key"] as? String) ?? ""
                guard name.hasPrefix("KeyboardShortcuts_profile_shortcut_") else { return }
                self?.registerShortcuts()
            }
        }
    }

    deinit {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
    }

    func loadProfiles() async {
        profiles = await ChromeProfileService.loadProfiles()
        updateSyncedShortcutRegistrations()
        registerShortcuts()
    }

    private func updateSyncedShortcutRegistrations() {
        let desired: Set<SyncedKey> = Set(
            profiles.prefix(KeyboardShortcuts.Name.maxSlots).map { profile in
                SyncedKey.profileShortcut(for: ProfileIdentity.forProfile(profile))
            }
        )

        for key in desired.subtracting(registeredShortcutKeys) {
            SyncedDefaults.shared.register(key)
            SyncedDefaults.shared.observeLibraryOwnedKey(key)
        }
        for key in registeredShortcutKeys.subtracting(desired) {
            SyncedDefaults.shared.stopObservingLibraryOwnedKey(key)
        }
        registeredShortcutKeys = desired
    }

    private func registerShortcuts() {
        KeyboardShortcuts.removeAllHandlers()

        for profile in profiles.prefix(KeyboardShortcuts.Name.maxSlots) {
            let identity = ProfileIdentity.forProfile(profile)
            let name = KeyboardShortcuts.Name.forProfile(identity)
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in
                    do {
                        try await ChromeLauncher.switchToProfile(profile)
                    } catch {
                        Log.chrome.error("switchToProfile failed: \(error.localizedDescription, privacy: .public)")
                        ErrorAlert.present(error)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles clean.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SyncedDefaults.swift Sources/Diriger/DirigerApp.swift
git commit -m "Observe library-owned shortcut keys and react to remote changes"
```

---

## Task 13: One-time local migration from directory-keyed to identity-keyed storage

`SyncMigration.runIfNeeded()` is called once at startup. Guarded by `sync_schema_version`. It:
1. Awaits `ChromeProfileService.loadProfiles()` once.
2. Re-encodes `routing_rules` so any rule currently carrying `.directory(name)` whose `name` maps to a current Chrome profile with a non-empty email becomes `.email(...)`.
3. For each legacy `profile_<directoryName>` shortcut binding in UserDefaults, reads it with the `KeyboardShortcuts` API, writes it under the new `profile_shortcut_<identity-storage-key>` name, and removes the old entry.
4. Sets `sync_schema_version = 1` unconditionally when done, even if profile loading failed.

**Files:**
- Create: `Sources/Diriger/SyncMigration.swift`
- Create: `Tests/DirigerTests/SyncMigrationTests.swift`
- Modify: `Sources/Diriger/DirigerApp.swift` (call `SyncMigration.runIfNeeded` at startup)

- [ ] **Step 1: Write the failing tests**

Create `Tests/DirigerTests/SyncMigrationTests.swift`:

```swift
import XCTest
import KeyboardShortcuts
@testable import Diriger

@MainActor
final class SyncMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    private func encodeRules(_ rules: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: rules)
    }

    func test_migrationRewritesDirectoryIdentityToEmailWhenProfileHasEmail() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Profile 1", displayName: "Jane", email: "jane@x.com")]

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let data = defaults.data(forKey: RuleStore.defaultsKey)!
        let rules = try! JSONDecoder().decode([RoutingRule].self, from: data)
        XCTAssertEqual(rules.first?.profileIdentity, .email("jane@x.com"))
    }

    func test_migrationKeepsDirectoryWhenProfileHasNoEmail() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Default"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Default", displayName: "Guest", email: "")]

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Default"))
    }

    func test_migrationKeepsDirectoryWhenProfileNotPresent() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles: [ChromeProfile] = []

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Profile 1"))
    }

    func test_runIfNeededBumpsSchemaVersion() async {
        XCTAssertEqual(defaults.integer(forKey: SyncMigration.schemaVersionKey), 0)
        SyncMigration.performMigration(defaults: defaults, profiles: [])
        // Direct bump helper:
        SyncMigration.markSchemaApplied(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: SyncMigration.schemaVersionKey), 1)
    }

    func test_runIfNeededSkipsWhenSchemaAlreadyCurrent() async {
        defaults.set(1, forKey: SyncMigration.schemaVersionKey)
        defaults.set(encodeRules([[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Profile 1", displayName: "Jane", email: "jane@x.com")]

        await SyncMigration.runIfNeeded(
            defaults: defaults,
            loadProfiles: { profiles }
        )

        // Should NOT have been upgraded, because schema version gates the run.
        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Profile 1"))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter SyncMigrationTests`
Expected: build failure — `SyncMigration` not defined.

- [ ] **Step 3: Implement `SyncMigration`**

Create `Sources/Diriger/SyncMigration.swift`:

```swift
import Foundation
import KeyboardShortcuts

enum SyncMigration {
    static let schemaVersionKey = "sync_schema_version"
    static let currentSchemaVersion = 1

    @MainActor
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        loadProfiles: @Sendable () async -> [ChromeProfile] = { await ChromeProfileService.loadProfiles() }
    ) async {
        guard defaults.integer(forKey: schemaVersionKey) < currentSchemaVersion else { return }
        let profiles = await loadProfiles()
        performMigration(defaults: defaults, profiles: profiles)
        markSchemaApplied(defaults: defaults)
    }

    /// Performs the one-shot transformation. Idempotent. Exposed for tests.
    @MainActor
    static func performMigration(defaults: UserDefaults, profiles: [ChromeProfile]) {
        migrateRules(defaults: defaults, profiles: profiles)
        migrateShortcuts(defaults: defaults, profiles: profiles)
    }

    @MainActor
    static func markSchemaApplied(defaults: UserDefaults) {
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
    }

    // MARK: - Rules

    private static func migrateRules(defaults: UserDefaults, profiles: [ChromeProfile]) {
        guard let data = defaults.data(forKey: RuleStore.defaultsKey) else { return }
        guard var rules = try? JSONDecoder().decode([RoutingRule].self, from: data) else { return }

        var didChange = false
        for (index, rule) in rules.enumerated() {
            if case .directory(let name) = rule.profileIdentity,
               let match = profiles.first(where: { $0.directoryName == name }),
               !match.email.isEmpty {
                var copy = rule
                copy.profileIdentity = .email(match.email)
                rules[index] = copy
                didChange = true
            }
        }

        guard didChange else { return }
        if let encoded = try? JSONEncoder().encode(rules) {
            defaults.set(encoded, forKey: RuleStore.defaultsKey)
        }
    }

    // MARK: - Shortcuts

    @MainActor
    private static func migrateShortcuts(defaults: UserDefaults, profiles: [ChromeProfile]) {
        let legacyPrefix = "KeyboardShortcuts_profile_"
        let allKeys = defaults.dictionaryRepresentation().keys
        for defaultsKey in allKeys where defaultsKey.hasPrefix(legacyPrefix)
            && !defaultsKey.hasPrefix("KeyboardShortcuts_profile_shortcut_") {
            let legacyName = String(defaultsKey.dropFirst("KeyboardShortcuts_".count))
            let directoryName = String(legacyName.dropFirst("profile_".count))
            let oldName = KeyboardShortcuts.Name(legacyName)
            let shortcut = KeyboardShortcuts.getShortcut(for: oldName)

            let identity: ProfileIdentity
            if let match = profiles.first(where: { $0.directoryName == directoryName }), !match.email.isEmpty {
                identity = .email(match.email)
            } else {
                identity = .directory(directoryName)
            }
            let newName = KeyboardShortcuts.Name.forProfile(identity)

            KeyboardShortcuts.setShortcut(shortcut, for: newName)
            KeyboardShortcuts.reset([oldName])
        }
    }
}
```

- [ ] **Step 4: Call `runIfNeeded` at app startup**

In `Sources/Diriger/DirigerApp.swift`, change the `AppDelegate` `applicationWillFinishLaunching` method to additionally kick off migration before continuing. Replace the existing method with:

```swift
    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSAppleEventManager.shared().setEventHandler(
                self,
                andSelector: #selector(handleURL(event:replyEvent:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
            Task { @MainActor in
                await SyncMigration.runIfNeeded()
            }
        }
    }
```

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: all tests pass, including the five new migration tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Diriger/SyncMigration.swift Sources/Diriger/DirigerApp.swift \
        Tests/DirigerTests/SyncMigrationTests.swift
git commit -m "Add one-time migration from directory-keyed to identity-keyed storage"
```

---

## Task 14: Add "iCloud" section to `SettingsView`

A new section at the top of the Settings form with the toggle, a caption, and a status line.

**Files:**
- Modify: `Sources/Diriger/SettingsView.swift`

- [ ] **Step 1: Add state + section**

In `Sources/Diriger/SettingsView.swift`, near the top of `SettingsView` (with the other `@State` properties), add:

```swift
    @State private var syncEnabled = SyncedDefaults.shared.isEnabled
    @State private var iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
```

Prepend `iCloudSection` to the `Form`:

```swift
    var body: some View {
        Form {
            iCloudSection
            generalSection
            profileShortcutsSection
            defaultBrowserSection
            rulesSection
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 720)
        .onAppear {
            launchAtLogin = SettingsView.readLaunchAtLogin()
            refreshDefaultBrowserState()
            iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshDefaultBrowserState()
            axGranted = AXIsProcessTrusted()
            iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
        }
    }
```

Add the section builder next to the other `*Section` computed properties:

```swift
    private var iCloudSection: some View {
        Section {
            Toggle(isOn: iCloudToggleBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync settings via iCloud")
                    Text("Syncs routing rules and profile shortcuts across your Macs. Profiles are identified by Chrome account email.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if syncEnabled, !iCloudSignedIn {
                Text("Not signed into iCloud on this Mac. Sign in via System Settings to start syncing.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud")
        }
    }

    private var iCloudToggleBinding: Binding<Bool> {
        Binding(
            get: { syncEnabled },
            set: { newValue in
                SyncedDefaults.shared.setEnabled(newValue)
                syncEnabled = SyncedDefaults.shared.isEnabled
            }
        )
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: compiles clean.

- [ ] **Step 3: Run tests**

Run: `swift test`
Expected: all tests still green.

- [ ] **Step 4: Launch manually and smoke-test the UI**

Run: `swift run Diriger`
Expected: app launches; open Settings from the menu bar; confirm the new "iCloud" section appears above "General" with a toggle and caption; flipping the toggle does not crash; if you sign out of iCloud (optional), the red caption appears after re-opening Settings.

Quit the app when done.

- [ ] **Step 5: Commit**

```bash
git add Sources/Diriger/SettingsView.swift
git commit -m "Add iCloud settings section with sync toggle"
```

---

## Task 15: Add KVS entitlement

Without this entitlement the app can sign but KVS calls silently no-op. Pair this change with a verification step.

**Files:**
- Modify: `Resources/Diriger.entitlements`

- [ ] **Step 1: Write the entitlements file**

Replace `Resources/Diriger.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>$(TeamIdentifierPrefix)tech.inkhorn.diriger</string>
</dict>
</plist>
```

- [ ] **Step 2: Build the signed `.app`**

Run: `bash scripts/build-app.sh`
Expected: script completes with `Built .../Diriger.app` and no `codesign` errors.

- [ ] **Step 3: Verify the entitlement is embedded**

Run: `codesign -d --entitlements - Diriger.app`
Expected output contains:

```xml
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>3YS4G5GH27.tech.inkhorn.diriger</string>
```

If it does not, check that `$ENTITLEMENTS_PATH` is unset (so the script picks the repo default) and that the file above was saved.

- [ ] **Step 4: Commit**

```bash
git add Resources/Diriger.entitlements
git commit -m "Enable iCloud Key-Value Storage entitlement"
```

---

## Task 16: End-to-end verification

Nothing to change; this task runs the manual test plan from spec §7.2 and produces a short notes file recording the results. If any test fails, open an issue and abandon merge.

**Files:**
- None to modify. (Optional: keep personal notes in a local scratchpad.)

- [ ] **Step 1: Ensure the App ID is configured on developer.apple.com**

Follow `iCloud.md` §2. Verify on <https://developer.apple.com/account/resources/identifiers/list> that `tech.inkhorn.diriger` is registered with iCloud capability enabled.

- [ ] **Step 2: Install the signed build on Mac A**

Run:

```bash
bash scripts/build-app.sh
cp -R Diriger.app /Applications/
open /Applications/Diriger.app
```

- [ ] **Step 3: Confirm Diriger appears in Apple ID → iCloud**

Add at least one routing rule in Diriger, toggle **Sync settings via iCloud** on in Settings, then open **System Settings → Apple ID → iCloud → Apps Using iCloud**. Diriger should be listed.

- [ ] **Step 4: Repeat install on Mac B with the same Apple ID**

Expected: Mac B, after turning the toggle on, receives Mac A's rules and shortcut bindings within ~30 seconds (bring app to foreground if needed — that triggers `didBecomeActive` reconcile).

- [ ] **Step 5: Bidirectional edit test**

Add a rule on Mac A. Verify it appears on Mac B. Edit a shortcut on Mac B. Verify it appears on Mac A.

- [ ] **Step 6: Identity-resilience test**

On one Mac, ensure a Chrome profile for a given email is stored under a different `Profile N` directory than on the other. Assign a rule to that profile on Mac A. Open a matching URL on Mac B. Confirm it routes to the profile with the matching email, not the matching directory name.

- [ ] **Step 7: Toggle-off preserves local state**

Turn sync off on Mac B. Add a new rule on Mac A. Confirm Mac B does not receive it. Turn sync on again on Mac B. Confirm the new rule arrives.

- [ ] **Step 8: Commit any notes (optional)**

If you keep notes about the test run, commit them under `docs/`. No code change is expected here.

---

## Self-Review

**Spec coverage:**

- §1 goal — Tasks 1–14 together deliver the opt-in iCloud sync of rules and shortcuts.
- §2 approach (KVS) — Tasks 6–10.
- §3.1 new types — `ProfileIdentity` (Task 2–3), `SyncedKey` (Task 6), `SyncedDefaults` (Tasks 7–10).
- §3.2 type changes — `RoutingRule` (Task 4), `ShortcutNames` (Task 5), `RuleStore.persist` (Task 11), `ProfileManager.registerShortcuts` (Task 5 + Task 12).
- §3.3 storage layout — metadata map (Task 8), toggle (Task 8), schema version (Task 13).
- §3.4 migration — Task 13.
- §4.1 startup — Task 13 (migration call) + Task 11 (RuleStore registration) + Task 12 (ProfileManager registration).
- §4.2 reconcile table — Task 7 pure function + Task 8 instance wiring.
- §4.3 write path — Task 10 debounced push.
- §4.4 read path — Tasks 9 (external change dispatch) + 10 (notification observer) + 11 + 12 (store reloads on notification).
- §4.5 enable/disable — Task 10 (`setEnabled` with attach/detach).
- §4.6 failure modes — iCloud-signed-in check shown in Task 14 UI; quota/entitlement cases are logged by KVS runtime (no additional code needed).
- §5 UI — Task 14.
- §6 portal + entitlements — Task 15.
- §7 testing — unit tests embedded in Tasks 2, 3, 4, 6, 7, 8, 9, 10, 13; manual plan in Task 16.
- §8 risks — clock skew and library-version risks are acknowledged in the spec; the migration-ordering risk is resolved in Task 13 (`runIfNeeded` awaits `loadProfiles` once, bumps schema unconditionally).

**Placeholder scan:** no "TBD", no "appropriate error handling", no "similar to task N". Every code step contains the full code.

**Type consistency:** `SyncedKey` fields (`name`, `ownedByApp`) used identically in Tasks 6, 7, 8, 9, 10, 11, 12. `ProfileIdentity` storage key referenced as `storageKey` in both Task 2 and Task 6. `SyncedDefaults.shared` is introduced in Task 11 and used in Tasks 11, 12, 14. `keyDidChangeRemotelyNotification` is defined in Task 8 and consumed in Tasks 11 (RuleStore), 12 (ProfileManager).
