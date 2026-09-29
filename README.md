# Claudio

Claudio is a native macOS app for running and organising many [Claude Code](https://claude.com/claude-code) sessions.

Sessions are grouped three levels deep:

- **Project**: a working directory.
- **Folder**: a group you name yourself, such as a change together with its PR review.
- **Session**: one Claude Code conversation.

Each session shows one of three states: **Working**, **Awaiting Input** or **Completed**.

The UI follows the Claude Design handoff in [`design/`](design/). It combines the full sidebar tree from option **1a** with option **1b**'s side-by-side sessions, grown into IDE-style panes, so a code session and its review can sit side by side.

## Features

- **Two rails** (design 8c, like PyCharm). Every control lives where its scope lives, and the side a tool is on tells you what it covers:
  - The **left rail** holds project tools: **Sessions** (the sidebar tree, ⌘1), **Pull Requests** (⌘2) and the **Assistant** (⌘3), with the **Shell** at its foot (⌃`; a badge counts hidden shells).
  - The **right rail** holds tools for the selected session: **Changes** (⌥⌘F, with a badge counting its files) and **Pull Request** (⌥⌘P). Both follow the focused tab. It shows only while a session's tab is selected; with an overview tab, or no tabs, it's hidden, and an open tool comes back with the next session.
  - Click a rail's tool to open it, and click it again to hide that side. Each side remembers its tool, and Claudio reopens them as you left them.
  - The session header holds only the session: its folder and name, role, context, status and **⋯** (Rename, Role, Move to Folder, Stop or Resume, and Delete).
  - The **status bar** across the foot of the window holds the app-wide figures: the status counts and plan usage.
- **Sidebar tree.** The left rail's Sessions tool: projects, folders and sessions in one list, with a filter field and live status dots and ages. Drag its edge to resize it.
  - Each project header shows how many of its sessions are Working, Awaiting Input and Completed, as coloured pills (a pill appears only when its count isn't zero); each folder shows the same for its own sessions. The pills count what the filters show (text, status and the recent-activity window), so they always match the list. The status bar shows the totals across all projects, following the text filter and the recent-activity window but not the status filter (its counts are that filter's buttons). The Dock badge counts every session awaiting input. Click a count in the status bar (or use the filter button in the filter field) to show only sessions with that status, which also brings up the Sessions tool if it's hidden; click it again to show all.
  - Only sessions active in the last 2 weeks are shown by default; sessions that are working, awaiting input, open in a tab or selected always show. The end of the list says how many are hidden, with Show All. Change the window (a preset or any number of days, or Any time) from the filter button or Settings → General.
  - A terminal icon beside a session means it's also open in a terminal outside Claudio. Its worktree and pull requests are in the right rail's Pull Request tool. Hover any icon, status dot or age for details.
  - Sessions that aren't in a folder appear under **Unfiled**.
- **Folders.** Create a folder with the folder-plus button or ⌥⌘N, then rename it in place (Return or a click elsewhere saves the name, Esc cancels). Double-click a folder to rename it later.
  - Drag sessions onto a folder to move them, or onto another session to reorder (it goes just above). Drop one on a project header to unfile it.
  - Drag a folder onto another folder (or one of its sessions) to put it just above, or onto a project header or Unfiled to move it, with its sessions, to the end of that project. Drag a project's header onto another project to take its place.
  - Click a folder, or Unfiled, to collapse or expand it.
  - Right-click a folder for Rename, New Session in Folder, Move to Project, Archive Completed and Delete Folder. Right-click a project for Archive Completed across all its folders and Unfiled.
- **Tabs and panes.** Sessions you open become tabs, across any folders and projects (like a browser); when they come from different folders each tab shows its folder. Arrange them like editor groups in an IDE:
  - Drag a tab onto the edge of any pane to dock it there, side by side or one above the other, in any mix of rows and columns. The drop area is highlighted before you let go. Drop it in the middle of a pane, or on its tab strip, to add it to that pane's tabs; drag along a strip to reorder. Sessions dragged from the sidebar open the same way.
  - Drag the dividers between panes to resize them. The layout, and the tab each pane shows, come back when Claudio reopens.
  - A pane closes when its last tab leaves. The focused pane (outlined, its tab underlined in teal) is the one the header, menus and new sessions use; click a pane to focus it.
  - Session → Split Right (`⌘\`) / Split Down (`⇧⌘\`), or Split Right / Split Down on a tab's right-click menu, move a tab into a new pane.
  - Close tabs with × or ⌘W; a closed tab's session keeps running. Right-click a tab for Close Other Tabs and Close Tabs to the Left / Right (within its pane), Close Completed Tabs and Close All Tabs.
- **Project Assistant** (design 9a, being built in steps; see `design/Project Assistant Backend.md`). The left rail's Assistant tool (⌘3) follows the selected session's project.
  - **Notes:** press ⇧⌘N anywhere (File → New Note) to open the capture box, linked to the session you're in. For a thought that isn't about that session, such as a new feature, click the × beside "Linked to…" to save it unlinked. Save Note (⌘↩) saves it straight away; Esc cancels. Notes are listed newest first, each with its author (you, the assistant or a session), the session it came from or was linked to, and its age. Notes the assistant or a session wrote have Undo. A note's **⋯** menu (top right, or right-click the card) copies it, checks it against the plan, adds it to the plan, attaches it to a plan item or detaches it, or deletes it.
  - **Plan:** the Plan | Notes switch shows the plan, grouped as In Session, Planned, Ideas and Done, each row with its notes count. The plan grows out of your notes: **Check Against Plan…** on a note (also in its ⋯ menu) checks it against the plan and suggests either a new item ("Create a plan item from this note?") or an existing one it duplicates ("Attach this note to an existing plan item?"). Each shows the assistant's reason ("Reads like a bug.") and the item it means on lines of their own. Nothing changes until you click Create Plan Item or Attach; Keep as Note dismisses it, and **Check Again** asks afresh. Suggestions stay on their notes across a relaunch, as long as they still apply. A promoted item takes the title the check suggested (or, without one, the note's first sentence) and goes in its session's folder. If you disagree with a suggested duplicate, **New Item Instead** makes a new item anyway, and **Add to Plan** (in a note's ⋯ menu) adds it without the check. Click an item for its status (change it from the pill), title (double-click to rename), folder and attached notes, or to delete it (its notes stay). Right-click a row to move it between statuses.
  - **The check:** one short Claude call (Haiku, no tools, nothing saved as a session). In a project set to Automatic (the default), a note you capture is checked straight away, while plan usage is under the threshold in **Settings › Assistant**. There you can also turn the assistant off everywhere (a note's link then reads **Add as Idea**, and adds it without asking Claude), set the threshold (80% of the 5-hour or weekly limit by default), and allow background work while using credits. Check Against Plan… that you press always runs. Each call is listed in the Activity Log.
  - **Start Session from a plan item:** a Planned item or Idea has **Start Session**, which opens New Session from Plan: its name, folder (the item's), role, worktree toggle, and a preview of the opening prompt, which is the item's title, its notes (oldest first) and its GitHub issue, then "Use these skills: /…" in blue. The skills are chips, picked in code from the project's approved skills (a skill's `paths` matching files the item's sessions changed, or its `metadata.claudio-folders` naming the item's folder; at most 3). Removing a chip only leaves that skill's name out of the prompt. The item then moves to In Session, and its view shows the session (click to open it) and the skills its prompt named. A session started before the assistant shows a hint instead, since it can't use skills or write notes. Approved skills come with a later step, so for now there are no chips.
  - **What sessions get:** every new session Claudio starts gets Claudio's plugin (`--plugin-dir`, written to `~/Library/Application Support/Claudio/plugin/claudio/` at launch) and the project's skills folder (`--add-dir`, `assistant/<project id>/skills`, whose `.claude/skills` holds approved skills). Resumed sessions never get them, because resuming a background agent with flags starts a copy. The plugin puts a `claudio` command on the session's Bash PATH, which the session may run without asking (its settings allow `Bash(claudio:*)`): `claudio plan` prints the plan with each item's id, `claudio item <id>` prints one item with its notes, and `claudio note "<text>"` (or `claudio note -` to read standard input) saves a note. Its `/claudio:note` skill tells the session when a note is worth writing. Notes a session writes appear marked with its name, have Undo, and join the plan item the session is working on. They go through `assistant/inbox.log`, which Claudio reads every half second and at launch, so notes written while Claudio was closed still arrive.
  - Notes and the plan are kept per project in `~/Library/Application Support/Claudio/assistant/<project id>/`: `assistant.json`; `audit.jsonl`, a log of every change and every call; and `suggestions.json`, the suggestions showing on notes; and `plan.md`, the copy `claudio plan` reads. An entry in `assistant.json` that can't be read is left as it was, and the panel counts it.
- **Shell** (design 7a). Your own login shell (`$SHELL -l`), separate from Claude, in a panel under all panes with its own tabs, like the terminal panel in VS Code or PyCharm. ⌃` (or the Shell button at the foot of the left rail) shows or hides it, and ⌃⇧` or + opens another shell. A new shell starts in the selected session's folder, or in its worktree when it has one. Each tab shows the folder's name and git branch. The panel stays open as you switch sessions, and hiding it keeps the shells running. Drag its top edge to resize it, or maximise it over the panes. Shells aren't sessions: they aren't saved, and they stay out of the sidebar and the status counts. Closing a shell (its ×, or ⌘W while it has the keyboard) ends it, and Claudio asks first if a command is still running. Typing `exit` closes its tab.
- **Files Changed** (designs 4 and 8c). Two scopes, switched in the Changes tool:
  - **This Session:** files the session's own Edit and Write tool calls changed (including its subagents'). Each file is compared from its state when the session first touched it to what's on disk now, so it works outside git. Only files inside the session's folder, or its project's folder, are listed. Claude Code's own files (such as `~/.claude/plans`), scratch files in `/tmp` and other sessions' worktrees are left out.
  - **Which folder:** Files Changed follows the session to where it's actually been working. That's the worktree of its latest edit (Claude may enter a worktree partway through, or a subagent may work in one), else its last working directory within the project. When that differs from the session's folder, the Changes tool says "In worktree …".
  - **vs main:** a git diff of the session's folder or worktree against where it branched from its base branch, including uncommitted and untracked files. The base is, in order:
    1. the base branch of the session's open pull request (merged or closed ones are ignored), found with the GitHub CLI (`gh pr view`, cached for 5 minutes) when `gh` is installed and signed in;
    2. the branch chosen for the project in the ▾ menu next to "vs";
    3. the repository's default branch (`origin/HEAD`, else `main`/`master`).

    The button shows the branch ("vs dev"), and its tooltip says where it came from. Each session remembers its last branch, and open tabs load in the background at launch, so switching sessions shows the right branch straight away (never a guessed "main"). Choosing another branch updates the label at once, and the lists show a spinner until the comparison is done. `.gitignore` is respected. As in `git status`, a folder that's entirely untracked (such as a leftover `node_modules`) is listed as one entry, and its files aren't read.

  The right rail's **Changes** tool (⌥⌘F) lists the selected session's files, each with its folder, a coloured A/M/D/R letter and its line counts. You can have it open beside the terminal. Click a file to show its full diff, with line numbers, in place of the session's terminal; **Close** brings the terminal back, which keeps running meanwhile. If the file drops out of the list, the pane says so (or why "vs" can't compare) rather than switching to another file. Right-click a file for Copy Path. Lists refresh after each tool call, and every 15 seconds for the selected session.
- **Pull Requests** (design 5). Pull requests are filled in with live GitHub data through the GitHub CLI (`gh`, which must be installed and signed in). A session is tied to a pull request only if it acted on it: opened it (`gh pr create`, or the GitHub MCP server's create tool), or reviewed, commented on, edited or merged it (`gh pr review/comment/edit/merge…`, `gh api` writes to `…/pulls/N/…`, GitHub MCP review tools). Links it merely saw, in `gh pr list` output, docs or Claude's replies, don't count, and nor do pull requests in any repository other than its project's (from `gh`, or the `origin` remote). Three scopes:
  - **Projects:** the left rail's **Pull Requests** tool lists each project's pull requests that its sessions opened or reviewed. With **Include PRs without a session** it also lists the project's other open ones. A switch above the list picks which: **Open** (the default), **Attention** (a failing check or changes requested), **Merged**, or **All**. Open ones come first, the most urgent at the top, and closed and merged ones are those updated within the sidebar's recent-activity window. Click a project's name to collapse or expand its list, or right-click it for Collapse All and Expand All. Claudio remembers the filter and which projects are collapsed. Each row gives its state in a few words (Checks failing, Changes requested, Approved, Merged…) and its folder. Click one for the session that worked on it, or, when no session did, for the project's overview. If loading fails, the project says why, or, when older data is showing, how old it is. The ↗ button beside a project's name (which also shows how many need attention and how many are listed) opens its overview, which shows the repository's pull requests in a table: its open ones (up to 100), its 40 most recent of any state, and older ones sessions acted on (up to 20 of those fetched with details per refresh). Columns are state, checks, review, the sessions on it, lines changed and last update. They're grouped by the folder of the session that opened them (else the first that reviewed them), then "No Session" for ones no session here opened or reviewed (hide those with **Include PRs without a session**). Filter by Needs Attention (open, with a failing check or changes requested), Open, Merged or All. With pull requests without a session included, the Open, Merged and All counts are GitHub's totals (one `gh api graphql` query). Merged and All then load the repository's older pull requests too (`gh pr list --state all`, at most 5,000; about 9 s for 1,200). Those come without checks, reviews or line counts, shown as "—", which load when the row is hovered for a moment or clicked; a click still goes where it always does. A failure shows red "—"s, whose tooltip says why. Clicking one of them only retries; clicking elsewhere on the row retries and goes where it always does. The older ones load again only when GitHub's totals have changed and some are still missing, at most every 2 minutes. If loading them fails, the note says why, and the refresh button tries again. While the list is short of the count (loading, failed, or past 5,000), a note under the table says how many are shown and links to the rest on GitHub. Click a row for its folder, or on GitHub when no session has it.
  - **Folder:** a folder's PR chip in the sidebar (`#1427 +1`, led by the open pull request that most needs doing, whose state colours its dot) opens a card per pull request: each check with its time, each reviewer's latest review, the sessions on it (click one to open it), and its unresolved review comments.
  - **Session:** the right rail's **Pull Request** tool (⌥⌘P) shows the state, checks, review and unresolved comments of each of the selected session's pull requests, with View Folder Overview and Open on GitHub. It also names the worktree the session works in.

  The project and folder overviews open as tabs in the focused pane, next to session tabs: drag one onto a pane's edge to dock it beside a session, and close it like any tab. Opening an overview that's already open shows its tab. While one has focus, the header shows where it is, when it was last updated, and Open on GitHub. The folder in a session's header opens its folder's overview. Pull requests reload every 2 minutes, or with the refresh button: `gh pr list` for the repository's open ones and its 40 most recent, `gh pr view` for older ones sessions acted on, and `gh api graphql` for the unresolved review threads of pull requests on screen (a folder's cards or the right rail's Pull Request tool), which reload every 2 minutes while they're shown, and with the refresh button. If a refresh fails, what loaded before stays, with a note saying what failed and how old it is. A project gh says has no GitHub repository isn't polled again (the refresh button still tries); other gh failures, such as being offline, are retried.
- **Context window.** The header shows how full the selected session's context window is: teal, then orange from 60%, red from 85%. Sessions started or resumed in Claudio report it exactly through Claude Code's status line. Claudio records the status line's data, then runs your own status line from `~/.claude/settings.json`, so what you see in the terminal is unchanged. For other sessions it's estimated from the token counts in their history, shown with a `~` and a fainter bar. History doesn't record the window size, so the estimate assumes 200k until usage passes that (or the model is a `[1m]` one).
- **Roles.** Optional labels for sessions (Code, Review, Research by default). Pick one in the New Session sheet, or change it later from the role tag in the session header ("Add Role" when there's none) or the Role submenu when you right-click a session or tab. Edit the list in Settings → Roles.
- **Claude Code background agents.** New sessions start (with Auto permissions by default) as background agents (`claude --bg`). By default each works in its own git worktree (`.claude/worktrees/<name>`), so sessions don't step on each other. The agent creates the worktree itself before its first edit, so it also commits (and pushes) its work there. Untick the worktree option to let it edit the project's checkout instead.
  - In the New Session sheet, ⌘Return starts the session, even while typing the initial prompt (where Return adds a line).
  - A tab is a terminal running `claude attach <id>`, so you get the full interactive Claude Code UI: slash-command autocomplete, `@` mentions, permission prompts, plan mode and pickers.
  - Claude Code stays open in its tab: a second Ctrl+C or Ctrl+D on an empty prompt, which would quit it, is ignored with a short hint (close the tab to detach, or use Stop Session). A single Ctrl+C still interrupts Claude or clears the prompt.
  - Shift+Enter adds a new line to the prompt instead of sending it, as in iTerm2 or Ghostty.
  - The terminal stays in its session. In Claude Code, ← on an empty prompt switches an attached terminal to its agents view; the app spots that (the terminal title becomes "claude agents") and reattaches the tab straight away, since the sidebar and tabs handle navigation. ← still moves the cursor as normal.
  - A session that isn't running shows its history with a message box: type and press Return to resume it with that message as the first prompt, or click Resume to resume without one.
  - Closing a tab only detaches; the agent keeps running and its sidebar status keeps updating. Quitting the app leaves agents running, and they reattach when you reopen them.
  - Agents you start elsewhere (`claude --bg`, the `claude agents` view) show up in their project automatically. Worktree sessions are grouped under their repository.
  - Sessions open in an interactive `claude` in a terminal get a live status and a terminal icon. Resuming one asks first, because it starts a copy of the conversation; the copy appears beside the original as "<name> (copy)".
  - Stop runs `claude stop`. Delete offers two choices. Remove from Claudio leaves the conversation and its agent in Claude Code, and File → Removed & Archived Sessions… restores it (to its folder, or Unfiled if that's gone). Remove from Claude Code and Claudio runs `claude rm` (which also removes the worktree when that's safe) and deletes the conversation's history files; that can't be undone. Either way, the session isn't imported again from its history file or the agent list. The same sheet unarchives archived sessions. A stopped session resumes in the background with `claude --bg --resume`.
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
- **PR links.** The pull requests a session opened or reviewed are collected, and the right rail's Pull Request tool (⌥⌘P) opens them on GitHub.
- **Plan usage.** The status bar shows how much of your 5-hour session and weekly limits you've used (`Session 80% · Week 11%`); click it for reset times and credits. If your account has usage credits (extra usage) turned on, it also shows this month's credit spend against your limit, and keeps showing it (in red) once the monthly spend limit is reached. When a plan limit is reached it's marked **Using credits** while credits remain, and **Out of credits** once they're spent. It's read at launch and every minute with `claude -p /usage`, which makes no model call, so figures are at most about a minute old. Your hooks are turned off for this check, so they don't run every minute. If it stops updating (signed out, or a problem with `claude`), the figures dim and the details say when they were last read, and a window whose reset time has passed shows as unused.
- **Notifications.** macOS notifications when a session needs your input or finishes (and, if you turn it on, when an agent stops unexpectedly). They're skipped for the session you're looking at while Claudio is in front; clicking one opens its session. Claudio also tells you when a plan limit you'd reached (the 5-hour session or the week) resets, as soon as its reset time passes or a reading shows it below the limit, even while Claudio is in front; resets are also noted in the Activity Log. Choose which ones, and whether they play a sound, in Settings. They need the bundled `Claudio.app` (not `swift run`), and macOS asks for permission on first launch.
- **Settings** (⌘,). A sidebar of pages, each with grouped rows:
  - **General:** the `claude` executable and Claude Code's setup checklist, the sidebar's recent-activity window, and where Claudio's data, its log and Claude Code's history are kept.
  - **New Sessions:** Direct or Background sessions, the default model, and default permissions for background agents (Auto) and for sessions run in a terminal.
  - **Notifications**, **Roles** and **About**.
- **Claude Code setup checks.** At launch (and when you come back to Claudio, at most every 5 minutes), Claudio checks three things:
  - that Claude Code is installed and runs (`claude --version`)
  - that you're signed in (`claude auth status`)
  - that it supports background agents (`claude agents`)

  The checklist also shows the GitHub CLI as an optional tool, with Install (Homebrew, or its download page) and Sign In (`gh auth login`). It's never counted as a problem.

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
- `claude agents --json` parsing (recorded output), background agent commands, worktree isolation, and the agent lifecycle in `AppModel`
- session discovery from `.jsonl` history
- launch arguments and executable lookup
- persistence
- notification rules (which status changes notify, and when they're suppressed)
- `AppModel` itself

```sh
swift test                        # macOS or Linux with a Swift toolchain
./scripts/test-linux.sh           # no local toolchain: runs in the swift:6.1 Docker image
```

GitHub Actions (`.github/workflows/ci.yml`) runs the suite on Linux and on macOS for every pull request and every push to `main`. On macOS it also builds the `.app` bundle and uploads it as an artifact, so a pull request's build can be downloaded and tried before merging.

## Contributing

Changes go through pull requests: branch from `main` (`feature/…`, `fix/…`, `ci/…`, `docs/…`), push the branch, and open a pull request into `main`. Merge once both CI jobs pass.

## Layout

```
Sources/ClaudioCore/          models, workspace ops, hooks, history, launch commands, AppModel
Sources/Claudio/              SwiftUI app (macOS only): SwiftTerm terminals, theme, bundled Nunito Sans (OFL)
Resources/Assets.xcassets/    app icon
Tests/ClaudioCoreTests/       XCTest suite and fixtures
design/                       Claude Design handoff (prototype HTML, chat transcript)
```
