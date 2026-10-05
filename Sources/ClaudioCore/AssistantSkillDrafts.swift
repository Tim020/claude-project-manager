import Foundation

// Step 5 of the Project Assistant: drafting a skill from a lesson. One call
// (the project's "Follow-ups, skills and Ask" model) gets the lesson, its
// evidence and the approved skills, and must prefer patching one of them to
// adding a new one. It returns the skill's fields and its whole body, never
// a diff; code writes the frontmatter and Claudio's metadata, then runs
// deterministic checks. A draft that fails them is dropped and logged (by
// name and the checks it failed, never its text), and never shown.

/// Writing and reading a `SKILL.md`.
public enum SkillText {
    /// The file: frontmatter (name, description, `when_to_use`, `paths`,
    /// and Claudio's `metadata`), then the body.
    public static func compose(name: String, description: String, whenToUse: String, paths: [String], body: String,
                               metadata: [(String, String)]) -> String {
        var lines = ["---", "name: \(name)", "description: \(quoted(description))"]
        if !whenToUse.isEmpty { lines.append("when_to_use: \(quoted(whenToUse))") }
        if !paths.isEmpty {
            lines.append("paths:")
            lines += paths.map { "  - \(quoted($0))" }
        }
        if !metadata.isEmpty {
            lines.append("metadata:")
            lines += metadata.map { "  \($0.0): \($0.1)" }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// One line, in double quotes (the frontmatter reader takes them off).
    /// Double quotes inside become single ones, so nothing needs escaping.
    static func quoted(_ value: String) -> String {
        let line = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        return "\"\(line)\""
    }

    /// The text with `metadata` keys set (added to an existing `metadata:`
    /// block, replacing keys it has, or a new block before the closing
    /// `---`). Text without frontmatter is returned as it is.
    public static func settingMetadata(_ text: String, _ values: [(String, String)]) -> String {
        var lines = SkillFiles.lines(text)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        if let start = lines[1..<close].firstIndex(where: { $0.hasPrefix("metadata:") }) {
            var end = start + 1
            while end < close, lines[end].first == " " || lines[end].first == "\t" { end += 1 }
            var block = Array(lines[(start + 1)..<end])
            for (key, value) in values {
                if let index = block.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) {
                    block[index] = "  \(key): \(value)"
                } else {
                    block.append("  \(key): \(value)")
                }
            }
            lines.replaceSubrange((start + 1)..<end, with: block)
        } else {
            lines.insert(contentsOf: ["metadata:"] + values.map { "  \($0.0): \($0.1)" }, at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// The text after the frontmatter.
    public static func body(of text: String) -> String {
        let lines = SkillFiles.lines(text)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a, 64-bit, as hex: enough to see a file changed (step 5b's
    /// check), and the same on every platform.
    public static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", value)
    }
}

/// The deterministic checks a draft must pass before you see it.
public enum SkillCheck {
    public static let maxName = 64
    /// `description` plus `when_to_use`: Claude Code's skill listing cuts
    /// the rest off.
    public static let maxListing = 1536
    public static let maxBodyCharacters = 20_000
    public static let maxBodyLines = 500

    /// Names Claude Code already uses for its own skills and commands, from
    /// signed-out containers (`Fixtures/init-builtins-*.json`, 2.1.169 and
    /// 2.1.289), and its interactive commands. A skill named like one would
    /// be shadowed, or shadow it.
    public static let reservedNames: Set<String> = [
        // Skills (2.1.169, 2.1.289).
        "deep-research", "design", "design-sync", "dataviz", "update-config", "verify", "debug", "code-review", "simplify",
        "batch", "fewer-permission-prompts", "doctor", "loop", "claude-api", "workflow-authoring", "run",
        "run-skill-generator", "plugin-authoring",
        // Commands listed in -p mode.
        "agents", "auto-mode-setup", "autocompact", "clear", "color", "compact", "config", "output-style", "context",
        "effort", "fast", "focus", "heapdump", "init", "mcp", "model", "reload-plugins", "reload-skills", "rename",
        "review", "security-review", "usage", "insights", "recap", "goal", "design-consent", "design-revoke",
        "list-agents", "team-onboarding", "workflow-launch-exec",
        // Interactive commands.
        "help", "login", "logout", "resume", "memory", "permissions", "status", "cost", "exit", "quit", "export",
        "hooks", "ide", "bug", "feedback", "pr-comments", "terminal-setup", "vim", "add-dir", "plugin", "plugins",
        "skills", "statusline", "upgrade", "release-notes", "privacy-settings", "rewind", "todos", "theme", "tasks",
        "bashes", "btw", "sandbox", "install-github-app", "migrate-installer", "keybindings",
    ]

    /// Shell words that aren't commands on the PATH.
    static let shellWords: Set<String> = [
        "cd", "export", "echo", "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "set", "unset", "source", ".", "[", "[[", "test", "true", "false", "exit", "read", "local", "function", "return",
        "alias", "eval", "exec", "pwd", "printf", "wait", "trap", "shift", "time", "type", "command", "builtin", "{", "}",
        "(", ")", "!", "sudo", "env",
    ]

    /// What the checks need to know about the project.
    public struct Context {
        public var projectPath: String
        /// Approved skills' names, and the repository's own.
        public var existingNames: Set<String>
        /// The skill a change patches (its name may be the same).
        public var patching: String?
        /// Whether a command is on the user's login shell PATH; nil when
        /// that couldn't be read, which skips the command check rather than
        /// dropping every draft that mentions `gh` or `jq`.
        public var commandExists: ((String) -> Bool)?
        public var fileExists: (String) -> Bool

        public init(projectPath: String, existingNames: Set<String>, patching: String?, commandExists: ((String) -> Bool)?,
                    fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
            self.projectPath = projectPath
            self.existingNames = existingNames
            self.patching = patching
            self.commandExists = commandExists
            self.fileExists = fileExists
        }
    }

    /// What's wrong with a skill's text, in words for the log (they name
    /// the check, a path or a command, never quote the text). Empty: it passes.
    public static func problems(_ text: String, context: Context) -> [String] {
        var problems: [String] = []
        let fields = SkillFiles.closesFrontmatter(text) ? SkillFiles.frontmatter(text) : [:]
        if fields.isEmpty { problems.append("no frontmatter") }
        let name = fields["name"]?.first ?? ""
        if name.isEmpty {
            problems.append("no name")
        } else {
            if name.count > maxName || name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
                problems.append("the name isn't a lower-case slug of up to \(maxName) characters")
            }
            if let patching = context.patching {
                if name != patching { problems.append("a change renames the skill") }
            } else if context.existingNames.contains(name) {
                problems.append("a skill named \(name) already exists")
            }
            if reservedNames.contains(name) { problems.append("\(name) is one of Claude Code's own names") }
        }
        let description = fields["description"]?.first ?? ""
        if description.isEmpty { problems.append("no description") }
        if description.count + (fields["when_to_use"]?.first?.count ?? 0) > maxListing {
            problems.append("the description and when_to_use are over \(maxListing) characters")
        }
        for glob in fields["paths"] ?? [] where glob.isEmpty || glob.hasPrefix("/") || glob.hasPrefix("~") || glob.contains("..") {
            problems.append("a paths glob isn't relative to the repository")
        }
        let body = SkillText.body(of: text)
        if body.isEmpty { problems.append("no instructions") }
        if body.count > maxBodyCharacters || SkillFiles.lines(body).count > maxBodyLines {
            problems.append("the instructions are over \(maxBodyLines) lines or \(maxBodyCharacters) characters")
        }
        for path in referencedPaths(in: body) where !context.fileExists(context.projectPath + "/" + path) {
            problems.append("it refers to \(path), which isn't in the repository")
        }
        if let exists = context.commandExists {
            for command in commands(in: body) where !exists(command) {
                problems.append("it runs \(command), which isn't on the PATH")
            }
        }
        problems += SecretPatterns.matches(in: text).map { "it looks like it holds a secret (\($0))" }
        return problems
    }

    /// Relative file paths in backticks: a `/` or a file extension, no
    /// spaces, no globs or variables, and not a URL or an absolute path.
    static func referencedPaths(in body: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "`([^`\\s]+)`")
        var paths: [String] = []
        for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            var token = String(body[range])
            // A line number after a path: `Sources/a.swift:42`.
            if let colon = token.lastIndex(of: ":"), Int(token[token.index(after: colon)...]) != nil {
                token = String(token[..<colon])
            }
            guard token.contains("/") || token.range(of: #"^[\w.-]+\.(swift|md|json|ya?ml|sh|py|js|ts|tsx|toml|txt|plist)$"#,
                                                     options: .regularExpression) != nil,
                  !token.hasPrefix("/"), !token.hasPrefix("~"), !token.hasPrefix("-"), !token.hasPrefix("$"),
                  !token.contains("://"), !token.contains("*"), !token.contains("<"), !token.contains("{"),
                  !token.contains("="), !token.contains("("), !token.hasPrefix("@"),
                  !token.hasPrefix("origin/"), !token.hasPrefix("feature/"), !token.hasPrefix("fix/")
            else { continue }
            let path = token.hasPrefix("./") ? String(token.dropFirst(2)) : token
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// The commands a skill runs: the first word of each line of its shell
    /// code blocks (```bash, sh, zsh, shell or console), after `$ `, `sudo`
    /// and variables, and after `&&`, `||`, `;` and `|`. Scripts by path
    /// are checked as files instead (see `referencedPaths`).
    static func commands(in body: String) -> [String] {
        var commands: [String] = []
        var inShell = false
        for line in SkillFiles.lines(body) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                inShell = !inShell && ["bash", "sh", "zsh", "shell", "console"].contains(language)
                continue
            }
            guard inShell, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let text = trimmed.hasPrefix("$ ") ? String(trimmed.dropFirst(2)) : trimmed
            for part in text.components(separatedBy: CharacterSet(charactersIn: ";|&")) {
                var words = part.split(whereSeparator: \.isWhitespace).map(String.init)
                while let first = words.first, shellWords.contains(first) || (first.contains("=") && !first.hasPrefix("-")) {
                    if first == "cd" || first == "export" || first == "echo" || first == "printf" { words = []; break }
                    words.removeFirst()
                }
                guard let command = words.first, !command.contains("/"), !command.hasPrefix("-"), !command.hasPrefix("$"),
                      !command.hasPrefix("\""), !command.hasPrefix("'"), !command.hasPrefix("<"), !command.hasPrefix(">"),
                      command.range(of: #"^[A-Za-z0-9_.+-]+$"#, options: .regularExpression) != nil,
                      !shellWords.contains(command)
                else { continue }
                if !commands.contains(command) { commands.append(command) }
            }
        }
        return commands
    }
}

/// Secrets a skill must never hold. (The app's Activity Log hides command
/// output rather than redacting it, so these patterns are new in step 5.)
public enum SecretPatterns {
    static let patterns: [(String, NSRegularExpression)] = [
        ("an Anthropic API key", #"sk-ant-[A-Za-z0-9_-]{20,}"#),
        ("an API key", #"\bsk-[A-Za-z0-9]{32,}"#),
        ("a GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        ("an AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("a Google API key", #"\bAIza[0-9A-Za-z_-]{35}"#),
        ("a Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("a private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("a JSON web token", #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}"#),
        ("a password or token", #"(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b\s*[:=]\s*['"]?[^\s'"<>{}$]{8,}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// What kinds of secret the text seems to hold.
    public static func matches(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0)
    }
}

/// What the drafting call came back with.
public struct SkillDraft: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case new
        /// A change to the approved skill with this name.
        case patch(String)
        /// Not worth a skill.
        case none
    }

    public var action: Action
    public var name: String
    public var description: String
    public var whenToUse: String
    public var paths: [String]
    public var body: String
    public var why: String
}

public enum SkillDraftJob {
    public static let job = "Skill draft"
    /// The cap is $0.15 on Haiku, scaled by model ($0.45 on Sonnet).
    public static let budgetUSD = 0.15
    public static let timeout = 120
    /// An approved skill's body, at most, in the input.
    static let maxExistingBody = 4000

    static let systemPrompt = """
    You turn a lesson from a software project's Claude Code sessions into a Claude Code skill: a SKILL.md file future sessions in this project load when it's relevant.
    You get the lesson, the evidence it rests on (failures and the user's corrections, by session), and the project's approved skills.
    Prefer changing an approved skill that covers the same area: action "patch", skill set to its name, and its whole new body (every line, not a diff), keeping what still holds. Otherwise action "new". If the lesson isn't worth a skill (a one-off, too vague, or already covered), action "none".
    name: a lower-case slug, under 40 characters, saying what it's for. For a patch, the skill's own name.
    description: what it's for and when to use it, one or two sentences, under 300 characters. whenToUse: extra situations that should bring it in, or empty.
    paths: globs relative to the repository when the lesson is tied to certain files (such as "Sources/**/*.swift"), else empty.
    body: Markdown instructions for a future session: short, imperative, under 60 lines, with the exact commands that work. Mention only files and commands from the evidence or the approved skills. Never include tokens, keys, passwords or personal details.
    why: under 20 words, for the user, saying what it will stop happening.
    British English. Reply only through the schema.
    """

    static let schema = #"{"type":"object","properties":{"action":{"type":"string","enum":["new","patch","none"]},"skill":{"type":["string","null"]},"name":{"type":"string"},"description":{"type":"string"},"whenToUse":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"body":{"type":"string"},"why":{"type":"string"}},"required":["action","skill","name","description","whenToUse","paths","body","why"],"additionalProperties":false}"#

    public static func request(candidate: LessonCandidate, projectName: String, skills: [ApprovedSkill],
                               model: AssistantModel = .sonnet) -> AssistantCall {
        let evidence: [JSONValue] = candidate.evidence.map {
            .object(["session": .string($0.sessionName), "kind": .string($0.kind.rawValue), "text": .string($0.text)])
        }
        let existing: [JSONValue] = skills.map {
            .object(["name": .string($0.name), "description": .string($0.description), "paths": .array($0.paths.map(JSONValue.string)),
                     "body": .string(String(SkillText.body(of: $0.text).prefix(maxExistingBody)))])
        }
        let input = JSONValue.object(["project": .string(projectName),
                                      "lesson": .object(["summary": .string(candidate.summary), "evidence": .array(evidence)]),
                                      "approvedSkills": .array(existing)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AssistantCall(job: job, model: model.rawValue, systemPrompt: systemPrompt, schema: schema, input: text,
                             maxBudgetUSD: budgetUSD * model.budgetFactor, timeout: timeout)
    }

    /// The draft in a reply. A patch must name an approved skill (else it's
    /// read as new); nil when the reply doesn't make sense.
    public static func draft(from reply: JSONValue, skills: [ApprovedSkill]) -> SkillDraft? {
        func string(_ key: String) -> String { reply[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let action: SkillDraft.Action
        switch string("action") {
        case "none": action = .none
        case "patch":
            let target = string("skill")
            action = skills.contains { $0.name == target } ? .patch(target) : .new
        case "new": action = .new
        default: return nil
        }
        var name = string("name")
        if case .patch(let target) = action { name = target }
        let paths = (reply["paths"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return SkillDraft(action: action, name: name, description: string("description"), whenToUse: string("whenToUse"),
                          paths: paths, body: string("body"), why: SuggestionCopy.sentence(string("why")))
    }
}
