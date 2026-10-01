import Foundation

// The assistant's Claude calls (design: `design/Project Assistant
// Backend.md`, Runtime). Each is one short `claude -p` run with a JSON
// schema, no tools and no session history, from a working directory of its
// own. Code decides when to call; the reply is only ever a suggestion.

/// One `claude -p` call for the assistant.
public struct AssistantCall: Equatable, Sendable {
    /// The job, for the Activity Log: "Promote check".
    public var job: String
    /// A model alias: "haiku" or "sonnet".
    public var model: String
    public var systemPrompt: String
    /// The reply's JSON schema.
    public var schema: String
    /// What the model reads: the job's input, as JSON.
    public var input: String
    /// `--max-budget-usd`, at API prices. Claude Code checks it after each
    /// turn, so it stops a call that runs away (more turns, an unexpected
    /// tool) rather than capping one turn exactly.
    public var maxBudgetUSD: Double
    /// Seconds before the call is stopped (the launch's own timeout).
    public var timeout: Int

    public init(job: String, model: String, systemPrompt: String, schema: String, input: String,
                maxBudgetUSD: Double = AssistantCall.quickBudgetUSD, timeout: Int = AssistantCall.quickTimeout) {
        self.job = job
        self.model = model
        self.systemPrompt = systemPrompt
        self.schema = schema
        self.input = input
        self.maxBudgetUSD = maxBudgetUSD
        self.timeout = timeout
    }

    /// A quick check costs $0.004–0.006 (Haiku, measured with 2.1.284).
    /// This is Haiku's cap; other models scale it (`AssistantModel.budgetFactor`).
    public static let quickBudgetUSD = 0.05
    /// A quick check answers in 5–8 s.
    public static let quickTimeout = 60
    /// `CLAUDE_CODE_MAX_RETRIES` for assistant calls. Claude Code's default
    /// retried a rejected API key for 190 s; with 2 it fails in about 3 s,
    /// with the real error (checked with 2.1.284). Overloads still get retries.
    public static let maxRetries = 2
}

public enum AssistantModels {
    /// Quick checks (Promote, issue triage).
    public static let quick = "haiku"

    public static func displayName(_ alias: String) -> String {
        alias.prefix(1).uppercased() + alias.dropFirst()
    }
}

/// Which of the user's settings files a call loads (`--setting-sources`).
///
/// None, normally: loading the user's settings can bring tools into the call
/// that it doesn't need. With 2.1.284 a user-settings call sometimes consulted
/// an Opus advisor tool the user had set up, costing about 20 times as much
/// and taking over 40 s. The user's settings are loaded only when signing in
/// may depend on them: an `apiKeyHelper`, or a provider chosen in `env`.
public enum AssistantSettingSources {
    static let providerKeys = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                               "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]

    public static func value(userSettings: JSONValue?) -> String {
        guard let settings = userSettings else { return "" }
        if settings["apiKeyHelper"] != nil { return "user" }
        if let env = settings["env"]?.objectValue, providerKeys.contains(where: { env[$0] != nil }) { return "user" }
        return ""
    }
}

extension AgentCommands {
    /// `claude -p` for an assistant call. Hooks are off (each `-p` run would
    /// fire the user's SessionStart hooks), and nothing is saved as a session,
    /// so Claudio never imports it.
    public func assistant(_ call: AssistantCall, in directory: String, settingSources: String) -> TerminalLaunch {
        var launch = command(["-p", "--model", call.model, "--output-format", "json",
                              "--json-schema", call.schema, "--system-prompt", call.systemPrompt,
                              "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                              "--settings", #"{"disableAllHooks":true}"#, "--setting-sources", settingSources,
                              "--max-budget-usd", String(format: "%.2f", call.maxBudgetUSD)]
                             + TerminalLaunch.promptArguments(call.input),
                             in: directory)
        launch.label = "claude -p (assistant: \(call.job), \(AssistantModels.displayName(call.model)))"
        launch.environment["CLAUDE_CODE_MAX_RETRIES"] = String(AssistantCall.maxRetries)
        launch.timeout = TimeInterval(call.timeout)
        return launch
    }
}

/// Why an assistant call gave no answer, in the words the panel shows.
public enum AssistantFailure: Equatable, Sendable, Error {
    case claudeMissing
    case signedOut
    case timedOut(seconds: Int)
    /// Claude Code answered with an error (its message).
    case apiError(String)
    /// The reply didn't match the schema.
    case invalidReply
    /// It went over its `--max-budget-usd` and was stopped.
    case overBudget(Double)
    /// Anything else (the command's output).
    case failed(String)

    public var message: String {
        switch self {
        case .claudeMissing:
            return "Claudio couldn't find the claude command. Install Claude Code, or set its location in Settings."
        case .signedOut:
            return "Claude Code is installed but not signed in. Run claude in a Shell and sign in, then try again."
        case .timedOut(let seconds):
            return "No answer came back within \(seconds) seconds. Nothing was changed. If this keeps happening, check that Claude Code is signed in: run claude in a Shell."
        case .apiError(let text):
            return "Claude Code couldn't answer: \(text)"
        case .invalidReply:
            return "The answer wasn't in the form Claudio expected. Nothing was changed."
        case .overBudget(let limit):
            return String(format: "It went over its cost limit ($%.2f at API prices), so it was stopped. Nothing was changed.", limit)
        case .failed(let text):
            return "The assistant's call failed: \(text)"
        }
    }
}

/// What came back from an assistant call.
public struct AssistantReply: Equatable, Sendable {
    public var output: JSONValue
    /// API-equivalent price, as Claude Code reports it (subscriptions pay in
    /// plan usage instead).
    public var costUSD: Double?
    public var durationMS: Int?
}

public enum AssistantReplyParser {
    /// Reads `claude -p --output-format json`. A failed call still says
    /// `"subtype": "success"`; `is_error` and the exit code are what tell
    /// (recorded with 2.1.284: signed out, and a rejected API key).
    /// An exceeded `--max-budget-usd` says `"subtype": "error_max_budget_usd"`,
    /// `terminal_reason: "budget_exhausted"`, with no `result`.
    public static func parse(_ result: CommandResult, timeout: Int, budget: Double = AssistantCall.quickBudgetUSD)
        -> Result<AssistantReply, AssistantFailure> {
        if result.timedOut { return .failure(.timedOut(seconds: timeout)) }
        guard let json = envelope(in: result.output) else {
            // Not the JSON reply at all: stderr says why ("command not found"),
            // and stdout (which may hold the note) is never shown.
            let error = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(result.exitCode == 0 ? .invalidReply : .failed(error.isEmpty ? "exit code \(result.exitCode)" : String(error.prefix(300))))
        }
        let text = json["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if json["subtype"]?.stringValue == "error_max_budget_usd" || json["terminal_reason"]?.stringValue == "budget_exhausted" {
            return .failure(.overBudget(budget))
        }
        if json["is_error"]?.boolValue == true || result.exitCode != 0 {
            if text.localizedCaseInsensitiveContains("not logged in") || text.contains("/login") { return .failure(.signedOut) }
            return .failure(.apiError(text.isEmpty ? errorDescription(of: json, exitCode: result.exitCode) : String(text.prefix(300))))
        }
        guard let output = json["structured_output"], output.objectValue != nil else { return .failure(.invalidReply) }
        return .success(AssistantReply(output: output, costUSD: json["total_cost_usd"]?.doubleValue,
                                       durationMS: json["duration_ms"]?.doubleValue.map { Int($0) }))
    }

    /// The reply is the last line that's a JSON object: a login shell's
    /// profile may print lines of its own first.
    static func envelope(in output: String) -> JSONValue? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)), json.objectValue != nil
            else { continue }
            return json
        }
        return nil
    }

    /// An error with no `result` text (`error_during_execution`,
    /// `error_max_turns`…): its `errors`, else its subtype and reason.
    static func errorDescription(of json: JSONValue, exitCode: Int32) -> String {
        let errors = (json["errors"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["message"]?.stringValue }
        if !errors.isEmpty { return String(errors.joined(separator: "; ").prefix(300)) }
        let parts = [json["subtype"]?.stringValue, json["terminal_reason"]?.stringValue].compactMap { $0 }
        return parts.isEmpty ? "exit code \(exitCode)" : parts.joined(separator: ", ")
    }

    /// What a reply looked like, for the Activity Log when it wasn't usable:
    /// its type, subtype, reason and keys, never its contents (which may
    /// hold the note).
    public static func summary(of output: String) -> String {
        guard let json = envelope(in: output), let object = json.objectValue else {
            return "No JSON reply (\(output.count) characters of output)."
        }
        let fields = ["type", "subtype", "terminal_reason"].compactMap { key in json[key]?.stringValue.map { "\(key): \($0)" } }
        return (fields + ["keys: " + object.keys.sorted().joined(separator: ", ")]).joined(separator: " · ")
    }
}

// MARK: - The Promote check

/// Checks a note against the plan: is it work worth planning, and does an
/// item already cover it? Its answer is only a suggestion on the note.
public enum PromoteCheck {
    public static let job = "Promote check"

    static let systemPrompt = """
    You check one note from a software project's notebook against the project's plan.
    Decide what kind of note it is: a bug, a task, an idea, or a fact (knowledge worth keeping, not work).
    Set promote to true when the note describes work worth adding to the plan.
    If an existing plan item already covers the same work, set duplicateOf to that item's ref; otherwise null.
    title: a short plan item title for the note's work, under 60 characters, British English, no full stop.
    reason: under 12 words, for the user, such as "Reads like a bug." or "Same work as the shell height item."
    Reply only through the schema.
    """

    static let schema = #"{"type":"object","properties":{"kind":{"type":"string","enum":["bug","task","idea","fact"]},"promote":{"type":"boolean"},"title":{"type":"string"},"duplicateOf":{"type":["string","null"]},"reason":{"type":"string"}},"required":["kind","promote","title","duplicateOf","reason"],"additionalProperties":false}"#

    /// The plan items the model sees, by short ref ("i1"), so it never
    /// handles real ids. Items that are done aren't offered.
    public static func refs(for items: [PlanItem]) -> [(ref: String, item: PlanItem)] {
        items.filter { $0.status != .done }.enumerated().map { ("i\($0.offset + 1)", $0.element) }
    }

    /// A check to run: the call, and which item each ref in it stands for.
    /// Refs are positions, so they're resolved with the map made for the
    /// call, never renumbered from the plan when the reply comes back.
    public struct Request: Equatable, Sendable {
        public var call: AssistantCall
        public var refs: [String: UUID]
    }

    public static func request(note: ProjectNote, items: [PlanItem], model: AssistantModel = .haiku) -> Request {
        let offered = refs(for: items)
        let plan: [JSONValue] = offered.map {
            .object(["ref": .string($0.ref), "title": .string($0.item.title), "status": .string($0.item.status.rawValue)])
        }
        let input = JSONValue.object(["note": .string(note.text), "plan": .array(plan)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Request(call: AssistantCall(job: job, model: model.rawValue, systemPrompt: systemPrompt, schema: schema, input: text,
                                           maxBudgetUSD: AssistantCall.quickBudgetUSD * model.budgetFactor),
                       refs: Dictionary(uniqueKeysWithValues: offered.map { ($0.ref, $0.item.id) }))
    }

    /// The suggestion to show, or nil for none. The reply is untrusted: its
    /// `duplicateOf` is looked up in the call's own `refs`, and only counts
    /// if that item is still in the plan and not done (`items`: the plan
    /// now). The title is cleaned, falling back to one from the note.
    /// `askedFor`: the user pressed Promote…, so they get a Promote
    /// suggestion even when the model wouldn't have made one.
    public static func suggestion(from reply: JSONValue, note: ProjectNote, refs: [String: UUID], items: [PlanItem],
                                  askedFor: Bool) -> NoteSuggestion? {
        let reason = SuggestionCopy.sentence(reply["reason"]?.stringValue ?? "")
        if let ref = reply["duplicateOf"]?.stringValue, let itemID = refs[ref],
           items.contains(where: { $0.id == itemID && $0.status != .done }) {
            return .attach(itemID: itemID, reason: reason)
        }
        guard reply["promote"]?.boolValue == true || askedFor else { return nil }
        let title = PlanTitle.clean(reply["title"]?.stringValue ?? "")
        let status: PlanStatus = reply["kind"]?.stringValue == "idea" ? .idea : .planned
        return .promote(title: title.isEmpty ? PlanTitle.from(note.text) : title, status: status, reason: reason)
    }
}
