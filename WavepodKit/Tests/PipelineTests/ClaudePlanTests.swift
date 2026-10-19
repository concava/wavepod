import Foundation
import Networking
import XCTest
@testable import LLM

final class ClaudePlanTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testSubscriptionOnlyAndNoAmbientProviderCredentials() throws {
        XCTAssertEqual(try ClaudePlan.account(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"owner@example.invalid"}"#.utf8)), "owner@example.invalid")
        for method in ["api_key", "api_key_helper", "third_party", "oauth_token", "none"] {
            XCTAssertThrowsError(try ClaudePlan.account(Data("{\"loggedIn\":true,\"authMethod\":\"\(method)\"}".utf8)))
        }
        let root = try temporary()
        let environment = ClaudePlan.environment(root: root, inherited: ["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_BASE_URL": "https://example.invalid", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "CLAUDE_CONFIG_DIR": "/other", "HOME": "/other", "CLAUDECODE": "1"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], root.appendingPathComponent("account").path)
        XCTAssertEqual(environment["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
    }
    func testGenerationUsesStdinAndDisablesToolsCustomizationsAndPersistence() async throws {
        let root = try temporary(), executor = ClaudeFixture(), client = HTTPClient()
        let plan = ClaudePlan(root: root, client: client, executor: executor)
        let answer = try await plan.generate("private transcript evidence", executable: "/usr/bin/true", model: "sonnet")
        XCTAssertEqual(answer, "[]")
        let commands = await executor.commands
        let request = try XCTUnwrap(commands.last)
        XCTAssertEqual(String(decoding: request.input, as: UTF8.self), "private transcript evidence")
        XCTAssertFalse(request.arguments.joined().contains("private transcript"))
        for flag in ["--safe-mode", "--restricted", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"] {
            XCTAssertTrue(request.arguments.contains(flag))
        }
        let toolIndex = try XCTUnwrap(request.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(request.arguments[toolIndex + 1], "")
        XCTAssertTrue(request.arguments.contains("{\"mcpServers\":{}}"))
        XCTAssertTrue(request.arguments.contains { $0.contains("forceLoginMethod") && $0.contains("claudeai") })
        XCTAssertEqual(request.directory, root.appendingPathComponent("workspace"))
        let entries = await client.log()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].method, "EXTERNAL")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(entries), as: UTF8.self).contains("private transcript"))
    }
    func testAPIAccountCannotGenerateAndFailedResultsAreNotAnswers() async throws {
        let executor = ClaudeFixture(method: "api_key"), plan = ClaudePlan(root: try temporary(), client: HTTPClient(), executor: executor)
        do { _ = try await plan.generate("private", executable: "/usr/bin/true", model: "sonnet"); XCTFail("Must require subscription") } catch {}
        let commands = await executor.commands
        XCTAssertFalse(commands.contains { !$0.input.isEmpty })
        for data in [#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"partial"}"#,
                     #"{"type":"result","subtype":"success","is_error":true,"result":"quota"}"#,
                     #"{"type":"result","subtype":"success","is_error":false,"result":""}"#, "partial"] {
            XCTAssertThrowsError(try ClaudePlan.answer(.init(data: Data(data.utf8), status: 0)))
        }
        XCTAssertThrowsError(try ClaudePlan.answer(.init(data: Data(#"{"type":"result","subtype":"success","is_error":false,"result":"[]"}"#.utf8), status: 1)))
    }
    func testSignInAndDisconnectUseOnlyWavepodConfiguration() async throws {
        let executor = ClaudeFixture(), root = try temporary()
        let plan = ClaudePlan(root: root, client: HTTPClient(), executor: executor)
        _ = try await plan.signIn(executable: "/usr/bin/true")
        try await plan.disconnect(executable: "/usr/bin/true")
        let commands = await executor.commands
        XCTAssertTrue(commands.contains { $0.arguments.suffix(2) == ["auth", "login"] })
        XCTAssertTrue(commands.contains { $0.arguments.suffix(2) == ["auth", "logout"] })
        XCTAssertTrue(commands.allSatisfy { $0.environment["CLAUDE_CONFIG_DIR"] == root.appendingPathComponent("account").path })
    }
    func testProcessHandlesLargeStdinCancellationAndTimeout() async throws {
        let root = try temporary()
        let echo = root.appendingPathComponent("echo")
        try Data("#!/bin/sh\nexec /bin/cat\n".utf8).write(to: echo)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: echo.path)
        let input = Data(repeating: 65, count: 200_000)
        let output = try await ClaudeProcess().run(.init(executable: echo, arguments: [], input: input, directory: root, environment: [:], timeout: 10))
        XCTAssertEqual(output.data, input)
        let command = ClaudeCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], input: Data(), directory: root, environment: [:], timeout: 10)
        let pending = Task { try await ClaudeProcess().run(command) }
        try await Task.sleep(for: .milliseconds(30)); pending.cancel()
        do { _ = try await pending.value; XCTFail("Must cancel") } catch is CancellationError {}
        do {
            _ = try await ClaudeProcess().run(.init(executable: command.executable, arguments: command.arguments, input: Data(), directory: root, environment: [:], timeout: 0.05))
            XCTFail("Must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }
}

private actor ClaudeFixture: ClaudeExecuting {
    var commands: [ClaudeCommand] = []
    let method: String
    init(method: String = "claude.ai") { self.method = method }
    func run(_ command: ClaudeCommand) async throws -> ClaudeOutput {
        commands.append(command)
        let text: String
        if command.arguments.contains("--help") { text = "--safe-mode --restricted --no-session-persistence --tools --strict-mcp-config" }
        else if command.arguments.contains("status") { text = "{\"loggedIn\":true,\"authMethod\":\"\(method)\",\"email\":\"owner@example.invalid\"}" }
        else if !command.input.isEmpty { text = #"{"type":"result","subtype":"success","is_error":false,"result":"[]"}"# }
        else { text = "" }
        return .init(data: Data(text.utf8), status: 0)
    }
}
