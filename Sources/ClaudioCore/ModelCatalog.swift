import Foundation

/// One choice in a model picker (New Session, Settings' default). `id` is
/// what's passed to `--model`; `nil` leaves it off, so Claude Code's own
/// default stands.
public struct ModelChoice: Equatable, Sendable {
    public var id: String?
    public var label: String

    public init(id: String?, label: String) {
        self.id = id
        self.label = label
    }
}

/// The models offered in the pickers, read from the CLI's own `/model`
/// aliases rather than a list of version strings Claudio would otherwise have
/// to update by hand every time Anthropic ships a model. An alias always
/// resolves to the current model, so the list never goes stale.
public enum ModelCatalog {
    /// Shown until a live list is read, and whenever that fails.
    public static let fallback: [ModelChoice] = [
        ModelChoice(id: nil, label: "Default"),
        ModelChoice(id: "opus", label: "Opus"),
        ModelChoice(id: "sonnet", label: "Sonnet"),
        ModelChoice(id: "fable", label: "Fable"),
        ModelChoice(id: "haiku", label: "Haiku"),
    ]

    /// Labels for the aliases `/model` is known to list (2.1.332). An alias
    /// this doesn't recognise (a future one) falls back to title-casing it.
    private static let labels: [String: String] = [
        "sonnet": "Sonnet", "opus": "Opus", "haiku": "Haiku", "fable": "Fable",
        "best": "Best available", "opusplan": "Opus in Plan Mode, else Sonnet",
        "sonnet[1m]": "Sonnet (1M context)", "opus[1m]": "Opus (1M context)", "fable[1m]": "Fable (1M context)",
    ]

    /// Parses `claude -p /model`'s reply, e.g. "Current model: `Sonnet 5.5`
    /// \nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best,
    /// sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model
    /// ID.", into its alias tokens, in the order given. The trailing "or a
    /// full model ID" isn't one of them: requiring an identifier shape drops
    /// it without the parser needing to know that exact wording.
    public static func parseModelCommand(_ text: String) -> [String] {
        guard let range = text.range(of: "Available:") else { return [] }
        return text[range.upperBound...].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.range(of: #"^[a-z]+(\[1m\])?$"#, options: .regularExpression) != nil }
    }

    /// Turns the alias list into picker choices. "default" becomes `nil`
    /// (Claudio already treats a `nil` model as leaving `--model` off), and
    /// always comes first.
    public static func choices(fromAliases aliases: [String]) -> [ModelChoice] {
        let known = aliases.filter { $0 != "default" }
        guard !known.isEmpty else { return fallback }
        return [ModelChoice(id: nil, label: "Default")] + known.map { ModelChoice(id: $0, label: labels[$0] ?? $0.capitalized) }
    }
}
