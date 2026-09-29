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

    public init(job: String, model: String, systemPrompt: String, schema: String, input: String) {
        self.job = job
        self.model = model
        self.systemPrompt = systemPrompt
        self.schema = schema
        self.input = input
    }
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
/// an Opus advisor tool the user had set up, costing about 15 times as much
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
                              "--settings", #"{"disableAllHooks":true}"#, "--setting-sources", settingSources]
                             + TerminalLaunch.promptArguments(call.input),
                             in: directory)
        launch.label = "claude -p (assistant: \(call.job), \(AssistantModels.displayName(call.model)))"
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
    /// Anything else (the command's output).
    case failed(String)

    public var message: String {
        switch self {
        case .claudeMissing:
            return "Claudio couldn't find the claude command. Install Claude Code, or set its location in Settings."
        case .signedOut:
            return "Claude Code is installed but not signed in. Run claude in a Shell and sign in, then try again."
        case .timedOut(let seconds):
            return "No answer came back within \(seconds) seconds. Nothing was changed."
        case .apiError(let text):
            return "Claude Code couldn't answer: \(text)"
        case .invalidReply:
            return "The answer wasn't in the form Claudio expected. Nothing was changed."
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
    public static func parse(_ result: CommandResult, timeout: Int) -> Result<AssistantReply, AssistantFailure> {
        if result.timedOut { return .failure(.timedOut(seconds: timeout)) }
        let json = result.output.firstIndex(of: "{").flatMap { start in
            try? JSONDecoder().decode(JSONValue.self, from: Data(result.output[start...].utf8))
        }
        guard let json else {
            return .failure(result.exitCode == 0 ? .invalidReply : .failed(result.failureMessage))
        }
        let text = json["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if json["is_error"]?.boolValue == true || result.exitCode != 0 {
            if text.localizedCaseInsensitiveContains("not logged in") || text.contains("/login") { return .failure(.signedOut) }
            return .failure(.apiError(text.isEmpty ? result.failureMessage : String(text.prefix(300))))
        }
        guard let output = json["structured_output"], output.objectValue != nil else { return .failure(.invalidReply) }
        return .success(AssistantReply(output: output, costUSD: json["total_cost_usd"]?.doubleValue,
                                       durationMS: json["duration_ms"]?.doubleValue.map { Int($0) }))
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

    public static func call(note: ProjectNote, items: [PlanItem], model: String = AssistantModels.quick) -> AssistantCall {
        let plan: [JSONValue] = refs(for: items).map {
            .object(["ref": .string($0.ref), "title": .string($0.item.title), "status": .string($0.item.status.rawValue)])
        }
        let input = JSONValue.object(["note": .string(note.text), "plan": .array(plan)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AssistantCall(job: job, model: model, systemPrompt: systemPrompt, schema: schema, input: text)
    }

    /// The suggestion to show, or nil for none. The reply is untrusted: a
    /// `duplicateOf` that isn't one of `refs` is ignored, and the title is
    /// cleaned, falling back to one from the note. `askedFor`: the user
    /// pressed Promote…, so they get a Promote suggestion even when the model
    /// wouldn't have made one.
    public static func suggestion(from reply: JSONValue, note: ProjectNote, items: [PlanItem], askedFor: Bool) -> NoteSuggestion? {
        let reason = PlanTitle.clean(reply["reason"]?.stringValue ?? "")
        if let ref = reply["duplicateOf"]?.stringValue, let match = refs(for: items).first(where: { $0.ref == ref }) {
            return .attach(itemID: match.item.id, reason: reason)
        }
        guard reply["promote"]?.boolValue == true || askedFor else { return nil }
        let title = PlanTitle.clean(reply["title"]?.stringValue ?? "")
        let status: PlanStatus = reply["kind"]?.stringValue == "idea" ? .idea : .planned
        return .promote(title: title.isEmpty ? PlanTitle.from(note.text) : title, status: status, reason: reason)
    }
}
