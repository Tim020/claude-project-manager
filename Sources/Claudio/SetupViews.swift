#if os(macOS)
import AppKit
import ClaudioCore
import SwiftTerm
import SwiftUI

// MARK: - Checklist rows

/// One line of the Claude Code checklist: installed, signed in, agents.
struct EnvironmentCheck: Identifiable {
    enum State { case ok, problem, warning, unknown }

    let id: String
    let title: String
    let detail: String
    let state: State
    let fix: EnvironmentFix?
    let fixTitle: String?

    static func rows(for environment: ClaudeEnvironment, home: String) -> [EnvironmentCheck] {
        var rows: [EnvironmentCheck] = []
        switch environment.install {
        case .unchecked:
            rows.append(EnvironmentCheck(id: "install", title: "Claude Code", detail: "Not checked yet", state: .unknown, fix: nil, fixTitle: nil))
        case .notFound:
            rows.append(EnvironmentCheck(id: "install", title: "Claude Code isn't installed",
                                         detail: "Install it here, or choose where it is if Claudio didn't find it.",
                                         state: .problem, fix: .install, fixTitle: "Install…"))
        case .broken(let path, let message):
            rows.append(EnvironmentCheck(id: "install", title: "Claude Code won't start",
                                         detail: "\(PathDisplay.tilde(path, home: home)): \(message)",
                                         state: .problem, fix: .chooseExecutable, fixTitle: "Choose…"))
        case .installed(let path, let version):
            let outdated = version.map { $0 < ClaudeEnvironment.minimumVersion } ?? false
            rows.append(EnvironmentCheck(
                id: "install",
                title: outdated ? "Claude Code \(version!) is out of date" : "Claude Code \(version.map(\.description) ?? "")",
                detail: outdated
                    ? "Claudio needs \(ClaudeEnvironment.minimumVersion) or later. \(PathDisplay.tilde(path, home: home))"
                    : PathDisplay.tilde(path, home: home),
                state: outdated ? .warning : .ok, fix: .update, fixTitle: outdated ? "Update…" : "Check for Updates…"))
        }

        switch environment.signIn {
        case .unchecked:
            rows.append(EnvironmentCheck(id: "auth", title: "Account", detail: "Not checked yet", state: .unknown, fix: nil, fixTitle: nil))
        case .signedIn(let status):
            let who = [status.planLabel, status.email].compactMap { $0 }.joined(separator: " · ")
            rows.append(EnvironmentCheck(id: "auth", title: "Signed in", detail: who.isEmpty ? "Ready to start sessions" : who,
                                         state: .ok, fix: nil, fixTitle: nil))
        case .signedOut:
            rows.append(EnvironmentCheck(id: "auth", title: "Not signed in",
                                         detail: "Sign in to your Claude account (or set up an API key) to start sessions.",
                                         state: .problem, fix: .signIn, fixTitle: "Sign In…"))
        case .unknown:
            rows.append(EnvironmentCheck(id: "auth", title: "Account", detail: "This Claude Code didn't say whether it's signed in.",
                                         state: .unknown, fix: .signIn, fixTitle: "Sign In…"))
        }

        switch environment.githubCLI {
        case .unchecked:
            break
        case .notInstalled:
            rows.append(EnvironmentCheck(id: "gh", title: "GitHub CLI (optional)",
                                         detail: "With gh signed in, “vs” compares against your pull request's base branch.",
                                         state: .unknown, fix: .installGitHubCLI, fixTitle: "Install…"))
        case .signedOut:
            rows.append(EnvironmentCheck(id: "gh", title: "GitHub CLI isn't signed in (optional)",
                                         detail: "Sign in so “vs” can compare against your pull request's base branch.",
                                         state: .unknown, fix: .signInGitHubCLI, fixTitle: "Sign In…"))
        case .signedIn(_, let account):
            rows.append(EnvironmentCheck(id: "gh", title: "GitHub CLI", detail: account.map { "Signed in as \($0)" } ?? "Signed in",
                                         state: .ok, fix: nil, fixTitle: nil))
        }

        switch environment.agents {
        case .unchecked:
            rows.append(EnvironmentCheck(id: "agents", title: "Background agents", detail: "Not checked yet", state: .unknown, fix: nil, fixTitle: nil))
        case .supported:
            rows.append(EnvironmentCheck(id: "agents", title: "Background agents", detail: "Sessions keep running when you close their tab or quit.",
                                         state: .ok, fix: nil, fixTitle: nil))
        case .unsupported:
            rows.append(EnvironmentCheck(id: "agents", title: "No background agents",
                                         detail: "New sessions run directly in their tab until Claude Code is updated.",
                                         state: .warning, fix: .update, fixTitle: "Update…"))
        }
        return rows
    }
}

struct EnvironmentCheckRow: View {
    let check: EnvironmentCheck
    let isChecking: Bool
    let onFix: (EnvironmentFix) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(DS.font(13.5, .semibold))
                    .foregroundStyle(DS.text)
                Text(check.detail)
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let fix = check.fix, let title = check.fixTitle {
                if check.state == .ok {
                    Button(title) { onFix(fix) }
                } else {
                    Button(title) { onFix(fix) }
                        .buttonStyle(PrimaryButtonStyle(horizontalPadding: 12, verticalPadding: 4))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var icon: some View {
        if isChecking && check.state == .unknown {
            ProgressView().controlSize(.small)
        } else {
            switch check.state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.teal)
            case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(DS.red)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.orange)
            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(DS.dim)
            }
        }
    }
}

// MARK: - Setup sheet

/// Shown at launch when Claude Code needs attention, from the banner, from
/// Settings, and when an action needed Claude Code but it can't run. Fixes
/// run in a terminal inside the sheet, then everything is checked again.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// A fix to start straight away (from Settings).
    var initialFix: EnvironmentFix?

    @State private var running: TerminalLaunch?
    @State private var runID = UUID()
    @State private var exitCode: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(DS.font(18, .bold))
                        .foregroundStyle(DS.text)
                    Text("Claudio runs your sessions with the Claude Code CLI.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                }
            }

            VStack(spacing: 0) {
                let rows = EnvironmentCheck.rows(for: model.environment, home: model.home)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, check in
                    EnvironmentCheckRow(check: check, isChecking: model.isCheckingEnvironment, onFix: perform)
                        .disabled(running != nil && exitCode == nil)
                    if index < rows.count - 1 { HorizontalRule() }
                }
            }
            .fieldChrome(background: DS.window)

            if let launch = running {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(launch.displayCommand)
                            .font(DS.mono(11.5))
                            .foregroundStyle(DS.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let exitCode {
                            Text(exitCode == 0 ? "Finished" : "Exited with code \(exitCode)")
                                .font(DS.font(12, .semibold))
                                .foregroundStyle(exitCode == 0 ? DS.teal : DS.orange)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    FixTerminal(launch: launch) { code in
                        exitCode = code
                        Task { await model.checkEnvironment(force: true) }
                    }
                    .id(runID)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border, lineWidth: 1))
                }
            }

            HStack {
                Button("Check Again") { Task { await model.checkEnvironment(force: true) } }
                    .disabled(model.isCheckingEnvironment || (running != nil && exitCode == nil))
                if running != nil && exitCode == nil {
                    Text("Follow any prompts in the terminal above.")
                        .font(DS.font(12))
                        .foregroundStyle(DS.dim)
                }
                Spacer()
                Button(model.environment.problems.isEmpty ? "Done" : (model.environment.canRunSessions ? "Continue" : "Continue Without Sessions")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
        .task {
            if let initialFix { perform(initialFix) } else { await model.checkEnvironment(force: true) }
        }
    }

    private var headline: String {
        if model.environment.problems.isEmpty { return model.isCheckingEnvironment ? "Checking Claude Code…" : "Claude Code is ready" }
        return model.environment.canRunSessions ? "Claude Code needs attention" : "Set up Claude Code"
    }

    private func perform(_ fix: EnvironmentFix) {
        if fix == .chooseExecutable {
            chooseExecutable()
            return
        }
        guard let launch = model.fixLaunch(for: fix) else {
            // No Homebrew to install gh with: its download page instead.
            if fix == .installGitHubCLI { NSWorkspace.shared.open(GitHubCLI.installURL) }
            return
        }
        exitCode = nil
        runID = UUID()
        running = launch
        model.log.append(.terminal, "Terminal started: \(launch.displayCommand)", detail: "in \(launch.workingDirectory)")
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use"
        panel.message = "Choose the claude executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = model.settings
        settings.claudePath = url.path
        model.updateSettings(settings)
        Task { await model.checkEnvironment(force: true) }
    }
}

/// A terminal running one command; reports its exit code.
struct FixTerminal: NSViewRepresentable {
    let launch: TerminalLaunch
    let onExit: (Int32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 230))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x222222)
        view.nativeForegroundColor = NSColor(hex: 0xF1F3F5)
        view.caretColor = NSColor(hex: 0x00BC8C)
        view.processDelegate = context.coordinator
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environmentList,
                          execName: nil, currentDirectory: launch.workingDirectory)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.processDelegate = nil
        nsView.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32) -> Void
        init(onExit: @escaping (Int32) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let code = exitCode ?? -1
            DispatchQueue.main.async { self.onExit(code) }
        }
    }
}

// MARK: - Banner

/// A strip at the bottom of the main window while Claude Code needs attention.
struct EnvironmentBanner: View {
    @Environment(AppModel.self) private var model
    let onFix: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let problems = model.environment.problems
        if let first = problems.first {
            HStack(spacing: 10) {
                Image(systemName: first.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(first.isBlocking ? DS.red : DS.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.title + (problems.count > 1 ? " (and \(problems.count - 1) more)" : ""))
                        .font(DS.font(13, .semibold))
                        .foregroundStyle(DS.text)
                    Text(first.detail)
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button("Fix…", action: onFix)
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 12, verticalPadding: 4))
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.dim)
                }
                .buttonStyle(.plain)
                .help("Hide until something changes")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background((first.isBlocking ? DS.red : DS.orange).opacity(0.12))
            .overlay(alignment: .top) { HorizontalRule() }
        }
    }
}
#endif
