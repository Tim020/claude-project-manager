import Foundation

// Step 4b of the Project Assistant: each project's Assistant Settings (its
// mode, "Don't send transcripts" and the two models). The mode lives in
// `assistant.json`; the rest is in `settings.json` beside it, kept apart so
// adding to it never changes `assistant.json`'s version (older builds would
// then open the notes read-only).

/// The models the assistant's calls can use.
public enum AssistantModel: String, Codable, CaseIterable, Sendable {
    case haiku, sonnet, opus

    public var label: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    /// For the picker. Relative, since only Haiku and Sonnet calls have
    /// been measured (about $0.004 and $0.01 a call).
    public var costHint: String {
        switch self {
        case .haiku: return "Quickest and cheapest"
        case .sonnet: return "About 2–3× Haiku"
        case .opus: return "About 5× Sonnet (estimated)"
        }
    }

    /// How much more a call costs than on Haiku, roughly, so each call's
    /// `--max-budget-usd` stops a runaway call without stopping a normal one.
    /// Opus is estimated, not measured.
    var budgetFactor: Double {
        switch self {
        case .haiku: return 1
        case .sonnet: return 3
        case .opus: return 15
        }
    }
}

/// A project's Assistant Settings, saved as `settings.json`.
public struct ProjectAssistantSettings: Codable, Equatable, Sendable {
    /// Follow-ups use only the session's final message and the files it
    /// changed. The substance check still reads the whole digest locally.
    public var dontSendTranscripts = false
    /// Quick checks: checking a note against the plan (and, later, triage).
    public var quickModel = AssistantModel.haiku
    /// Follow-ups (and, later, skill drafts and Ask).
    public var deepModel = AssistantModel.sonnet

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant: a model this build doesn't know falls back to the default.
        dontSendTranscripts = ((try? c.decodeIfPresent(Bool.self, forKey: .dontSendTranscripts)) ?? nil) ?? false
        quickModel = ((try? c.decodeIfPresent(AssistantModel.self, forKey: .quickModel)) ?? nil) ?? .haiku
        deepModel = ((try? c.decodeIfPresent(AssistantModel.self, forKey: .deepModel)) ?? nil) ?? .sonnet
    }
}
