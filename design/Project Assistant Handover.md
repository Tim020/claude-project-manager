# Project Assistant — handover (build 9a)

Design: `Project Assistant.dc.html`, concept **9a Side notebook** (chosen). 9b is kept for reference only.
Builds on the shipped two-rail layout: `ToolRails.swift`, `ToolWindows.swift`, `DetailView.swift`, `Theme.swift`.
9a has nine clickable journeys. Journeys 6–9 cover the states added after the backend design.

## Placement
- A new left-rail tool, **Assistant** (`notebook-edit-outline`, ⌘3), below Sessions (⌘1) and Pull Requests (⌘2).
- The rail button shows a blue count badge for Needs You items. Jobs still in progress don't count. Nothing else on the rail changes.
- It opens in the left tool panel at the same width as Sessions, and replaces the session tree while it's open, like the other left tools.
- It's project-scoped: it follows the project of the selected session.

## Panel anatomy (top to bottom)
1. **Header:**
   - the title: ASSISTANT, or the view name when drilled in, with a ‹ back button
   - New Note (⌘⇧N)
   - a ⋯ menu holding Import Issues…, Skills (with a count), Activity Log and Assistant Settings…
2. **Status line** (only one shows at a time):
   - **Off:** a card reading "The assistant is off for this project…" or "…turned off in Settings…", with Turn On.
   - **Paused** (Automatic mode, over the usage threshold): "Background work paused · 5-hour usage 84% · 2 waiting", in quiet muted text, with a Limits… link. The count is the number of held-back jobs.
   - **Manual:** "Manual: it only works when you ask."
3. **Capture box:** shown while capturing. It has a text field, "Linked to <session>", and Cancel and Save Note buttons. *(Added in the build, not in the Claude Design file: an × beside "Linked to <session>" removes the link for a note that isn't about that session, which then reads "Not linked to a session".)*
4. **Needs You · n:** one card per item. When there's nothing, it shows "Nothing needs you." When the assistant is off, the section is hidden. Card kinds:
   - suggestion: icon, title and one-line reason, which opens a drill-in view
   - in progress: spinner, dashed border, "Usually a few seconds, up to about 30.", not clickable
   - failed: red icon and border, which opens the Job Failed view
5. **Plan | Notes switch:** each side shows its count.
   - Plan is grouped as IN SESSION, PLANNED, IDEAS and DONE. Each row shows a status dot, the title and a meta line (issue · n notes · session).
   - Notes: see "Note authorship".
6. **Ask bar:** "Ask about this project…" plus one suggested question. When the assistant is off, it's dimmed and reads "Ask is off for this project".

## Note authorship
Notes are listed newest first, with a legend at the top (You, Assistant, A session). There are three authors:

| Author | Marker | Meta line | Undo |
|---|---|---|---|
| You (⌘⇧N) | `account-outline`, subtle grey | "You · linked to Shell Follow Up · 3h" (or "You · 3h") | No |
| Assistant | ✦ `creation`, blue `#3498db` | "Assistant · from Shell Terminal · 1h" | Yes |
| A session | `console-line`, teal `#00bc8c` | "Shell Follow Up · 2m" (the session name is the author) | Yes |

- Each note links to its plan item with a chip, if it has one.
- Notes without an item show a **Promote…** link, which you start yourself.

## Promote suggestions
After a capture in Automatic mode, the note shows "Checking it against the plan…", then one of:
- **New item:** "Reads like a bug. Promote it to the plan?" with Promote or Keep as Note.
- **Duplicate:** "Looks like 'Remember Shell panel height per project'. Attach it?" with Attach or Keep as Note. Attach links the note to that item.

What happens in other modes:
- **Manual, or paused:** no automatic check. **Promote…** runs the same check. While usage is high, it shows "5-hour usage is 84%. Things you start still run."
- **Off:** Promote… creates an Idea straight away, titled from the note, with no Claude call.

## Drill-in views (all in the panel; back returns to the list)
- **Plan Item:**
  - status pill, and a GitHub chip or **Create GitHub Issue**
  - title and folder
  - ATTACHED NOTES
  - SKILLS FOR ITS PROMPT (planned items) or SKILLS NAMED IN ITS PROMPT (in session)
  - "In session: <name>" or **Start Session**
  - For a session started before the assistant, the skills are replaced by: "Started before the assistant, so it can't use its skills or write notes. New sessions get its skills."
- **New Skill:**
  - NEW SKILL pill
  - **Why**
  - skill text as added lines
  - Approve, Edit and Not Now
- **Changed Skill:**
  - CHANGED SKILL pill and "The current version stays in use until you approve"
  - **Why**
  - a diff with removed lines (red tint, −, struck through) and added lines (teal tint, +)
  - Approve, Edit (edits the new version) and Not Now
- **Skill Change** (edited outside Claudio):
  - EDITED OUTSIDE CLAUDIO pill (amber)
  - who changed which file and when, for example "The Update PR session changed .claude/skills/readme-style/SKILL.md 10h ago"
  - the diff
  - Keep Change and Revert. Revert puts back the approved version and rewrites the file.
- **Unused Skill:**
  - UNUSED SKILL pill
  - "Not used by any session for 30 days", with the last use
  - a preview
  - Retire (red outline) and Keep. Retired skills can be restored from Skills.
- **Mark Done:**
  - In Session → Done
  - the item title
  - the evidence ("PR #14 was merged into main as 352ddc7…" or "Issue #19 was closed…")
  - Mark Done and Not Yet
- **GitHub Issues:** one card per issue with a suggested label, the reason, the action (Add to Plan or Attach) or Skip, and then the result.
- **Skills** (⋯):
  - every skill, with a location tag: **CLAUDIO** (the default, grey) or **REPOSITORY** (blue tint)
  - how many sessions used it and when it last changed
  - retired skills are greyed out
- **Skill** (from Skills):
  - location tag
  - the skill text
  - For a Claudio skill: **Save to Repository**, with an inline confirmation: "Claudio copies this skill to `.claude/skills/<slug>/SKILL.md` in <project>. Commit it to share it with anyone who clones the repository. From then on Claudio uses the repository copy." Cancel or Save to Repository.
  - For a repository skill: its path, and "Edits made there show up in Needs You for review."
  - For a retired skill: Restore.
- **Assistant Settings** (⋯, per project):
  - **MODE:** radio cards.
    - Automatic (Default): also works in the background (follow-ups when a session finishes, skill proposals and new GitHub issues). It only calls Claude when something new needs judgement.
    - Manual: only when you ask (Promote, Review This Session, Import Issues and Ask).
    - Off: notes and the plan by hand. No Claude calls.
  - **PRIVACY:** a "Don't send transcripts" toggle. Follow-ups then use only the final message and the files changed.
  - **MODELS:** "Quick checks" (Haiku) and "Follow-ups, skills and Ask" (Sonnet). Each opens a picker.
  - **STORAGE:** read-only: "Skills are stored by Claudio, not in the repository."
  - A link to the app-wide Settings › Assistant.
- **Activity Log** (⋯, and from Job Failed): every Claude call, newest first. Each row shows the time, the job, what it was about, the model, and the result: Done (teal), Waiting (amber, for example "Waiting: 5-hour usage 84%") or Failed (red, with the reason). A Waiting row changes to Done or Failed once the job runs.
- **Job Failed:**
  - the title and a plain explanation, for example:
    - "Claude Code is installed but not signed in. Run claude in a Shell and sign in, then try again."
    - "No answer came back within 60 seconds. Nothing was changed."
    - "Claudio couldn't find the claude command…"
  - a job line (job · subject · model · time)
  - **Try Again** and **Open Activity Log**. Try Again turns the card back into an in-progress card.
- **Ask:** the question, then "Reading the plan, notes and recent sessions…" with a spinner and "Answers take a few seconds, up to about 30." (plus the usage note while usage is high), then the answer and links to items.

## Overlays
- **New Session from Plan** is a modal sheet with:
  - Name
  - Folder (suggested)
  - Role
  - Worktree toggle
  - OPENING PROMPT preview (the item title, its notes, a linked issue, and then "Use these skills: <chip names>" in blue)
  - SKILLS chips (blue tint), which can be removed

  The copy under the chips reads "Named in the opening prompt. Other approved skills stay available." Removing a chip only drops that skill's name from the prompt; the session can still use any approved skill if it's relevant.
- **Follow-up card** (inline at the bottom of the session's terminal):
  - **Working:** a spinner, "Reviewing <session>…", "This can take up to about 30 seconds. You can keep working." (plus the usage note while usage is high, when you started it yourself).
  - **Ready:** checkbox rows. NOTE rows are already saved; unticking one removes it. PLAN rows are applied with **Add n to Plan**.
    - If there's nothing to keep: "Nothing new to keep from this session." and Close.
  - Later (or ✕) keeps it in Needs You as "<session> finished".
  - In **Automatic** mode it appears when a session finishes. If paused by usage, it waits and appears once usage drops (the Activity Log shows Waiting until then).
  - Older sessions get the same card. Follow-ups are built from the session's history and hook events inside Claudio.
  - In **Manual** mode it only appears from **Review This Session**.
- **Session context menu** (⋯ in the session header): Rename…, Move to Folder, **Review This Session** (✦), Stop Session. It works in Automatic and Manual modes. When the assistant is off, it shows a toast instead.
- **Settings window › Assistant** (app-wide; opened from Assistant Settings, the Limits… link, or the status-bar usage figures):
  - "Use the assistant": the global switch. "Off turns it off in every project. Notes and plans stay."
  - "Pause background work at [80]% of the 5-hour or weekly limit": an editable number from 50 to 100, with the current usage under it.
  - "Allow background work while using credits": off by default.
  - A note: "Things you start yourself always run: Ask, Promote, Review This Session and Import Issues."
- **Toast** (teal, bottom centre, about 2.6s): confirms saves, approvals, exports and repository saves.

## Rules
- **Notes:** saved straight away, whoever writes them. Notes from the assistant or a session can always be undone.
- **Plan items and skills:** only change after an explicit user action (Promote, Attach, Add to Plan, Approve, Keep Change, Revert, Retire, Mark Done).
- **Skills:** stored by Claudio unless saved to the repository. They're only surfaced when proposed, changed (by the assistant or outside Claudio) or unused. A proposal isn't used until it's approved.
- **Background work:** runs only in Automatic mode, while the app switch is on, below the usage threshold, and not on credits unless allowed. Held-back work isn't dropped. It waits and runs once usage falls below the threshold, and a newer job for the same session replaces the waiting one. Things the user starts always run.
- **GitHub:** import and export only. Nothing is written to GitHub without Create GitHub Issue. Triage labels are suggestions.
- **Older sessions:** they can't use skills or write their own notes, so the plan item shows a hint. Follow-ups work fully for them.
- **Copy:** British English, Title Case buttons, and no emoji.

## Colours (from `Theme.swift` and DigiScript)
- Backgrounds: body `#222`, panel `#2b2b2b`, cards `#303030`, borders `#444`.
- Text: muted `#adb5bd`, subtle `#6c757d`.
- Teal `#00bc8c`: primary action, In Session, success, the session-author marker, Done in the log.
- Blue `#3498db`: the assistant marker, Planned, the selection tint `rgba(52,152,219,.35)`, badges, the REPOSITORY tag, spinners.
- Amber `#f39c12`: the Edit outline, EDITED OUTSIDE CLAUDIO, the paused icon, Waiting in the log.
- Red `#e74c3c`: the bug label, failed jobs, removed diff lines, Retire and Revert.

## Shortcuts
⌘3 opens the Assistant. ⌘⇧N creates a new note from anywhere, linked to the focused session. Esc closes capture and sheets.

## Backend
The backend has since been designed (see its own design doc). The UI states above come from it: the three modes, the usage threshold, transcript privacy, the model choice, where skills are stored, the Activity Log and job failures.

## Suggested build order
1. Notes and capture (⌘⇧N), with all three authors.
2. Plan items, Promote and Attach, and the Plan list.
3. Start Session from an item: the opening prompt with named skills.
4. The follow-up card (Automatic and Review This Session), with its working and failed states.
5. Assistant Settings, app Settings › Assistant, the paused state and the Activity Log.
6. Skills: new, changed, edited outside Claudio, unused, and Save to Repository.
7. GitHub import, triage and export, and Mark Done.
8. Ask.

## Changes since build 9a
1. **Note authorship:** a third author, "A session", with a teal `console-line` marker, the session name as the author, and Undo. Notes has a legend.
2. **Skill chips in New Session from Plan:** a chip now means the skill is named in the opening prompt. The prompt preview shows "Use these skills: …". The copy changed to "Named in the opening prompt. Other approved skills stay available."
3. **Assistant Settings** (per project): Mode, "Don't send transcripts", Models and a read-only Storage line.
4. **Settings › Assistant** (app-wide): a global switch, the pause threshold, and "Allow background work while using credits".
5. **Paused state:** a quiet paused line, and a usage note on things you start yourself.
6. **New Needs You cards:** Changed Skill (with a two-sided diff), Edited Outside Claudio, Unused Skill and Mark Done, each with a view.
7. **Skill locations:** Claudio or Repository in the Skills list and the skill view, and Save to Repository with a confirmation.
8. **Duplicate check on capture:** the "Looks like … Attach it?" suggestion, alongside Promote.
9. **Manual mode:** Review This Session in the session ⋯ menu. No automatic follow-up card in Manual mode.
10. **Working and error states:** in-progress cards, working states for follow-ups and Ask, and a Job Failed view with Try Again and Activity Log.
11. **Older sessions:** a hint on their plan item. Their follow-up card looks the same as any other.
12. **Held-back work waits:** the Activity Log shows Waiting instead of Skipped, and the paused line shows how many jobs are waiting.
