#if os(macOS)
import SessionManagerCore
import SwiftUI

/// Monospaced transcript: `>` prompts, `⏺` tool calls, `*` replies.
struct TranscriptView: View {
    let session: Session
    let activity: SessionActivity
    let compact: Bool

    private var fontSize: CGFloat { compact ? 12.5 : 13 }
    private var rowGap: CGFloat { compact ? 10 : 12 }
    private var markWidth: CGFloat { compact ? 12 : 14 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowGap) {
                    ForEach(activity.transcript.lines) { line in
                        row(mark: line.mark, markColor: markColor(line.kind), text: line.text, color: textColor(line.kind))
                            .id(line.id)
                    }
                    if activity.isTurnActive || session.status == .working {
                        row(mark: "", markColor: DS.dim, text: thinkingText, color: DS.dim)
                    } else if activity.transcript.lines.isEmpty {
                        row(mark: "", markColor: DS.dim, text: session.hasConversation ? "No transcript found for this session." : "No messages yet.", color: DS.dim)
                    }
                    Color.clear.frame(height: 1).id(TranscriptView.bottomID)
                }
                .padding(.vertical, compact ? 14 : 20)
                .padding(.horizontal, compact ? 16 : 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(TranscriptView.bottomID, anchor: .bottom) }
            .onChange(of: activity.transcript.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(TranscriptView.bottomID, anchor: .bottom) }
            }
        }
    }

    private static let bottomID = "transcript-bottom"

    private var thinkingText: String {
        if let detail = activity.liveDetail { return "✻ \(detail)… (esc to interrupt)" }
        return "✻ Thinking… (esc to interrupt)"
    }

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

/// Message box: "Message <session>…", model name and Send.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let compact: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isBusy: Bool { model.activity(for: session.id).isTurnActive }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message \(session.name)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.font(compact ? 13 : 14))
                .foregroundStyle(DS.text)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    guard isBusy else { return .ignored }
                    model.interrupt(session.id)
                    return .handled
                }
            if !compact {
                Text(ModelName.display(session.model))
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                    .fixedSize()
            }
            if isBusy {
                Button { model.interrupt(session.id) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                }
                .buttonStyle(OutlineButtonStyle(color: DS.red))
                .help("Interrupt (esc)")
            }
            if !compact || !draft.isEmpty {
                Button("Send", action: send)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.vertical, compact ? 8 : 10)
        .padding(.horizontal, compact ? 10 : 12)
        .fieldChrome(border: focused ? DS.blue.opacity(0.7) : DS.border)
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 10 : 18)
        .padding(.horizontal, compact ? 12 : 20)
        .overlay(alignment: .top) { HorizontalRule() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text, to: session.id)
        draft = ""
    }
}
#endif
