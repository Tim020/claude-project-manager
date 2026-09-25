#if os(macOS)
import SessionManagerCore
import SwiftUI

/// Read-only history for a session that isn't running, in the design's
/// monospaced style: `>` prompts, `⏺` tool calls, `*` replies.
struct TranscriptView: View {
    let session: Session
    let lines: [TranscriptLine]
    let compact: Bool

    private var fontSize: CGFloat { compact ? 12.5 : 13 }
    private var rowGap: CGFloat { compact ? 10 : 12 }
    private var markWidth: CGFloat { compact ? 12 : 14 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowGap) {
                    ForEach(lines) { line in
                        row(mark: line.mark, markColor: markColor(line.kind), text: line.text, color: textColor(line.kind))
                            .id(line.id)
                    }
                    if lines.isEmpty {
                        row(mark: "", markColor: DS.dim,
                            text: session.hasConversation ? "No transcript found for this session." : "No messages yet.",
                            color: DS.dim)
                    }
                    Color.clear.frame(height: 1).id(TranscriptView.bottomID)
                }
                .padding(.vertical, compact ? 14 : 20)
                .padding(.horizontal, compact ? 16 : 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(TranscriptView.bottomID, anchor: .bottom) }
            .onChange(of: lines.count) { _, _ in proxy.scrollTo(TranscriptView.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "transcript-bottom"

    private func row(mark: String, markColor: Color, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 10) {
            Text(mark)
                .foregroundStyle(markColor)
                .frame(width: markWidth, alignment: .leading)
            Text(text)
                .foregroundStyle(color)
                .lineSpacing(fontSize * 0.6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DS.mono(fontSize))
    }

    private func markColor(_ kind: TranscriptLine.Kind) -> Color {
        switch kind {
        case .prompt, .assistant: return DS.teal
        case .tool: return DS.muted
        case .error: return DS.red
        }
    }

    private func textColor(_ kind: TranscriptLine.Kind) -> Color {
        switch kind {
        case .prompt, .assistant: return DS.text
        case .tool: return DS.muted
        case .error: return DS.red
        }
    }
}
#endif
