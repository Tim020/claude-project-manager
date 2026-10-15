# Features

The full feature list, in detail. For the short version, see the [README](../README.md). The UI follows the Claude Design handoff in [`design/`](../design/); it combines the full sidebar tree from option **1a** with option **1b**'s side-by-side sessions, grown into IDE-style panes, so a code session and its review can sit side by side.

- [Two rails](#two-rails)
- [Sidebar tree](#sidebar-tree)
- [Folders](#folders)
- [Tabs and panes](#tabs-and-panes)
- [Project Assistant](#project-assistant)
- [Shell](#shell)
- [Files Changed](#files-changed)
- [Pull Requests](#pull-requests)
- [Context window](#context-window)
- [Tags](#tags)
- [Claude Code background agents](#claude-code-background-agents)
- [Live status](#live-status)
- [Import Claude Code projects](#import-claude-code-projects)
- [Imports existing sessions](#imports-existing-sessions)
- [Names stay in step with Claude Code](#names-stay-in-step-with-claude-code)
- [PR links](#pr-links)
- [Plan usage](#plan-usage)
- [Usage](#usage)
- [Notifications](#notifications)
- [Settings](#settings)
- [Claude Code setup checks](#claude-code-setup-checks)
- [Folder access up front](#folder-access-up-front)
- [Dock badge](#dock-badge)
- [Activity Log](#activity-log)
- [App icon](#app-icon)

## Two rails

Design 8c, like PyCharm. Every control lives where its scope lives, and the side a tool is on tells you what it covers:

- The **left rail** holds project tools: **Sessions** (the sidebar tree, ⌘1), **Pull Requests** (⌘2), the **Assistant** (⌘3) and **Usage** (⌘4), with the **Shell** at its foot (⌃`; a badge counts hidden shells).
- The **right rail** holds tools for the selected session: **Changes** (⌥⌘F, with a badge counting its files), **Pull Request** (⌥⌘P) and **Usage** (⌥⌘U). Both follow the focused tab. It shows only while a session's tab is selected; with an overview tab, or no tabs, it's hidden, and an open tool comes back with the next session.
- Click a rail's tool to open it, and click it again to hide that side. Each side remembers its tool, and Claudio reopens them as you left them.
- The session header holds only the session: its folder and name, tags, context, status and **⋯** (Rename, Tags, Move to Folder, Review This Session, Stop or Resume, Archive, and Delete). Archive takes the session out of the sidebar and its tab; a running one is stopped first (the item says **Stop and Archive Session**). File › Removed & Archived Sessions… brings it back. The same menu opens when you right-click a session in the sidebar.
- The **status bar** across the foot of the window holds the app-wide figures: the status counts and plan usage.
- The window's close, minimise and full-screen buttons sit in a strip of their own across the top, so the rails and headers never run under them.

## Sidebar tree

The left rail's Sessions tool: projects, folders and sessions in one list, with a filter field and live status dots and ages. Drag its edge to resize it.

- Each project header shows how many of its sessions are Working, Awaiting Input and Completed, as coloured pills (a pill appears only when its count isn't zero); each folder shows the same for its whole subtree, including whatever's nested inside it. The pills count what the filters show (text, status and the recent-activity window), so they always match the list. The status bar shows the totals across all projects, following the text filter and the recent-activity window but not the status filter (its counts are that filter's buttons). The Dock badge counts every session awaiting input. Click a count in the status bar (or use the filter button in the filter field) to show only sessions with that status, which also brings up the Sessions tool if it's hidden; click it again to show all.
- Only sessions active in the last 2 weeks are shown by default; sessions that are working, awaiting input, open in a tab or selected always show. A folder stays in the sidebar even once every session in it has aged out — it just shows none, rather than disappearing. The end of the list says how many sessions are hidden, with Show All. Change the window (a preset or any number of days, or Any time) from the filter button or Settings → General.
- A terminal icon beside a session means it's also open in a terminal outside Claudio. Its worktree and pull requests are in the right rail's Pull Request tool. Hover any icon, status dot or age for details.
- Sessions that aren't in a folder appear under **Unfiled**.

## Folders

Create a folder with the folder-plus button or ⌥⌘N, then rename it in place (Return or a click elsewhere saves the name, Esc cancels). Double-click a folder to rename it later. Folders nest inside folders without limit; nesting steps the indent in by less than a top-level folder, and stops stepping in past a few levels, so a deep tree still reads cleanly. Pickers and breadcrumbs that aren't in the tree itself (New Session, Start Session from a plan item, the pull request overview, a session's header) spell out a nested folder's full path ("Backend › Auth › OAuth") since the tree's indentation isn't there to show it.

- Drag sessions onto a folder to move them, or onto another session to reorder (it goes just above). Drop one on a project header to unfile it.
- Drag a folder onto another folder's row to nest it inside, as its last subfolder. Drop near that row's top or bottom edge instead to put it just before or after as a sibling (same nesting level), rather than inside. Dropping on a project header or Unfiled moves it, with its whole subtree, to the end of that project's top level. Drag a project's header onto another project to take its place. A folder can't be dropped into itself or one of its own subfolders.
- Click a folder, or Unfiled, to collapse or expand it; collapsing hides everything nested inside it too.
- Right-click a folder for Rename, New Session in Folder, New Subfolder, Default Tags, Move to Folder (nest it inside another one in the project), Move to Project, Archive Completed (its whole subtree) and Delete Folder. Deleting a folder that has anything in it (sessions or subfolders, at any depth) asks whether to move its contents up one level or unfile everything inside it; an empty folder just goes. Right-click a project for Archive Completed across all its folders and Unfiled.

## Tabs and panes

Sessions you open become tabs, across any folders and projects (like a browser); when they come from different folders each tab shows its folder. Arrange them like editor groups in an IDE:

- Drag a tab onto the edge of any pane to dock it there, side by side or one above the other, in any mix of rows and columns. The drop area is highlighted before you let go. Drop it in the middle of a pane, or on its tab strip, to add it to that pane's tabs; drag along a strip to reorder. Sessions dragged from the sidebar open the same way.
- Drag the dividers between panes to resize them. The layout, and the tab each pane shows, come back when Claudio reopens.
- A pane closes when its last tab leaves. The focused pane (outlined, its tab underlined in teal) is the one the header, menus and new sessions use; click a pane to focus it.
- Session → Split Right (`⌘\`) / Split Down (`⇧⌘\`), or Split Right / Split Down on a tab's right-click menu, move a tab into a new pane.
- Close tabs with × or ⌘W; a closed tab's session keeps running. Right-click a tab for Close Other Tabs and Close Tabs to the Left / Right (within its pane), Close Completed Tabs and Close All Tabs.

## Project Assistant

Notes, a plan, follow-ups and skills built on top of sessions — see [Project Assistant](project-assistant.md) for the full detail.

## Shell

Design 7a. Your own login shell (`$SHELL -l`), separate from Claude, in a panel under all panes with its own tabs, like the terminal panel in VS Code or PyCharm. ⌃` (or the Shell button at the foot of the left rail) shows or hides it, and ⌃⇧` or + opens another shell. A new shell starts in the selected session's folder, or in its worktree when it has one. Each tab shows the folder's name and git branch. The panel stays open as you switch sessions, and hiding it keeps the shells running. Drag its top edge to resize it, or maximise it over the panes. Shells aren't sessions: they aren't saved, and they stay out of the sidebar and the status counts. Closing a shell (its ×, or ⌘W while it has the keyboard) ends it, and Claudio asks first if a command is still running. Typing `exit` closes its tab.

## Files Changed

Designs 4 and 8c. Two scopes, switched in the Changes tool:

- **This Session:** files the session's own Edit and Write tool calls changed (including its subagents'). Each file is compared from its state when the session first touched it to what's on disk now, so it works outside git. Only files inside the session's folder, or its project's folder, are listed. Claude Code's own files (such as `~/.claude/plans`), scratch files in `/tmp` and other sessions' worktrees are left out.
- **Which folder:** Files Changed follows the session to where it's actually been working. That's the worktree of its latest edit (Claude may enter a worktree partway through, or a subagent may work in one), else its last working directory within the project. When that differs from the session's folder, the Changes tool says "In worktree …".
- **vs main:** a git diff of the session's folder or worktree against where it branched from its base branch, including uncommitted and untracked files. The base is, in order:
  1. the base branch of the session's open pull request (merged or closed ones are ignored), found with the GitHub CLI (`gh pr view`, cached for 5 minutes) when `gh` is installed and signed in;
  2. the branch chosen for the project in the ▾ menu next to "vs";
  3. the repository's default branch (`origin/HEAD`, else `main`/`master`).

  The button shows the branch ("vs dev"), and its tooltip says where it came from. Each session remembers its last branch, and open tabs load in the background at launch, so switching sessions shows the right branch straight away (never a guessed "main"). Choosing another branch updates the label at once, and the lists show a spinner until the comparison is done. `.gitignore` is respected. As in `git status`, a folder that's entirely untracked (such as a leftover `node_modules`) is listed as one entry, and its files aren't read.

The right rail's **Changes** tool (⌥⌘F) lists the selected session's files, each with its folder, a coloured A/M/D/R letter and its line counts. You can have it open beside the terminal. Click a file to show its full diff, with line numbers, in place of the session's terminal; **Close** brings the terminal back, which keeps running meanwhile. If the file drops out of the list, the pane says so (or why "vs" can't compare) rather than switching to another file. Right-click a file for Copy Path. Lists refresh after each tool call, and every 15 seconds for the selected session.

## Pull Requests

Design 5. Live GitHub data, scoped to a project, a folder or a session — see [Pull Requests](pull-requests.md) for the full detail.

## Context window

The header shows how full the selected session's context window is: teal, then orange from 60%, red from 85%. Sessions started or resumed in Claudio report it exactly through Claude Code's status line. Claudio records the status line's data, then runs your own status line from `~/.claude/settings.json`, so what you see in the terminal is unchanged. For other sessions it's estimated from the token counts in their history, shown with a `~` and a fainter bar. History doesn't record the window size, so the estimate assumes 200k until usage passes that (or the model is a `[1m]` one).

## Tags

Optional, coloured labels for sessions (Code, Review, Research by default). Pick any number in the New Session sheet, or change them later from the tags row in the session header ("Add Tags" when there's none) or the Tags submenu when you right-click a session or tab. Edit the catalog — names and colours — in Settings → Tags.

- **Folders can have default tags too** (right-click a folder → Default Tags). A new session created in that folder starts with the union of the folder's own default tags and every ancestor's, deduplicated (a session in Backend › Auth › OAuth gets Backend's, Auth's and OAuth's defaults together) — a snapshot taken once at creation, which the New Session sheet shows pre-ticked and you can still change before starting. The Default Tags submenu shows a tag inherited from an ancestor as a plain row naming where it comes from, since a folder can't opt out of it short of moving out from under that ancestor. Moving a session into a tagged folder, or moving a folder itself, never retags anything after the fact — only creation does.

## Claude Code background agents

New sessions start (with Auto permissions by default) as background agents (`claude --bg`). By default each works in its own git worktree (`.claude/worktrees/<name>`), so sessions don't step on each other. The agent creates the worktree itself before its first edit, so it also commits (and pushes) its work there. Untick the worktree option to let it edit the project's checkout instead.

- In the New Session sheet, ⌘Return starts the session, even while typing the initial prompt (where Return adds a line).
- A tab is a terminal running `claude attach <id>`, so you get the full interactive Claude Code UI: slash-command autocomplete, `@` mentions, permission prompts, plan mode and pickers.
- Claude Code stays open in its tab: a second Ctrl+C or Ctrl+D on an empty prompt, which would quit it, is ignored with a short hint (close the tab to detach, or use Stop Session). A single Ctrl+C still interrupts Claude or clears the prompt.
- Shift+Enter adds a new line to the prompt instead of sending it, as in iTerm2 or Ghostty.
- Option types the characters your keyboard layout puts behind it (`#` is Option+3 on a British keyboard; `@`, `|`, `[`, `{` and `~` on many others; `€`; letters such as Polish `ą`; accents through dead keys such as Option+E). It still works as Alt on the keys Claude Code uses: Option+P, O, T and W, the word keys Option+B, F, D and Y (which shells share), Option+Return and Option+⌫. Other shell Meta keys on letters and digits, such as M-c or M-u, type their character instead. Option+←/→ move by word, ⌘←/→ go to the start or end of the line, and ⌘⌫ deletes to the start of the line (the whole line in zsh). The same applies in the Shell panel.
- The terminal stays in its session. In Claude Code, ← on an empty prompt switches an attached terminal to its agents view; the app spots that (the terminal title becomes "claude agents") and reattaches the tab straight away, since the sidebar and tabs handle navigation. ← still moves the cursor as normal.
- A session that isn't running shows its history with a message box: type and press Return to resume it with that message as the first prompt, or click Resume to resume without one.
- Closing a tab only detaches; the agent keeps running and its sidebar status keeps updating. Quitting the app leaves agents running, and they reattach when you reopen them.
- Agents you start elsewhere (`claude --bg`, the `claude agents` view) show up in their project automatically. Worktree sessions are grouped under their repository.
- Sessions open in an interactive `claude` in a terminal get a live status and a terminal icon. Resuming one asks first, because it starts a copy of the conversation; the copy appears beside the original as "<name> (copy)".
- Stop runs `claude stop`; the tab says "Stopping the agent…" until it has gone, and doesn't attach to it again meanwhile. `/clear` in a tab carries on in that tab with the new conversation, and the conversation it left isn't imported as a separate session. Delete offers two choices. Remove from Claudio leaves the conversation and its agent in Claude Code, and File → Removed & Archived Sessions… restores it (to its folder, or Unfiled if that's gone). Remove from Claude Code and Claudio runs `claude rm` (which also removes the worktree when that's safe) and deletes the conversation's history files (with those of conversations `/clear` left behind); that can't be undone. Either way, the session isn't imported again from its history file or the agent list. The same sheet unarchives archived sessions. A stopped session resumes in the background with `claude --bg --resume`.
- **Restart to Update.** Claude Code updates itself, but a running agent keeps the version it started on until it's restarted, and Claude Code won't restart one that's attached or busy. Claudio reads each agent's version from the daemon's roster (`~/.claude/daemon/roster.json`). A session on an older version than the installed one gets a **Restart to Update** chip in its header, and the same item in its ⋯ and right-click menus. Session → Restart All Idle Sessions to Update restarts every one that can. A restart runs `claude respawn`, which keeps the conversation, the agent's id and Claudio's hooks, and the tab attaches again once the agent is back. `claude respawn` doesn't wait for a turn to end, so it's only offered while the session is idle with no background tasks running; until then the item says why. When an agent turns up on a version newer than the one Claudio last saw, Claude Code is checked again straight away.
- Commands run through your login shell, so your `PATH` and node setup match your terminal. You can turn background agents off in Settings; tabs then run `claude` directly.

## Live status

`claude agents --json --all` is polled every 3 seconds for liveness, state and titles. Claude Code hooks, passed with `--settings` to the sessions the app launches, give instant updates:

- Prompts and tool use mark a session **Working**.
- A permission request, or a reply that ends in a question, marks it **Awaiting Input**.
- A finished turn marks it **Completed**, and Claude's last message becomes the summary. A turn that leaves background work running (a backgrounded command, a Monitor, a subagent) keeps it **Working** until that work finishes and the turn it wakes ends with none left.
- A session with background work shows a pill with how many tasks are running; its tooltip lists each one, what kind it is and how long it's run. Once they've run for 30 minutes the pill turns orange and the session appears in **Needs You** (assistant on or off), since some never end (a dev server, `tail -f`). **Mark Finished** there, or **Mark Background Tasks Finished** in the session's menu, stops waiting on them: the session counts as finished, and those tasks don't hold it again while they run. Ending the task itself also lets the session finish on its own.
- The list is saved. At launch, a background agent's running tasks are read from its job state, so tasks that finished or started while Claudio was closed are caught; the session shows Working again once its agent is seen alive.
- Your own hook settings are left untouched.

## Import Claude Code projects

File → Import Claude Code Projects… (⇧⌘I) lists every project on this Mac that you've used Claude Code in and that isn't in the sidebar yet. It's offered automatically on first launch, and projects active in the last 30 days start out ticked. Folders listed in `~/.claude.json` are included even after Claude Code has cleaned up their history (after `cleanupPeriodDays`, 30 days by default); they show "No saved sessions". Projects whose folder no longer exists are hidden, and the sheet says how many.

## Imports existing sessions

Adding a project reads `~/.claude/projects/<project>/*.jsonl`, so sessions you started in a terminal appear too, with their titles, summaries, PR links and history.

- Resuming an imported session uses `claude --resume`.

## Names stay in step with Claude Code

Renaming a session in Claudio sets its Claude Code title (the same `custom-title` record `/rename` writes), so `claude agents` and `claude --resume` use the new name. A `/rename` in the terminal renames the session in Claudio within about 30 seconds. A session named in the New Session sheet passes its name on once Claude Code has saved it.

## PR links

The pull requests a session opened or reviewed are collected, and the right rail's Pull Request tool (⌥⌘P) opens them on GitHub.

## Plan usage

The status bar shows how much of your 5-hour session and weekly limits you've used (`Session 80% · Week 11%`); click it for reset times and credits. A reset less than a day away shows as time left (`resets in 2h 14m`), and one further off as a date and time (`resets Sep 29 at 9am`). If your account has usage credits (extra usage) turned on, it also shows this month's credit spend against your limit, and keeps showing it (in red) once the monthly spend limit is reached. When a plan limit is reached it's marked **Using credits** while credits remain, and the status bar then shows the credit spend against your limit (`£12.50 of £50.00`) instead of the session and weekly figures, which don't move while you're on credits. It's marked **Out of credits** once they're spent, or **Limit reached** if you don't have credits turned on, and the status bar then shows when you can run again (`back in 2h 14m`, or `until Sep 29 at 9am` more than a day off), from the reset time of the full plan window (the later one if both are full). It's read at launch and every minute with `claude -p /usage`, which makes no model call, so figures are at most about a minute old. Your hooks are turned off for this check, so they don't run every minute. If it stops updating (signed out, or a problem with `claude`), the figures dim and the details say when they were last read, and a window whose reset time has passed shows as unused.

## Usage

Design 11a. What your sessions would cost at API rates, read from their transcripts: on a plan it's an estimate (**est.**), since plans aren't charged per token. Transcripts are read every 30 seconds, only what's new, and the totals are kept in `usage.json`, so removed sessions (and ones deleted from Claude Code, read before their transcripts go) still count.

- The left rail's **Usage** tool (⌘4) follows the selected session's project, like the Assistant. Pick 24h, 7d, 30d, All or custom dates (kept per project). It shows the total and its share of all usage, cost over time stacked by folder with the assistant on top, sessions against the assistant, cost by model, and the project's folders by cost. Click a folder to see its sessions (and the follow-ups on them); click a session to open its usage on the right.
- The right rail's **Usage** tool (⌥⌘U) shows the selected session's all-time cost, its input, output and cache tokens, cost by model, its approximate part of this week's limit, turns, main model, what its subagents cost (already in its total) and what the assistant's follow-ups on it cost.
- The status-bar popover adds today's cost across every project and **Open Usage Window**. The **Usage window** (⇧⌘U) covers every project: plan limits (with the assistant's pause threshold marked), usage credits, cost by model and by project, and the assistant's own calls by job and project, from the cost Claude Code reports for each.
- Each reply is counted once, from the last of the lines Claude Code writes it in, with subagents' transcripts and `/clear`ed conversations counting towards their session. Cache writes are priced by their lifetime, and fast mode at twice the rate. A model that isn't in the price table is priced at its family's rate, and the footnote says so.

## Notifications

macOS notifications when a session needs your input or finishes (and, if you turn it on, when an agent exits before its task is done, other than when you stopped it). They're skipped for the session you're looking at while Claudio is in front; clicking one opens its session. Each session keeps one notification (a newer one replaces it), and they stack as one group in Notification Centre, so Clear All dismisses them together. Claudio also tells you when a plan limit you'd reached (the 5-hour session or the week) resets, as soon as its reset time passes or a reading shows it below the limit, even while Claudio is in front; resets are also noted in the Activity Log. Choose which ones, and whether they play a sound, in Settings. They need the bundled `Claudio.app` (not `swift run`), and macOS asks for permission on first launch.

## Settings

Open with ⌘,. A sidebar of pages, each with grouped rows:

- **General:** the `claude` executable and Claude Code's setup checklist, the sidebar's recent-activity window, and where Claudio's data, its log and Claude Code's history are kept.
- **New Sessions:** Direct or Background sessions, the default model, and default permissions for background agents (Auto) and for sessions run in a terminal.
- **Notifications**, **Tags** and **About**.

## Claude Code setup checks

At launch (and when you come back to Claudio, at most every 5 minutes), Claudio checks three things:

- that Claude Code is installed and runs (`claude --version`)
- that you're signed in (`claude auth status`)
- that it supports background agents (`claude agents`)

The checklist also shows the GitHub CLI as an optional tool, with Install (Homebrew, or its download page) and Sign In (`gh auth login`). It's never counted as a problem.

If something's wrong, a setup sheet lists each check with a fix: **Install** (Claude Code's install script), **Sign In** (`claude auth login`), **Update** (`claude update`) or **Choose…** (point Claudio at the executable). Fixes run in a terminal inside the sheet and everything is checked again when it exits. Other problems show as a banner at the bottom of the window. Without a working, signed-in Claude Code you can still browse sessions and history; starting or resuming a session opens the setup sheet instead. Without background agents, new sessions run directly in their tab. The same checklist is in Settings → General, and File → Claude Code Setup… opens the sheet. Account details from `claude auth status` aren't written to the Activity Log.

## Folder access up front

macOS asks before an app reads Documents, Desktop, Downloads, iCloud Drive or another volume, and there's no way to request that ahead of time. So at launch Claudio reads one project in each of those places, and any prompts appear together at startup instead of in the middle of an action.

## Dock badge

Shows how many sessions are awaiting input.

## Activity Log

Window → Activity Log (⌥⌘L) lists every command the app runs, with its exit code, duration and output, plus terminal launches and exits, and errors. Agent polling is only logged when its output changes. Everything is also appended to `~/Library/Logs/Claudio.log`.

## App icon

The light design (3b) from `Resources/Assets.xcassets`, compiled by `scripts/build-app.sh`. A classic `.appiconset` can't carry a dark variant, so the dark design (3a) is kept in `design/app-icon/` (SVG masters plus PNGs in `dark/`), ready for an Icon Composer `.icon` file.
