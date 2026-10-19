import Foundation
import Engine
import Library
import Networking
import Pipeline
import Resolver

@main struct FeedService {
    static func main() async {
        do {
            var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wavepod")
            #if DEBUG
            if let workspace = ProcessInfo.processInfo.environment["WAVEPOD_TEST_WORKSPACE"] { root = URL(fileURLWithPath: workspace) }
            #endif
            let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let client = HTTPClient(logURL: root.appendingPathComponent("network.json"))
            let defaults = UserDefaults.standard
            let engine: any Engine
            if defaults.string(forKey: "engine") == "scriberr",
               let value = defaults.string(forKey: "scriberrURL"), let url = URL(string: value) {
                engine = try ScriberrEngine(base: url, client: client)
            } else { engine = IsolatedEngine() }
            let queue = try JobQueue(store: store, directory: root.appendingPathComponent("jobs"), client: client, engine: engine)
            #if DEBUG
            let testing = ProcessInfo.processInfo.environment["WAVEPOD_TEST_AUDIO"] != nil
            #else
            let testing = false
            #endif
            var paused = !testing && PowerPolicy.shouldPause(currentlyPaused: false)
            try await queue.setOnBattery(paused)
            await queue.start()
            // The foreground app owns the queue while it runs; it also checks the feeds.
            guard await queue.hasLease() else { return }
            #if DEBUG
            if let audio = ProcessInfo.processInfo.environment["WAVEPOD_TEST_AUDIO"] {
                try await queue.enqueue(ResolvedEpisode(title: "Packaged engine smoke test", enclosureURL: URL(fileURLWithPath: audio), language: "en", source: .file))
            }
            #endif
            let monitor = SubscriptionMonitor(store: store, client: client, queue: queue)
            do { try await monitor.refresh() }
            catch { NSLog("wavepod feed check: %@", error.localizedDescription) }
            while true {
                paused = !testing && PowerPolicy.shouldPause(currentlyPaused: paused)
                try await queue.setOnBattery(paused)
                let jobs = await queue.snapshot()
                let busy = await queue.isBusy()
                if !busy, !jobs.contains(where: { $0.state == .running || $0.state == .queued }) { break }
                try await Task.sleep(for: .seconds(2))
            }
            await queue.retryPendingSummaries()
            await queue.shutdown()
        } catch { NSLog("wavepod feed check: %@", error.localizedDescription) }
    }
}
