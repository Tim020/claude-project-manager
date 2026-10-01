import Foundation

// Step 4 of the Project Assistant: what a session did since its last
// follow-up, boiled down in code from its history file. The digest is what a
// follow-up call reads (never the raw transcript), and the substance check
// decides, without Claude, whether there's anything worth offering.

/// Where a session's last follow-up got to: its conversation, and how far
/// into that conversation's history file (in bytes; the file is only ever
/// appended to). `/clear` starts a new conversation, a new file, which is
/// read from the top. A byte offset lets a session be given a mark from
/// its file's size alone, without reading it.
public struct FollowUpMark: Codable, Equatable, Sendable {
    public var conversationID: String
    public var offset: UInt64

    public init(conversationID: String, offset: UInt64) {
        self.conversationID = conversationID
        self.offset = offset
    }
}

/// Reads the whole lines a history file gained after an offset.
public enum HistorySlice {
    /// What was read: whole lines, and the offset after the last of them.
    public struct Read: Equatable, Sendable {
        public var lines: [String]
        public var end: UInt64
        /// More than `maxBytes` were new, so only the newest were read.
        public var truncated = false
    }

    /// The most read at once. History files hold tool results and can be
    /// large; a digest only needs the newest part.
    public static let maxBytes: UInt64 = 8 * 1024 * 1024

    /// The complete lines after `offset`, and the offset after the last of
    /// them. An offset in the middle of a line (a mark taken while a line was
    /// being written) skips to the next line. With more than `maxBytes` new,
    /// only the newest are read, from the first line that starts inside them.
    public static func read(_ url: URL, from offset: UInt64, maxBytes: UInt64 = HistorySlice.maxBytes) -> Result<Read, Error> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            var from = offset
            var truncated = false
            if size > offset, size - offset > maxBytes {
                // Starting part-way through a line: the skip below finds the next one.
                from = size - maxBytes
                truncated = true
            }
            let start = from > 0 ? from - 1 : 0
            try handle.seek(toOffset: start)
            var data = try handle.readToEnd() ?? Data()
            var end = start
            if from > 0 {
                // The byte before: a newline means `from` is at a line's start.
                guard !data.isEmpty else { return .success(Read(lines: [], end: max(offset, from), truncated: truncated)) }
                let atLineStart = data.first == 0x0A
                data = data.dropFirst()
                end += 1
                if !atLineStart {
                    guard let newline = data.firstIndex(of: 0x0A) else {
                        return .success(Read(lines: [], end: from, truncated: truncated))
                    }
                    end += UInt64(data.distance(from: data.startIndex, to: newline) + 1)
                    data = data[data.index(after: newline)...]
                }
            }
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                return .success(Read(lines: [], end: end, truncated: truncated))
            }
            let complete = data[data.startIndex...lastNewline]
            let lines = String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init)
            return .success(Read(lines: lines, end: end + UInt64(complete.count), truncated: truncated))
        } catch {
            return .failure(error)
        }
    }
}

public struct SessionDigest: Equatable, Sendable {
    /// Your prompts since the mark, oldest first (each cut short).
    public var prompts: [String] = []
    /// Prompts that read like a correction ("no, …", "don't …").
    public var corrections: [String] = []
    /// Bash commands it ran.
    public var commands: [String] = []
    /// Tool calls that failed, with their errors.
    public var failures: [String] = []
    /// Files it edited or wrote, relative to the project where possible.
    public var filesChanged: [String] = []
    /// Commands that committed (`git commit`) or acted on a PR (`gh pr …`).
    public var commits: [String] = []
    public var pullRequestCommands: [String] = []
    /// Its last message.
    public var finalMessage: String = ""

    public init() {}

    static let maxPrompts = 12
    static let maxCommands = 30
    static let maxFailures = 15
    static let maxFiles = 40
    static let maxPrompt = 400
    static let maxCommand = 200
    static let maxFailure = 300
    static let maxFinal = 1500

    /// The code check: is there anything a follow-up could find? A quick
    /// question and answer never costs a call.
    public var hasSubstance: Bool {
        !filesChanged.isEmpty || !failures.isEmpty || !commits.isEmpty || !pullRequestCommands.isEmpty
            || !corrections.isEmpty || prompts.count >= 3
    }

    /// Words that start a correction, or ask Claude to remember something.
    static let correctionPattern = try! NSRegularExpression(
        pattern: #"^(no\b|nope\b|don'?t\b|do not\b|stop\b|wrong\b|that'?s (not|wrong)\b|actually\b)|\b(instead|next time|remember( to| that)?|you should have|never do)\b"#,
        options: [.caseInsensitive])

    public static func isCorrection(_ prompt: String) -> Bool {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return correctionPattern.firstMatch(in: prompt, range: range) != nil
    }

    /// Builds the digest from the history lines since the last follow-up.
    /// Subagent (sidechain) messages are left out.
    public static func build(lines: [String], projectPath: String) -> SessionDigest {
        var digest = SessionDigest()
        var toolNames: [String: String] = [:]
        for line in lines {
            guard let event = StreamEventParser.parse(line) else { continue }
            switch event {
            case .user(let blocks, false):
                for block in blocks {
                    switch block {
                    case .text(let text):
                        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Claude Code's own injected text (commands, reminders) isn't yours.
                        guard !prompt.isEmpty, !prompt.hasPrefix("<") else { continue }
                        let short = ToolSummary.truncate(prompt, to: maxPrompt)
                        digest.prompts.append(short)
                        if isCorrection(prompt) { digest.corrections.append(short) }
                    case .toolResult(let id, let content, true):
                        let tool = toolNames[id].map { "\($0): " } ?? ""
                        digest.failures.append(tool + ToolSummary.truncate(content.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                           to: maxFailure))
                    default:
                        continue
                    }
                }
            case .assistant(let blocks, false):
                for block in blocks {
                    switch block {
                    case .text(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { digest.finalMessage = trimmed }
                    case .toolUse(let id, let name, let input):
                        toolNames[id] = name
                        switch name {
                        case "Bash":
                            let command = input["command"]?.stringValue ?? ""
                            let short = ToolSummary.truncate(command, to: maxCommand)
                            digest.commands.append(short)
                            if command.contains("git commit") { digest.commits.append(short) }
                            if command.contains("gh pr ") { digest.pullRequestCommands.append(short) }
                        case "Edit", "MultiEdit", "Write", "NotebookEdit":
                            if let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue {
                                let relative = SkillChips.relativePath(path, projectPath: projectPath) ?? path
                                if !digest.filesChanged.contains(relative) { digest.filesChanged.append(relative) }
                            }
                        default:
                            continue
                        }
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }
        digest.prompts = Array(digest.prompts.suffix(maxPrompts))
        digest.corrections = Array(digest.corrections.suffix(maxPrompts))
        digest.commands = Array(digest.commands.suffix(maxCommands))
        digest.failures = Array(digest.failures.suffix(maxFailures))
        digest.filesChanged = Array(digest.filesChanged.prefix(maxFiles))
        digest.finalMessage = ToolSummary.truncate(digest.finalMessage, to: maxFinal)
        return digest
    }

    /// The digest as the call's input. `withTranscripts` false ("Don't send
    /// transcripts", step 4b) keeps only the final message and the files.
    public func json(withTranscripts: Bool = true) -> JSONValue {
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        var object: [String: JSONValue] = ["filesChanged": strings(filesChanged), "finalMessage": .string(finalMessage)]
        if withTranscripts {
            object["prompts"] = strings(prompts)
            object["corrections"] = strings(corrections)
            object["commands"] = strings(commands)
            object["failures"] = strings(failures)
            object["commits"] = strings(commits)
            object["pullRequestCommands"] = strings(pullRequestCommands)
        }
        return .object(object)
    }
}
