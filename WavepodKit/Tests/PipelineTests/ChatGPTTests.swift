import CryptoKit
import Foundation
import Networking
import Security
import XCTest
@testable import LLM

final class ChatGPTTests: XCTestCase {
    func testOAuthUsesPKCEAndRejectsWrongStateClientAndDuplicateParameters() throws {
        let attempt = ChatGPTOAuth.Attempt(redirect: URL(string: "http://127.0.0.1:1455/auth/callback")!, clientID: nil, hostID: "urn:uuid:test", idTokenHint: nil)
        let items = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
        XCTAssertTrue(items.first { $0.name == "scope" }!.value!.contains("chatgpt.tokens.use.direct"))
        let url = attempt.redirect.absoluteString + "?state=\(attempt.state)&code=test-code&client_id=oaiapp_test"
        XCTAssertEqual(try attempt.callback(URL(string: url)!).client, "oaiapp_test")
        XCTAssertThrowsError(try attempt.callback(URL(string: url + "&state=evil")!))
        XCTAssertThrowsError(try attempt.callback(URL(string: url.replacingOccurrences(of: attempt.state, with: "evil"))!))
        XCTAssertThrowsError(try attempt.callback(URL(string: url.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!))
        XCTAssertThrowsError(try attempt.callback(URL(string: url.replacingOccurrences(of: "oaiapp_test", with: "dynamic_agent_client"))!))
        let returning = ChatGPTOAuth.Attempt(redirect: attempt.redirect, clientID: "oaiapp_original", hostID: attempt.hostID, idTokenHint: nil)
        XCTAssertThrowsError(try returning.callback(URL(string: attempt.redirect.absoluteString + "?state=\(returning.state)&code=x&client_id=oaiapp_other")!))
    }

    func testOIDCVerifiesRSASignatureIssuerAudienceExpiryAndNonce() throws {
        let fixture = try SignedIdentity()
        let identity = try ChatGPTOAuth.identity(token: fixture.token(), jwks: fixture.jwks, client: "oaiapp_test", nonce: "nonce")
        XCTAssertEqual(identity.subject, "test-subject")
        XCTAssertEqual(identity.email, "test@example.invalid")
        let overrides: [[String: Any]] = [["iss": "https://attacker.invalid"], ["aud": "other"], ["nonce": "evil"], ["exp": 1], ["sub": ""]]
        for override in overrides {
            XCTAssertThrowsError(try ChatGPTOAuth.identity(token: fixture.token(overrides: override), jwks: fixture.jwks, client: "oaiapp_test", nonce: "nonce"))
        }
        let parts = try fixture.token().split(separator: ".")
        let tampered = "\(parts[0]).\(Data("{\"sub\":\"evil\"}".utf8).base64URL).\(parts[2])"
        XCTAssertThrowsError(try ChatGPTOAuth.identity(token: tampered, jwks: fixture.jwks, client: "oaiapp_test", nonce: "nonce"))
        XCTAssertThrowsError(try ChatGPTOAuth.identity(token: fixture.token(algorithm: "none"), jwks: fixture.jwks, client: "oaiapp_test", nonce: "nonce"))
    }

    func testLoopbackCallbackAndCancellation() async throws {
        let server = ChatGPTCallback()
        defer { server.cancel() }
        let base = try await server.start()
        XCTAssertEqual(base.host, "127.0.0.1")
        server.expect(state: "test-state")
        let pending = Task { try await server.callback(state: "test-state") }
        let response = try await URLSession.shared.data(from: URL(string: base.absoluteString + "?state=test-state&code=test&client_id=oaiapp_test")!)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await pending.value
        XCTAssertEqual(callback.host, "127.0.0.1")
        let cancelled = ChatGPTCallback()
        _ = try await cancelled.start()
        cancelled.cancel()
        do { _ = try await cancelled.callback(state: "x"); XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    func testStreamingRequiresCompletedAndReportsFailuresAfterDeltas() async throws {
        let partial = ChatGPTResponse()
        try await partial.consume(event(["type": "response.output_text.delta", "delta": "[]"]))
        do { _ = try await partial.answer(); XCTFail("A partial stream must not be accepted") } catch {}
        do { try await partial.consume(event(["type": "response.failed"])); XCTFail("Expected failure") } catch {}
        let complete = ChatGPTResponse()
        try await complete.consume(event(["type": "response.output_text.delta", "delta": "[]"]))
        try await complete.consume(event(["type": "response.completed", "response": ["status": "completed"]]))
        let answer = try await complete.answer()
        XCTAssertEqual(answer, "[]")
    }

    func testBrowserCallbackExchangeAndVerifiedProfilePersistence() async throws {
        let fixture = try SignedIdentity()
        let store = MemoryCredentials(Data("[]".utf8))
        let client = transport { _ in (500, Data(), [:]) }
        let plan = ChatGPTPlan(client: client, store: store)
        let profile = try await plan.signIn(reusing: nil) { authorization in
            let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            let jwt = try fixture.token(overrides: ["nonce": values["nonce"]!])
            let tokenResponse = try JSONSerialization.data(withJSONObject: ["access_token": "fresh-test-token", "refresh_token": "fresh-refresh",
                "id_token": jwt, "expires_in": 3600, "scope": ChatGPTOAuth.scopes])
            ChatGPTURLProtocol.lock.withLock {
                ChatGPTURLProtocol.handler = { request in
                    if request.url!.path.hasSuffix("jwks.json") { return (200, fixture.jwks, [:]) }
                    let form = String(decoding: Self.body(request), as: UTF8.self)
                    XCTAssertTrue(form.contains("client_id=oaiapp_test"))
                    XCTAssertFalse(form.contains("dynamic_agent_client"))
                    return (200, tokenResponse, [:])
                }
            }
            var callback = URLComponents(string: values["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: values["state"]), URLQueryItem(name: "client_id", value: "oaiapp_test")]
            _ = try await URLSession.shared.data(from: callback.url!)
        }
        XCTAssertEqual(profile.id, "oaiapp_test")
        XCTAssertTrue(profile.connected)
        let saved = try JSONDecoder().decode([ChatGPTCredentials].self, from: store.read()!)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].subject, "test-subject")
        XCTAssertEqual(saved[0].access, "fresh-test-token")
        let profiles = try await plan.profiles()
        XCTAssertEqual(profiles, [profile])
    }

    func testPlanSendsOnlySupportedFieldsAndLogsNoTranscriptOrTokens() async throws {
        let store = MemoryCredentials(try JSONEncoder().encode([credential()]))
        let client = transport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            let json = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(Set(json.keys), ["model", "store", "stream", "instructions", "input"])
            let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"[]\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
            return (200, Data(stream.utf8), ["Content-Type": "text/event-stream"])
        }
        let plan = ChatGPTPlan(client: client, store: store)
        let answer = try await plan.generate("private transcript", account: "oaiapp_test", model: "model-from-catalog")
        XCTAssertEqual(answer, "[]")
        let entries = await client.log()
        let log = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        XCTAssertFalse(log.contains("private transcript"))
        XCTAssertFalse(log.contains("test-access"))
    }

    func testExpiredCredentialsAreRenewedOnceForConcurrentRequests() async throws {
        var old = credential(); old.expires = .distantPast
        let store = MemoryCredentials(try JSONEncoder().encode([old]))
        let counter = RequestCounter()
        let client = transport { request in
            counter.add()
            XCTAssertEqual(request.url?.host, "auth.openai.com")
            let body = String(decoding: Self.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("client_id=oaiapp_test"))
            XCTAssertFalse(body.contains("dynamic_agent_client"))
            return (200, Data("{\"access_token\":\"renewed\",\"refresh_token\":\"rotated\",\"expires_in\":3600}".utf8), [:])
        }
        let plan = ChatGPTPlan(client: client, store: store)
        async let first = plan.accessToken(for: "oaiapp_test")
        async let second = plan.accessToken(for: "oaiapp_test")
        let values = try await [first, second]
        XCTAssertEqual(values, ["renewed", "renewed"])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try JSONDecoder().decode([ChatGPTCredentials].self, from: store.read()!)[0].refresh, "rotated")
    }

    func testModelCatalogUsesSelectedAccountAndServerOrdering() async throws {
        let client = transport { _ in
            (200, Data("{\"models\":[{\"slug\":\"preferred\",\"display_name\":\"Preferred\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hide\"}]}".utf8), [:])
        }
        let store = MemoryCredentials(try JSONEncoder().encode([credential()]))
        let plan = ChatGPTPlan(client: client, store: store)
        let models = try await plan.models(account: "oaiapp_test")
        XCTAssertEqual(models.map(\.id), ["preferred"])
    }

    func testCredentialRedirectsAreRejectedEvenOnSameHost() async throws {
        let counter = RequestCounter()
        let client = transport { _ in counter.add(); return (302, Data(), ["Location": "http://auth.openai.com/stolen"]) }
        try await client.allow(URL(string: "https://auth.openai.com")!)
        var request = URLRequest(url: URL(string: "https://auth.openai.com/token")!)
        request.httpMethod = "POST"; request.httpBody = Data("secret".utf8)
        do { _ = try await client.data(request, purpose: "test"); XCTFail("Must reject redirect") } catch {}
        XCTAssertEqual(counter.value, 1)
    }

    private func event(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func credential() -> ChatGPTCredentials {
        .init(client: "oaiapp_test", subject: "test-subject", email: "test@example.invalid", access: "test-access", refresh: "test-refresh", idToken: nil, expires: .now.addingTimeInterval(3600))
    }
    private func transport(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])) -> HTTPClient {
        ChatGPTURLProtocol.lock.withLock { ChatGPTURLProtocol.handler = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTURLProtocol.self]
        return HTTPClient(configuration: configuration)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
    func testCatalogEffortLevelsDecodeAndModelsWithoutThemTakeNone() throws {
        let data = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list","supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high"}],"default_reasoning_level":"low"},{"slug":"b","display_name":"B","visibility":"list"}]}"#.utf8)
        struct Catalog: Decodable { let models: [ChatGPTModel] }
        let models = try JSONDecoder().decode(Catalog.self, from: data).models
        XCTAssertEqual(models[0].efforts, ["low", "high"])
        XCTAssertEqual(models[0].default_reasoning_level, "low")
        XCTAssertEqual(models[1].efforts, [])
    }
}

private final class MemoryCredentials: ChatGPTCredentialStore, @unchecked Sendable {
    let lock = NSLock()
    var data: Data
    init(_ data: Data) { self.data = data }
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
}
private final class RequestCounter: @unchecked Sendable {
    let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
private final class ChatGPTURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler! }
        let (status, data, headers) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct SignedIdentity: @unchecked Sendable {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(key)!
        let bytes = [UInt8](SecKeyCopyExternalRepresentation(publicKey, nil)! as Data)
        var offset = 0
        func length() -> Int {
            let head = Int(bytes[offset]); offset += 1
            if head < 128 { return head }
            var result = 0
            for _ in 0..<(head & 127) { result = result * 256 + Int(bytes[offset]); offset += 1 }
            return result
        }
        offset += 1; _ = length()
        func integer() -> Data {
            offset += 1; let count = length()
            let result = Data(bytes[offset..<offset + count].drop(while: { $0 == 0 })); offset += count
            return result
        }
        let n = integer(), e = integer()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": n.base64URL, "e": e.base64URL]]])
    }
    func token(overrides: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test"]).base64URL
        var payload: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_test", "sub": "test-subject", "email": "test@example.invalid", "nonce": "nonce", "exp": Date.now.timeIntervalSince1970 + 3600]
        payload.merge(overrides) { _, new in new }
        let body = try JSONSerialization.data(withJSONObject: payload).base64URL
        let message = header + "." + body
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)! as Data
        return message + "." + signature.base64URL
    }
}
