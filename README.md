# Diriger

A lightweight macOS menu bar app for quickly switching between Google Chrome profiles.

## Features

- Lists all Chrome profiles in the menu bar with profile pictures
- Switches to a profile by clicking Chrome's native Profiles menu via Accessibility API
- Configurable global keyboard shortcuts for up to 10 profiles
- Launch at login support
- Automatically reads profiles from Chrome's local state

## Requirements

- macOS 14.0+
- Google Chrome
- Accessibility permission (prompted on first use)

## Building

```bash
bash scripts/build-app.sh
```

The build script will:
1. Compile the Swift package in release mode
2. Assemble the `.app` bundle
3. Generate the app icon
4. Code sign using the first available signing identity (falls back to ad-hoc)

## Installation

After building, move `Diriger.app` to `/Applications` and launch it. On first profile switch, macOS will prompt for Accessibility permission — grant it in System Settings > Privacy & Security > Accessibility.

## How It Works

Diriger reads Chrome's profile data from `~/Library/Application Support/Google/Chrome/Local State`. When you select a profile:

- **Chrome not running**: Launches Chrome with `--profile-directory` to open the correct profile
- **Chrome running**: Activates Chrome and clicks the matching item in Chrome's Profiles menu via the Accessibility API

## Tech Stack

- Swift 5.9 / SwiftUI
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus

## License

MIT
