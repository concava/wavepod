import Engine
import Foundation
@preconcurrency import Network

/// HTTP loopback only. Never binds a LAN interface or prints the authorization code/URL.
final class ChatGPTCallback: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.wavepod.chatgpt.callback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var redirect: URL?
    private var state: String?

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if result != nil { continuation.resume(throwing: CancellationError()); return }
                    ready = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] status in
                            switch status {
                            case .ready: self?.becameReady()
                            case .failed(let error): self?.finish(.failure(error))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
                        listener.start(queue: queue)
                    } catch { ready = nil; continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func becameReady() {
        let value: (CheckedContinuation<URL, Error>?, URL?) = lock.withLock {
            guard let port = listener?.port else { return (nil, nil) }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
            redirect = url
            let continuation = ready; ready = nil
            return (continuation, url)
        }
        if let url = value.1 { value.0?.resume(returning: url) }
    }
    func callback(state: String) async throws -> URL {
        lock.withLock { self.state = state }
        let timeout = Task { try await Task.sleep(for: .seconds(300)); self.cancel() }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let result { continuation.resume(with: result) }
                    else { waiting = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }
    func expect(state: String) { lock.withLock { self.state = state } }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        let pending: (CheckedContinuation<URL, Error>?, CheckedContinuation<URL, Error>?) = lock.withLock {
            guard self.result == nil else { return (nil, nil) }
            self.result = result
            listener?.cancel(); listener = nil
            connections.forEach { $0.cancel() }; connections = []
            let values = (ready, waiting); ready = nil; waiting = nil
            return values
        }
        pending.0?.resume(with: result); pending.1?.resume(with: result)
    }
    private func receive(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, bytes: Data())
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            let bytes = bytes + (data ?? Data())
            guard error == nil, bytes.count <= 16_384 else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if ended { connection.cancel() } else { self.receive(connection, bytes: bytes) }
                return
            }
            let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            let url: URL? = self.lock.withLock {
                guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/auth/callback?"),
                      let base = self.redirect, let url = URL(string: String(request[1]), relativeTo: base)?.absoluteURL,
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      items.filter({ $0.name == "state" }).count == 1,
                      items.first(where: { $0.name == "state" })?.value == self.state else { return nil }
                return url
            }
            let body = url == nil ? "Invalid callback." : "Return to wavepod to finish connecting. You can close this window."
            let response = "HTTP/1.1 \(url == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                if let url { self.finish(.success(url)) }
            })
        }
    }
}
