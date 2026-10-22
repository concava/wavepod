import Foundation
import Library
import Networking
import Security

public enum APIKeyStore {
    private static let service = "app.wavepod.scriberr"
    public static func set(_ key: String, host: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: host]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw EngineError.unavailable("Wavepod could not save the Scriberr key in the Keychain.")
        }
    }
    public static func get(host: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: host,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct ScriberrEngine: Engine {
    public var id: String { "scriberr@" + base.absoluteString }
    private let base: URL
    private let client: HTTPClient
    public init(base: URL, client: HTTPClient) throws {
        guard let host = base.host, HTTPClient.isPrivateHost(host), ["http", "https"].contains(base.scheme ?? ""),
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw EngineError.unavailable("Scriberr must use a loopback, private LAN, or .local address.")
        }
        self.base = base; self.client = client
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Data {
        let url = base.appendingPathComponent("api/v1").appendingPathComponent(path)
        try await client.allow(url)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue(APIKeyStore.get(host: base.absoluteString), forHTTPHeaderField: "X-API-Key")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await client.data(request, purpose: "Scriberr", localOnly: true)
        guard (200..<300).contains(response.statusCode) else { throw NetworkError.status(response.statusCode) }
        return data
    }
    public func capabilities() async throws -> EngineCapabilities {
        _ = try await request("health")
        _ = try await request("transcription/models")
        // Missing fields are filled by the native aligner/diarizer rather than inventing word timestamps.
        return EngineCapabilities(wordTimestamps: false, diarization: false, embeddings: false)
    }
    public func transcribe(_ audio: AudioAsset, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        let boundary = UUID().uuidString
        // A window is bounded by the pipeline, so multipart never holds the entire episode.
        var body = Data()
        var fields = [("title", audio.url.lastPathComponent), ("model", "large-v3-turbo"),
                      ("diarization", "true"), ("vad_filter", "false")]
        if let language = options.language, language != "auto" { fields.append(("language", language)) }
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio.url))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        struct Submission: Codable { var id: String }
        let checkpoint = audio.url.appendingPathExtension("scriberr.json")
        let submitted: Submission
        if let data = try? Data(contentsOf: checkpoint), let saved = try? JSONDecoder().decode(Submission.self, from: data) { submitted = saved }
        else {
            submitted = try JSONDecoder().decode(Submission.self, from: await request("transcription/submit", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
            try JSONEncoder().encode(submitted).write(to: checkpoint, options: .atomic)
        }
        do {
            var delay = 1
            while true {
                try Task.checkCancellation()
                struct Status: Decodable { var status: String; var progress: Double? }
                let status = try JSONDecoder().decode(Status.self, from: await request("transcription/\(submitted.id)/status"))
                let fraction = status.progress ?? 0
                progress(min(0.99, max(0, fraction > 1 ? fraction / 100 : fraction)))
                if ["completed", "complete"].contains(status.status) { break }
                if ["failed", "error", "cancelled"].contains(status.status) { throw EngineError.remoteFailure("Scriberr job \(status.status).") }
                try await Task.sleep(for: .seconds(delay))
                delay = min(10, delay + 1)
            }
            let data = try await request("transcription/\(submitted.id)/transcript")
            let result = try Self.parse(data, language: options.language ?? "auto")
            progress(1)
            return result
        } catch {
            // Detached cleanup is not cancelled along with the caller, so the server job is actually stopped.
            if error is CancellationError || Task.isCancelled {
                _ = await Task { try? await request("transcription/\(submitted.id)/kill", method: "POST") }.value
                try? FileManager.default.removeItem(at: checkpoint)
            } else if error is EngineError {
                try? FileManager.default.removeItem(at: checkpoint)
            }
            throw error
        }
    }
    public static func parse(_ data: Data, language: String) throws -> RawTranscript {
        struct Response: Decodable {
            struct Segment: Decodable {
                struct Token: Decodable { var word: String; var start: Double; var end: Double; var probability: Float?; var score: Float?; var speaker: String? }
                var text: String; var start: Double; var end: Double; var speaker: String?; var words: [Token]?
            }
            var segments: [Segment]
        }
        struct Envelope: Decodable { var transcript: Response?; var available: Bool? }
        let decoder = JSONDecoder()
        let response: Response
        if let envelope = try? decoder.decode(Envelope.self, from: data), let transcript = envelope.transcript, envelope.available != false { response = transcript }
        else if let transcript = try? decoder.decode(Response.self, from: data) { response = transcript }
        else { throw EngineError.invalidResult }
        var words: [RawWord] = []
        var turns: [SpeakerTurn] = []
        for segment in response.segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else { throw EngineError.invalidResult }
            // Segment text is retained as a cue if the server has no word alignment; the pipeline replaces it
            // with locally aligned words before storage. It is never presented as word-level timing.
            if let tokens = segment.words, !tokens.isEmpty {
                for token in tokens {
                    guard token.start.isFinite, token.end.isFinite, token.start >= 0, token.end >= token.start else { throw EngineError.invalidResult }
                    words.append(RawWord(Word(text: token.word, start: token.start, end: token.end, confidence: token.probability ?? token.score ?? 1), speaker: token.speaker ?? segment.speaker))
                    if let speaker = token.speaker, segment.speaker == nil { turns.append(SpeakerTurn(speaker: speaker, start: token.start, end: token.end)) }
                }
            } else if !segment.text.isEmpty {
                words.append(RawWord(Word(text: segment.text, start: segment.start, end: segment.end, confidence: 0), speaker: segment.speaker))
            }
            if let speaker = segment.speaker { turns.append(SpeakerTurn(speaker: speaker, start: segment.start, end: segment.end)) }
        }
        return RawTranscript(language: language, words: words, turns: turns)
    }
}
