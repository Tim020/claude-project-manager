# Claudio

Claudio is a native macOS app for running and organising many [Claude Code](https://claude.com/claude-code) sessions.

Sessions are grouped three levels deep:

- **Project**: a working directory.
- **Folder**: a group you name yourself, such as a change together with its PR review. Folders nest inside folders without limit.
- **Session**: one Claude Code conversation.

Each session shows one of three states: **Working**, **Awaiting Input** or **Completed**.

The UI follows the Claude Design handoff in [`design/`](design/): the full sidebar tree from option **1a** with option **1b**'s side-by-side sessions, grown into IDE-style panes, so a code session and its review can sit side by side.

## Highlights

See [`docs/features.md`](docs/features.md) for the full list, with every detail and design decision behind it.

- **Two rails** either side of the window: project tools (Sessions, Pull Requests, Assistant, Usage, Shell) on the left, tools for the selected session (Changes, Pull Request, Usage) on the right.
- **Tabs and panes** like an IDE — split, dock and drag sessions into any layout of rows and columns.
- A **Project Assistant** that turns your notes into a plan, follows up on finished sessions, and drafts reusable skills from lessons learned the hard way.
- **Files Changed** and **Pull Requests** tools, backed by git and the GitHub CLI, scoped to a session, a folder or a whole project.
- Sessions run as **Claude Code background agents** (`claude --bg`), each in its own git worktree by default, so you get the full interactive Claude Code UI in a tab you can close and reopen.
- **Live status** (Working / Awaiting Input / Completed) from Claude Code's hooks and `claude agents --json`, plus context-window and plan-usage readouts in the header and status bar.
- **Usage**: what your sessions would cost at API rates, broken down by project, folder, model and session.
- Imports sessions you started outside Claudio, keeps titles in step with `/rename`, and sends macOS notifications when a session needs you.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 / Swift 5.10+ toolchain
- Claude Code CLI 2.1.169 or later (the first version with `claude agents --json --all`), installed and logged in. Older versions still run sessions, directly in their tab. Claudio checks this at launch. The app looks for it on `PATH`, in `~/.claude/local`, `~/.local/bin` and Homebrew, or you can set the path in **Settings**.

## Build and run

```sh
swift run Claudio                 # run directly from the package (no notifications; those need the .app)
./scripts/build-app.sh            # build/Claudio.app (+ .zip), then open it
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for signing, so macOS remembers folder and notification permissions between rebuilds.

App state (projects, folders, names, settings) is saved to `~/Library/Application Support/Claudio/state.json`; conversation history stays in Claude Code's own store. See [`docs/architecture.md`](docs/architecture.md) for the full picture of what's kept where.

## Documentation

- [`docs/features.md`](docs/features.md) — the full feature list and the design decisions behind it
- [`docs/architecture.md`](docs/architecture.md) — the two-target split, data model, how sessions run, where status comes from, and what's on disk
- [`docs/testing.md`](docs/testing.md) — running the test suite and the conventions it follows
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — branches, PRs, CI and local builds
- [`CLAUDE.md`](CLAUDE.md) — the exhaustive, version-pinned log of Claude Code CLI behaviour Claudio depends on, written for Claude Code itself
- [`design/`](design/) — the original Claude Design handoff (prototype HTML, chat transcripts)
