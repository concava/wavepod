import Darwin
import Engine
import Foundation
import Library
import NativeEngine

final class Service: NSObject, EngineServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EngineServiceProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.cancel() }
        connection.resume()
        return true
    }
    func run(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { reply(nil, "The engine is busy."); return }
        task = Task {
            let memoryWatch = Task.detached {
                while !Task.isCancelled {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                        }
                    }
                    // Leave 512 MB for the app/queue within the combined 4 GB pipeline budget.
                    if result == KERN_SUCCESS, info.phys_footprint > 3500 * 1024 * 1024 {
                        NSLog("wavepod engine exceeded its memory budget; terminating the isolated stage")
                        exit(75)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { memoryWatch.cancel() }
            do {
                let request = try JSONDecoder().decode(EngineRequest.self, from: data)
                let directory = WavepodFolder.default.appendingPathComponent("models")
                let engine = NativeEngine(models: directory)
                let result = request.diarize ? try await engine.diarize(request.audio) :
                    try await engine.transcribe(request.audio, options: request.options, progress: { _ in })
                reply(try JSONEncoder().encode(result), nil)
            } catch { reply(nil, error.localizedDescription) }
            clear()
        }
    }
    private func clear() { lock.lock(); task = nil; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); lock.unlock() }
}
let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
