# Octodot

macOS menu bar app for GitHub notifications. SwiftUI views inside AppKit shell (NSPanel, NSStatusItem). No dock icon (LSUIElement).

## Build & Test

```bash
xcodebuild build -project Octodot.xcodeproj -scheme Octodot -configuration Debug -destination 'platform=macOS' -derivedDataPath .deriveddata
xcodebuild test -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata
```

Or via justfile: `just build`, `just test`. Dev loop: `./scripts/dev.sh` (builds, launches, watches).

Always rebuild after code changes so the user can test immediately. Use `killall -9 Octodot` to stop the running app (not `pkill`, which triggers Xcode debugger pause).

## Architecture

- **AppState** (`App/AppState.swift`): Central `@MainActor @Observable` model. Owns all notification data, selection, search, auth, background refresh. ~1200 lines. All UI state derives from here.
- **GitHubAPIClient** (`Auth/GitHubAPIClient.swift`): `actor` for thread-safe API calls with caching, pagination, conditional polling (`If-Modified-Since`/304), and rate limit awareness.
- **InboxStore** (`App/InboxStore.swift`): Manages inbox projection — tracks recent reads, pruning, security alert state. Persists to UserDefaults.
- **ThreadActionStore** (`App/ThreadActionStore.swift`): Optimistic actions (done, unsubscribe) with batched dispatch. Reconciles with server on refresh.
- **StatusItemController** (`Panel/StatusItemController.swift`): Menu bar icon, panel toggle, global hotkey (Carbon Events), right-click context menu, outside-click dismiss.
- **NotificationPanel** (`Panel/NotificationPanel.swift`): `NSPanel` hosting SwiftUI via `NSHostingView`. Floating, non-activating, status bar level.
- **PanelInput** (`Views/PanelInput.swift`): All keyboard routing. Vim-style (`j/k/d/x/u/o/gg/G`) plus standard shortcuts (`Cmd+Up/Down`, arrows, Page Up/Down).

## Patterns to Follow

- **@Observable + @MainActor** on all state classes. Use `@Bindable` in views for `$` bindings, plain `var` for read-only observation. Never use `@ObservedObject`/`ObservableObject`.
- **@State private** for view-local state only.
- **Dependency injection** via init parameters and closure typealiases (`SleepHandler`, `URLOpener`, `TokenSaver`, `APIClientFactory`). No singletons.
- **NetworkSession protocol** for testable networking. Production uses `URLSession.shared`, tests use `StubNetworkSession`.
- **Race condition prevention**: UUID-based `activeLoadRequestID` pattern — generate ID before async work, check it after `await`.
- **Narrow view dependencies**: Pass specific values to row views (`let notification`, `let isSelected`), not entire state objects.
- **Equatable views** for list performance (`NotificationRowView: View, Equatable`).

## Testing

Uses Swift Testing framework (`import Testing`, `@Test`, `#expect`). Not XCTest.

- **StubNetworkSession** / **DelayedStubNetworkSession** in `TestSupport.swift` for mocking.
- Factory methods in test files: `makeNotification()`, `makeState()`, `makeIsolatedUserDefaults()`.
- Isolated `UserDefaults(suiteName: UUID)` per test to prevent cross-contamination.
- Zero-delay sleep handlers in tests (`sleepHandler: { _ in }`).

## Key Conventions

- **Entitlements**: Network client only (no sandbox). Hardened runtime for notarization.
- **Token storage**: Keychain in release, file (`~/Library/Application Support/Octodot/.debug-token`) in debug.
- **Debug logging**: `DebugTrace.log()` — compiled out in release builds (`#if DEBUG`). Writes to `/tmp/octodot-debug-trace.log`.
- **Version config**: `OCTODOT_MARKETING_VERSION` in project.pbxproj. CI overrides from git tag.
- **New files**: Must be added to `project.pbxproj` manually (PBXFileReference, PBXBuildFile, PBXGroup children, PBXSourcesBuildPhase). Follow existing ID patterns (`AA00...` for refs, `BB00...` for build files).
- **Commit style**: Imperative mood, concise subject line. Body explains "why" not "what".
