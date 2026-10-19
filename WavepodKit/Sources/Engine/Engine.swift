import Foundation
import Darwin
import Library

public struct AudioAsset: Sendable, Codable {
    public var url: URL
    public var duration: Double
    public init(url: URL, duration: Double) { self.url = url; self.duration = duration }
}
public struct TranscribeOptions: Sendable, Codable {
    public var language: String?
    public init(language: String? = nil) { self.language = language }
}
public struct EngineCapabilities: Sendable, Codable {
    public var wordTimestamps: Bool
    public var diarization: Bool
    public var embeddings: Bool
    public init(wordTimestamps: Bool, diarization: Bool, embeddings: Bool) {
        self.wordTimestamps = wordTimestamps; self.diarization = diarization; self.embeddings = embeddings
    }
}
public struct RawWord: Sendable, Codable, Equatable {
    public var word: Word
    public var speaker: String?
    public init(_ word: Word, speaker: String? = nil) { self.word = word; self.speaker = speaker }
}
public struct SpeakerTurn: Sendable, Codable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}
public struct RawTranscript: Sendable, Codable {
    public var language: String
    public var words: [RawWord]
    public var turns: [SpeakerTurn]
    public var embeddings: [String: [Float]]
    public init(language: String, words: [RawWord], turns: [SpeakerTurn] = [], embeddings: [String: [Float]] = [:]) {
        self.language = language; self.words = words; self.turns = turns; self.embeddings = embeddings
    }
}
public protocol Engine: Sendable {
    var id: String { get }
    func capabilities() async throws -> EngineCapabilities
    func transcribe(_ audio: AudioAsset, options: TranscribeOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript
}
public protocol Diarizing: Sendable {
    func diarize(_ audio: AudioAsset) async throws -> RawTranscript
}
public enum EngineError: Error, LocalizedError, Sendable {
    case unavailable(String), invalidResult, remoteFailure(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .remoteFailure(let detail): detail
        case .invalidResult: "The engine returned an unsupported transcript."
        }
    }
}

/// Shared lease for memory-heavy inference. Cancellation removes waiters without releasing another owner's lease.
public actor InferenceGate {
    public static let shared = InferenceGate(processLockURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wavepod/inference.lock"))
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var processFD: Int32 = -1
    public init(processLockURL: URL? = nil) {
        if let url = processLockURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            processFD = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
    }
    deinit { if processFD >= 0 { close(processFD) } }
    public func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id }
        else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in waiters.append((id, continuation)) }
            } onCancel: { Task { await self.cancel(id) } }
        }
        do {
            try Task.checkCancellation()
            if processFD >= 0 {
                while flock(processFD, LOCK_EX | LOCK_NB) != 0 {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        } catch { release(id); throw error }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
        if owner == id { release(id) }
    }
    public func release(_ id: UUID) {
        guard owner == id else { return }
        if processFD >= 0 { flock(processFD, LOCK_UN) }
        owner = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            owner = next.0
            next.1.resume()
        }
    }
}

@objc public protocol EngineServiceProtocol {
    func run(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    func cancel()
}
public struct EngineRequest: Codable, Sendable {
    public var audio: AudioAsset
    public var options: TranscribeOptions
    public var diarize: Bool
    public init(audio: AudioAsset, options: TranscribeOptions, diarize: Bool) {
        self.audio = audio; self.options = options; self.diarize = diarize
    }
}

/// One XPC connection per stage: invalidating it terminates a crashed/cancelled worker's outstanding request.
public struct IsolatedEngine: Engine, Diarizing {
    public let id = "native"
    public init() {}
    public func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(wordTimestamps: true, diarization: true, embeddings: true)
    }
    public func transcribe(_ audio: AudioAsset, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        progress(0)
        let result = try await run(EngineRequest(audio: audio, options: options, diarize: false))
        progress(1)
        return result
    }
    public func diarize(_ audio: AudioAsset) async throws -> RawTranscript {
        try await run(EngineRequest(audio: audio, options: .init(), diarize: true))
    }
    private func run(_ request: EngineRequest) async throws -> RawTranscript {
        let call = XPCCall()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await call.run(request)
        } onCancel: { call.cancel() }
    }
}

private final class XPCCall: @unchecked Sendable {
    // NSXPC callbacks and cancellation race; the lock guarantees a single continuation resume.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RawTranscript, Error>?
    private var connection: NSXPCConnection?
    private var cancelled = false
    func run(_ request: EngineRequest) async throws -> RawTranscript {
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let connection = NSXPCConnection(serviceName: "app.wavepod.engine")
            self.connection = connection
            lock.unlock()
            connection.remoteObjectInterface = NSXPCInterface(with: EngineServiceProtocol.self)
            connection.interruptionHandler = { [weak self] in self?.finish(.failure(EngineError.unavailable("The engine helper stopped. Resume the job to retry this stage."))) }
            connection.invalidationHandler = { [weak self] in self?.finish(.failure(EngineError.unavailable("The engine helper is unavailable. Open the built wavepod app to use native transcription."))) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.finish(.failure(EngineError.remoteFailure(error.localizedDescription)))
            } as? EngineServiceProtocol
            guard let proxy else { finish(.failure(EngineError.invalidResult)); return }
            proxy.run(data) { [weak self] data, error in
                if let data {
                    do { self?.finish(.success(try JSONDecoder().decode(RawTranscript.self, from: data))) }
                    catch { self?.finish(.failure(error)) }
                } else { self?.finish(.failure(EngineError.remoteFailure(error ?? "The engine returned no result."))) }
            }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let active = connection; lock.unlock()
        // Wait for the worker's reply before releasing the inference lease. Core ML may finish a
        // non-cancellable prediction first; starting an LLM while it still owns its models exceeds the budget.
        (active?.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.finish(.failure(error))
        } as? EngineServiceProtocol)?.cancel()
    }
    private func finish(_ result: Result<RawTranscript, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let active = connection
        connection = nil
        let wasCancelled = cancelled
        lock.unlock()
        active?.invalidate()
        pending?.resume(with: wasCancelled ? .failure(CancellationError()) : result)
    }
}
