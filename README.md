# Octodot

Octodot is a native macOS menu bar app for triaging GitHub notifications with a keyboard-first workflow.

It is built for fast inbox processing:

- native SwiftUI/AppKit shell, no Electron or web wrapper
- `Inbox` and `Unread` views
- optimistic `done` and `unsubscribe` actions with undo
- background unread refresh and menu bar unread indicator
- Vim-style navigation and commands

## What It Does

Octodot lives in the macOS menu bar and opens a focused notifications panel. It is designed for quick review and triage without keeping the GitHub inbox open in a browser.

Current behavior includes:

- unread badge state in the menu bar icon
- `Inbox` and `Unread` inbox modes
- `Inbox` is designed to feel closer to GitHub's active inbox rather than a raw archive feed
- repository grouping with recency-aware ordering
- optimistic local actions that survive refreshes and relaunches
- search with explicit entry/exit behavior
- background polling that respects GitHub polling headers
- configurable global shortcut
- native settings window for account, appearance, and shortcuts
- pull request CI status indicators in the list
- Dependabot/security alerts layered into `Inbox`

## Authentication

Octodot currently uses a **classic GitHub Personal Access Token** with the `notifications` and `repo` scopes.

The app validates the token against GitHub, then stores it in the macOS Keychain.

## Inbox Model

Octodot has two modes:

- `Inbox`: the default view, mixing unread notifications with a recent inbox-style view of read items
- `Unread`: an exact unread notifications view from GitHub

Security alerts are shown in `Inbox` as a separate source:

- unread by default inside Octodot
- `o` opens and marks them read locally
- `d` dismisses them locally
- `u` restores a dismissed alert

They are intentionally not treated as normal GitHub notification threads.

## Shortcuts

The app is intentionally keyboard-centric.

- `j` / `k`: move selection
- `Up` / `Down`: move selection
- `ctrl-f` or `Space`: page down
- `ctrl-b`: page up
- `ctrl-d` / `ctrl-u`: half-page down / up
- `gg` / `G`: jump to top / bottom
- `Home` / `End`: jump to top / bottom
- `o` or `Return`: open in browser and mark read
- `d`: mark done
- `x`: unsubscribe
- `u`: undo queued action
- `y`: copy URL
- `a`: toggle `Inbox` / `Unread`
- `s`: toggle repo grouping
- `/`: enter search
- `return` or `tab` in search: keep filter, return to list
- `esc` in search: clear filter, return to list
- `r`: force refresh
- `Esc`: close panel

Global hotkey:

- configurable in Settings
- defaults to `⌘'`

## Settings

Octodot includes a native settings window with:

- `Account`: sign in, update token, sign out
- `Appearance`: `System`, `Light`, or `Dark`
- `Shortcuts`: global shortcut recorder and full panel keybinding reference

## Development

Requirements:

- macOS
- Xcode 17+

Run in Xcode:

1. Open `Octodot.xcodeproj`.
2. Build and run the `Octodot` scheme.
3. Sign in with a classic GitHub PAT that has the `notifications` and `repo` scopes.

Command line:

```sh
xcodebuild build -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata
xcodebuild test -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata
```

Convenience dev loop:

```sh
./scripts/dev.sh
```

This builds, launches, and watches for subsequent rebuilds.

## Project Structure

- `Octodot/App/AppState.swift`: app orchestration, fetching, polling, selection
- `Octodot/App/InboxStore.swift`: inbox projection and recent-read/security alert behavior
- `Octodot/App/ThreadActionStore.swift`: optimistic actions, undo, reconciliation
- `Octodot/Auth/GitHubAPIClient.swift`: GitHub API client and caching
- `Octodot/Panel/StatusItemController.swift`: menu bar item and panel lifecycle
- `Octodot/Views/PanelContentView.swift`: main panel UI and key routing
- `OctodotTests`: state, client, keychain, shell, and panel tests

## Test Coverage

The project includes focused tests for:

- optimistic mutation behavior
- refresh and reconciliation logic
- GitHub API caching and pagination
- inbox projection and recent inbox seeding
- security alert ingestion and local dismiss/read behavior
- pull request subject state and CI metadata
- keychain persistence
- panel key routing
- shell behavior, menu bar appearance, and settings preferences

The app also ships with:

- CI on pushes and pull requests
- a tag-driven release workflow that builds the macOS app and attaches the zip to GitHub releases
