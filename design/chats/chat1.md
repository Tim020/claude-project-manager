# MacOS Agent Session Manager

_Started 2026-09-25 11:05 UTC_

---

## User

Make UI mockups for a native MacOS app that wraps Claude Code to produce a UI for managaing multiple agent sessions. As you can see from the attached screenshot, I have multiple sessions running that could be grouped together in the concept of folders - there is a session for making code changes, and a session for performing a PR review on that code.

I want a way to group sessions into folders based I can give custom names to in a navigation bar, I would also like to have them grouped by project - eg having multiple claude code sessions from multiple project directories, and under the project is then where you get the folders for the grouped sessions.

## Assistant

_[tool: read_file]_

_[tool: dc_write]_

_[tool: ready_for_verification]_

I've made three macOS mockups in `Session Manager.dc.html`, styled with the DigiScript design system. Each groups sessions three levels deep: project (a working directory), then your custom-named folders, then the sessions inside each folder.

- **1a – Sidebar tree:** the sidebar shows every project, folder and session. Picking a session opens it, with the other sessions in its folder shown as tabs (e.g. the code session next to its PR review). One folder is shown mid-rename to show custom naming. Clicking sessions in the sidebar or tabs switches between them.
- **1b – Project rail:** a narrow strip of project icons with badges for working or awaiting-input sessions, then a folder list. Opening a folder shows its code and review sessions side by side, with a switch to show them as tabs instead.
- **1c – Folder board:** each folder is a column of session cards in a project overview, and you drag cards between folders. A right-click menu covers renaming a folder, adding a session to it and moving it to another project. A dashed empty column makes a new folder.

Sessions sit in one of three states: Working, Awaiting Input or Completed. Sessions not yet in a folder go under "Unfiled". The dreamteam-web and digiscript-electron projects are made-up examples to show more than one project. I assumed rather than asked on a few points, so tell me what to change.

## User

Found issues — fixing…

## Assistant

_[tool: run_script]_

_[tool: ready_for_verification]_

All five columns in 1c now fit inside the window, including the dashed new-folder column. I narrowed the columns and tightened the spacing. The remaining overlap warnings come from the right-click menu sitting on top of the cards, which is intended.

