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

- **AppState** (`App/AppState.swift`): Central `@MainActor @Observable` model. Owns all notification data, selection, search, auth, and background refresh. All UI state derives from here.
- **GitHubAPIClient** (`Auth/GitHubAPIClient.swift`): `actor` for thread-safe API calls with caching, pagination, conditional polling (`If-Modified-Since`/304), and rate limit awareness.
- **InboxStore** (`App/InboxStore.swift`): Manages inbox projection — tracks recent reads, pruning, security alert state. Persists to UserDefaults.
- **ThreadActionStore** (`App/ThreadActionStore.swift`): Optimistic actions (mark read, done, unsubscribe) with batched dispatch. Reconciles with server on refresh.
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
- **Narrow row inputs** for list performance; keep list rows independent from the full app state.

## Testing

Uses Swift Testing framework (`import Testing`, `@Test`, `#expect`). Not XCTest.

- **StubNetworkSession** / **DelayedStubNetworkSession** in `TestSupport.swift` for mocking.
- Factory methods in test files: `makeNotification()`, `makeState()`, `makeIsolatedUserDefaults()`.
- Isolated `UserDefaults(suiteName: UUID)` per test to prevent cross-contamination.
- Zero-delay sleep handlers in tests (`sleepHandler: { _ in }`).

## Key Conventions

- **Entitlements**: Network client only (no sandbox). Hardened runtime for notarization.
- **Token storage**: Keychain in release, file (`~/Library/Application Support/Octodot/.debug-token`) in debug.
- **Debug logging**: `DebugTrace.log()` — compiled out in release builds (`#if DEBUG`). Writes to the current user's temporary directory.
- **Version config**: `OCTODOT_MARKETING_VERSION` in project.pbxproj. CI overrides from git tag.
- **New files**: Must be added to `project.pbxproj` manually (PBXFileReference, PBXBuildFile, PBXGroup children, PBXSourcesBuildPhase). Follow existing ID patterns (`AA00...` for refs, `BB00...` for build files).
- **Commit style**: Imperative mood, concise subject line. Body explains "why" not "what".


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
