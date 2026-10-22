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
        else { claudeStatus = "\(url.lastPathComponent) isn’t Claude Code. Install Claude Code, or open the Code tab in the Claude app once. Then choose it again." }
    }
    func connectClaude(action: String) {
        guard let services, !isConnectingClaude else { return }
        isConnectingClaude = true
        claudeStatus = action == "login" ? "Sign in with your Claude plan in the browser…" : "Checking Claude…"
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
                    claudeStatus = "Claude plan connected: \(account). Claude checks model access when you ask."
                }
            } catch is CancellationError { claudeStatus = "Claude connection cancelled." }
            catch { claudeStatus = error.localizedDescription }
        }
    }
}

struct ClaudeSettings: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    private var executableLabel: String {
        if model.claudeExecutable.isEmpty { return "Not found. Install Claude Code or the Claude app." }
        if model.claudeExecutable.contains("/Application Support/Claude/claude-code/") { return "From the Claude app" }
        return model.claudeExecutable
    }

    var body: some View {
        SettingsGroup(title: "Claude") {
            SettingRow(title: "Claude Code", detail: executableLabel) {
                HStack(spacing: 8) {
                    if model.claudeExecutable.isEmpty {
                        Link("Install", destination: URL(string: "https://code.claude.com/docs/en/setup")!).font(type.callout)
                    }
                    Button("Choose…", action: model.chooseClaudeExecutable).buttonStyle(SecondaryButtonStyle())
                }
                .help(model.claudeExecutable)
                .disabled(model.isConnectingClaude)
            }
            SettingRow(title: "Account", detail: model.claudeStatus) {
                if model.isConnectingClaude {
                    HStack { ProgressView().controlSize(.small); Button("Cancel") { model.claudeConnectionTask?.cancel() } }
                } else {
                    HStack(spacing: 8) {
                        Button("Continue with Claude") { model.connectClaude(action: "login") }.buttonStyle(PrimaryButtonStyle())
                        Menu {
                            Button("Check Connection") { model.connectClaude(action: "status") }
                            Divider()
                            Button("Disconnect", role: .destructive) { model.connectClaude(action: "logout") }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More account actions")
                    }
                    .disabled(model.claudeExecutable.isEmpty)
                }
            }
            SettingRow(title: "Model", detail: "Sonnet is fast. Opus is the most capable.", last: ClaudePlan.efforts(for: model.claudeModel).isEmpty) {
                Picker("Claude model", selection: $model.claudeModel) {
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                    Text("Haiku").tag("haiku")
                }
                .labelsHidden().fixedSize()
                .disabled(model.isConnectingClaude)
            }
            if !ClaudePlan.efforts(for: model.claudeModel).isEmpty {
                SettingRow(title: "Effort", detail: EffortPicker.detail, last: true) {
                    EffortPicker(selection: $model.claudeEffort, efforts: ClaudePlan.efforts(for: model.claudeModel))
                }
            }
        }
        PlanFootnote(text: "When you ask a question or wavepod writes a summary, your question, recent conversation and transcript text go to Anthropic through Claude Code. wavepod signs in to Claude Code separately, so your other Claude sessions do not change. wavepod does not send audio. Your plan limits apply.",
                     link: ("Manage usage", URL(string: "https://claude.ai/settings/usage")!))
    }
}
