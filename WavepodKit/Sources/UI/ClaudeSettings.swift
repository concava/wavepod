import AppKit
import Engine
import LLM
import SwiftUI

extension AppModel {
    func chooseClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose Claude Code, or the Claude app to use the Claude Code inside it."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let path = ClaudePlan.executable(choosing: url) { claudeExecutable = path }
        else { claudeStatus = "\(url.lastPathComponent) isn’t Claude Code. Install Claude Code, or open the Code tab in the Claude app once, then choose it again." }
    }
    func connectClaude(action: String) {
        guard let services, !isConnectingClaude else { return }
        isConnectingClaude = true
        claudeStatus = action == "login" ? "Finish signing in with your Claude subscription in the browser…" : "Checking Claude…"
        let executable = claudeExecutable
        claudeConnectionTask = Task {
            defer { isConnectingClaude = false; claudeConnectionTask = nil }
            do {
                if action == "logout" {
                    try await services.claude.disconnect(executable: executable)
                    askProvider = "local"
                    claudeStatus = "Disconnected from Claude."
                } else {
                    let account = action == "login" ? try await services.claude.signIn(executable: executable) : try await services.claude.status(executable: executable)
                    claudeStatus = "Claude plan connected: \(account). Model eligibility is checked when you ask."
                }
            } catch is CancellationError { claudeStatus = "Claude connection cancelled." }
            catch { claudeStatus = error.localizedDescription }
        }
    }
}

struct ClaudeSettings: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Questions, recent conversation and transcript text are sent to Anthropic through Claude Code. Audio is not sent. Your Claude subscription limits apply. This does not read your Claude Desktop conversations.")
                .font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            Text("Requires a current Claude Code installation. Wavepod uses a separate sign-in; your other Claude Code sessions are unchanged.")
                .font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.claudeExecutable.isEmpty ? "Claude Code not found"
                     : model.claudeExecutable.contains("/Application Support/Claude/claude-code/") ? "Claude Code from the Claude app" : model.claudeExecutable)
                    .help(model.claudeExecutable)
                    .font(type.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Choose executable", action: model.chooseClaudeExecutable)
                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            }.disabled(model.isConnectingClaude)
            HStack {
                Button("Continue with Claude") { model.connectClaude(action: "login") }.buttonStyle(PrimaryButtonStyle())
                Button("Check connection") { model.connectClaude(action: "status") }
                Button("Disconnect") { model.connectClaude(action: "logout") }
            }.disabled(model.claudeExecutable.isEmpty || model.isConnectingClaude)
            if model.isConnectingClaude {
                HStack { ProgressView().controlSize(.small); Button("Cancel") { model.claudeConnectionTask?.cancel() } }
            }
            Picker("Claude model", selection: $model.claudeModel) {
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
                Text("Haiku").tag("haiku")
            }.disabled(model.isConnectingClaude)
            Text(model.claudeStatus).font(type.callout).foregroundStyle(Palette.inkMuted).textSelection(.enabled)
            Text("Claude Code manages this connection and its network requests. Wavepod records each answer request in the network log; its HTTP allow-list does not control Claude Code’s traffic.")
                .font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            Link("Manage Claude usage", destination: URL(string: "https://claude.ai/settings/usage")!)
        }
    }
}
