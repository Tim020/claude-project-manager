import Foundation

/// One row of the session transcript, rendered as `mark  text` in a monospaced
/// column as in the design (`>` prompt, `⏺` tool call, `*` assistant reply).
public struct TranscriptLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case prompt
        case assistant
        case tool
        case error
    }

    public var id: Int
    public var kind: Kind
    public var text: String

    public var mark: String {
        switch kind {
        case .prompt: return ">"
        case .assistant: return "*"
        case .tool: return "⏺"
        case .error: return "!"
        }
    }
}

/// Folds stream events into transcript lines.
public struct TranscriptBuilder: Equatable, Sendable {
    public private(set) var lines: [TranscriptLine] = []
    public var workingDirectory: String
    private var seenToolIDs: Set<String> = []
    private var nextID = 0

    public init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    public mutating func appendPrompt(_ text: String) {
        append(.prompt, text)
    }

    public mutating func appendError(_ text: String) {
        append(.error, text)
    }

    public mutating func apply(_ event: StreamEvent) {
        switch event {
        case .assistant(let blocks, false):
            for block in blocks {
                switch block {
                case .text(let text):
                    append(.assistant, text.trimmingCharacters(in: .whitespacesAndNewlines))
                case .toolUse(let id, let name, let input):
                    if !id.isEmpty {
                        guard seenToolIDs.insert(id).inserted else { continue }
                    }
                    append(.tool, ToolSummary.describe(name: name, input: input, cwd: workingDirectory))
                default:
                    break
                }
            }
        case .user(let blocks, false):
            for block in blocks {
                switch block {
                case .text(let text):
                    if let prompt = TranscriptBuilder.cleanPrompt(text) { append(.prompt, prompt) }
                case .toolResult(_, let content, true):
                    append(.error, TranscriptBuilder.firstLine(content))
                default:
                    break
                }
            }
        case .result(let info) where info.isError:
            let detail = info.text.map(TranscriptBuilder.firstLine).flatMap { $0.isEmpty ? nil : $0 } ?? info.subtype
            append(.error, "Session ended: \(detail)")
        default:
            break
        }
    }

    private mutating func append(_ kind: TranscriptLine.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        lines.append(TranscriptLine(id: nextID, kind: kind, text: text))
        nextID += 1
    }

    static func firstLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// Turns a user message from history into prompt text, unwrapping slash
    /// command markup and dropping local command output.
    static func cleanPrompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<local-command") { return nil }
        if let name = tagContent("command-name", in: text) {
            let args = tagContent("command-args", in: text) ?? ""
            return [name, args].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return text
    }

    private static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One-line descriptions of tool calls, e.g. `Edit client/App.vue  +18 −4`.
public enum ToolSummary {
    static let maxArgumentLength = 90

    public static func describe(name: String, input: [String: JSONValue], cwd: String) -> String {
        switch name {
        case "Read", "Write", "NotebookEdit", "NotebookRead":
            guard let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue else { return name }
            return "\(name) \(relative(path, to: cwd))"
        case "Edit", "MultiEdit":
            guard let path = input["file_path"]?.stringValue else { return name }
            let base = "\(name) \(relative(path, to: cwd))"
            let edits: [(String, String)]
            if let list = input["edits"]?.arrayValue {
                edits = list.map { ($0["old_string"]?.stringValue ?? "", $0["new_string"]?.stringValue ?? "") }
            } else if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
                edits = [(old, new)]
            } else {
                return base
            }
            let added = edits.reduce(0) { $0 + lineCount($1.1) }
            let removed = edits.reduce(0) { $0 + lineCount($1.0) }
            return "\(base)  +\(added) −\(removed)"
        case "Bash":
            guard let command = input["command"]?.stringValue else { return name }
            let lines = command.split(separator: "\n", omittingEmptySubsequences: true)
            var shown = truncate(lines.first.map(String.init) ?? "", to: maxArgumentLength)
            if lines.count > 1 && !shown.hasSuffix("…") { shown += " …" }
            return "Bash(\(shown))"
        case "Task", "Agent":
            guard let description = input["description"]?.stringValue else { return name }
            return "\(name)(\(truncate(description, to: maxArgumentLength)))"
        case "Grep":
            return input["pattern"]?.stringValue.map { "Grep \"\($0)\"" } ?? name
        case "Glob":
            return input["pattern"]?.stringValue.map { "Glob \($0)" } ?? name
        case "WebSearch":
            return input["query"]?.stringValue.map { "Search \"\($0)\"" } ?? name
        case "WebFetch":
            return input["url"]?.stringValue.map { "Fetch \($0)" } ?? name
        case "TodoWrite":
            return "Update todos"
        default:
            let firstString = input.keys.sorted().lazy.compactMap { input[$0]?.stringValue }.first
            guard let argument = firstString else { return name }
            return "\(name)(\(truncate(argument, to: maxArgumentLength)))"
        }
    }

    static func relative(_ path: String, to cwd: String) -> String {
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(prefix) && path.count > prefix.count { return String(path.dropFirst(prefix.count)) }
        return path
    }

    private static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func truncate(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length - 1)) + "…"
    }
}
