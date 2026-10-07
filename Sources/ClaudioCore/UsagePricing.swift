import Foundation

// Usage (design 11a): what a session's tokens would cost at API rates. On a
// plan that's an estimate ("est."), since plans aren't charged per token.

/// A model family, for the By Model bars and for pricing a model that isn't
/// in the table.
public enum ModelFamily: String, Codable, CaseIterable, Sendable {
    case fable, opus, sonnet, haiku

    public var name: String {
        switch self {
        case .fable: return "Fable"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }

    /// The family a model id or display name ("claude-opus-5-5", "Sonnet")
    /// belongs to. Mythos is priced and shown as Fable.
    public static func of(_ model: String) -> ModelFamily? {
        let lowered = model.lowercased()
        if lowered.contains("mythos") { return .fable }
        return allCases.first { lowered.contains($0.rawValue) }
    }
}

/// USD per million tokens.
public struct TokenPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }

    /// Cache writes: 1.25× input for the 5-minute TTL, 2× for an hour.
    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2 }

    public func cost(of tokens: TokenCounts) -> Double {
        (Double(tokens.input) * input + Double(tokens.output) * output
            + Double(tokens.cacheWrite5m) * cacheWrite5m + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead) / 1_000_000
    }
}

public enum UsagePricing {
    public struct Rate: Equatable, Sendable {
        public var price: TokenPrice
        public var family: ModelFamily
        /// The model wasn't in the table, so it's priced at its family's rate
        /// (or Sonnet's, for a model of no known family).
        public var isFallback: Bool
    }

    /// Anthropic's first-party API rates, as the claude-api skill listed them
    /// (cached 2026-09-25). Matched by prefix, longest first, so
    /// `claude-opus-5-5` isn't priced as `claude-opus-5`, and dated ids
    /// (`claude-haiku-4-5-20251001`) still match.
    static let table: [(prefix: String, family: ModelFamily, price: TokenPrice)] = [
        ("claude-fable-5-1", .fable, TokenPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .fable, TokenPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", .fable, TokenPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", .fable, TokenPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", .opus, TokenPrice(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", .opus, TokenPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", .opus, TokenPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", .opus, TokenPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", .opus, TokenPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-sonnet-5-5", .sonnet, TokenPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", .sonnet, TokenPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4-6", .sonnet, TokenPrice(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-4-5", .haiku, TokenPrice(input: 1, output: 5, cacheRead: 0.1)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// A model not in the table is priced as its family's commonest rate.
    /// Ones that aren't listed are most likely older models. A switch, so a
    /// new family can't be left without a rate.
    static func familyRate(_ family: ModelFamily) -> TokenPrice {
        switch family {
        case .fable: return TokenPrice(input: 10, output: 50, cacheRead: 1)
        case .opus: return TokenPrice(input: 5, output: 25, cacheRead: 0.5)
        case .sonnet: return TokenPrice(input: 3, output: 15, cacheRead: 0.3)
        case .haiku: return TokenPrice(input: 1, output: 5, cacheRead: 0.1)
        }
    }

    /// Fast mode (`usage.speed: "fast"`) costs twice the standard rate on
    /// every model that has it (Opus 5.5: $8 / $40; Opus 5: $10 / $50).
    static let fastMultiplier = 2.0

    public static func rate(for model: String) -> Rate {
        let id = model.lowercased()
        if let row = table.first(where: { id == $0.prefix || id.hasPrefix($0.prefix + "-") || id.hasPrefix($0.prefix + "[") }) {
            return Rate(price: row.price, family: row.family, isFallback: false)
        }
        let family = ModelFamily.of(id) ?? .sonnet
        return Rate(price: familyRate(family), family: family, isFallback: true)
    }

    /// What a model's tokens cost at API rates, in USD.
    public static func cost(of tokens: TokenCounts, model: String, fast: Bool = false) -> Double {
        rate(for: model).price.cost(of: tokens) * (fast ? fastMultiplier : 1)
    }
}
