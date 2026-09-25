# Session Manager

A native macOS app for running and organising many [Claude Code](https://claude.com/claude-code) sessions.

Sessions are grouped three levels deep:

- **Project**: a working directory.
- **Folder**: a group you name yourself, such as a change together with its PR review.
- **Session**: one Claude Code conversation.

Each session shows one of three states: **Working**, **Awaiting Input** or **Completed**.

The UI follows the Claude Design handoff in [`design/`](design/). It combines the full sidebar tree from option **1a** with the Split/Tabs view from option **1b**, so a code session and its review can sit side by side.

## Features

- **Sidebar tree.** Projects, folders and sessions in one list, with a filter field and live status dots and ages.
  - The footer counts Working / Awaiting Input / Completed sessions.
  - Sessions that aren't in a folder appear under **Unfiled**.
- **Folders.** Create a folder with the folder-plus button or ⇧⌘N, then rename it in place. Double-click a folder to rename it later.
  - Drag sessions onto a folder to move them. Drop one on a project header to unfile it.
  - Right-click a folder for Rename, New Session in Folder, Move to Project, Archive Completed and Delete Folder.
- **Tabs or Split.** The other sessions in the selected session's folder show as tabs, or as side-by-side panes. Toggle between them in the header, or with ⌥⌘1 / ⌥⌘2.
- **Real Claude Code sessions.** Each session runs `claude -p --input-format stream-json --output-format stream-json`. The app shows its transcript (`>` prompt, `⏺` tool call, `*` reply) and gives you a composer to reply, or to interrupt with esc.
  - Status comes from Claude Code's own `post_turn_summary` events. A `blocked` event means Awaiting Input.
- **Imports existing sessions.** Adding a project reads `~/.claude/projects/<project>/*.jsonl`, so sessions you started in a terminal appear too, with their titles, summaries, PR links and history.
  - Replying to an imported session resumes it with `--resume`.
- **PR links.** GitHub PR URLs that a session mentions are collected and can be opened from the header.
- **Dock badge.** Shows how many sessions are awaiting input.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 / Swift 5.10+ toolchain
- Claude Code CLI installed and logged in. The app looks for it on `PATH`, in `~/.claude/local`, `~/.local/bin` and Homebrew, or you can set the path in **Settings**.

## Build and run

```sh
swift run SessionManager          # run directly from the package
./scripts/build-app.sh            # build/Session Manager.app (+ .zip)
```

App state (projects, folders, names, settings) is saved to `~/Library/Application Support/SessionManager/state.json`. Conversation history stays in Claude Code's own store.

## Tests

The project is built test-first. All logic lives in the platform-independent `SessionManagerCore` target, and the SwiftUI layer stays a thin view over `AppModel`. The core tests cover:

- workspace operations
- stream-json parsing, using a fixture recorded from a real `claude` run
- transcript building and status reduction
- session discovery from `.jsonl` history
- launch arguments and executable lookup
- persistence
- the process runner, run against a fake `claude` script
- `AppModel` itself

```sh
swift test                        # macOS or Linux with a Swift toolchain
./scripts/test-linux.sh           # no local toolchain: runs in the swift:6.1 Docker image
```

GitHub Actions (`.github/workflows/ci.yml`) runs the suite on Linux and on macOS. On macOS it also builds the `.app` bundle and uploads it as an artifact.

## Layout

```
Sources/SessionManagerCore/   models, workspace ops, stream-json, discovery, process, AppModel
Sources/SessionManager/       SwiftUI app (macOS only), theme and bundled Nunito Sans (OFL)
Tests/SessionManagerCoreTests/ XCTest suite and fixtures
design/                       Claude Design handoff (prototype HTML, chat transcript)
```
