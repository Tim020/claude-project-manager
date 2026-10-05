import Foundation

// Usage, step 1: the token counts in a session's transcripts, read a little
// at a time. Claude Code writes one reply across several lines (a line per
// content block), each repeating the reply's `usage`. In subagent
// transcripts the later lines have more output tokens, so the last line of a
// reply is the one counted. A copy of a conversation (a resume with flags, a
// fork) repeats the original's replies under the same message ids, so a
// project's replies are counted once. All seen in real transcripts, 2.1.289.

/// Token counts, as an assistant message's `usage` gives them.
public struct TokenCounts: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheWrite5m = "w", cacheWrite1h = "h", cacheRead = "r"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite5m = try c.decodeIfPresent(Int.self, forKey: .cacheWrite5m) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var total: Int { input + output + cacheWrite + cacheRead }
    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
                    cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    public static func - (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input - rhs.input, output: lhs.output - rhs.output, cacheWrite5m: lhs.cacheWrite5m - rhs.cacheWrite5m,
                    cacheWrite1h: lhs.cacheWrite1h - rhs.cacheWrite1h, cacheRead: lhs.cacheRead - rhs.cacheRead)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }

    /// From a message's `usage`. Cache writes are split by TTL where the
    /// usage says (`cache_creation.ephemeral_5m/1h_input_tokens`); otherwise
    /// they're taken as 5-minute writes.
    init(usage: [String: Any]) {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        input = int(usage["input_tokens"])
        output = int(usage["output_tokens"])
        cacheRead = int(usage["cache_read_input_tokens"])
        let writes = int(usage["cache_creation_input_tokens"])
        if let split = usage["cache_creation"] as? [String: Any] {
            cacheWrite1h = int(split["ephemeral_1h_input_tokens"])
            cacheWrite5m = max(0, writes - cacheWrite1h)
        } else {
            cacheWrite5m = writes
        }
    }
}

/// One hour of a model's use in a transcript. Hours are counted from 1970
/// (UTC), so they add up into local days wherever the offset is whole hours.
public struct UsageBucket: Codable, Equatable, Sendable {
    public var hour: Int
    /// The model id, with `UsageBucket.fastSuffix` for fast mode.
    public var model: String
    public var tokens: TokenCounts

    public init(hour: Int, model: String, tokens: TokenCounts) {
        self.hour = hour
        self.model = model
        self.tokens = tokens
    }

    enum CodingKeys: String, CodingKey { case hour = "t", model = "m", tokens = "k" }

    public static let fastSuffix = "@fast"

    public var isFast: Bool { model.hasSuffix(UsageBucket.fastSuffix) }
    public var modelID: String { isFast ? String(model.dropLast(UsageBucket.fastSuffix.count)) : model }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(hour) * 3600) }
    public var cost: Double { UsagePricing.cost(of: tokens, model: modelID, fast: isFast) }

    public static func hour(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }
}

/// How far a transcript file has been read, and what it held.
public struct TranscriptProgress: Codable, Equatable, Sendable {
    /// Bytes read: up to the end of the last complete line.
    public var offset = 0
    /// The file's size when it was last read, so an unchanged file is skipped.
    public var size = 0
    /// Prompts sent (not tool results), in a session's own transcript.
    public var turns = 0
    public var buckets: [UsageBucket] = []
    /// Message ids counted from this file.
    public var messageIDs: Set<String> = []
    /// The last reply counted, so its later lines replace it rather than add
    /// to it, even across reads.
    public var last: CountedMessage?

    public struct CountedMessage: Codable, Equatable, Sendable {
        public var id: String
        public var hour: Int
        public var model: String
        public var tokens: TokenCounts
    }

    public init() {}

    public var tokens: TokenCounts { buckets.reduce(TokenCounts()) { $0 + $1.tokens } }

    /// Reads complete lines from `data` (the file from `offset` on). A line
    /// still being written is left for the next read. `isCountedElsewhere`
    /// says a message id was already counted in another file of the project.
    public mutating func read(_ data: Data, countsTurns: Bool = true, isCountedElsewhere: (String) -> Bool = { _ in false }) {
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        var index: [String: Int] = [:]
        for (position, bucket) in buckets.enumerated() { index["\(bucket.hour)|\(bucket.model)"] = position }
        func add(_ tokens: TokenCounts, hour: Int, model: String) {
            let key = "\(hour)|\(model)"
            if let position = index[key] {
                buckets[position].tokens += tokens
            } else {
                index[key] = buckets.count
                buckets.append(UsageBucket(hour: hour, model: model, tokens: tokens))
            }
        }

        var lineStart = data.startIndex
        while lineStart <= end {
            let lineEnd = data[lineStart...end].firstIndex(of: UInt8(ascii: "\n")) ?? end
            defer { lineStart = lineEnd + 1 }
            let line = data[lineStart..<lineEnd]
            if countsTurns, let prompt = TranscriptProgress.prompt(in: line) {
                let id = "u:" + prompt
                if !messageIDs.contains(id) && !isCountedElsewhere(id) {
                    messageIDs.insert(id)
                    turns += 1
                }
                continue
            }
            guard let message = TranscriptProgress.reply(in: line) else { continue }
            if let last, last.id == message.id {
                // A later line of the same reply: it replaces the earlier one.
                add(TokenCounts() - last.tokens, hour: last.hour, model: last.model)
            } else if messageIDs.contains(message.id) || isCountedElsewhere(message.id) {
                continue
            }
            add(message.tokens, hour: message.hour, model: message.model)
            messageIDs.insert(message.id)
            last = message
        }
        buckets.removeAll { $0.tokens.isEmpty }
        offset += data.distance(from: data.startIndex, to: end) + 1
    }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let toolResultMarker = Data("\"tool_result\"".utf8)

    /// A prompt's `uuid`: a user line with text that isn't a tool result or
    /// Claude Code's own (`isMeta`).
    static func prompt(in line: Data) -> String? {
        guard line.range(of: userMarker) != nil, line.range(of: toolResultMarker) == nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "user", record["isMeta"] as? Bool != true,
              let uuid = record["uuid"] as? String,
              let message = record["message"] as? [String: Any]
        else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : uuid }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.contains { $0["type"] as? String == "text" } ? uuid : nil
    }

    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    // ISO8601DateFormatter is thread-safe, and making one per line is slow.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func parseDate(_ string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }

    /// An assistant reply's id, hour, model and usage. Lines are checked for
    /// the markers before they're decoded, since most lines aren't replies.
    static func reply(in line: Data) -> CountedMessage? {
        guard line.range(of: usageMarker) != nil, line.range(of: assistantMarker) != nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<"),
              let stamp = record["timestamp"] as? String, let date = parseDate(stamp)
        else { return nil }
        let fast = usage["speed"] as? String == "fast"
        return CountedMessage(id: id, hour: UsageBucket.hour(of: date), model: fast ? model + UsageBucket.fastSuffix : model,
                              tokens: TokenCounts(usage: usage))
    }
}
