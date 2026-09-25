# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Claudio is a native macOS app (SwiftUI, macOS 14+) for running and organising many Claude Code sessions. It drives the `claude` CLI: each tab is an embedded terminal attached to a Claude Code background agent. See `README.md` for the feature list, and `design/` for the original Claude Design handoff.

## Commands

```sh
swift test                                    # full suite (macOS, or Linux with a toolchain)
swift test --filter EnvironmentCheckTests     # one test class
swift test --filter EnvironmentCheckTests/testSignedOut   # one test
./scripts/test-linux.sh                       # no local toolchain: runs the suite in the swift:6.1-noble Docker image
./scripts/test-linux.sh --filter TitleSyncTests          # extra args are passed to `swift test`
swift run Claudio                             # run from the package (no notifications; see below)
./scripts/build-app.sh [--no-open]            # build/Claudio.app + zip; opens it unless --no-open or CI
```

- Behind an HTTPS proxy, `test-linux.sh` passes the proxy variables through, and mounts `$SSL_CERT_FILE` when that's set.
- CI (`.github/workflows/ci.yml`) runs the tests on Linux (`swift:6.1-noble`) and on macOS 15 (Xcode 16.4). The macOS job also runs `build-app.sh` and uploads `Claudio.zip`. The macOS job is the only place the SwiftUI layer gets compiled, so when working without a Mac, check its result after pushing UI changes.
- There's no linter. Keep builds warning-free.

## Architecture

**Two targets, one rule: logic lives in `ClaudioCore`.**
- `ClaudioCore` (library) builds and is tested on Linux. It holds the models, workspace operations, CLI command builders, parsers, persistence and `AppModel`, the `@Observable` main-actor model the whole UI reads.
- `Claudio` (executable) is a thin SwiftUI/AppKit layer. Every file is wrapped in `#if os(macOS)`, and `LinuxStub.swift` provides `main` on Linux. It owns the SwiftTerm terminals (`TerminalRegistry`), notifications (`SessionNotifier`) and all views.
- New behaviour goes in core, with tests. The UI calls into `AppModel`.

**Data model.** Project (a working directory) → Folder (the user's grouping) → Session (one Claude Code conversation). `Workspace` holds these and the ordered open tabs (`openTabIDs`), which span all folders. `PersistedState` (workspace + `AppSettings`) is saved as JSON to `~/Library/Application Support/Claudio/state.json`. Decoding is tolerant: new fields use `decodeIfPresent` with defaults, and `PersistedState.currentVersion` handles migrations.

**How sessions run.**
- New sessions are dispatched as background agents: `claude "<prompt>" --bg [--worktree name] --settings <hooks>`, which prints `backgrounded · <8-hex id>`.
- A tab is a SwiftTerm terminal running `claude attach <id>`. Closing a tab only detaches; stop is `claude stop`, delete is `claude rm`.
- Command builders are `AgentCommands` and `TerminalLaunch` in `Agents.swift` and `ClaudeLaunch.swift`. They run through the login shell so `PATH` matches the user's terminal. Frequent polling skips the login shell for speed.
- If background agents are off or unsupported, a tab runs `claude --session-id/--resume` directly.

**Where session status comes from.** Three sources are merged in `AppModel`:
1. **Hooks.** `HookSettings` passes `--settings` JSON whose hooks append `<app session UUID>\t<hook JSON>` lines to `hook-events.log`. `pollHookEvents` (every 0.5 s) feeds them to `HookReducer`. Events are routed by their own `session_id` first, not only by the app UUID, because a CLI-made copy inherits the original session's settings. See `hookTarget(for:)`.
2. **`claude agents --json --all`** (every 3 s), applied by `apply(_:)`. A session stays linked to the agent it's attached to; only unclaimed sessions are matched by conversation id.
3. **History files** in `~/.claude/projects/<cwd with non-alphanumerics → '-'>/<sessionId>.jsonl`, read by `SessionDiscovery` in the background (cached by mtime and size) every 30 s. They give titles, summaries, PR links, context estimates and imported sessions. They must never override the status of a session that's live (a terminal here, or a running agent). See `liveSessionIDs`.

The status line (`StatusLineCapture`) records `rate_limits` and `context_window` per session. Plan usage is also read at launch with `claude -p /usage`, which makes no model call.

**Observation churn.** Polling runs constantly, so mutate a copy and assign only when it differs; don't write to observed state on every tick. The menu bar reads only `menuFlags`, to stop menus redrawing.

## Claude Code CLI behaviour Claudio depends on

These were verified against real CLI output, which is recorded in `Tests/ClaudioCoreTests/Fixtures` and in the tests. Minimum version: 2.1.169, the first with `agents --json --all`.

- **Resuming a background agent with any flags starts a copy.** Claude Code prints `…the flags you passed started a copy as <id>`. So `resume(session:prompt:continuingAgent:)` passes no flags when continuing an existing agent. Copies are detected by `AgentListParser.copiedID` and kept as separate "(copy)" sessions.
- **Resuming a session that's open in an interactive terminal elsewhere also makes a copy.** Claudio asks the user first.
- **← on an empty prompt in an attached terminal switches to the agents view.** Its title is "claude agents". `AgentsViewDetector` and `TerminalRegistry.returnToSession` reattach the tab.
- **Titles.** `/rename` writes `{"type":"custom-title","customTitle":…,"sessionId":…}` to the history file. Claudio writes the same record when renaming (`SessionTitleWriter`) and follows new ones from the terminal. `Session.claudeTitle` stops a rename bouncing back and forth.
- **`claude auth status --json`** exits 1 when signed out but still prints JSON with `loggedIn: false`. `claude auth login` signs in (Console / API-key sign-in is tracked in issue #1).
- **Background agents live in `<repo>/.claude/worktrees/<name>`.** Their history directories are prefixed `<encoded repo>--claude-worktrees-`, and they're grouped under the repository's project.

To check CLI behaviour without touching the user's setup, install it in a container:

```sh
docker run --rm node:22-slim bash -c 'npm i -g @anthropic-ai/claude-code@<version> && claude …'
```

A fresh container is signed out, with an empty config. Any claim about CLI output should be backed by such a run or by output the user pasted.

## Testing conventions

- **Don't mark an `XCTestCase` subclass `@MainActor`: it breaks test discovery on Linux.** Hop inside the test instead: `try MainActor.assumeIsolated { … }`, `await MainActor.run { … }`, or `@MainActor` helper methods.
- `AppModel` is fully injectable: store, discovery home, hook log URL, command runner, `locateClaude`, `now`, `home`. Use `MemoryStore`, `FakeRunner` (canned CLI output, and it records the arguments it was called with) and `FakeTerminals`. `FakeRunner` and `FakeTerminals` are defined in `AgentModelTests.swift` and `AppModelTests.swift`.
- `model.terminals` is a weak reference, so keep `FakeTerminals` in a stored property.
- Some `internal` helpers exist only for tests: `applyStatus`, `applyNeedsAction`, `applyAgentLink`, `applyTestSession`.
- `AppModel` resets Working sessions to Completed at launch. Tests that need a non-completed session after init should use Awaiting Input.

## Build and dependency constraints

- The package is `swift-tools-version:5.10`, in Swift 5 language mode.
- SwiftTerm is pinned to `exact: "1.20.0"`, because newer versions need tools 6.2. It's a macOS-only dependency of the `Claudio` target.
- Notifications need the bundled `.app`, not `swift run`.
- `build-app.sh` signs with an Apple Development or Developer ID certificate if the keychain has one (override with `CODESIGN_IDENTITY`). Otherwise it signs ad hoc, and macOS then forgets folder-access and notification permissions on every rebuild.
- The app icon in `Resources/Assets.xcassets` is light only. The dark variant (`design/app-icon/`) needs an Icon Composer `.icon` file.

## Working in this repo

- Commit directly to `main`, then check the CI run for the commit, the macOS job in particular.
- Keep `README.md`'s feature list current when behaviour changes. Log user-visible actions and CLI commands in the Activity Log (`log.append`), but never account details (see `run(_:hideOutput:)`).
