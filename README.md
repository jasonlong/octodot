# Octodot

Octodot is a native macOS menu bar app for triaging GitHub notifications with a keyboard-first workflow.

It is built for fast inbox processing:

- native SwiftUI/AppKit shell, no Electron or web wrapper
- unread and all views
- optimistic `done`, `mark read`, and `unsubscribe` actions with undo
- background unread refresh and menu bar unread indicator
- Vim-style navigation and commands

## What It Does

Octodot lives in the macOS menu bar and opens a focused notifications panel. It is designed for quick review and triage without keeping the GitHub inbox open in a browser.

Current behavior includes:

- unread badge state in the menu bar icon
- `Unread` and `All` inbox modes
- `All` mode limited to the last 30 days to avoid turning into an archive
- repository grouping with recency-aware ordering
- optimistic local actions that survive refreshes and relaunches
- search with explicit entry/exit behavior
- background polling that respects GitHub polling headers

## Authentication

Octodot currently uses a **classic GitHub Personal Access Token** with the `notifications` scope.

The app validates the token against GitHub, then stores it in the macOS Keychain.

## Shortcuts

The app is intentionally keyboard-centric.

- `j` / `k`: move selection
- `gg` / `G`: jump to top / bottom
- `o` or `Return`: open in browser
- `d`: mark done
- `m`: mark read
- `x`: unsubscribe
- `u`: undo queued action
- `a`: toggle `Unread` / `All`
- `/`: enter search
- `Enter` in search: keep filter, return to list
- `Esc` in search: clear filter, return to list
- `r`: force refresh
- `Esc`: close panel

Global hotkey:

- `Control + Option + N`: toggle the panel

## Development

Requirements:

- macOS
- Xcode 17+

Run in Xcode:

1. Open `Octodot.xcodeproj`.
2. Build and run the `Octodot` scheme.
3. Sign in with a classic GitHub PAT that has the `notifications` scope.

Command line:

```sh
xcodebuild build -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata
xcodebuild test -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata
```

## Project Structure

- `Octodot/App/AppState.swift`: app state, fetching, optimistic actions, polling
- `Octodot/Auth/GitHubAPIClient.swift`: GitHub API client and caching
- `Octodot/Panel/StatusItemController.swift`: menu bar item and panel lifecycle
- `Octodot/Views/PanelContentView.swift`: main panel UI and key routing
- `OctodotTests`: state, client, keychain, shell, and panel tests

## Test Coverage

The project includes focused tests for:

- optimistic mutation behavior
- refresh and reconciliation logic
- GitHub API caching and pagination
- keychain persistence
- panel key routing
- shell behavior and menu bar appearance

At the moment of publishing, the full suite passes locally via `xcodebuild test`.
