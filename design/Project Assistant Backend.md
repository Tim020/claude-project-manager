# Project Assistant: backend design

Status: proposal for review, before any code is written.
It answers the open questions in `Project Assistant Handover.md` (UI concept 9a, `Project Assistant.dc.html`).
CLI facts were checked against Claude Code 2.1.284 on macOS, and in `node:22-slim` containers with 2.1.284 and 2.1.169 (see [Verified](#what-was-verified)). Anything not checked is marked **assumed**.

## Summary

- **Claudio stores; Claude is called.** Notes, plan items, suggestions, skill records and the audit log live in Swift code in `ClaudioCore`, as plain files under Application Support. No model call is needed to read or change them.
- **No long-lived assistant agent.** Each piece of assistant work is one short, structured `claude -p` call. Examples: promoting a note, a session's follow-ups, a skill draft, triaging issues, an Ask answer. Each call runs with `--json-schema`, a narrow tool list, `--no-session-persistence` and hooks off. The reply is JSON, which maps straight onto a Needs You card.
- **Approved skills are native `SKILL.md` files.** They go in a directory Claudio owns and passes to every session it launches with `--add-dir`. Sessions find them like any project skill, pick up changes live, and nothing is written to `~/.claude` or the repository. Saving a skill to the repository is an extra per-skill action.
- **A small bundled plugin** (`--plugin-dir`) gives sessions a `claudio` command, so they can read the plan and write notes back. It's copied out of the app bundle at launch. Nothing is installed.
- **The learning loop feeds on data Claudio already has:** hook events, history files and changed files. Three more hook events cover failures. Skills need a high bar: a lesson has to recur, or the user has to correct Claude. Unused skills are offered for retirement.
- **Code checks first; Claude only judges.** Polling, diffing, counting and matching are plain Swift and `gh`/`git` commands. Claude is called only once code has found something new that needs judgement, such as a new issue or a finished session with real changes. It's never called to find out *whether* anything happened.
- **Background work is budgeted in plan usage.** It's deferred when the `/usage` reading Claudio already polls is high. What you ask for directly always runs.

## Research: what exists, and what we take from it

| Tool | How it works | What we take |
|---|---|---|
| **Claude Code auto memory** | Sessions write `~/.claude/projects/<p>/memory/*.md`. A `MEMORY.md` index loads at session start. It's on by default. | Don't duplicate it. Sessions already remember facts on their own. Notes are the *user's* notebook, and skills are for *procedures*. The assistant reads the memory index as context, so it won't propose a note or skill that memory already covers. |
| **GitHub Copilot Memory** | Stored facts cite the code that supports them. They're checked against the current branch before use, and deleted after 28 days unused. | Skills keep their evidence (the "Why" in the design). A skill nobody has used in 30 days gets a Retire suggestion, rather than being deleted silently. |
| **Devin knowledge suggestions** | The agent proposes knowledge entries, and a person approves or dismisses each one. | Matches our Needs You rule exactly: proposals, never silent writes. |
| **autoharness / skill-molt** | Reflect on a session, then propose adding, patching, merging or deleting a skill. Deterministic checks (paths exist, commands exist, length, trigger text, secrets) run before a person reviews. Keep only knowledge that can't be inferred from the code. | The proposal flow: patch existing skills before adding new ones, deterministic checks in Swift, and "non-inferable only" in the drafting prompt. |
| **CCPM, Task Master, Kiro specs** | The plan lives in files the agent reads (PRD → epics → issues, `tasks.md`), and GitHub Issues is the shared record. | Starting a session from a plan item puts the item and its notes in the opening prompt. GitHub stays import/export, as the handover says. We don't make the agent maintain the plan files itself, because worktrees would diverge (see Storage). |
| **Cursor rules and memories, Windsurf memories** | Rules are generated from chat, and memories are created automatically with little review. | This is what we're avoiding. Unreviewed memories are the most common complaint about these tools. |
| **Research** | Repository skills written by a model give small gains (GEPA +4.9 pp, SkillOpt +0.1 pp, within run-to-run variance), but maintainers found them useful. Skills specific to one person helped less than general procedures. | Fewer, procedural, evidence-backed skills. Measure usage, and retire what isn't used. |

## Architecture

```
┌─────────────────────────── Claudio.app ────────────────────────────┐
│  AssistantStoring (ClaudioCore)    assistant job queue (ClaudioCore)│
│   notes · items · suggestions ◄──── queue of jobs → `claude -p …`   │
│   skills · audit.jsonl              --json-schema → typed result    │
│        ▲            ▲                        ▲                      │
│        │ inbox.log  │ hook-events.log        │ digests from         │
│        │            │ (+3 new events)        │ SessionDiscovery,    │
│        │            │                        │ SessionChanges, gh   │
└────────┼────────────┼────────────────────────┼──────────────────────┘
         │            │                        │
   ┌─────┴────────────┴───────┐        ┌───────┴─────────┐
   │ claude session (bg/tab)  │        │ claude -p        │  one call per job,
   │  --settings <hooks>      │        │  no tools or     │  no history file
   │  --plugin-dir …/claudio  │        │  read-only tools │
   │  --add-dir …/skills      │        └──────────────────┘
   │  bin/claudio → inbox.log │
   └──────────────────────────┘
```

### Files on disk

```
~/Library/Application Support/Claudio/
  state.json                         existing: workspace and settings
  plugin/claudio/                    copied from the app bundle at launch
    .claude-plugin/plugin.json
    bin/claudio                      POSIX sh, on the Bash tool's PATH
    skills/note/SKILL.md             "/claudio:note": when and how to write a note
  assistant/
    inbox.log                        lines written by bin/claudio, tailed like hook-events.log
    index.tsv                        project path → project id, for bin/claudio
    runs/                            working directory for `claude -p` jobs
    <project-id>/
      assistant.json                 notes, plan items, skill records
      audit.jsonl                    append-only change log (backs Undo)
      suggestions.json               the suggestions showing on notes (throwaway: no audit, no version)
      plan.md                        read-only snapshot that `claudio plan` prints
      skills/.claude/skills/<name>/SKILL.md    ← the --add-dir root: approved skills only
      drafts/<suggestion-id>/SKILL.md          proposals, outside the add-dir so nothing loads them
      history/<name>/<n>.md                    every approved version
```

## Decisions, by open question

### 1. Storage

**Decision:** keep everything in Claudio's Application Support, one folder per project. Don't put it in `state.json` or in the repository.

- **Not `state.json`.** It's rewritten whole on every save, and the churn rules in `CLAUDE.md` assume it stays small. Assistant data grows without limit (notes, audit), so give it its own file per project, with the same tolerant decoding (`decodeIfPresent`, a version field).
- **Not the repository.**
  - Plan items change all the time. Background agents run in `<repo>/.claude/worktrees/<name>` on their own branches, so each worktree would carry its own copy of a repo plan file, and those copies would diverge and conflict.
  - Agents running in place (`bgIsolation: none`) would sweep the file into unrelated commits.
  - It would also show up in every PR diff.
- **Syncing across machines** isn't in v1. GitHub Issues is the sharing path for plan items (export, as designed). Approved skills can be saved to the repository one at a time (below), which is how they reach a team or another machine. If whole-store sync is wanted later, the per-project folder can move to an iCloud or Dropbox path, because nothing in it is machine-specific except `index.tsv`.
- **Projects are keyed by `Project.id`,** not by path. The data belongs to the project entry: it survives renames and reordering, and removing and re-adding a project starts it afresh.

### 2. Skill format, location and versioning

**Decision:** native Claude Code skills. An approved skill is `<name>/SKILL.md` under `assistant/<project-id>/skills/.claude/skills/`. Claudio passes that root to each session it launches with `--add-dir`.

Why `--add-dir` rather than the other homes:

| Home | Reaches worktree agents | Live reload | Outside-Claudio sessions | Touches user's files | Verdict |
|---|---|---|---|---|---|
| `--add-dir <claudio>/skills` | yes (verified) | yes (docs; not tested) | no | no | **default** |
| `<repo>/.claude/skills` | yes: found by walking up from `.claude/worktrees/w` (verified) | yes | yes | untracked files in the checkout; in-place agents may commit them | **opt-in per skill: "Save to Repository"** |
| Bundled plugin `skills/` | yes | no, needs `/reload-plugins` | no | no | only for Claudio's own `note` skill |
| `~/.claude/skills` | yes | yes | yes, in *every* project | yes, global | no |

- **Name and frontmatter.** `name` is a kebab-case slug. `description` plus `when_to_use` must fit in 1,536 characters (the listing truncates beyond that). Use `paths:` globs when the lesson is tied to files. Claudio's own data goes under `metadata:` (Claude Code ignores that key): `claudio-id`, `claudio-evidence` (session ids) and `claudio-version`.
- **Versioning.** Each approval writes `history/<name>/<n>.md`. The model always returns the **whole proposed text**, never a diff. Claudio computes the "added lines" view with the existing `Diff.swift`, so the diff can't be wrong about what changes.
- **Drift.** `--add-dir` also gives sessions write access to that folder, so a session could edit a skill. On each poll, Claudio hashes the approved files. If one changed outside Claudio, a Needs You card offers Keep Change or Revert. The same check covers skills saved to the repository. The card says who made the change when Claudio can tell: a `PostToolUse` Edit or Write event whose `file_path` is the skill file names the session ("The Update PR session changed …"). Otherwise it just says the file changed. For a repository skill, only the main checkout's copy is watched, so an edit made on a worktree's branch shows up once it's merged.
- **Loading.** The `.claude/skills` directory must exist before a session starts, or live detection needs `/reload-skills` (per the docs). Claudio creates it when the project is added.
- **Save to Repository** copies the skill to `<repo>/.claude/skills/<name>/`, removes Claudio's copy (so sessions don't load it twice), and marks the record `location: repo`. The skill is then the user's to commit. Claudio stops managing it except for the drift check and usage counts.
- **Retire** moves the skill to `retired/<name>/`, outside the `--add-dir` root, so no session loads it. **Restore** moves it back.

### 3. Runtime

**Decision:** short, typed calls per event through a job queue in `AppModel+AssistantJobs.swift`, not a long-lived agent.

Why not a background agent per project:
- It would appear in `claude agents`.
- It uses context all the time, and needs compaction.
- It can't return typed results.
- Resuming it with flags makes a copy.

The work comes in discrete events, and each wants a structured answer.

The command shape (`AgentCommands.assistant(job:)`):

```sh
claude -p --model <haiku|sonnet> --output-format json \
  --json-schema '<job schema>' \
  --system-prompt '<job prompt>' \
  --tools '<"" or Read,Grep,Glob>' [--allowedTools 'Bash(git log:*)' …] \
  --add-dir <repo>            # only for jobs that read the code \
  --strict-mcp-config --no-session-persistence \
  --settings '{"disableAllHooks":true}' --setting-sources '' \
  --max-budget-usd <cap> -- '<job input>'
```

- **Run from `assistant/runs/`, not the project.** That way the project's `CLAUDE.md` and auto-memory aren't loaded into every call. Jobs that need them get them explicitly. `--no-session-persistence` means no history file is written, so `SessionDiscovery` never imports assistant calls (verified in step 2: no `…-runs` folder in `~/.claude/projects`, and no entry in `~/.claude.json`).
- **Don't use `--bare`.** It never reads OAuth or the keychain, so it fails for subscription users.
- **`--setting-sources ''`, not `user`** (measured in step 2, 2.1.284). Loading the user's settings can bring tools into the call. In 1 of 3 runs with `user`, Haiku consulted an Opus advisor tool the user had configured: $0.099 and 43 s, against $0.004–0.006 and 5–8 s otherwise, and 90% of it was the advisor. With `''` that never happened. The user's settings are loaded only when signing in may depend on them: an `apiKeyHelper`, or a provider or key in `env` (`AssistantSettingSources`).
- **Hooks off**, for the same reason as `/usage`: each call would otherwise fire the user's SessionStart hooks.
- **The result** is `structured_output` in the JSON (verified). Step 2 reads it as `JSONValue` and checks each field it uses (the Promote check trusts nothing it can't verify in code). The job's audit entry records `total_cost_usd` and `duration_ms`. A `Codable` result type per job, and `num_turns`, can come with the later jobs if they help.
- **Models.** Haiku for classifying (promote a note, triage labels). Sonnet for follow-ups, skill drafts and Ask. These are Assistant Settings, per project.
- **Concurrency:** two jobs at most overall, first in, first out (step 2). One job at a time per project, and coalescing (a newer follow-up job for the same session replaces a queued one), come with step 4's follow-ups, where they matter.
- **Timeouts and failures.** A job is killed after 60 seconds (120 for Ask, which reads code), and nothing is changed. The runner sorts failures into the reasons the Job Failed view shows:
  - `claude` not found (`locateClaude` returned nil)
  - signed out (step 2 reads it from the reply's text, "Not logged in"; a `claude auth status --json` check can be added if that text changes)
  - timed out
  - output that doesn't match the schema
  - any other exit, with the first line of stderr

  Try Again re-queues the same input.

**Cost, measured and estimated** (`total_cost_usd` is the API-equivalent price; subscription users pay in plan usage instead):
- A stripped classification call (empty directory, no tools, about 1.1k input tokens) cost $0.0039 on Haiku (6.2 s) and $0.0054 on Sonnet (1.5 s).
- The same kind of task with the default system prompt and tools cost $0.064 on Haiku, over 6 turns. So the flags above matter about 15-fold.
- A follow-up job with an 8k-token digest is **estimated** at $0.03–0.06 on Sonnet. *(Measured in step 4a: about $0.01 and 2 s for short digests.)*

**Code checks first; Claude only judges.** A background job reaches the job queue only after a code check has found work for it. Anything a script could answer is done in code and never becomes a Claude call:

| Background work | Checked in code (no Claude) | Claude is called only when |
|---|---|---|
| GitHub issues | `gh issue list --json number,updatedAt` against the issue numbers already seen | there are unseen issues. All of them go in **one** triage call. |
| Issue closed, linked PR merged | `gh` state, already polled for the Pull Requests overview | never: the "Mark Done" suggestion is made by code |
| PR that closes an item's issue | `gh pr view --json closingIssuesReferences` | never: code links the PR to the item |
| Session follow-ups | the "finished" trigger, plus the substance check below | the session changed files, failed a tool call, acted on a PR, committed, was corrected, or had 3 or more prompts since the last follow-up |
| Skill proposals | lesson signatures counted across sessions (below) | a signature has recurred, or the user asked Claude to remember something |
| Skill retirement | usage counts from `PreToolUse` Skill events | never: the Retire card is made by code |
| Skill drift | file hashes | never |
| Plan usage | `claude -p /usage`, already polled, with no model call | never |
| Checking a captured note (step 2) | the gate below, and whether the project is Automatic | the note was just saved, the assistant is on, and usage is under the threshold. Skipped otherwise, not queued (see below). |

A job is also skipped when its input is the same as the last run's (a hash of the digest or issue list is stored with the watermark). And a queued job is replaced, not repeated, when newer input for the same thing arrives.

**Plan-usage gate.** Before running a *background* job (follow-ups, skill drafts, retire checks, issue triage), the gate (`backgroundGate(forProject:)`) reads `AppModel.usage`. It defers the job if any of these holds:
- the 5-hour or weekly window is at or above the **app-level** threshold (Settings, default 80%, one number for both windows)
- `isUsingCredits` is true, unless the user has allowed background work on credits (an app-level toggle, off by default)
- there's no reading yet, but one is expected (a subscription sign-in whose first `/usage` hasn't come back)

Deferred jobs stay queued and are retried on the next usage refresh.

**One exception: checking a captured note** (step 2). It's skipped when the gate says no, not queued. The check is only useful while the note is fresh, and the note keeps its Promote… link, which runs the same check whenever you want it. This matches the design ("Manual, or paused: no automatic check").

Some users never get a plan-usage reading: API-key and Console sign-in (issue #1), Bedrock and Vertex. For them the gate doesn't apply, so it mustn't block. Jobs run, capped only by `--max-budget-usd` per call ($0.05 for quick checks; Claude Code checks it after each turn, so it stops a runaway call rather than capping one turn) and a daily job limit set in Assistant Settings (the limit isn't built yet: step 2 has only the capture check, one Haiku call per note you write, so it comes with step 4's background work). Jobs the user starts (Promote from capture, Ask, Import Issues) always run, with a note in the panel when usage is high. The threshold and the credits toggle are app-level settings in `AppSettings`, not per project, because plan usage belongs to the account, not the project.

### 4. The learning loop

Signals Claudio already receives, plus three new hook events:

| Signal | Source | Used for |
|---|---|---|
| Turn ended, final message | `Stop` → `last_assistant_message` (already parsed) | the follow-ups trigger, and the digest |
| User prompts | `UserPromptSubmit`, and history files | corrections ("no, …", "don't …", "next time …") |
| Tool calls | `PostToolUse` (already parsed) | PR activity, commands, the digest |
| **Tool failures** | **new: `PostToolUseFailure`** (`tool_name`, `tool_input`, `error` as a string, `is_interrupt`, `duration_ms`; recorded in step 4). It fires when a tool runs and fails, including a Bash command that exits non-zero, not when a command is denied. | "learned the hard way" evidence. `is_interrupt: true` is the user pressing Esc, so it doesn't count. |
| ~~Denied actions~~ | ~~`PermissionDenied`~~ | *Dropped in step 4:* it didn't fire when default mode denied a command (2.1.284), so it's probably auto-mode only. Corrections come from prompts instead. |
| **Turn failed** | **new: `StopFailure`** (`error` as a string, such as `authentication_failed`, and `last_assistant_message`; recorded in step 4). It fires *instead of* `Stop`: with both set up, only `StopFailure` fired (2.1.285 and 2.1.169). | it ends the turn, so the session isn't left Working. Don't draw lessons from a turn that ended in an API error. |
| Skill used | `PreToolUse` with `tool_name == "Skill"` | the "used by n sessions" count, and retirement |
| Files changed | `SessionChanges` / `ChangesDirectory` | skill `paths`, and skill selection |
| PRs | `Session.pullRequests`, via `gh` | follow-ups ("PR #14 merged"), and marking items Done |

Add the two events to `HookSettings.events`. *(Step 4: real payloads are recorded in `Fixtures/hook-failures.log`. 2.1.169 accepts both keys in `--settings` and fires `StopFailure`. The Skill tool's input key is `skill`, recorded from a `PreToolUse` event.)*

**When each job runs:**

- **Promote (right after capture):** in Automatic mode this is background work, so the usage gate applies. Promote… on a note is started by you, so it always runs. In Off mode, Promote… makes an Idea from the note in code, with no call. One Haiku call per saved note. Input: the note, plus the plan's items that aren't done, each as a ref ("i1"), title and status. The refs are resolved with the map made for that call, never renumbered when the reply comes back. Output: `{kind: bug|task|idea|fact, promote: Bool, title, reason, duplicateOf: ref|null}`. Measured at 5–8 s.
- **Follow-ups (when a session finishes):** *(Superseded in step 4a: follow-ups are offered on Claude Code's own signals, with no timer, and run only when you accept. See Build order › 4 › Done in 4a, and Decisions. The substance check and the digest below still apply.)*
  - `Stop` fires at the end of *every turn*, so it isn't "finished". A session counts as finished when it's Completed (not Awaiting Input), has been quiet for 2 minutes, and has new turns since its last follow-up (a watermark per session: the count of Stop events). Stopping the agent or closing its tab brings the job forward.
  - **Substance check (code):** only call Claude if, since the last follow-up, the session changed files, had a tool failure, acted on a PR, made a commit, got a prompt matching a correction pattern ("no,", "don't", "instead", "next time", "remember"), or had 3 or more prompts. Otherwise there's nothing to follow up, and no call is made. A quick question and answer never costs a follow-up.
  - Input: a **digest**, built by Swift from the history file (first prompt, user corrections, failures, commands, the final message, files changed, PR state). It's capped at about 8k tokens, not the raw transcript. Also the current plan (ids, titles, statuses), the item this session belongs to, and the auto-memory index.
  - Output: `notes[]` (saved at once, marked assistant, undoable), `planChanges[]` (new item, move, mark done; each needs approval) and `lessons[]` (candidates, below).
  - This fills the follow-up card and its Needs You entry.
- **Skill proposals (not per session):**
  - A lesson from a follow-up is stored as a candidate with its evidence (session id, the failing command, the correction). Code gives each one a **signature** from its evidence, not from the model's wording: for example the failing command's first two words plus the error's first line, normalised (`git worktree` + "refused…"), or the tool name and the files involved.
  - A draft is only requested when one of these holds:
    - (a) the same signature appears in at least 2 sessions (counted in code), or
    - (b) the user corrected Claude explicitly and said to remember it (flagged by the follow-up job, which is already running).
  - So a lesson seen once costs nothing beyond the follow-up that found it.
  - The drafting call gets the existing skills and must prefer **patching** one over adding a new one.
  - Deterministic checks run in Swift before the card appears: referenced paths exist, commands exist on `PATH`, length limits, a valid name, the description limit, and no secrets (the same patterns as the Activity Log's redaction).
  - A draft that fails is dropped and logged, never shown.
- **Retire:** a daily check in code, with no Claude call. An approved skill that no session has used for 30 days becomes a Needs You card with Retire or Keep.
- **On demand:** a "Review this session" item in the session's context menu runs the follow-up job straight away.

### 5. Skill selection at session start

**Decision:** score skills in Swift, with no model call. Be honest in the UI about what a chip does.

- **How chips are picked.** A chip for skill *s* on item *i* scores from three things:
  - *s*'s `paths` globs matching files that *i*'s linked sessions touched
  - *s*'s `metadata.claudio-folders` or labels matching the folder picked for the session, and *i*'s issue labels
  - how often *s* was used by sessions in that folder

  *(Changed in step 3: items have no folder, so the folder terms use the one picked in New Session from Plan.)*

  Show at most 3. This matches the design's "Picked from the files this item touches."
- **What a chip means.** Every approved skill is visible to every Claudio session in the project by its description. That's how native skills load, and `paths` already limits auto-activation to matching files. So a chip means "**named in the opening prompt**": the prompt says "Use the /worktree-setup and /shell-panel-code-map skills". Removing a chip leaves the skill out of the prompt, but Claude can still use it if it matches. The sheet's hint should say so, for example "Named in the opening prompt."
- **Later, if needed: a skill set per session.** Give each session its own `--add-dir` root containing only its chosen skills. **Not verified:** that the skill loader follows symlinks. Without symlinks, it means copying skills per session.

### 6. GitHub

- **Poll with `gh`; no webhooks.** A desktop app has no public endpoint.
  - Every 10 minutes, while the project's assistant is on and the repository is on GitHub, run a light query: `gh issue list --state open --json number,updatedAt --limit 100`.
  - Compare it with the issue numbers already seen, which are stored per project. Only if there are unseen numbers, fetch their `title,body,labels,author` with a second `gh` call.
  - Import Issues… runs the full query straight away. Record `gh` output as fixtures, as `GitHubCLI` does.
- **Triage:** one Haiku call per batch of *new* issues, and only when the poll found some. The input is the issues, the repository's existing labels (`gh label list --json name,description`) and the plan's item titles and linked issues. The output per issue is `{label?, action: add|attach|skip, targetItemID?, reason}`. Only existing labels are suggested, and nothing is applied to GitHub.
- **Duplicates:**
  - Deterministic first: the issue is already linked to an item, or the same URL appears in a note.
  - Then the model: "attach to item X" when the titles match.
- **Export:** Create GitHub Issue runs `gh issue create --title … --body-file -`, with the item's notes as the body. It stores the returned number on the item, and logs it in the Activity Log. Nothing else writes to GitHub.
- **Status back from GitHub (code only):** an issue closed on GitHub, or a linked PR merged, leads to a "Mark Done" suggestion, never an automatic change. A PR whose `closingIssuesReferences` includes an item's issue is linked to the item. Neither needs Claude.

### 7. Chat (Ask)

- **The call:** one Sonnet call per question, run from `runs/` with `--add-dir <repo>` and `--tools Read,Grep,Glob`. `--allowedTools` covers `Bash(git log:*)`, `Bash(git show:*)` and `Bash(gh issue view:*)`, so the answer can look at code and history but can't change anything.
- **Context given in the prompt:**
  - the plan (items shown as `[i3] title · status · issue · session`)
  - the most recent 50 notes
  - sessions and their statuses and summaries
  - the auto-memory index
  - the previous question and answer, for a follow-up
- **The answer** comes back as `{answer: markdown, cites: [itemID]}`. Claudio shows chips only for `cites` that are real item ids, and drops any `[iN]` in the text that isn't one. A follow-up reuses the previous exchange as input rather than using `--resume`, so no history file is ever needed.

### 8. Audit and Undo

- `audit.jsonl` gets one line per change: `{id, at, actor: user|assistant|session, action, entity, before, after, cause}`. `cause` is a job id, a session id or `ui`. Assistant job lines also carry the model, cost, duration and outcome.
- Undo applies the inverse of an entry. It's shown for entries the assistant wrote, as designed. The mechanism is general, so the user's own changes could get Undo later.
- The entry is written *before* the change is saved, and a change whose entry can't be written isn't made (step 1). So every change that lands has an entry. A save that then fails leaves an entry for a change that didn't happen, so anything that reads the log (Undo, the Activity Log view) checks an entry against the current data before acting on it or showing it as done.
- The Assistant's own Activity Log view (⋯) lists the job entries from `audit.jsonl` for that project, as Done, Waiting (held by the usage gate) or Failed. Jobs a code check never started aren't listed, because nothing happened.
- Each job and each export also gets one line in the Activity Log (`log.append`), for example "Assistant: suggested 3 follow-ups for Shell Terminal (Sonnet, 4.1 s)". Prompts and account details are never logged.

### 9. Privacy

- **What leaves the machine:** only what goes in a `claude -p` call, to the user's own Claude provider, under the same account and terms as their sessions. That means note text, digests (excerpts of the user's own transcripts), plan titles, issue text, and code read by Ask. Nothing goes to GitHub except on Create GitHub Issue. No other service is involved.
- **Per project, in Assistant Settings:**
  - **Off:** notes and plan still work by hand. No jobs run, and no background polling.
  - **Manual:** jobs run only when the user asks: Promote, Review this session, Import Issues, Ask.
  - **Automatic** (the default for new projects): Manual, plus the background work in the table under Runtime, each behind its code check.
  - "Don't send transcripts": follow-ups use only the final message and the list of changed files.
- **A global switch** in Settings turns all assistant jobs off.

## Installing and first run

Nothing is installed into `~/.claude`, the repository or the user's settings by default.

1. **The bundled plugin.**
   - *Built in step 3, in place of shipping it in `Contents/Resources`:* the plugin's files are embedded in `ClaudioCore` (`ClaudioPlugin`). At launch, if any file in `~/Library/Application Support/Claudio/plugin/claudio/` differs, the whole plugin is written to a folder beside it, then moved into place.
   - **The path must be stable,** because `--plugin-dir`'s absolute path is saved in the job's `respawnFlags` (verified). A path inside the app bundle would break when the app moves or updates, and App Translocation randomises it.
   - Running agents pick up new plugin content on `/reload-plugins` or a respawn.
2. **Per-project folders** (`assistant/<project-id>/skills/.claude/skills/`) are created when a project is added, and for existing projects on first launch. `index.tsv` is rewritten whenever projects change.
3. **The launch flags** `--plugin-dir <plugin>` and `--add-dir <project skills root>` go on every *new* session: `AgentCommands.dispatch` and the direct `TerminalLaunch.make` for `--session-id`.
   - They are **never added when continuing an agent**, because resuming with flags starts a copy.
   - So background agents that exist before the upgrade keep their old flags, and never get the plugin or the skills. They still feed the learning loop, because hooks and history are read app-side. *(Step 3, from review round 1 on PR #26: a direct-mode session is a new process on every launch, so it gets the flags each time, `--resume` included, and older direct sessions gain them. So does a background resume that isn't continuing an agent.)*
   - The New Session sheet could say this once for the first session after an upgrade. It isn't in the design.
4. **Version gate.** All the flags used here exist in 2.1.169, the current minimum (checked with `--help`), so the minimum doesn't change.
5. **Opt-in, for sessions outside Claudio.** Assistant Settings could offer "Use Claudio's skills in all Claude Code sessions". That would use `claude plugin marketplace add <App Support path>` and `claude plugin install claudio@claudio --scope user`, which writes `enabledPlugins` to `~/.claude/settings.json`. It would only happen after an explicit click, with the command shown. It isn't needed for v1.

### The session-side plugin

- **`bin/claudio`** is a POSIX `sh` script: no dependencies, and testable on Linux.
  - It identifies its session from `$CLAUDE_CODE_SESSION_ID`, which is set in the Bash tool of background agents (verified in 2.1.284) and of direct-mode tabs (verified in 2.1.285, step 3). `$CLAUDIO_SESSION_ID`, which `TerminalLaunch.make` sets, is kept as a fallback. It identifies its project from `$PWD` via `index.tsv`, matching the longest path (worktrees sit under the repository).
  - It writes base64 text, so nothing needs JSON escaping in shell: `printf '%s\t%s\tnote\t%s\n' "$sid" "$PWD" "$(printf %s "$text" | base64 | tr -d '\n')" >> inbox.log`. The `tr` matters: GNU `base64` wraps its output at 76 columns, and BSD `base64` doesn't. That's the same single-write append as `HookSettings.command`.
  - Commands:
    - `claudio plan`: prints `plan.md`
    - `claudio item <id>`: an item with its notes
    - `claudio note "<text>"`: a note, saved at once and undoable, and tagged as written by that session (see Notes and authorship)
    - `claudio suggest "<text>"`: a plan change that goes to Needs You
- **`skills/note/SKILL.md`** (`/claudio:note`) tells the session when a note is worth writing: non-obvious, not in the code, not already in memory. It also says to use `claudio note`, and never to edit plan files.
  - **Decided:** sessions may write notes on their own, so the skill is model-invocable. Its description sets a high bar, so sessions don't write a note every turn.

#### Notes and authorship

Every note records who wrote it: `author: user | assistant | session`, plus `sessionID` when a session wrote it, or when the note came from a follow-up about a session.
- **user:** from the capture box (⇧⌘N). The note may still be *linked* to the focused session, but the author is you. The link is optional: an × in the capture box removes it for a thought that isn't about that session (step 2).
- **assistant:** from a follow-up job. Shown with the ✦ marker and Undo, as designed.
- **session:** from `claudio note` inside a session. Shown as "<session name> · time", with Undo like assistant notes. Its marker is a teal `terminal` icon, with "A session" in the legend (build 9a; step 1 ships it).

Follow-up jobs get the notes that session already wrote, and don't repeat them.
- **Why a file and not an MCP server:**
  - `bin/` needs no process management.
  - The inbox is ingested even if Claudio was closed when the note was written.
  - It follows the pattern `hook-events.log` already proves.

## Where it lives in the code

| Piece | Target | Notes |
|---|---|---|
| `AssistantStoring` (`AssistantFileStore`, and `MemoryAssistantStore` as `AppModel`'s default), models (`ProjectNote`, `AssistantData`, `AuditEntry`; later `PlanItem`, `Suggestion`, `SkillRecord`), Undo | ClaudioCore | One file per project. A file from a newer version is refused (read-only), never downgraded. Most tests use the memory store; file behaviour is tested in a temporary directory. |
| `AssistantJobs`: prompt, schema and `Codable` result for each job | ClaudioCore | Pure functions. Tests use recorded `structured_output` fixtures. |
| `AppModel+AssistantJobs.swift`: queue, usage gate (coalescing in step 4) | ClaudioCore | Uses the injectable command runner (a fake in tests). |
| `SessionDigest`: history, hooks and changes into a capped digest | ClaudioCore | Builds on `Transcript` and `SessionChanges`. |
| `SkillFiles`: frontmatter, write/approve/revert, hashes, checks | ClaudioCore | Uses `Diff.swift` for the added-lines view. |
| `InboxReader` | ClaudioCore | Built in step 3. Unlike `HookEventTailer`, it reads from a saved offset (`inbox.offset`), not the end, so notes written while Claudio was closed arrive. |
| New hook events | ClaudioCore | `HookSettings.events`, `HookEventParser` fields, with fixtures. |
| `AppModel+Assistant.swift` | ClaudioCore | UI entry points, as `AppModel+PullRequests.swift` does. |
| Plugin files | `ClaudioPlugin` in `AssistantPlugin.swift` (ClaudioCore) | Embedded, and written out at launch (step 3). `bin/claudio` is tested under `/bin/sh`. |
| Views | Claudio | Only the 9a panel, sheet and card. |

## Build order (the handover's order, with backend steps)

1. **Notes and capture.** `AssistantStoring`, `audit.jsonl`, and Undo. No model calls.
2. **Plan items and promotion.** The first job (Promote, Haiku) brings in the job queue, the usage gate, and the job fixtures.
   - **Done in step 2:**
     - Plan items in `assistant.json`, now version 2, so a step 1 build refuses the file (read-only) rather than dropping the plan. A note's link to its item is stored on the note only.
     - **Lenient decoding** (carried over from step 1's review, PR #21): notes and items are decoded one by one. An entry that fails is kept as raw JSON, written back unchanged, and counted in the panel. The project is refused whole only for a newer version.
     - **Added (Tim's request, PR #24):** an × on "Linked to <session>" in the capture box, so a note that isn't about the focused session (a new feature idea, say) can be saved unlinked. New Note pressed again keeps it unlinked.
     - **Added after step 2 (Tim's request, PR #25):**
       - Suggestions on notes survive a relaunch, in `suggestions.json` beside `assistant.json`. That file is kept apart because suggestions are throwaway: they need no audit entry, and no version bump that would make step 2 builds refuse `assistant.json`.
       - "Checking…" isn't saved.
       - At launch, a saved suggestion is only restored if it still applies: its note is there without an item, and an Attach target is still in the plan and not done. The file is then rewritten to match.
       - **Check Again** on a suggestion, and **Check Against Plan** in a note's menu, run the check afresh. The new answer replaces the old one, and a failed check leaves the old one in place.
       - Each note card has a **⋯** menu in its top-right corner with its actions (Copy, Check Against Plan, Add to Plan, Attach To, Detach, Delete). A right-click only reached them on the card's edges, because the selectable text has its own menu.
       - The suggestion's wording became a question on its own line ("Create a plan item from this note?"), then the reason, then the item.
       - A note's **Promote…** link is now **Check Against Plan…** while the assistant is on, and **Add as Idea** while it's off, since "Promote…" read as though it would create the item.
     - **Moved earlier from step 4:** app-level Settings › Assistant (the switch, the threshold and the credits toggle), so the first Claude call ships with a way to turn it off. The project's mode is stored now (Automatic by default; Off makes Promote… add an Idea with no call). Its UI waits for step 4's Assistant Settings.
     - Each call is recorded in `audit.jsonl` (`jobRan`), for step 4's Activity Log view.
   - **Moved on to step 4:** tolerant reading of `audit.jsonl` (carried over from step 1's review). Step 2 doesn't read the log; the first reader is step 4's Activity Log view.
3. **Start Session from an item.**
   - The opening prompt builder.
   - The skills root and `--add-dir`.
   - The bundled plugin, `--plugin-dir`, `bin/claudio`, and the inbox.
   - Skill chip scoring. Before this ships, the list of approved skills is empty, but the flags are in place.
   - **Done in step 3:**
     - **Start Session** on a plan item that isn't done opens New Session from Plan. The opening prompt (`OpeningPrompt`) is the title, `Notes:` with the attached notes oldest first, `GitHub issue: #n`, then `Use these skills: /a, /b`. An item without notes sends just its title, not the design's "No notes attached." filler. The model and permissions are the settings' defaults, since the sheet has neither. Only once the session exists does the item move to In Session, linked to it, with an audit entry. If that session is deleted, the item offers Start Session again.
     - **Launch flags** (`AssistantLaunch`): `--plugin-dir` and `--add-dir <assistant/<id>/skills>` go on `dispatch` and the direct `--session-id` launch, on every new session whatever the project's mode (Off means no Claude calls; flags can't be added later without making a copy). *(Changed in review round 1: they also go on every direct launch, `--resume` included, and on `resume(continuingAgent: false)`. Only continuing a background agent goes without.)* A flag whose folder isn't there is left out. The same sessions' `--settings` JSON allows `Bash(claudio:*)`, so `claudio note` runs without asking in Ask mode (see Decisions). `Session.hasAssistant` records sessions launched with the plugin (skills alone don't count, since without the plugin a session can't write notes), which drives the "Started before the assistant" hint. `Session.namedSkills` keeps the skills the prompt named, for SKILLS NAMED IN ITS PROMPT. Both live in `state.json` (tolerant decoding), so `assistant.json` stays at version 2.
     - **Changed from the design: the plugin is embedded in `ClaudioCore`** (`ClaudioPlugin`), not shipped in `Contents/Resources` and copied by `build-app.sh`. It's written to `plugin/claudio/` at launch whenever any file there differs from what it should be. Files are compared, not a version number, so a forgotten version bump can't leave old files. It's built in a folder beside the target and then moved into place. That way `bin/claudio` is tested on Linux and `swift run` works.
     - **`bin/claudio`:** `plan`, `item <id>` and `note "<text>"` (or `note -` for standard input). It finds `assistant/` from its own path. Item ids are the first 8 characters of the item's UUID. `plan.md` (`PlanSnapshot`) is rewritten after every change and at launch, with item lines `- [id] title · issue · session` and indented notes, so `claudio plan` leaves notes out and `claudio item` cuts out one item. `index.tsv` is checked on every save and written when it changes.
     - **The inbox:** Claudio reads `inbox.log` every half second (with hook events) and at launch. `InboxReader` saves its position in `inbox.offset` rather than starting at the end like the hook tailer, so notes written while Claudio was closed arrive, and none arrives twice. The session is found by Claude Code's id, then by Claudio's id (direct tabs), then the project by the longest project path containing the directory. A note from the session working on an item joins that item. Notes are capped at 4,000 characters. `inbox.log` isn't compacted; notes are small.
     - **Skill chips** (`SkillChips`, `SkillFiles`, `Glob`): scored in code from `paths` globs against files the item's sessions changed (worktree paths read as repository paths), and `metadata.claudio-folders` against the folder picked in the sheet (the chips are picked again when it changes, leaving out any you removed). At most 3, and none that score nothing. The frontmatter reader handles only what skill files use.
   - **Notes and plan items have no folder** (Tim's call, PR #26). `PlanItem.folderID` is gone, so Promote no longer files an item in its session's folder, and the item view has no folder line. A step 2 file's `folderID` is ignored and dropped on the next save; step 2 builds already read items without one, so `assistant.json` stays at version 2. The only folder is the new session's, picked in New Session from Plan, starting at Unfiled.
   - **Tested in the app** (Tim, 2.1.285, PR #26): the sheet with and without a folder-matched skill; the session's opening prompt and `Skill(test-skill)` loading; `respawnFlags` holding `--plugin-dir`, `--add-dir` and the `Bash(claudio:*)` rule; `claudio plan`, `item` and `note` from a worktree agent (in auto mode), the note attached to the item and undone; a note written while Claudio was closed arriving once; a direct-mode tab's note; a resume with no new flags.
   - **Moved on to step 4:** `claudio suggest` (a plan change from a session, into Needs You). Needs You doesn't exist yet, so the command and the note skill leave it out.
   - **Fixed in review round 1 (PR #26):**
     - The inbox reader keeps its place in memory as well as in `inbox.offset`. It takes nothing when the place can't be saved, and treats an offset file it can't read as an error rather than 0, so notes are never read twice. The failure is logged once.
     - A session note that can't be saved is logged with its text (it also stays in `inbox.log`), not shown as an alert. Projects whose notes can't be read are left out of `index.tsv`, so `claudio` refuses there.
     - `startSession` checks `canStartSession` itself, refuses for an unreadable project before starting anything, says so when the item is gone or the link fails, names only approved skills, and puts the item back (with an audit entry) when its background agent fails to start.
     - `claudio note` refuses a note Claudio would drop (no session and no project), and notes over 4,000 characters.
     - The plugin is swapped in by renames with the old copy moved aside, not deleted first; a failed update keeps using the old copy.
     - `index.tsv` drops trailing slashes and leaves out paths with tabs or line breaks. Item ids that collide in a plan are written in full. Note text that isn't UTF-8 is kept, with replacement characters.
   - **Moved on to step 5:**
     - Logging `SKILL.md` files that can't be read or have no closing `---` (from review round 1, PR #26), with step 5's deterministic skill checks. Today such a skill is skipped or read without its frontmatter, silently.
     - Chip scoring's usage term (skill use from `PreToolUse` Skill events).
     - Its touched files should come from the linked sessions' history (`EditLogCache` over their history files), not from `sessionChanges`, which only has sessions whose Files Changed has loaded. So for now the file term depends on what's been opened.
4. **Follow-ups.** The ~~three~~ two new hook events, `SessionDigest`, the "finished" trigger, and the follow-up card.
   - **Decided at the start of step 4 (Tim, 2026-09-29):**
     - **Two PRs.** 4a: the hook events, the digest, the finished trigger, the follow-up card, Needs You, Review This Session, `claudio suggest`, and the queue's per-project limit and coalescing. 4b: Assistant Settings, the paused line, the Activity Log and Job Failed views, and tolerant audit reading.
     - **Follow-ups for every session** in an Automatic project, behind the substance check. Not only sessions from plan items. *(Later in 4a: offered, not run; see below.)*
     - **The daily job limit is 20** background calls. **Moved into 4a** (it was 4b's): it had to ship with the first background Sonnet calls. Once follow-ups became offers, it only caps the captured-note check. Its editing UI stays in 4b.
     - **Real probes** on Tim's account are fine for recording CLI behaviour (Haiku, a few cents).
   - **Baseline for existing sessions:** a session with no follow-up watermark gets one at the current end of its history, with no call. So upgrading, or importing old sessions, never starts a burst of follow-ups. The watermark is kept with the conversation it belongs to (`/clear` starts a new one).
   - **Lessons wait for step 5:** 4a's follow-up schema has no `lessons` field. Step 5 adds it with the candidates it feeds.
   - **Done in 4a:**
     - **Hook events:** `PostToolUseFailure` and `StopFailure` are in `HookSettings.events`. `StopFailure` ends the turn (Completed) and sets `Session.lastTurnFailed`, which holds back its follow-up until a turn ends normally.
     - **`SessionDigest`**, built in code from the history file since the session's `FollowUpMark` (conversation id and byte offset; `HistorySlice` reads only the new whole lines). It holds prompts, corrections, commands, failures, changed files, commits, `gh pr` commands and the final message, each capped. The whole call input is capped at 60,000 characters. Changed files come from the history's own Edit and Write calls, so it doesn't depend on Files Changed having loaded.
     - **Offers, not calls (Tim's call during 4a, replacing the 2-minute timer):** a timer can't tell a finished session from one left overnight, one waiting for a usage limit to reset, or one paused mid-task. So Claudio *offers* a follow-up when code decides a session looks ready, and Claude is only asked when you accept (**Follow Up**; **Not Now** dismisses it). Accepting counts as something you started: no usage gate, no daily limit. Follow-ups make no background calls at all.
     - **When a session looks ready,** checked every 15 s (its own `Polling.every`), from Claude Code's own signals only:
       - its last turn ended normally. A `StopFailure` (a usage limit, an API error) doesn't count, so the session carries on when the limit resets;
       - it isn't waiting on you (a question or a permission prompt: Awaiting Input);
       - Claude Code's task state for its agent (`claude agents --json`) is `done` or `review_ready`, **or** you stopped it or closed its tab. `working` means Claude Code expects to carry on, so nothing is offered. Direct tabs have no task state, so only stopping or closing counts for them;
       - the project is Automatic (Manual: only Review This Session), and the digest since the last follow-up has substance.
     - **A new prompt withdraws the offer** (the `UserPromptSubmit` hook): the session is carrying on, and it's offered again at its next ready point, covering everything since the last follow-up. **Not Now** isn't offered again for the same history, across launches too (`Session.followUpDeclined` keeps where the history had got to); once the session does more and looks ready again, it is. Offers aren't saved: after a relaunch, a session that still looks ready is offered again.
     - **Evidence that the signal is there:** of 40 background agents' job files on Tim's machine (2026-09-30), 34 were `done`, 3 `blocked` (waiting on him, so no offer), 1 `working` and 1 `failed`; none was `review_ready`. So Claude Code does move finished tasks to `done`.
     - **What code reads:** a session's history file only when its size has changed since the last check. A session from before this build, seen for the first time, gets a mark at its history's end (the file's size: nothing is read), so upgrading offers nothing for old work. A session made in Claudio after it starts with a mark that matches no conversation, so its first ready point covers its whole history. A conversation whose history file isn't found (Claude Code deletes old ones) isn't looked for again until the next launch. When a conversation has files in both the repository's folder and a worktree's, the newest is read.
     - **The follow-up call:** Sonnet, `--max-budget-usd 0.30`, 120 s. Input: the digest, the plan by refs, the session's item, its notes and the project's `MEMORY.md` (first 4,000 characters). Output: notes (at most 5, saved at once as assistant notes, undoable) and plan changes (at most 5: add, done, move; refs checked when the reply arrives and again when applied). The mark only moves on success.
     - **The card** under the session's terminal (offered, working, ready, failed), and **Needs You** in the panel (an unanswered offer waits there as "<session> looks done"). Finished and failed follow-ups and session suggestions are kept in `needs-you.json` (throwaway, like `suggestions.json`, with entries that can't be read kept as they were). Offers and follow-ups still working aren't saved: their session's mark didn't move, so it may be offered again. There's a drill-in view for a follow-up, and the rail's blue badge counts what's waiting.
     - **Review This Session** in the session's ⋯ menu. It runs straight away in Automatic or Manual mode, and reads the whole conversation when nothing is new. With the assistant off, it shows a toast.
     - **`claudio suggest`**: a Needs You card with Add to Plan, Add as Idea and Dismiss.
     - **The queue:** two calls at once, and one *background* call per project (the captured-note check: follow-ups only run when you accept), so things you start never wait behind one. A newer job with the same key (`followup:<session>`) replaces one still waiting.
     - **The daily limit** of 20 background calls a day, for sign-ins without a plan-usage reading, counted in `daily-jobs.json`. With follow-ups offered rather than run, only the captured-note check is background work now. Things you start, accepted offers included, don't count.
   - **Fixed in review round 1 (PR #28):**
     - **Not Now** holds until a new *prompt*: lines a history gains without one (a rename's title, Claude Code's bookkeeping, a stop) don't bring the offer back.
     - **A failed follow-up** on a session's card is replaced by a new offer or follow-up for the same work, so there's never one of each. A failure you deferred to Needs You stays.
     - **Add n to Plan** counts only changes that saved, and leaves any that didn't on the card. Unticking a note only shows it unticked once it's really gone. A follow-up note that can't be saved is logged with its text.
     - **Review This Session** can't start twice from two quick clicks. Try Again after a relaunch keeps the failed card until the new follow-up takes its place.
     - **Reading history:** a read that fails is logged and tried again, instead of looking like "nothing new". At most the newest 8 MB is read at once.
     - **`needs-you.json`** is read one entry at a time, and an entry that can't be read is kept as it was. A plan change that doesn't make sense (a new item with an item id, "done" to Idea, a move to Done or In Session) can't be made or read.
     - A `StopFailure` is logged with its error. A daily count that can't be read is logged once and starts at 0. A `claudio suggest` card shows in Needs You with the assistant off too, since the session was told you'd see it.
   - **Moved on to 4b:**
     - A failed follow-up shows its message with Try Again and Close in its own view. The Job Failed view and the Activity Log link come with 4b's Activity Log.
     - "Don't send transcripts" (the digest supports it: `json(withTranscripts:)`), the model choice, the daily limit's editing UI, and the paused line with its count of what's waiting.
   - **Measured in Tim's testing (2026-09-30, Sonnet, 2.1.285):** $0.0097 in 2.0 s (a two-prompt test session), and $0.0104 in 2.1 s (Review This Session on a long session from before this build, which read only its latest turns). Well under the $0.03–0.06 estimate. The tests still use a reply written by hand from the schema.
   - **Known limit:** files written by shell commands (`echo > file`, `sed -i`, `mv`) don't count as changed files in the digest: only Edit, MultiEdit, Write and NotebookEdit calls do. Found in Tim's testing, when a session wrote its file with Bash. Sessions normally edit through those tools, and reading shell redirections reliably is guesswork, so it's left as is.
   - **`claudio suggest`** (moved from step 3): a session's proposed plan change, as a Needs You card. Add it to `bin/claudio`, the inbox's commands and the note skill.
   - **The job queue's per-project limit and coalescing** (from step 2's review, PR #24): one job at a time per project, and a newer follow-up for the same session replacing a queued one. Step 2 has only the overall limit of two, first in, first out. *(4a: the per-project limit is for background calls only; see Done in 4a.)*
   - **Assistant Settings** (per project: the mode's UI, "Don't send transcripts", models), the paused status line, the daily job limit for users without a plan-usage reading, and **the Assistant's Activity Log view**, with the Job Failed view for background failures.
   - **Decided at the start of 4b (Tim, 2026-10-01):**
     - **Held-back work waits, in a queue built now:** background jobs the usage gate holds back are queued and run once it opens, newest replacing an older one with the same key. It's tried on the captured-note check (which step 2 skipped instead), so later steps (GitHub triage, skills) use the same pattern. This is what the paused line's "n waiting" and the Activity Log's Waiting rows count. *(Reverses step 2's "skip, don't queue" for the note check.)*
     - **The daily job limit is edited in Settings › Assistant,** app-wide beside the pause threshold, since the count is the account's, not a project's.
     - **The model pickers offer Haiku, Sonnet and Opus,** both defaulting as before (Haiku for quick checks, Sonnet for follow-ups), each with a short cost hint.
   - **Carried over from step 1's review (PR #21), moved here from step 2:** tolerant reading of `audit.jsonl`. `AuditEntry` still uses the synthesized, strict `Codable`. The Activity Log view, the log's first reader, must skip or tolerate lines it can't decode (from a newer version, or cut short), and check each entry against the data before showing it as done (see Audit and Undo).
5. **Skills.** Lesson candidates, the drafting job, checks, approval, history, drift, retirement, and Save to Repository.
6. **GitHub.** Polling, triage, export, and status suggestions.
7. **Ask.**

## What was verified

| Claim | How |
|---|---|
| `--plugin-dir` and `--add-dir` are kept in a background agent's `respawnFlags`, and reach the agent process | `claude --bg --plugin-dir /plug/claudio …` in a 2.1.284 container. `~/.claude/jobs/<id>/state.json` → `respawnFlags: ["--plugin-dir","/plug/claudio","--settings",…]`, and the same for `--add-dir`. |
| A plugin's skill loads as `claudio:<name>`, and its `bin/` is on the Bash PATH | A real `claude -p --plugin-dir` call (Haiku) listed `claudio:probe`, read its text, and ran `claudio ping`. |
| `--json-schema` returns `structured_output` in `--output-format json` | The same calls. |
| A skill in `<repo>/.claude/skills/` (uncommitted) loads in a session started in `<repo>/.claude/worktrees/w` | A real `claude -p` call run from the worktree listed it. |
| Skills under an `--add-dir` root's `.claude/skills/` load | The same call listed `addprobe`. |
| A launch's environment isn't saved for respawns | `CLAUDIO_SESSION_ID=… claude --bg` in a container. The job's `providerEnv` is `{}`. Whether the variable reaches the *first* agent process couldn't be settled. Agents are often started in pre-spawned `bg-spare` processes, and `/proc/<pid>/environ` doesn't show what those set once claimed. So nothing here relies on per-launch environment variables. |
| `CLAUDE_CODE_SESSION_ID` is set in a background agent's Bash tool | Read from this session's own Bash tool (2.1.284). Direct-mode tabs (`--session-id`) have it too: Tim's step 3 test (2.1.285) printed the conversation id, and `claudio note` from that tab wrote it to the inbox. |
| Costs listed under Runtime | `total_cost_usd` from the calls above. |
| `--plugin-dir` and `--add-dir` work from a path with a space in it (`…/a b/Claudio/…`, as under `Application Support`) | Real Haiku calls (2.1.284, step 3): `claudio:note` loaded, `bin/claudio` ran from the Bash tool (with an allow rule; see the next row), and an `--add-dir` skill loaded. |
| A session in Ask mode can't run `claudio` without an allow rule; `permissions.allow: ["Bash(claudio:*)"]` in `--settings` lets it | Real Haiku calls (2.1.284, `--permission-mode default`): without the rule the Bash call was denied (`permission_denials`); with it in the `--settings` JSON, `claudio ping` ran. |
| `--add-dir` skills need project settings loaded | The same probe: with `--setting-sources ''` the add-dir skill was "Unknown skill", while the plugin's skill loaded; with `project` it loaded. Sessions load every source by default, so they get it. Only the assistant's own `-p` calls use `''`. |
| `PostToolUseFailure` and `StopFailure` payloads; `StopFailure` replaces `Stop`; the Skill tool's input key is `skill`; `PermissionDenied` doesn't fire for a default-mode denial | Step 4 probes: Haiku `-p` runs with a recording hook (2.1.284/285), and a signed-out container with a rejected key for `StopFailure` (no cost). 2.1.169 accepts both keys and fires `StopFailure`. Recorded in `Fixtures/hook-failures.log`. |
| 2.1.169 has every flag used here | `claude --help` in a 2.1.169 container. |
| `--setting-sources user` can bring in the user's tools; `''` doesn't | Six real Promote-check calls (Haiku, 2.1.284): with `user`, 1 in 3 consulted an Opus advisor ($0.099, 43 s); with `''`, $0.004 and 5–7 s. |
| `--max-budget-usd` stops a call after the turn that crosses it: `"subtype": "error_max_budget_usd"`, `terminal_reason: "budget_exhausted"`, no `result` | Real Haiku calls (2.1.284): a normal check at $0.05 succeeded; one at $0.0001 was stopped after spending $0.0046. Recorded in `Fixtures/assistant-over-budget.json`. |
| Assistant calls from `assistant/runs` with `--no-session-persistence` don't show up as a project | After the probe calls: no `…-runs` folder in `~/.claude/projects`, no entry in `~/.claude.json`. (Calls that loaded user settings left an empty `memory/` folder, which import ignores: it needs a `.jsonl`.) |
| A failed `-p` call still reports `"subtype": "success"`; `is_error`, `terminal_reason: "api_error"` and exit 1 tell | A signed-out container, and one with a rejected API key (2.1.284). The rejected key took 190 s of retries, so the 60 s timeout matters. Recorded in `Fixtures/assistant-*.json`. |

**Assumed, and to check at the build step that needs it:**
- live reload of `--add-dir` skills (step 5)
- whether the skill loader follows symlinks (only for skill sets per session)

## Decisions

Decided (2026-09-28):
- **Where skills live:** Claudio's folder via `--add-dir`. Save to Repository stays as a per-skill action.
- **Usage threshold:** app-level, user-configurable, default 80%.
- **Session notes:** allowed, and tagged with the session as author.
- **Skill chips:** a chip means "named in the opening prompt", and the sheet's hint says so. There are no skill sets per session.
- **Default mode:** Automatic. Background work is checked in code first, and Claude is called only for judgement (see Runtime).
- **Plan in git:** no. There's no `PLAN.md` export.

Decided in step 4a (2026-09-30):
- **No baseline when Automatic is turned back on** (Tim's call, PR #28 review round 1). Sessions made while a project was Manual or Off, or while the assistant switch was off, keep their unread start. So turning Automatic on can bring a one-off batch of offers for sessions finished meanwhile. Offers cost nothing, and Review This Session covers anything skipped.
- **Follow-ups are offered, not run.** Code decides a session looks ready from Claude Code's own signals (turn ended normally, not waiting on you, task state `done` or `review_ready`, or stopped); the card asks, and Claude is called only when you accept. No timers, so sessions left overnight or waiting for a usage limit cost nothing. A new prompt withdraws the offer.

Decided in step 3 (2026-09-29):
- **Session flags whatever the mode:** every new session gets `--plugin-dir` and `--add-dir`, even in a project set to Off or with the app switch off. Off means no Claude calls, and notes and plans stay. Flags can't be added to a session later without making a copy.
- **`claudio` runs without asking:** the same sessions' `--settings` JSON allows `Bash(claudio:*)` (`HookSettings.claudioAllowRule`). Without it, in Ask mode a session's first `claudio note` stops for approval, which would leave a background agent Awaiting Input and send a notification. The rule covers only Claudio's own command, which appends to Claudio's inbox or prints the plan.

Still open: none. The marker for notes written by a session is in build 9a: a teal `terminal` icon.

## Sources

- Claude Code docs: [Skills](https://code.claude.com/docs/en/skills), [Plugins reference](https://code.claude.com/docs/en/plugins-reference), [Hooks](https://code.claude.com/docs/en/hooks), [Memory](https://code.claude.com/docs/en/memory)
- [About GitHub Copilot Memory](https://docs.github.com/en/copilot/concepts/agents/copilot-memory)
- [autoharness / skill learning discussion](https://github.com/codelisperer/ouranos/issues/327), [skill-molt](https://dev.to/_konippi/your-coding-agent-discovers-gold-every-session-then-throws-it-away-38me)
- [CCPM](https://github.com/automazeio/ccpm), [Kiro steering and specs](https://kirotutorial.com/concepts/steering/)
- [Skill Issue: Lessons from Optimizing Repository SKILLs for Coding Agents](https://arxiv.org/abs/2609.12742), [Do Personalized Skills Help Coding Agents?](https://arxiv.org/abs/2608.10319)
