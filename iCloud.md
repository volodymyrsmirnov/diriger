# iCloud Setup for Diriger

This document is a step-by-step guide for configuring **iCloud Key-Value Storage (KVS)** for Diriger on the Apple Developer portal, updating the app's entitlements, and verifying that a signed build can talk to iCloud. It is written for someone who has not previously configured App IDs or capabilities on developer.apple.com.

Diriger uses KVS (and only KVS) for settings sync. No CloudKit container, no iCloud Drive document syncing, no schema. If a future version needs CloudKit, this document will need to be extended.

## 1. Prerequisites

You should already have:

- An **Apple Developer Program** membership (paid, $99/year). Diriger's Team ID is `3YS4G5GH27`.
- A **Developer ID Application** signing certificate installed in your login keychain. You can confirm with:

  ```bash
  security find-identity -v -p codesigning
  ```

  The entry you want looks like:

  ```
  0AA2F73AF0C104F5146ABC4C5691062BF66C0FAE "Developer ID Application: Volodymyr Smirnov (3YS4G5GH27)"
  ```

- An Apple ID signed into iCloud on the Mac you will test on. System Settings → Apple ID → iCloud must show "iCloud Drive" or just a green status for your account.

If any of these is missing, fix that before proceeding.

## 2. Register the App ID on the Apple Developer portal

You will create an **Explicit App ID** that matches the app's bundle identifier (`tech.inkhorn.diriger`) and enable the iCloud capability on it.

1. Go to <https://developer.apple.com/account/>. Sign in.
2. In the sidebar, click **Certificates, Identifiers & Profiles**.
3. Click **Identifiers** in the sidebar. This page lists your App IDs.
4. Click the blue **+** button next to "Identifiers" to add a new one.
5. On the "Register a new identifier" page, select **App IDs**, then **Continue**.
6. On the "Select a type" page, leave **App** selected, then **Continue**.
7. On the "Register an App ID" form:
   - **Description:** `Diriger` (free-form; this label is only shown on the portal).
   - **Bundle ID:** leave **Explicit** selected, and enter `tech.inkhorn.diriger`. It must match exactly — the same string that's in `Resources/Info.plist`.
   - Scroll to the **Capabilities** list. Find **iCloud** and tick its checkbox.
     - When you tick iCloud, a small **Configure** button appears next to it. **You do not need to click Configure for Diriger.** The "Configure" flow is for CloudKit containers. Diriger uses Key-Value Storage only, which is enabled just by the top-level iCloud checkbox.
   - Scroll down. Leave every other capability unchecked.
   - Click **Continue**, then **Register** on the confirmation page.
8. You are back on the Identifiers list. Confirm your new App ID is listed with "iCloud" under its Capabilities column.

That is the entire portal-side configuration required for KVS. There is no provisioning profile to create for a Developer ID-distributed (non-App Store) Mac app.

### 2.1 If you previously registered the App ID without iCloud

Open the App ID on the portal, click **Edit**, tick **iCloud**, and click **Save**. Do not click "Configure" — that is the CloudKit flow. Wait a minute or two for the change to propagate before signing a new build.

## 3. Update the app's entitlements

The app bundle must carry the `com.apple.developer.ubiquity-kvstore-identifier` entitlement, and its value must match the App ID you just registered, prefixed by your Team ID.

Edit `Resources/Diriger.entitlements` so that it contains:

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

`$(TeamIdentifierPrefix)` is expanded by the code-signing tooling to `3YS4G5GH27.` (note the trailing period). The resulting identifier stored in the signed binary is `3YS4G5GH27.tech.inkhorn.diriger`. **Do not hand-expand this string** — keep the `$(TeamIdentifierPrefix)` macro so that a future Team ID change (e.g., switching to a business account) does not silently break signing.

## 4. Build and sign

The existing `scripts/build-app.sh` already passes `--entitlements "$ENTITLEMENTS"` to `codesign`, so no script changes are required. Build as usual:

```bash
bash scripts/build-app.sh
```

## 5. Verify the signed build

Run these checks on the produced `Diriger.app`.

### 5.1 The KVS entitlement is embedded

```bash
codesign -d --entitlements - Diriger.app
```

You should see, among other entitlements:

```xml
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>3YS4G5GH27.tech.inkhorn.diriger</string>
```

If this key is missing, codesign used a different entitlements file — check the `ENTITLEMENTS_PATH` env var and `Resources/Diriger.entitlements`.

### 5.2 The app is signed with a Developer ID cert

```bash
codesign -dv Diriger.app 2>&1 | grep 'Authority='
```

Expect three `Authority=` lines, the first one being `Developer ID Application: Volodymyr Smirnov (3YS4G5GH27)`. Ad-hoc (`-`) signing will not grant the entitlement — KVS will silently no-op at runtime.

### 5.3 The app appears in iCloud's "Apps Using iCloud" list

After the first successful KVS read or write (i.e., after enabling the "Sync settings via iCloud" toggle in Diriger with at least one rule present), open **System Settings → Apple ID → iCloud → Apps Using iCloud**. Diriger should appear with a toggle. This is the user-facing confirmation that the entitlement is granted and iCloud accepted the app.

If Diriger does not appear after a minute or two of having sync enabled with rules present, one of the following is true:
- The entitlement is missing from the signed binary (see 5.1).
- The App ID on the portal does not have iCloud capability enabled (see section 2).
- The Mac is not signed into iCloud.

## 6. Notarization

Diriger is distributed via Homebrew, which means the `.dmg` is notarized and stapled after signing. The notary service **accepts** Developer ID-signed apps with the iCloud KVS entitlement — there is no additional entitlement allow-listing step required. If notarization begins failing after the iCloud change, the failure log from `xcrun notarytool log` will name the exact cause; the most common mistake is leaving the entitlement file empty on one of the `codesign` invocations (the script signs twice — binary and bundle — both must use the same entitlements file).

## 7. Troubleshooting

**"Sync settings via iCloud" toggle turns on but nothing syncs.**
- Check `FileManager.default.ubiquityIdentityToken`: if `nil`, the user is not signed into iCloud. Diriger shows this in Settings.
- Check `codesign -d --entitlements - Diriger.app` (5.1).
- Check that the App ID on the portal has iCloud enabled (section 2).
- Try quitting the app, running `killall cloudd`, and relaunching — `cloudd` occasionally needs a nudge after entitlement changes to an already-signed bundle.

**Two Macs both have sync on, but edits don't propagate.**
- Both Macs must be signed into the *same* iCloud account.
- KVS is not instant; propagation takes seconds to minutes depending on network conditions. Bringing the receiving Mac to the foreground triggers a reconcile (`NSApplication.didBecomeActiveNotification`), which typically pulls changes immediately.
- Check Console.app for entries tagged `cloudd` while the edit is made and while the other Mac is active.

**The portal says "Explicit App ID already exists" when registering.**
- Either the App ID is already yours (re-open it and enable iCloud per 2.1), or another team has registered it. Bundle IDs are globally unique across all of Apple's developer accounts. If another team holds `tech.inkhorn.diriger`, that would indicate the current production builds are signed under a different team — double-check `security find-identity -v -p codesigning` and the Team ID embedded in the existing signature.

**KVS quota exceeded (logged by Diriger).**
- Something is wrong in Diriger's code, not in your setup. KVS allows 1 MB total. A reasonable rule set is kilobytes. Open an issue.
