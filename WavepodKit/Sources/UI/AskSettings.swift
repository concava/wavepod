import AppKit
import Engine
import Foundation
import LLM
import SwiftUI

extension AppModel {
    public func refreshChatGPTProfiles() async {
        guard let services else { return }
        do {
            chatGPTProfiles = try await services.chatGPT.profiles()
            if chatGPTProfileID.isEmpty { chatGPTProfileID = chatGPTProfiles.first?.id ?? "" }
            if chatGPTProfiles.first(where: { $0.id == chatGPTProfileID })?.connected == true { await loadChatGPTModels() }
        } catch { chatGPTStatus = error.localizedDescription }
    }
    public func loadChatGPTModels() async {
        guard let services, !chatGPTProfileID.isEmpty else { return }
        let id = chatGPTProfileID
        chatGPTModels = []
        do {
            let models = try await services.chatGPT.models(account: id)
            guard chatGPTProfileID == id else { return }
            chatGPTModels = models
            let saved = UserDefaults.standard.string(forKey: "chatGPTModel.\(id)") ?? ""
            chatGPTModelID = models.contains(where: { $0.id == saved }) ? saved : models.first?.id ?? ""
            chatGPTStatus = models.isEmpty ? "No eligible models were returned for this account." : "ChatGPT plan connected. Model access is verified when you ask a question."
        } catch { if chatGPTProfileID == id { chatGPTStatus = error.localizedDescription } }
    }
    public func connectChatGPT(newAccount: Bool = false) {
        guard let services, !isConnectingChatGPT else { return }
        isConnectingChatGPT = true
        chatGPTStatus = "Finish connecting in your browser…"
        let id = newAccount || chatGPTProfileID.isEmpty ? nil : chatGPTProfileID
        chatGPTConnectionTask = Task {
            defer { isConnectingChatGPT = false; chatGPTConnectionTask = nil }
            do {
                let profile = try await services.chatGPT.signIn(reusing: id) { url in
                    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                    guard opened else { throw EngineError.unavailable("The sign-in browser could not be opened.") }
                }
                chatGPTProfileID = profile.id
                await refreshChatGPTProfiles()
                let key = "chatGPTUsageNotice.\(profile.id)"
                if !UserDefaults.standard.bool(forKey: key) { showChatGPTPlanNotice = true; UserDefaults.standard.set(true, forKey: key) }
            } catch is CancellationError { chatGPTStatus = "Connection cancelled. Local inference is still available." }
            catch { chatGPTStatus = error.localizedDescription }
        }
    }
    public func disconnectChatGPT() {
        guard let services, !isConnectingChatGPT else { return }
        let id = chatGPTProfileID
        isConnectingChatGPT = true
        Task {
            defer { isConnectingChatGPT = false }
            askProvider = "local"
            chatGPTModels = []
            do { try await services.chatGPT.disconnect(id); chatGPTStatus = "Disconnected from ChatGPT." }
            catch { chatGPTStatus = error.localizedDescription }
            chatGPTProfiles = (try? await services.chatGPT.profiles()) ?? []
        }
    }
}

struct AskSettings: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Answer model") {
                SettingRow(title: "Run answers", detail: "Local is the default. Choose an eligible ChatGPT or Claude plan for cloud answers.", last: true) {
                    Picker("Answer model", selection: $model.askProvider) {
                        Text("On this Mac").tag("local")
                        Text("My ChatGPT plan").tag("chatgpt")
                        Text("My Claude plan").tag("claude")
                    }.labelsHidden().fixedSize()
                }
            }
            if model.askProvider == "chatgpt" {
                Text("Questions, recent conversation and transcript text are sent to OpenAI when you ask. Audio is not sent. ChatGPT plan limits apply. This connection does not read your existing ChatGPT conversations.")
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.chatGPTProfiles.isEmpty {
                    Picker("ChatGPT account", selection: $model.chatGPTProfileID) {
                        ForEach(model.chatGPTProfiles) { profile in Text(profile.label + (profile.connected ? "" : " (disconnected)")).tag(profile.id) }
                    }.onChange(of: model.chatGPTProfileID) { _, _ in Task { await model.loadChatGPTModels() } }
                }
                HStack {
                    Button("Continue with ChatGPT") { model.connectChatGPT() }.buttonStyle(PrimaryButtonStyle())
                    Button("Add another account") { model.connectChatGPT(newAccount: true) }
                    if model.chatGPTProfiles.contains(where: { $0.id == model.chatGPTProfileID && $0.connected }) {
                        Button("Disconnect", action: model.disconnectChatGPT)
                    }
                }.disabled(model.isConnectingChatGPT)
                if model.isConnectingChatGPT {
                    HStack { ProgressView().controlSize(.small); Button("Cancel") { model.chatGPTConnectionTask?.cancel() } }
                }
                if !model.chatGPTModels.isEmpty {
                    Picker("ChatGPT model", selection: $model.chatGPTModelID) {
                        ForEach(model.chatGPTModels) { Text($0.display_name).tag($0.id) }
                    }
                }
                Text(model.chatGPTStatus).font(type.callout).foregroundStyle(Palette.inkMuted).textSelection(.enabled)
                HStack {
                    Button("Refresh models") { Task { await model.loadChatGPTModels() } }
                    Link("Manage usage", destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
                }
            } else if model.askProvider == "claude" {
                ClaudeSettings(model: model)
            } else {
                Text("Uses the language model installed in Models. Every transcript section is read before producing an answer; long episodes take longer on the local model.")
                    .font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.isAnswering)
        .task { await model.refreshChatGPTProfiles() }
        .alert("You’re using your ChatGPT plan", isPresented: $model.showChatGPTPlanNotice) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible requests use your ChatGPT plan. You can manage app access and usage in ChatGPT Settings. Local inference remains available in wavepod.")
        }
    }
}
