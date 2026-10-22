import Foundation
import Library
import LLM
import Networking
@testable import Pipeline
import XCTest

final class AnswerModelTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func model(_ settings: MemorySettings, interactive: Bool = true) -> AnswerModel {
        AnswerModel(settings: settings, local: LocalGenerator(directory: folder.appendingPathComponent("models/language")),
                    chatGPT: ChatGPTPlan(client: HTTPClient()), claude: ClaudePlan(root: folder.appendingPathComponent("claude"), client: HTTPClient()),
                    interactive: interactive)
    }

    func testTheChoiceIsKeptPerAccountAndPerModel() {
        let settings = MemorySettings()
        var choice = AnswerChoice(provider: .chatgpt, chatGPTAccount: "a", chatGPTModel: "gpt-a", chatGPTEffort: "high")
        choice.save(to: settings)
        choice.selectChatGPTAccount("b", settings: settings)
        XCTAssertEqual(choice.chatGPTModel, "", "account b has no model yet")
        choice.selectChatGPTModel("gpt-b", settings: settings)
        choice.chatGPTEffort = "low"
        choice.save(to: settings)

        choice.selectChatGPTAccount("a", settings: settings)
        XCTAssertEqual(choice.chatGPTModel, "gpt-a")
        XCTAssertEqual(choice.chatGPTEffort, "high")
        let loaded = AnswerChoice.load(from: settings, detectClaude: { "" })
        XCTAssertEqual(loaded.provider, .chatgpt)
        XCTAssertEqual(loaded.chatGPTAccount, "b")
        XCTAssertEqual(loaded.chatGPTModel, "gpt-b")
        XCTAssertEqual(loaded.chatGPTEffort, "low")
    }

    func testAClaudeEffortTheModelDoesNotTakeIsDropped() {
        var choice = AnswerChoice(provider: .claude, claudeModel: "opus", claudeEffort: "max")
        choice.selectClaudeModel("haiku")
        XCTAssertEqual(choice.claudeEffort, "")
    }

    func testReadinessHasOneRulePerProvider() throws {
        let answers = model(MemorySettings())
        XCTAssertEqual(answers.readiness(AnswerChoice(provider: .local)), .needsSetup("Download the Ask model in Settings → Ask."))
        let language = folder.appendingPathComponent("models/language")
        try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: language.appendingPathComponent("config.json"))
        XCTAssertEqual(answers.readiness(AnswerChoice(provider: .local)), .ready)

        let chatGPT = AnswerChoice(provider: .chatgpt, chatGPTAccount: "a", chatGPTModel: "gpt")
        XCTAssertEqual(answers.readiness(chatGPT), .ready, "without the connected list, a chosen account and model are enough")
        XCTAssertFalse(answers.readiness(chatGPT, connectedChatGPTAccounts: []).isReady, "an account that is not connected")
        XCTAssertTrue(answers.readiness(chatGPT, connectedChatGPTAccounts: ["a"]).isReady)
        XCTAssertFalse(answers.readiness(AnswerChoice(provider: .chatgpt, chatGPTAccount: "a")).isReady, "no model")

        XCTAssertFalse(answers.readiness(AnswerChoice(provider: .claude, claudeExecutable: "/nonexistent/claude")).isReady)
    }

    func testWithoutAWindowChatGPTSummariesWaitForTheApp() {
        let settings = MemorySettings()
        AnswerChoice(provider: .chatgpt, chatGPTAccount: "a", chatGPTModel: "gpt").save(to: settings)
        XCTAssertTrue(model(settings).isAvailable)
        XCTAssertFalse(model(settings, interactive: false).isAvailable, "the feed checker must not read the Keychain")
    }

    func testWorkspaceWiresTheSameAnswerModelEverywhere() throws {
        let settings = MemorySettings()
        AnswerChoice(provider: .chatgpt, chatGPTAccount: "a", chatGPTModel: "gpt").save(to: settings)
        let workspace = try Workspace(root: folder, settings: settings, interactive: false)
        XCTAssertEqual(workspace.answers.choice.provider, .chatgpt)
        XCTAssertFalse(workspace.answers.interactive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.sqlite").path))
    }
}
