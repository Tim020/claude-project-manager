# Usage: handover (build 11a)

Design: `Usage.dc.html`, option **11a In the panel** (chosen). 11b is kept for reference only.
Builds on the shipped two-rail layout: `ToolRails.swift`, `ToolWindows.swift`, `Theme.swift`, and the status bar's `UsageSection` popover.
Rule: tabs only hold session things, so project and folder usage lives in the left panel and never opens a tab.

## Where it lives
1. **Left rail › Usage** (`chart.bar`, ⌘4), below Assistant. It covers the project and its folders, and follows the selected session's project, like the Assistant. It has no badge.
2. **Right rail › Usage** (`chart.bar`, ⌥⌘U), below Pull Request. It shows the selected session's all-time usage, at the right panel's 320px.
3. **Usage window** (⇧⌘U, Window › Usage, or **Open Usage Window** in the status-bar popover) covers every project, and is the assistant's global home.
4. **Status-bar popover:** the existing `UsageSection`, plus a "Today, all projects · $x est." row and an **Open Usage Window** link.

## Left panel: Usage tool (top to bottom)
1. **Header:** USAGE, with a ‹ back button when drilled into a folder.
2. **Range:** a segmented control (24h, 7d, 30d, All) and a calendar button for **Custom Dates…**. Custom shows From and To date fields under it. Default 7d. The range is kept per project.
3. **Scope:** the project's name in caps (or the folder's), and the range in words ("Last 7 days", "All time, since 4 Aug", "22 Sep – 28 Sep 2026").
4. **Total:** cost (26pt bold) with an **est.** pill, then "n tokens · n% of all usage". The share is this scope's part of all usage across every project in the same range.
5. **Cost over time:** stacked bars, 84pt tall, with first and last labels. Buckets: hourly for 24h, daily for 7d, 30d and custom, weekly for All. Segments are one per folder (the project) or one per session (a folder), with the assistant on top in blue. Hovering a bar shows "label · $x".
6. **Sessions and Assistant:** a split bar with both amounts. In a folder, the assistant part is **Follow-ups**: only the follow-ups on that folder's sessions.
7. **By model:** a split bar with a legend: Opus `#fff`, Sonnet `#adb5bd`, Haiku `#6c757d`. *(Built: Fable, which the design has no colour for, is purple `oklch(0.72 0.11 300)`.)*
8. **List:** FOLDERS (the project) or SESSIONS (a folder), with a COST column. Rows are sorted by cost, with a thin share bar under each.
   - A folder row drills in.
   - A session row selects the session and opens the right-rail Usage tool.
   - Removed sessions still count. They show a **Removed** tag, muted text, and aren't clickable. *(Built: sessions deleted from Claude Code too, whose transcripts are gone, keep the totals read before deleting, and show the same way.)*
   - In the project scope, an **Assistant** row follows (✦, its cost, and ↗ to the Usage window).

### States
- **Reading transcripts:** a spinner line, "Reading transcripts… 4 of 7. Figures will rise." The figures show what has been read so far. *(Built: shown for the first read after launch, and for any later one with at least 4 files to read, so the 30 s top-ups don't flash it.)*
- **Unreadable transcript:** an amber line, "1 session's transcript couldn't be read, so it isn't counted. The Activity Log (⌥⌘L) says why."
- **No usage in range:** a dashed box, "No usage in this range." and "Sessions and assistant calls in this project show here as they run. Try a longer range."

## Right panel: a session's Usage
- the name, then "All time · started 14 Sep"
- cost with the **est.** pill, and total tokens
- a 2×2 grid: Input, Output, Cache write, Cache read
- By model (bar and legend)
- THIS WEEK'S LIMIT ≈ n%, with a bar (amber over 15%), and "Its share of the 31% used this week."
- facts: Turns, Last active, Main model, Assistant follow-ups (cost, or None)
- the footnote "Priced at API rates from the session's transcript. Plans aren't charged per token."
- Per session it's absolute: there's no range control.

## Usage window
- a title (All Projects), the range in words, and the same range control as the panel
- **Left column:**
  - PLAN LIMITS: 5-hour and Weekly meters with reset times, and a white mark at the assistant's pause threshold (from Settings › Assistant)
  - Usage credits (Off, or the `amountLabel` figure)
  - BY MODEL
- **Main column:**
  - three summary cards: Cost, Tokens and Assistant (with its share)
  - COST OVER TIME · BY PROJECT (stacked bars, plus the assistant)
  - a project table: Sessions, Assistant ("Off" if it isn't on), Total, Share
  - **ASSISTANT section:** cost, Claude calls and share of all usage; BY JOB (Follow-ups, Skill proposals, Note checks, Ask, Issue triage, each with its model, calls and cost); BY PROJECT; and an **Open Activity Log** link. Its note says things you start yourself are counted too. *(Built: BY JOB lists the jobs that have run, by the names the Activity Log uses; Skill proposals, Ask and Issue triage appear once those steps of the assistant exist.)*

## Data (from the repo)
- **Session cost:** sum the token counts on each assistant message in the session's transcript (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` and `output_tokens`, as `SessionDiscovery.swift` already reads), times the price table for that message's model. It's in **USD**, because API prices are. Show it as an estimate (est.) on a plan.
  - *(Built, from real transcripts with 2.1.289: a reply is written as several lines, one per content block, each repeating its `usage`, and in subagent transcripts the later lines have more output tokens, so the last line of each message id is counted. A copy of a conversation repeats the original's replies under the same ids, so a project counts each id once, for the oldest session. Subagent transcripts (`<id>/subagents/*.jsonl`) count towards their session. Cache writes are priced by TTL from `cache_creation.ephemeral_5m/1h_input_tokens`, and `usage.speed: "fast"` at twice the rate. `<synthetic>` replies aren't counted. A `/clear`ed conversation stays its session's.)*
- **Assistant cost:** each job's `costUSD` (`total_cost_usd` from `claude -p`, already in `AssistantJobs.swift` and the Activity Log). It's attributed to a session for follow-ups and Review This Session, and to the project for everything else.
- **Buckets:** use message timestamps, so a long session spreads across days.
- **Share of the weekly limit, per session:** its last 7 days of cost divided by the cost-equivalent of the whole weekly window (all usage over the last 7 days ÷ the weekly utilisation). Always show it as "≈".
- **Plan limits and credits:** the existing `UsageSnapshot`.
- **Cache:** per-session daily totals, keyed by transcript path and size, so a refresh only reads new lines. Removed sessions keep their totals. *(Built: hourly totals per transcript, so 24h has its hourly bars, in `usage.json` beside `state.json`.)*
- **Unknown models:** price them at the nearest family's rate, and add "Some messages priced at Sonnet rates" to the footnote.

## Colours
- Folders and projects use one series colour each: teal `#00bc8c`, amber `#f39c12`, then `oklch(0.72 0.11 300)`. Sessions inside a folder use its colour at opacity 1, .62, .4 and .25.
- The assistant is always blue `#3498db`.
- Cards are `#303030` with `#444` borders. Section labels are 11pt, extra bold, tracked, `#adb5bd`.

## Copy
British English and Title Case buttons. Use "est." wherever a cost is priced from tokens. No emoji.

## Suggested build order
1. A transcript token scan and price table, with the per-session daily cache.
2. Right rail › Usage.
3. Left rail › Usage: the range control, total, chart, splits and list, with drill-in and the three states.
4. The status-bar popover additions, and the Usage window (plan limits, projects, and the assistant section from the job costs).
