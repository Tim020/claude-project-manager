# Project Assistant — handover (build 9a)

Design: `Project Assistant.dc.html`, concept **9a Side notebook** (chosen). 9b is kept for reference only.
Builds on the shipped two-rail layout: `ToolRails.swift`, `ToolWindows.swift`, `DetailView.swift`, `Theme.swift`.

## Placement
- A new left-rail tool, **Assistant** (`notebook-edit-outline`, ⌘3), below Sessions (⌘1) and Pull Requests (⌘2).
- The rail button shows a blue count badge for Needs You items. Nothing else on the rail changes.
- It opens in the left tool panel at the same width as Sessions, and replaces the session tree while it's open, like the other left tools.
- It's project-scoped: it follows the project of the selected session.

## Panel anatomy (top to bottom)
1. **Header:** the title (ASSISTANT, or the view name when drilled in, with a ‹ back button), New Note (⌘⇧N) and a ⋯ menu. The menu holds Import Issues…, Skills (with a count) and Assistant Settings….
2. **Capture box:** shown while capturing. It has a text field, "Linked to <session>", and Cancel and Save Note buttons.
3. **Needs You · n:** one card per pending suggestion (icon, title, one-line reason). When empty, it shows "Nothing needs you."
4. **Plan | Notes switch:** each side shows its count.
   - Plan is grouped as IN SESSION, PLANNED, IDEAS and DONE. Each row shows a status dot, the title and a meta line (issue · n notes · session).
   - Notes are listed newest first. Each card shows the text and "Author · source session · time". Notes the assistant wrote show a ✦ (`creation`) marker and an Undo link. A chip links to the note's plan item, if it has one.
5. **Ask bar:** "Ask about this project…" plus one suggested question. Answers open in the panel as the Ask view, with chips linking to plan items.

## Drill-in views (all in the panel, with back returning to the list)
- **Plan Item:**
  - status pill, and a GitHub chip or a **Create GitHub Issue** button
  - title and folder
  - ATTACHED NOTES
  - SKILLS IT WILL USE
  - either "In session: <name>" (links to the session) or a **Start Session** button
- **Skill:**
  - NEW SKILL pill and "Not used until you approve it"
  - name
  - **Why** (the lesson and its evidence)
  - skill text as added lines
  - Approve, Edit (switches to a text editor) and Not Now
- **GitHub Issues:** one card per issue with a suggested label, the reason for the suggestion, and the action (Add to Plan or Attach) or Skip. Each card then shows its result.
- **Skills** (from ⋯): the approved skills, each with how many sessions have used it and when it last changed.
- **Ask:** the question, the answer, and links to items.

## Overlays
- **New Session from Plan** is a modal sheet. It has:
  - Name (suggested)
  - Folder (suggested: the same folder as the item's notes)
  - Role (CODE or REVIEW)
  - Worktree toggle, showing the path
  - OPENING PROMPT preview (read-only: the item title, its notes and a linked issue)
  - SKILLS chips, which can be removed
  - Cancel and Start Session buttons

  After Start, the session opens in a new tab and becomes the selected session. The item moves to In Session. The panel stays on the item.
- **Follow-up card:** shown inline at the bottom of a session's terminal when that session finishes. It lists checkbox rows:
  - NOTE rows are already saved; unticking one removes it.
  - PLAN rows are only applied when you click **Add n to Plan**.

  Later (or ✕) keeps it in Needs You.
- **Toast** (teal, bottom centre, about 2.6s): confirms saves, approvals and exports.

## Rules
- **Notes:** saved straight away, whoever writes them. Notes the assistant writes can always be undone.
- **Plan items and skills:** only change after an explicit user action (Promote, Add to Plan, Approve, Apply).
- **Promotion:** after a capture, the assistant can suggest promoting the note in place ("Reads like a bug. Promote it to the plan?" with Promote or Keep as Note).
- **Skills:** only surfaced when one is proposed or changed. They aren't used until approved.
- **GitHub:** import and export only. Nothing is written to GitHub without Create GitHub Issue. Triage labels are suggestions.
- **Copy:** British English, Title Case buttons, and no emoji.

## Colours (from `Theme.swift` and DigiScript)
- Backgrounds: body `#222`, panel `#2b2b2b`, cards `#303030`, borders `#444`.
- Text: muted `#adb5bd`, subtle `#6c757d`.
- Teal `#00bc8c`: primary action, In Session, success.
- Blue `#3498db`: assistant marker, Planned, the selection tint `rgba(52,152,219,.35)` and badges.
- Amber `#f39c12`: the Edit outline button.
- Red `#e74c3c`: the bug label.

## Shortcuts
⌘3 opens the Assistant. ⌘⇧N creates a new note from anywhere, linked to the focused session. Esc closes capture and sheets.

## Backend: NOT designed yet (Claude Code to design)
The assistant will be powered by Claude. The backend needs its own design pass before implementation. Open questions:
- **Storage:** where notes, plan items and skills live. Options include the app store, files in the repo (for example `.claude/`) or both. Consider how they sync across machines and how they show up in git.
- **Skill format:** whether to use native Claude Code skills (SKILL.md) so sessions pick them up. Also versioning, and how a changed-skill diff is produced.
- **Learning loop:** which signals trigger notes, follow-ups and skill proposals, for example transcripts, hook events, tool failures and user corrections. Also when it runs: on the Stop hook, on idle, or on demand.
- **Runtime:** a long-lived agent per project, or a short Claude call per event. Consider cost, rate limits and plan usage.
- **Skill selection:** how skills are matched when a session starts (files touched, labels, similarity).
- **GitHub:** via `gh`, as in `GitHubCLI.swift`. Decide polling vs webhooks, label mapping and duplicate detection.
- **Chat:** what context it gets, and how answers cite plan items.
- **Audit:** a log of every change the assistant makes, which backs Undo.
- **Privacy:** what leaves the machine, and a per-project opt-out.

## Suggested build order
1. Notes and capture (⌘⇧N), stored locally.
2. Plan items, promoting notes, and the Plan list.
3. Start Session from an item, using the opening prompt.
4. Follow-up card when a session finishes.
5. Skills: proposal, review and approval.
6. GitHub import, triage and export.
7. Ask.

The backend design answering these questions is in `Project Assistant Backend.md`.
