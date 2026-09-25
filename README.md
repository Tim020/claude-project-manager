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
- **Claude Code background agents.** New sessions start as background agents (`claude --bg`), each in its own git worktree (`.claude/worktrees/<name>`) by default, so sessions don't step on each other.
  - A tab is a terminal running `claude attach <id>`, so you get the full interactive Claude Code UI: slash-command autocomplete, `@` mentions, permission prompts, plan mode and pickers.
  - Closing a tab only detaches; the agent keeps running and its sidebar status keeps updating. Quitting the app leaves agents running, and they reattach when you reopen them.
  - Agents you start elsewhere (`claude --bg`, the `claude agents` view) show up in their project automatically. Worktree sessions are grouped under their repository.
  - Sessions open in an interactive `claude` in a terminal get a live status and a terminal icon. Resuming one asks first, because it starts a copy of the conversation; the copy appears beside the original as "<name> (copy)".
  - Stop runs `claude stop`, and Delete runs `claude rm`, which also removes the worktree when that's safe. A stopped session resumes in the background with `claude --bg --resume`.
  - Commands run through your login shell, so your `PATH` and node setup match your terminal. You can turn background agents off in Settings; tabs then run `claude` directly.
- **Live status.** `claude agents --json --all` is polled every 3 seconds for liveness, state and titles. Claude Code hooks, passed with `--settings` to the sessions the app launches, give instant updates:
  - Prompts and tool use mark a session **Working**.
  - A permission request, or a reply that ends in a question, marks it **Awaiting Input**.
  - A finished turn marks it **Completed**, and Claude's last message becomes the summary.
  - Your own hook settings are left untouched.
- **Import Claude Code projects.** File → Import Claude Code Projects… (⇧⌘I) lists every project on this Mac that you've used Claude Code in and that isn't in the sidebar yet. It's offered automatically on first launch, and projects active in the last 30 days start out ticked.
- **Imports existing sessions.** Adding a project reads `~/.claude/projects/<project>/*.jsonl`, so sessions you started in a terminal appear too, with their titles, summaries, PR links and history.
  - Resuming an imported session uses `claude --resume`.
- **PR links.** GitHub PR URLs that a session mentions are collected and can be opened from the header.
- **Dock badge.** Shows how many sessions are awaiting input.
- **App icon.** The light design (3b) from `Resources/Assets.xcassets`, compiled by `scripts/build-app.sh`. A classic `.appiconset` can't carry a dark variant, so the dark design (3a) is kept in `design/app-icon/` (SVG masters plus PNGs in `dark/`), ready for an Icon Composer `.icon` file.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 / Swift 5.10+ toolchain
- Claude Code CLI installed and logged in. The app looks for it on `PATH`, in `~/.claude/local`, `~/.local/bin` and Homebrew, or you can set the path in **Settings**.

## Build and run

```sh
swift run SessionManager          # run directly from the package
./scripts/build-app.sh            # build/Session Manager.app (+ .zip), then open it
./scripts/build-app.sh --no-open  # build only
```

App state (projects, folders, names, settings) is saved to `~/Library/Application Support/SessionManager/state.json`, and hook events are written to `hook-events.log` in the same folder. Conversation history stays in Claude Code's own store.

## Tests

The project is built test-first. All logic lives in the platform-independent `SessionManagerCore` target, and the SwiftUI layer stays a thin view over `AppModel`. The core tests cover:

- workspace operations
- hook event parsing and status reduction, using fixtures recorded from real `claude` runs
- JSONL history parsing and transcript building
- terminal launch commands, including shell quoting and hook commands run in a real shell
- `claude agents --json` parsing (recorded output), background agent commands, worktree naming, and the agent lifecycle in `AppModel`
- session discovery from `.jsonl` history
- launch arguments and executable lookup
- persistence
- `AppModel` itself

```sh
swift test                        # macOS or Linux with a Swift toolchain
./scripts/test-linux.sh           # no local toolchain: runs in the swift:6.1 Docker image
```

GitHub Actions (`.github/workflows/ci.yml`) runs the suite on Linux and on macOS. On macOS it also builds the `.app` bundle and uploads it as an artifact.

## Layout

```
Sources/SessionManagerCore/   models, workspace ops, hooks, history, launch commands, AppModel
Sources/SessionManager/       SwiftUI app (macOS only): SwiftTerm terminals, theme, bundled Nunito Sans (OFL)
Resources/Assets.xcassets/    app icon
Tests/SessionManagerCoreTests/ XCTest suite and fixtures
design/                       Claude Design handoff (prototype HTML, chat transcript)
```
