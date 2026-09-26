# Claudio

Claudio is a native macOS app for running and organising many [Claude Code](https://claude.com/claude-code) sessions.

Sessions are grouped three levels deep:

- **Project**: a working directory.
- **Folder**: a group you name yourself, such as a change together with its PR review.
- **Session**: one Claude Code conversation.

Each session shows one of three states: **Working**, **Awaiting Input** or **Completed**.

The UI follows the Claude Design handoff in [`design/`](design/). It combines the full sidebar tree from option **1a** with the Split/Tabs view from option **1b**, so a code session and its review can sit side by side.

## Features

- **Sidebar tree.** Projects, folders and sessions in one list, with a filter field and live status dots and ages. Drag the divider to resize it.
  - Each project header shows how many of its sessions are Working, Awaiting Input and Completed, as coloured pills (a pill appears only when its count isn't zero); each folder shows the same for its own sessions. The pills count what the filters show (text, status and the recent-activity window), so they always match the list. The footer shows the totals across all projects, following the text filter and the recent-activity window but not the status filter (its counts are that filter's buttons). The Dock badge counts every session awaiting input. Click a count (or use the filter button in the filter field) to show only sessions with that status; click it again to show all.
  - Only sessions active in the last 2 weeks are shown by default; sessions that are working, awaiting input, open in a tab or selected always show. The end of the list says how many are hidden, with Show All. Change the window (a preset or any number of days, or Any time) from the filter button or Settings → General.
  - Icons beside a session: a terminal (also open in a terminal outside Claudio), a branch (runs in its own git worktree) and a pull request (with a count when there's more than one). Hover any icon, status dot or age for details.
  - Sessions that aren't in a folder appear under **Unfiled**.
- **Folders.** Create a folder with the folder-plus button or ⇧⌘N, then rename it in place. Double-click a folder to rename it later.
  - Drag sessions onto a folder to move them, or onto another session to reorder (it goes just above). Drop one on a project header to unfile it.
  - Click a folder, or Unfiled, to collapse or expand it.
  - Right-click a folder for Rename, New Session in Folder, Move to Project, Archive Completed and Delete Folder.
- **Tabs or Split.** Sessions you open become tabs, across any folders and projects (like a browser); when they come from different folders each tab shows its folder. Split shows up to four open tabs side by side. Toggle in the header, or with ⌥⌘1 / ⌥⌘2. Close tabs with × or ⌘W; a closed tab's session keeps running. Right-click a tab for Close Other Tabs, Close Tabs to the Left / Right, Close Completed Tabs and Close All Tabs.
- **Files Changed** (design 4a + 4b). Two scopes, switched in either view:
  - **This Session:** files the session's own Edit and Write tool calls changed (including its subagents'). Each file is compared from its state when the session first touched it to what's on disk now, so it works outside git.
  - **vs main:** a git diff of the session's folder or worktree against where it branched from the main branch (`origin/HEAD`, else `main`/`master`), including uncommitted and untracked files.

  The header's **Files +a −d** button (⌥⌘F) opens an inspector beside the terminal. It groups files by folder, with coloured A/M/D/R letters, and clicking a file shows a preview of its diff with Open Full Diff, Open in Editor and Reveal in Finder. The **Terminal / Changes** switch in the tab strip (⌥⌘C) swaps the pane for the Changes view: a filterable file list and the selected file's full diff with line numbers. Lists refresh after each tool call, and every 15 seconds for the selected session.
- **Context window.** Each session's header (and split pane) shows how full its context window is: teal, then orange from 60%, red from 85%. Sessions started or resumed in Claudio report it exactly through Claude Code's status line. For other sessions it's estimated from the token counts in their history, shown with a `~` and a fainter bar. History doesn't record the window size, so the estimate assumes 200k until usage passes that (or the model is a `[1m]` one).
- **Roles.** Optional labels for sessions (Code, Review, Research by default). Pick one in the New Session sheet, or change it later from the role tag in the session header ("Add Role" when there's none) or the Role submenu when you right-click a session or tab. Edit the list in Settings → Roles.
- **Claude Code background agents.** New sessions start (with Auto permissions by default) as background agents (`claude --bg`), each in its own git worktree (`.claude/worktrees/<name>`) by default, so sessions don't step on each other.
  - A tab is a terminal running `claude attach <id>`, so you get the full interactive Claude Code UI: slash-command autocomplete, `@` mentions, permission prompts, plan mode and pickers.
  - Claude Code stays open in its tab: a second Ctrl+C or Ctrl+D on an empty prompt, which would quit it, is ignored with a short hint (close the tab to detach, or use Stop Session). A single Ctrl+C still interrupts Claude or clears the prompt.
  - The terminal stays in its session. In Claude Code, ← on an empty prompt switches an attached terminal to its agents view; the app spots that (the terminal title becomes "claude agents") and reattaches the tab straight away, since the sidebar and tabs handle navigation. ← still moves the cursor as normal.
  - A session that isn't running shows its history with a message box: type and press Return to resume it with that message as the first prompt, or click Resume to resume without one.
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
- **Import Claude Code projects.** File → Import Claude Code Projects… (⇧⌘I) lists every project on this Mac that you've used Claude Code in and that isn't in the sidebar yet. It's offered automatically on first launch, and projects active in the last 30 days start out ticked. Folders listed in `~/.claude.json` are included even after Claude Code has cleaned up their history (after `cleanupPeriodDays`, 30 days by default); they show "No saved sessions". Projects whose folder no longer exists are hidden, and the sheet says how many.
- **Imports existing sessions.** Adding a project reads `~/.claude/projects/<project>/*.jsonl`, so sessions you started in a terminal appear too, with their titles, summaries, PR links and history.
  - Resuming an imported session uses `claude --resume`.
- **Names stay in step with Claude Code.** Renaming a session in Claudio sets its Claude Code title (the same `custom-title` record `/rename` writes), so `claude agents` and `claude --resume` use the new name. A `/rename` in the terminal renames the session in Claudio within about 30 seconds. A session named in the New Session sheet passes its name on once Claude Code has saved it.
- **PR links.** GitHub PR URLs that a session mentions are collected and can be opened from the header.
- **Plan usage.** The sidebar shows how much of your 5-hour session and weekly limits you've used, with reset times. It's read at launch and every 5 minutes with `claude -p /usage`, which makes no model call. Sessions started in Claudio also update it live through their status line: it records Claude Code's usage and context data, then runs your own status line from `~/.claude/settings.json`, so what you see in the terminal is unchanged.
- **Notifications.** macOS notifications when a session needs your input or finishes (and, if you turn it on, when an agent stops unexpectedly). They're skipped for the session you're looking at while Claudio is in front; clicking one opens its session. Choose which ones, and whether they play a sound, in Settings. They need the bundled `Claudio.app` (not `swift run`), and macOS asks for permission on first launch.
- **Settings** (⌘,). A sidebar of pages, each with grouped rows:
  - **General:** the `claude` executable and Claude Code's setup checklist, the sidebar's recent-activity window, and where Claudio's data, its log and Claude Code's history are kept.
  - **New Sessions:** Direct or Background sessions, plus the default model and permissions.
  - **Notifications**, **Roles** and **About**.
- **Claude Code setup checks.** At launch (and when you come back to Claudio, at most every 5 minutes), Claudio checks three things:
  - that Claude Code is installed and runs (`claude --version`)
  - that you're signed in (`claude auth status`)
  - that it supports background agents (`claude agents`)

  If something's wrong, a setup sheet lists each check with a fix: **Install** (Claude Code's install script), **Sign In** (`claude auth login`), **Update** (`claude update`) or **Choose…** (point Claudio at the executable). Fixes run in a terminal inside the sheet and everything is checked again when it exits. Other problems show as a banner at the bottom of the window. Without a working, signed-in Claude Code you can still browse sessions and history; starting or resuming a session opens the setup sheet instead. Without background agents, new sessions run directly in their tab. The same checklist is in Settings → General, and File → Claude Code Setup… opens the sheet. Account details from `claude auth status` aren't written to the Activity Log.
- **Folder access up front.** macOS asks before an app reads Documents, Desktop, Downloads, iCloud Drive or another volume, and there's no way to request that ahead of time. So at launch Claudio reads one project in each of those places, and any prompts appear together at startup instead of in the middle of an action.
- **Dock badge.** Shows how many sessions are awaiting input.
- **Activity Log.** Window → Activity Log (⌥⌘L) lists every command the app runs, with its exit code, duration and output, plus terminal launches and exits, and errors. Agent polling is only logged when its output changes. Everything is also appended to `~/Library/Logs/Claudio.log`.
- **App icon.** The light design (3b) from `Resources/Assets.xcassets`, compiled by `scripts/build-app.sh`. A classic `.appiconset` can't carry a dark variant, so the dark design (3a) is kept in `design/app-icon/` (SVG masters plus PNGs in `dark/`), ready for an Icon Composer `.icon` file.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 / Swift 5.10+ toolchain
- Claude Code CLI 2.1.169 or later (the first version with `claude agents --json --all`), installed and logged in. Older versions still run sessions, directly in their tab. Claudio checks this at launch. The app looks for it on `PATH`, in `~/.claude/local`, `~/.local/bin` and Homebrew, or you can set the path in **Settings**.

## Build and run

```sh
swift run Claudio                 # run directly from the package
./scripts/build-app.sh            # build/Claudio.app (+ .zip), then open it
./scripts/build-app.sh --no-open  # build only
```

`build-app.sh` signs the app with your Apple Development (or Developer ID) certificate if you have one, so macOS remembers the folder and notification permissions you grant between builds. Without one it signs ad hoc, and macOS asks again after each rebuild. To get a certificate, sign in to Xcode with your Apple ID (Settings → Accounts). To choose one, set `CODESIGN_IDENTITY`.

App state (projects, folders, names, settings) is saved to `~/Library/Application Support/Claudio/state.json`. Hook events (`hook-events.log`) and the latest plan usage (`usage.json`) are written to the same folder. Data from before the rename (the `SessionManager` folder) is moved there on first launch. Conversation history stays in Claude Code's own store.

## Tests

The project is built test-first. All logic lives in the platform-independent `ClaudioCore` target, and the SwiftUI layer stays a thin view over `AppModel`. The core tests cover:

- workspace operations
- hook event parsing and status reduction, using fixtures recorded from real `claude` runs
- JSONL history parsing and transcript building
- terminal launch commands, including shell quoting and hook commands run in a real shell
- `claude agents --json` parsing (recorded output), background agent commands, worktree naming, and the agent lifecycle in `AppModel`
- session discovery from `.jsonl` history
- launch arguments and executable lookup
- persistence
- notification rules (which status changes notify, and when they're suppressed)
- `AppModel` itself

```sh
swift test                        # macOS or Linux with a Swift toolchain
./scripts/test-linux.sh           # no local toolchain: runs in the swift:6.1 Docker image
```

GitHub Actions (`.github/workflows/ci.yml`) runs the suite on Linux and on macOS. On macOS it also builds the `.app` bundle and uploads it as an artifact.

## Layout

```
Sources/ClaudioCore/          models, workspace ops, hooks, history, launch commands, AppModel
Sources/Claudio/              SwiftUI app (macOS only): SwiftTerm terminals, theme, bundled Nunito Sans (OFL)
Resources/Assets.xcassets/    app icon
Tests/ClaudioCoreTests/       XCTest suite and fixtures
design/                       Claude Design handoff (prototype HTML, chat transcript)
```
