# Diriger

A lightweight macOS menu bar app for working with multiple Google Chrome profiles.

## Features

- **Profile switcher in the menu bar** — every Chrome profile is listed with its picture; click to switch.
- **Global keyboard shortcuts** — bind a shortcut to each of your first ten profiles.
- **Launch at login** — optional.
- **Set Diriger as your default browser** — when another app opens an `http(s)` URL, Diriger decides where it goes.
- **Routing rules** — pre-defined rules send matching URLs straight to a specific profile. Rule kinds:
  - **Source** — match by the app that opened the link (e.g. Slack → Work profile).
  - **Domain** — exact host (`github.com`) or suffix (`*.example.com`).
  - **RegEx** — any regex matched against the full URL.
  - First matching rule wins. Rules are reorderable in Settings.
- **Link picker** — for any link that doesn't match a rule, a small picker appears at the cursor. Pick a profile with the mouse, arrow keys + Return, or the number keys (1–9, 0 for the tenth). `⌘C` copies the URL. `Esc` dismisses.
- Profiles are read live from Chrome's `Local State` — no manual configuration.

## Requirements

- macOS 14.0+
- Google Chrome (English-language menu bar; see *Limitations* below)
- Accessibility permission (prompted on first profile switch — needed to click Chrome's Profiles menu)

## Installation

### Homebrew

```bash
brew install volodymyrsmirnov/tap/diriger
```

### Download

1. Download the latest `.dmg` from [Releases](https://github.com/volodymyrsmirnov/diriger/releases/latest)
2. Open the `.dmg` and drag `Diriger.app` to `/Applications`

### Build from source

```bash
bash scripts/build-app.sh
```

Move the resulting `Diriger.app` to `/Applications`.

## Using Diriger as your default browser

Open Settings (menu bar → Settings…) and turn on **Use Diriger to open web links**. Any `http(s)` URL from another app is now handed to Diriger, which either applies a matching rule or shows the picker. Turning the toggle off hands the default role back to another installed browser.

Rules are only consulted when Diriger is the default browser. The Routing Rules section of Settings is disabled until then.

### Example rules

| Kind   | Pattern                | Profile |
|--------|------------------------|---------|
| Source | `com.tinyspeck.slackmacgap` | Work    |
| Domain | `*.corp.example.com`   | Work    |
| Domain | `github.com`           | Personal |
| RegEx  | `^https://mail\.google\.com/` | Personal |

## How profile switching works

Diriger reads Chrome's profile data from `~/Library/Application Support/Google/Chrome/Local State`.

- **Chrome not running**: launches Chrome with `--profile-directory` to open the correct profile.
- **Chrome running**: activates Chrome, then uses the Accessibility API to click the matching item in Chrome's Profiles menu. This is why the Accessibility permission is required.

## Limitations

- Profile switching clicks Chrome's "Profiles" menu by title and therefore requires Chrome to be running in English. If your Chrome UI is in another language, open links still work (they go via the CLI flag) but the menu-bar profile switcher won't.
- Diriger supports up to ten profile shortcuts (keys 1–9, 0). Additional profiles still appear in the menu bar and picker but can't have bound shortcuts.
- Chrome Beta / Canary / Dev / Chromium forks are not supported — Diriger targets stable Google Chrome (`com.google.Chrome`).

## Tech Stack

- Swift / SwiftUI on macOS 14+, strict concurrency enabled
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus

## License

MIT
