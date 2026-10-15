# Architecture

This is a human-readable overview of how Claudio is put together. For the exhaustive, version-pinned account of Claude Code CLI behaviour the app depends on — the kind of detail that matters when you're changing how Claudio drives `claude` — see `CLAUDE.md`, which is written for Claude Code itself and kept in lockstep with the code.

## Two targets, one rule: logic lives in `ClaudioCore`

- **`ClaudioCore`** (library) holds the models, workspace operations, CLI command builders, parsers, persistence and `AppModel`, the `@Observable` main-actor model the whole UI reads. It builds and is tested on Linux, with no UI dependencies.
- **`Claudio`** (executable) is a thin SwiftUI/AppKit layer. Every file is wrapped in `#if os(macOS)`, and `LinuxStub.swift` provides `main` on Linux. It owns the SwiftTerm terminals (`TerminalRegistry`), notifications (`SessionNotifier`) and all views.

New behaviour goes in core, with tests; the UI only calls into `AppModel`.

```
Sources/ClaudioCore/          models, workspace ops, hooks, history, launch commands, AppModel
Sources/Claudio/              SwiftUI app (macOS only): SwiftTerm terminals, theme, bundled Nunito Sans (OFL)
Resources/Assets.xcassets/    app icon
Tests/ClaudioCoreTests/       XCTest suite and fixtures
design/                       Claude Design handoff (prototype HTML, chat transcript)
docs/                         this documentation
```

## Data model

Project (a working directory) → Folder (the user's grouping, nesting inside other folders without limit) → Session (one Claude Code conversation).

- A `Folder`'s `parentID` points at the folder it sits inside (`nil` at a project's top level). Storage stays the flat `Project.folders` array it always was; sibling order at any depth is relative order within that array.
- `Workspace.relocateFolder` is the one move primitive (reparent, optionally into a different project, then position among the new siblings); `moveFolder(toProject:)`, `moveFolder(intoFolder:)` and `moveFolder(before/after:inProject:)` are its public shapes.
- `Workspace` also holds the ordered open tabs (`openTabIDs`), spanning all folders. A tab is either a session id or an `OverviewTab` (a project's or folder's Pull Requests), so not every tab id is a session — see `Workspace.isTab`.
- `PersistedState` (workspace + `AppSettings`) is saved as JSON to `~/Library/Application Support/Claudio/state.json`. Decoding is tolerant: new fields use `decodeIfPresent` with defaults, and `PersistedState.currentVersion` handles migrations.

The Project Assistant's data (notes and plan items) is kept apart, per project, under `~/Library/Application Support/Claudio/assistant/<project id>/` — see [Project Assistant](project-assistant.md) and `design/Project Assistant Backend.md`.

## How sessions run

- New sessions are dispatched as background agents: `claude --bg --settings <hooks> -- "<prompt>"`, which prints an agent id. By default each works in its own git worktree, so sessions don't step on each other.
- A tab is a SwiftTerm terminal running `claude attach <id>` — the full interactive Claude Code UI, not a custom rendering of it.
- Closing a tab only detaches; stopping a session runs `claude stop`, deleting runs `claude rm`.
- If background agents are off or unsupported, a tab runs `claude --session-id`/`--resume` directly instead.

Command builders are `AgentCommands` and `TerminalLaunch` in `Agents.swift` and `ClaudeLaunch.swift`. They run through the login shell so `PATH` matches the user's terminal (frequent polling skips the login shell for speed).

## Where session status comes from

Three sources are merged in `AppModel`:

1. **Hooks.** `HookSettings` passes `--settings` JSON whose hooks append events to `hook-events.log`, polled every 0.5 s and fed to `HookReducer`.
2. **`claude agents --json --all`**, polled every 3 s. Gives liveness, process status and Claude Code's own view of the task.
3. **History files** in `~/.claude/projects/<cwd>/<sessionId>.jsonl`, read in the background every 30 s. Give titles, summaries, PR links and context estimates — but never override the status of a session that's live (a terminal here, or a running agent).

Plan usage (the 5-hour/weekly limits in the status bar) is a separate, fourth source: `claude -p /usage`, polled at launch and every 60 s, making no model call.

## Files on disk

| Path | Holds |
| --- | --- |
| `~/Library/Application Support/Claudio/state.json` | Workspace + app settings (`PersistedState`) |
| `~/Library/Application Support/Claudio/hook-events.log` | Raw hook events, polled by `AppModel` |
| `~/Library/Application Support/Claudio/usage.json` | The cost ledger: estimated API-rate cost per session, built from transcripts (see [Usage](features.md#usage)). **Not** plan usage — the session/weekly limits shown in the status bar are read fresh from `claude -p /usage` and never written to disk. |
| `~/Library/Application Support/Claudio/plugin/claudio/` | Claudio's Claude Code plugin, written at launch |
| `~/Library/Application Support/Claudio/assistant/<project id>/` | Project Assistant data — see [Project Assistant](project-assistant.md) |
| `~/Library/Logs/Claudio.log` | Everything in the Activity Log |
| `~/.claude/projects/<cwd>/<sessionId>.jsonl` | Claude Code's own conversation history (not Claudio's) |

Data from before the app's rename (the `SessionManager` folder) is moved into `~/Library/Application Support/Claudio/` on first launch.

## Observation churn

Polling runs constantly, so `AppModel` mutates a copy and assigns only when it differs — it never writes to observed state on every tick. Periodic work runs in `.task { await Polling.every(…) }` loops, never `onReceive(Timer.publish(…).autoconnect())`: a `.task` lasts as long as its view, but an `onReceive` timer is recreated whenever the view's body re-evaluates, which happens on every session change — so a frequently re-evaluated body (such as `ContentView`'s, which reads `model.settings`) restarted those timers before the longer ones could ever fire.
