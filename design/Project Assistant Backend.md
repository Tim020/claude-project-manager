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
│  AssistantStore (ClaudioCore)      AssistantRunner (ClaudioCore)    │
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
      assistant.json                 notes, plan items, suggestions, skill records
      audit.jsonl                    append-only change log (backs Undo)
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
- **Projects are keyed by `Project.id`,** not by path, so moving a project folder doesn't orphan its data.

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
- **Drift.** `--add-dir` also gives sessions write access to that folder, so a session could edit a skill. On each poll, Claudio hashes the approved files. If one changed outside Claudio, a Needs You card offers Keep or Revert. The same check covers skills saved to the repository.
- **Loading.** The `.claude/skills` directory must exist before a session starts, or live detection needs `/reload-skills` (per the docs). Claudio creates it when the project is added.
- **Save to Repository** copies the skill to `<repo>/.claude/skills/<name>/` and marks the record `location: repo`. The skill is then the user's to commit. Claudio stops managing it except for the drift check.

### 3. Runtime

**Decision:** short, typed calls per event through an `AssistantRunner` queue, not a long-lived agent.

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
  --settings '{"disableAllHooks":true}' --setting-sources user \
  --max-budget-usd <cap> -- '<job input>'
```

- **Run from `assistant/runs/`, not the project.** That way the project's `CLAUDE.md` and auto-memory aren't loaded into every call. Jobs that need them get them explicitly. `--no-session-persistence` means no history file is written, so `SessionDiscovery` never imports assistant calls. Exclude the `runs` encoded directory anyway.
- **Don't use `--bare`.** It never reads OAuth or the keychain, so it fails for subscription users. `--setting-sources user` keeps the user's provider settings (Bedrock, `apiKeyHelper`) but drops project settings. My measured call used `""`. **Assumed:** `user` costs about the same.
- **Hooks off**, for the same reason as `/usage`: each call would otherwise fire the user's SessionStart hooks.
- **The result** is `structured_output` in the JSON (verified). Decode it into a `Codable` type per job, and reject anything that doesn't match. Also record `total_cost_usd`, `duration_ms` and `num_turns` in the audit entry.
- **Models.** Haiku for classifying (promote a note, triage labels). Sonnet for follow-ups, skill drafts and Ask. These are Assistant Settings, per project.
- **Concurrency:** one job at a time per project, and two at most overall. Jobs are coalesced: a newer follow-up job for the same session replaces a queued one.

**Cost, measured and estimated** (`total_cost_usd` is the API-equivalent price; subscription users pay in plan usage instead):
- A stripped classification call (empty directory, no tools, about 1.1k input tokens) cost $0.0039 on Haiku (6.2 s) and $0.0054 on Sonnet (1.5 s).
- The same kind of task with the default system prompt and tools cost $0.064 on Haiku, over 6 turns. So the flags above matter about 15-fold.
- A follow-up job with an 8k-token digest is **estimated** at $0.03–0.06 on Sonnet. It hasn't been measured.

**Plan-usage gate.** Before running a *background* job (follow-ups, skill drafts, retire checks, issue triage), `AssistantRunner` reads `AppModel.usage`. It defers the job if any of these holds:
- the 5-hour window is at 80% or more
- the weekly window is at 90% or more
- `isUsingCredits` is true
- there's no reading yet

Deferred jobs stay queued and are retried on the next usage refresh. Jobs the user starts (Promote from capture, Ask, Import Issues) always run, with a note in the panel when usage is high. The thresholds are settings.

### 4. The learning loop

Signals Claudio already receives, plus three new hook events:

| Signal | Source | Used for |
|---|---|---|
| Turn ended, final message | `Stop` → `last_assistant_message` (already parsed) | the follow-ups trigger, and the digest |
| User prompts | `UserPromptSubmit`, and history files | corrections ("no, …", "don't …", "next time …") |
| Tool calls | `PostToolUse` (already parsed) | PR activity, commands, the digest |
| **Tool failures** | **new: `PostToolUseFailure`** (`tool_name`, `tool_input`, `error.message`) | "learned the hard way" evidence |
| **Denied actions** | **new: `PermissionDenied`** | the user refused something, which is a strong correction signal |
| **Turn failed** | **new: `StopFailure`** (`error.type`: rate_limit, overloaded, …) | don't draw lessons from a turn that ended in an API error |
| Skill used | `PreToolUse` with `tool_name == "Skill"` | the "used by n sessions" count, and retirement |
| Files changed | `SessionChanges` / `ChangesDirectory` | skill `paths`, and skill selection |
| PRs | `Session.pullRequests`, via `gh` | follow-ups ("PR #14 merged"), and marking items Done |

Add the three events to `HookSettings.events`. Record real payloads as fixtures before writing the parsers. The field names above come from the hooks docs and aren't recorded yet. The Skill tool's input key is **assumed** to be `skill`.

**When each job runs:**

- **Promote (right after capture):** one Haiku call per saved note. Input: the note, plus plan item titles for duplicates. Output: `{kind: bug|task|idea|fact, promote: Bool, reason, duplicateOf?}`. Measured at about 1.5–6 s, fast enough for the inline suggestion.
- **Follow-ups (when a session finishes):**
  - `Stop` fires at the end of *every turn*, so it isn't "finished". A session counts as finished when it's Completed (not Awaiting Input), has been quiet for 2 minutes, and has new turns since its last follow-up (a watermark per session: the count of Stop events). Stopping the agent or closing its tab brings the job forward.
  - Input: a **digest**, built by Swift from the history file (first prompt, user corrections, failures, commands, the final message, files changed, PR state). It's capped at about 8k tokens, not the raw transcript. Also the current plan (ids, titles, statuses), the item this session belongs to, and the auto-memory index.
  - Output: `notes[]` (saved at once, marked assistant, undoable), `planChanges[]` (new item, move, mark done; each needs approval) and `lessons[]` (candidates, below).
  - This fills the follow-up card and its Needs You entry.
- **Skill proposals (not per session):**
  - A lesson from a follow-up is stored as a candidate with its evidence (session id, the failing command, the correction). A draft is only requested when one of these holds:
    - (a) the same lesson recurs in at least 2 sessions (matched by the drafting call, which gets the candidate list), or
    - (b) the user corrected Claude explicitly and said to remember it.
  - The drafting call gets the existing skills and must prefer **patching** one over adding a new one.
  - Deterministic checks run in Swift before the card appears: referenced paths exist, commands exist on `PATH`, length limits, a valid name, the description limit, and no secrets (the same patterns as the Activity Log's redaction).
  - A draft that fails is dropped and logged, never shown.
- **Retire:** a daily check. An approved skill that no session has used for 30 days becomes a Needs You card with Retire or Keep.
- **On demand:** a "Review this session" item in the session's context menu runs the follow-up job straight away.

### 5. Skill selection at session start

**Decision:** score skills in Swift, with no model call. Be honest in the UI about what a chip does.

- **How chips are picked.** A chip for skill *s* on item *i* scores from three things:
  - *s*'s `paths` globs matching files that *i*'s linked sessions touched
  - *s*'s `metadata.claudio-folders` or labels matching *i*'s folder and issue labels
  - how often *s* was used by sessions in the same folder

  Show at most 3. This matches the design's "Picked from the files this item touches."
- **What a chip means.** Every approved skill is visible to every Claudio session in the project by its description. That's how native skills load, and `paths` already limits auto-activation to matching files. So a chip means "**named in the opening prompt**": the prompt says "Use the /worktree-setup and /shell-panel-code-map skills". Removing a chip leaves the skill out of the prompt, but Claude can still use it if it matches. The sheet's hint should say so, for example "Named in the opening prompt."
- **Later, if needed: a skill set per session.** Give each session its own `--add-dir` root containing only its chosen skills. **Not verified:** that the skill loader follows symlinks. Without symlinks, it means copying skills per session.

### 6. GitHub

- **Poll with `gh`; no webhooks.** A desktop app has no public endpoint. Run `gh issue list --state open --json number,title,body,labels,author,createdAt,updatedAt --search "updated:>=<watermark>"` every 10 minutes, but only while the project's assistant is on and the repository is on GitHub. Import Issues… runs the same query straight away without the watermark. Record `gh` output as fixtures, as `GitHubCLI` does.
- **Triage:** one Haiku call per batch of new issues. The input is the issues, the repository's existing labels (`gh label list --json name,description`) and the plan's item titles and linked issues. The output per issue is `{label?, action: add|attach|skip, targetItemID?, reason}`. Only existing labels are suggested, and nothing is applied to GitHub.
- **Duplicates:**
  - Deterministic first: the issue is already linked to an item, or the same URL appears in a note.
  - Then the model: "attach to item X" when the titles match.
- **Export:** Create GitHub Issue runs `gh issue create --title … --body-file -`, with the item's notes as the body. It stores the returned number on the item, and logs it in the Activity Log. Nothing else writes to GitHub.
- **Status back from GitHub:** an issue closed on GitHub, or a linked PR merged, leads to a "Mark Done" suggestion, never an automatic change.

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
- Each job and each export also gets one line in the Activity Log (`log.append`), for example "Assistant: suggested 3 follow-ups for Shell Terminal (Sonnet, 4.1 s)". Prompts and account details are never logged.

### 9. Privacy

- **What leaves the machine:** only what goes in a `claude -p` call, to the user's own Claude provider, under the same account and terms as their sessions. That means note text, digests (excerpts of the user's own transcripts), plan titles, issue text, and code read by Ask. Nothing goes to GitHub except on Create GitHub Issue. No other service is involved.
- **Per project, in Assistant Settings:**
  - **Off:** notes and plan still work by hand. No jobs run, and no background polling.
  - **Manual:** jobs run only when the user asks: Promote, Review this session, Import Issues, Ask.
  - **Automatic** (the default for new projects; see Open decisions): everything above.
  - "Don't send transcripts": follow-ups use only the final message and the list of changed files.
- **A global switch** in Settings turns all assistant jobs off.

## Installing and first run

Nothing is installed into `~/.claude`, the repository or the user's settings by default.

1. **The bundled plugin.**
   - The app ships `Contents/Resources/ClaudioPlugin/`. At launch, if its version differs from `plugin/claudio/.claude-plugin/plugin.json`, it's copied to `~/Library/Application Support/Claudio/plugin/claudio/`: written to a temporary folder, then renamed into place.
   - **The path must be stable,** because `--plugin-dir`'s absolute path is saved in the job's `respawnFlags` (verified). A path inside the app bundle would break when the app moves or updates, and App Translocation randomises it.
   - Running agents pick up new plugin content on `/reload-plugins` or a respawn.
2. **Per-project folders** (`assistant/<project-id>/skills/.claude/skills/`) are created when a project is added, and for existing projects on first launch. `index.tsv` is rewritten whenever projects change.
3. **The launch flags** `--plugin-dir <plugin>` and `--add-dir <project skills root>` go on every *new* session: `AgentCommands.dispatch` and the direct `TerminalLaunch.make` for `--session-id`.
   - They are **never added when continuing an agent**, because resuming with flags starts a copy.
   - So sessions that exist before the upgrade keep their old flags, and never get the plugin or the skills. They still feed the learning loop, because hooks and history are read app-side.
   - The New Session sheet could say this once for the first session after an upgrade. It isn't in the design.
4. **Version gate.** All the flags used here exist in 2.1.169, the current minimum (checked with `--help`), so the minimum doesn't change.
5. **Opt-in, for sessions outside Claudio.** Assistant Settings could offer "Use Claudio's skills in all Claude Code sessions". That would use `claude plugin marketplace add <App Support path>` and `claude plugin install claudio@claudio --scope user`, which writes `enabledPlugins` to `~/.claude/settings.json`. It would only happen after an explicit click, with the command shown. It isn't needed for v1.

### The session-side plugin

- **`bin/claudio`** is a POSIX `sh` script: no dependencies, and testable on Linux.
  - It identifies its session from `$CLAUDE_CODE_SESSION_ID`, which is set in a background agent's Bash tool (verified in 2.1.284), and its project from `$PWD` via `index.tsv`, matching the longest path (worktrees sit under the repository).
  - It writes base64 text, so nothing needs JSON escaping in shell: `printf '%s\t%s\tnote\t%s\n' "$sid" "$PWD" "$(printf %s "$text" | base64)" >> inbox.log`. That's the same single-write append as `HookSettings.command`.
  - Commands:
    - `claudio plan`: prints `plan.md`
    - `claudio item <id>`: an item with its notes
    - `claudio note "<text>"`: a note, saved at once and undoable
    - `claudio suggest "<text>"`: a plan change that goes to Needs You
- **`skills/note/SKILL.md`** (`/claudio:note`) tells the session when a note is worth writing: non-obvious, not in the code, not already in memory. It also says to use `claudio note`, and never to edit plan files.
  - **To decide:** whether sessions should write notes on their own in v1. That's Open decision 4. If not, ship the skill with `disable-model-invocation: true`, so only the user's `/claudio:note` triggers it.
- **Why a file and not an MCP server:**
  - `bin/` needs no process management.
  - The inbox is ingested even if Claudio was closed when the note was written.
  - It follows the pattern `hook-events.log` already proves.

## Where it lives in the code

| Piece | Target | Notes |
|---|---|---|
| `AssistantStore`: models (`Note`, `PlanItem`, `Suggestion`, `SkillRecord`, `AuditEntry`), load/save, Undo | ClaudioCore | Tolerant decoding. One file per project. Tests use a temporary directory. |
| `AssistantJobs`: prompt, schema and `Codable` result for each job | ClaudioCore | Pure functions. Tests use recorded `structured_output` fixtures. |
| `AssistantRunner`: queue, usage gate, coalescing | ClaudioCore | Uses the injectable command runner (`FakeRunner` in tests). |
| `SessionDigest`: history, hooks and changes into a capped digest | ClaudioCore | Builds on `Transcript` and `SessionChanges`. |
| `SkillFiles`: frontmatter, write/approve/revert, hashes, checks | ClaudioCore | Uses `Diff.swift` for the added-lines view. |
| `InboxTailer` | ClaudioCore | Same shape as `HookEventTailer`. |
| New hook events | ClaudioCore | `HookSettings.events`, `HookEventParser` fields, with fixtures. |
| `AppModel+Assistant.swift` | ClaudioCore | UI entry points, as `AppModel+PullRequests.swift` does. |
| Plugin files | `Sources/Claudio/Resources/ClaudioPlugin/` | Copied by `build-app.sh`. The copy-on-launch code is in core, and tested. |
| Views | Claudio | Only the 9a panel, sheet and card. |

## Build order (the handover's order, with backend steps)

1. **Notes and capture.** `AssistantStore`, `audit.jsonl`, and Undo. No model calls.
2. **Plan items and promotion.** The first job (Promote, Haiku) brings in `AssistantRunner`, the usage gate, and the job fixtures.
3. **Start Session from an item.**
   - The opening prompt builder.
   - The skills root and `--add-dir`.
   - The bundled plugin, `--plugin-dir`, `bin/claudio`, and the inbox.
   - Skill chip scoring. Before this ships, the list of approved skills is empty, but the flags are in place.
4. **Follow-ups.** The three new hook events, `SessionDigest`, the "finished" trigger, and the follow-up card.
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
| Per-launch environment variables don't reach the agent | `CLAUDIO_SESSION_ID=… claude --bg` in a container. The job's `providerEnv` is `{}`. The agent inherits its environment from the shared daemon, which only has the variables of whichever launch started it. |
| `CLAUDE_CODE_SESSION_ID` is set in a background agent's Bash tool | Read from this session's own Bash tool (2.1.284). |
| Costs listed under Runtime | `total_cost_usd` from the calls above. |
| 2.1.169 has every flag used here | `claude --help` in a 2.1.169 container. |

**Assumed, and to check at the build step that needs it:**
- live reload of `--add-dir` skills (step 5)
- hook payload field names for the three new events, and the Skill tool's input key (step 4)
- whether the skill loader follows symlinks (only for skill sets per session)
- the cost of `--setting-sources user` compared with `""` (step 2)

## Open decisions for Tim

1. **Where approved skills live by default.**
   - Claudio's folder via `--add-dir` (recommended; the repository stays clean).
   - Or `<repo>/.claude/skills`, so they're shared through git from day one, at the cost of untracked files and the risk of accidental commits.
2. **What a removed skill chip means.**
   - "Not named in the opening prompt" (recommended for v1, with honest hint text).
   - Or a real skill set per session (more work, and depends on the symlink check).
3. **The assistant's default for new projects:** Automatic, Manual or Off. Also the usage thresholds for background jobs (proposed: 80% of the 5-hour window, 90% of the week, never while using credits).
4. **Whether sessions may write notes themselves** through `claudio note` in v1, or only when the user types `/claudio:note`. Self-written notes add signal, but overlap with auto memory.
5. **Plan data in git.** The proposal keeps it out and uses GitHub Issues for sharing. If you want a committed `PLAN.md` export as well, it should be a one-way export, never read back.

## Sources

- Claude Code docs: [Skills](https://code.claude.com/docs/en/skills), [Plugins reference](https://code.claude.com/docs/en/plugins-reference), [Hooks](https://code.claude.com/docs/en/hooks), [Memory](https://code.claude.com/docs/en/memory)
- [About GitHub Copilot Memory](https://docs.github.com/en/copilot/concepts/agents/copilot-memory)
- [autoharness / skill learning discussion](https://github.com/codelisperer/ouranos/issues/327), [skill-molt](https://dev.to/_konippi/your-coding-agent-discovers-gold-every-session-then-throws-it-away-38me)
- [CCPM](https://github.com/automazeio/ccpm), [Kiro steering and specs](https://kirotutorial.com/concepts/steering/)
- [Skill Issue: Lessons from Optimizing Repository SKILLs for Coding Agents](https://arxiv.org/abs/2609.12742), [Do Personalized Skills Help Coding Agents?](https://arxiv.org/abs/2608.10319)
