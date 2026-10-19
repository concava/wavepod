import Foundation

/// URLSession delivers file chunks here, avoiding a per-byte Swift async loop for multi-GB model weights.
final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<HTTPURLResponse, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var handle: FileHandle?
    private var failure: Error?
    private var response: HTTPURLResponse?
    private var received: Int64 = 0
    private let partial: URL
    private let tagURL: URL
    private let offset: Int64
    private let progress: @Sendable (Double) -> Void

    init(partial: URL, tagURL: URL, offset: Int64, progress: @Sendable @escaping (Double) -> Void) {
        self.partial = partial; self.tagURL = tagURL; self.offset = offset; self.progress = progress
    }
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                pending = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            self.response = response
            guard response.statusCode == 200 || response.statusCode == 206 else { throw NetworkError.status(response.statusCode) }
            if response.statusCode == 206 {
                guard response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true else { throw NetworkError.invalidResponse }
                received = offset
            } else { try Data().write(to: partial); received = 0 }
            if let tag = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified") {
                try tag.write(to: tagURL, atomically: true, encoding: .utf8)
            }
            handle = try FileHandle(forWritingTo: partial)
            try handle?.seekToEnd()
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            let expected = (response?.expectedContentLength ?? -1) + (response?.statusCode == 206 ? offset : 0)
            progress(expected > 0 ? Double(received) / Double(expected) : 0)
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        lock.lock()
        let continuation = pending
        pending = nil
        let cancelled = cancelled
        lock.unlock()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let failure = failure ?? error { continuation?.resume(throwing: failure) }
        else if let response { continuation?.resume(returning: response) }
        else { continuation?.resume(throwing: NetworkError.invalidResponse) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
