import Foundation

/// A content block inside an assistant or user message.
public enum ContentBlock: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case unknown(String)
}

public struct ResultInfo: Equatable, Sendable {
    public var isError: Bool
    public var subtype: String
    public var text: String?
    public var sessionID: String?
    public var costUSD: Double?
    public var permissionDenials: Int

    public init(isError: Bool, subtype: String, text: String?, sessionID: String?, costUSD: Double?, permissionDenials: Int) {
        self.isError = isError
        self.subtype = subtype
        self.text = text
        self.sessionID = sessionID
        self.costUSD = costUSD
        self.permissionDenials = permissionDenials
    }
}

/// One record from `claude -p --output-format stream-json --verbose`, or one
/// line of a session's `.jsonl` history file (the two share message shapes).
public enum StreamEvent: Equatable, Sendable {
    case initialized(sessionID: String, model: String?, cwd: String?)
    case status(String)
    /// Live one-line description of what the agent is doing (nil clears it).
    case taskSummary(String?)
    /// Claude Code's own post-turn classification: working / blocked /
    /// review_ready / done / failed.
    case postTurnSummary(category: String, detail: String?, needsAction: String?)
    case assistant(blocks: [ContentBlock], isSidechain: Bool)
    case user(blocks: [ContentBlock], isSidechain: Bool)
    case result(ResultInfo)
    case conversationSummary(String)
    case customTitle(String)
    /// Partial-message streaming chunk (`stream_event`); not used for display.
    case partial
    case other(type: String)
}

public enum StreamEventParser {
    public static func parse(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let type = value["type"]?.stringValue
        else { return nil }
        return parse(record: value, type: type)
    }

    static func parse(record value: JSONValue, type: String) -> StreamEvent {
        switch type {
        case "system":
            let subtype = value["subtype"]?.stringValue ?? ""
            switch subtype {
            case "init":
                return .initialized(sessionID: value["session_id"]?.stringValue ?? "",
                                    model: value["model"]?.stringValue,
                                    cwd: value["cwd"]?.stringValue)
            case "status":
                return .status(value["status"]?.stringValue ?? "")
            case "task_summary":
                return .taskSummary(nonEmpty(value["detail"]?.stringValue))
            case "post_turn_summary":
                return .postTurnSummary(category: value["status_category"]?.stringValue ?? "",
                                        detail: value["status_detail"]?.stringValue,
                                        needsAction: value["needs_action"]?.stringValue)
            default:
                return .other(type: "system:\(subtype)")
            }
        case "stream_event":
            return .partial
        case "assistant":
            return .assistant(blocks: blocks(value["message"]?["content"]), isSidechain: isSidechain(value))
        case "user":
            if value["isMeta"]?.boolValue == true { return .other(type: "user-meta") }
            return .user(blocks: blocks(value["message"]?["content"]), isSidechain: isSidechain(value))
        case "result":
            return .result(ResultInfo(
                isError: value["is_error"]?.boolValue ?? false,
                subtype: value["subtype"]?.stringValue ?? "",
                text: value["result"]?.stringValue,
                sessionID: value["session_id"]?.stringValue,
                costUSD: value["total_cost_usd"]?.doubleValue,
                permissionDenials: value["permission_denials"]?.arrayValue?.count ?? 0))
        case "summary":
            return .conversationSummary(value["summary"]?.stringValue ?? "")
        case "custom-title":
            return .customTitle(value["customTitle"]?.stringValue ?? "")
        default:
            return .other(type: type)
        }
    }

    private static func isSidechain(_ value: JSONValue) -> Bool {
        if value["isSidechain"]?.boolValue == true { return true }
        if value["parent_tool_use_id"]?.stringValue != nil { return true }
        return false
    }

    private static func blocks(_ content: JSONValue?) -> [ContentBlock] {
        switch content {
        case .string(let text)?:
            return [.text(text)]
        case .array(let items)?:
            return items.map(block)
        default:
            return []
        }
    }

    private static func block(_ item: JSONValue) -> ContentBlock {
        let type = item["type"]?.stringValue ?? ""
        switch type {
        case "text":
            return .text(item["text"]?.stringValue ?? "")
        case "thinking":
            return .thinking(item["thinking"]?.stringValue ?? "")
        case "tool_use":
            return .toolUse(id: item["id"]?.stringValue ?? "",
                            name: item["name"]?.stringValue ?? "",
                            input: item["input"]?.objectValue ?? [:])
        case "tool_result":
            return .toolResult(toolUseID: item["tool_use_id"]?.stringValue ?? "",
                               content: resultText(item["content"]),
                               isError: item["is_error"]?.boolValue ?? false)
        default:
            return .unknown(type)
        }
    }

    private static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text)?:
            return text
        case .array(let items)?:
            return items.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Splits a byte stream into newline-terminated UTF-8 lines. Bytes are only
/// decoded once a full line has arrived, so multi-byte characters split across
/// reads are handled correctly.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(LineBuffer.decode(lineData))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return LineBuffer.decode(pending)
    }

    private static func decode(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
