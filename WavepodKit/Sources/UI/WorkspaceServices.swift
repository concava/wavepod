import AppKit
import UniformTypeIdentifiers
import Engine
import Foundation
import IOKit.ps
import Library
import Networking
import Pipeline
import Resolver

struct WorkspaceServices: Sendable {
    let root: URL
    let store: LibraryStore
    let client: HTTPClient
    let queue: JobQueue
    var resolver: Resolver {
        let executable = root.appendingPathComponent("tools/yt-dlp")
        return Resolver(fetcher: URLSessionFetcher(client: client), extractor: FileManager.default.isExecutableFile(atPath: executable.path) ? YtDlpExtractor(executable: executable) : nil)
    }
    init(root: URL) throws {
        self.root = root
        store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        client = HTTPClient(logURL: root.appendingPathComponent("network.json"))
        let engine: any Engine
        if UserDefaults.standard.string(forKey: "engine") == "scriberr",
           let value = UserDefaults.standard.string(forKey: "scriberrURL"), let url = URL(string: value) {
            engine = try ScriberrEngine(base: url, client: client)
        } else { engine = IsolatedEngine() }
        queue = try JobQueue(store: store, directory: root.appendingPathComponent("jobs"), client: client, engine: engine)
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wavepod")
    }
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension AppModel {
    public func importFile(_ url: URL) {
        guard url.isFileURL else { return }
        enqueue(ResolvedEpisode(title: url.deletingPathExtension().lastPathComponent, enclosureURL: url, source: .file))
    }
    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }
    public func open(_ item: EpisodeListing, at start: Double? = nil) {
        guard let services else { return }
        do {
            if let record = try services.store.episode(item.id) { open(record, at: start) }
        } catch { show(error.localizedDescription) }
    }
    public func open(_ record: EpisodeRecord, at start: Double? = nil) {
        install(record)
        section = .library
        if let start { play(from: start) }
    }
    public func enqueue(_ episode: ResolvedEpisode) {
        guard let services else { show("Open the app to import an episode."); return }
        Task {
            do { try await services.queue.enqueue(episode); section = .queue; await refreshWorkspace() }
            catch { show(error.localizedDescription) }
        }
    }
    public func choose(_ candidate: ScoredCandidate) {
        guard let services else { return }
        Task {
            do { enqueue(try await services.resolver.resolve(candidate)); resolutionCandidates = [] }
            catch { show(error.localizedDescription) }
        }
    }
    public func manageJob(_ job: TranscriptionJob, action: String) {
        guard let services else { return }
        Task {
            do {
                switch action {
                case "pause": try await services.queue.pause(job.id)
                case "cancel": try await services.queue.cancel(job.id)
                default: try await services.queue.resume(job.id)
                }
                await refreshWorkspace()
            } catch { show(error.localizedDescription) }
        }
    }
    public func installModels(_ kind: String) {
        guard let services, !isInstalling else { return }
        isInstalling = true
        modelStatus = "Preparing download…"
        Task {
            defer { isInstalling = false }
            do {
                let installer = ModelInstaller(client: services.client, root: services.root.appendingPathComponent("models"))
                for spec in ModelSpec.native {
                    try await installer.install(spec) { status in
                        Task { @MainActor [weak self] in self?.modelStatus = status }
                    }
                }
                modelStatus = "Models installed"
            } catch { modelStatus = error.localizedDescription }
        }
    }
    public func saveEngine() {
        do {
            if engineChoice == "scriberr" {
                guard let url = URL(string: scriberrURL), let services else { return }
                _ = try ScriberrEngine(base: url, client: services.client)
                try APIKeyStore.set(scriberrKey, host: url.absoluteString)
            }
            UserDefaults.standard.set(engineChoice, forKey: "engine")
            UserDefaults.standard.set(scriberrURL, forKey: "scriberrURL")
            scriberrKey = ""
            show("Engine saved. Restart wavepod after current jobs finish to apply it.")
        } catch { show(error.localizedDescription) }
    }
    public func downloadAudio() {
        guard let services, let url = episode.enclosureURL else { return }
        let id = episode.id
        Task {
            do {
                let destination = services.root.appendingPathComponent("audio/\(UUID().uuidString).\(url.pathExtension)")
                if url.isFileURL { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: url, to: destination) }
                else { try await services.client.allow(url); try await services.client.download(url, to: destination) }
                guard var record = try services.store.episode(id) else { return }
                record.audioURL = destination
                try services.store.save(record)
                if episode.id == id { player.load(episode, audioURL: destination) }
                show("Audio downloaded")
            } catch { show(error.localizedDescription) }
        }
    }
}
