import Library
import Pipeline
import Resolver
import SwiftUI

struct LibrarySection: View {
    @Bindable var model: AppModel
    var body: some View {
        switch model.section {
        case .queue: QueueSection(model: model)
        case .shows: ShowsSection(model: model)
        case .search:
            ContentUnavailableView("Search arrives in Phase 5", systemImage: "magnifyingglass",
                                   description: Text("Keyword and meaning search across every episode."))
        case .settings: SettingsSection(model: model)
        case .library: EmptyView()
        }
    }
}

struct QueueSection: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Transcription queue").font(.title2)
                Spacer()
                Button("Open Audio…", action: model.chooseFile)
            }.padding()
            if model.isPowerPaused && !model.jobs.contains(where: { $0.state == .running }) {
                Label("Paused on battery. Jobs resume on external power.", systemImage: "battery.50percent")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
            }
            if model.jobs.isEmpty {
                ContentUnavailableView("The queue is empty", systemImage: "tray", description: Text("Paste a podcast link or open an audio file."))
            } else {
                List(model.jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(job.episode.title).font(.headline)
                            Spacer()
                            Text(job.state.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.fraction)
                        Text(job.batteryPaused ? "Paused on battery. Resumes on external power." : job.stage).font(.caption)
                        if let error = job.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        HStack {
                            if job.state == .running || job.state == .queued {
                                Button("Pause") { model.manageJob(job, action: "pause") }
                                Button("Cancel") { model.manageJob(job, action: "cancel") }
                            } else if job.state != .completed {
                                Button("Resume") { model.manageJob(job, action: "resume") }
                            } else if let record = model.savedEpisodes.first(where: { $0.id == JobQueue.episodeID(job.episode) }) {
                                Button("Open transcript") { model.open(record) }
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }
}

struct ShowsSection: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Shows").font(.title2)
                Spacer()
            }.padding()
            List {
                if !model.resolutionCandidates.isEmpty {
                    Section("Choose the matching episode") {
                        ForEach(Array(model.resolutionCandidates.enumerated()), id: \.offset) { _, candidate in
                            Button { model.choose(candidate) } label: {
                                VStack(alignment: .leading) {
                                    Text(candidate.candidate.title)
                                    Text("\(candidate.candidate.showTitle ?? "") · \(Int(candidate.confidence * 100))% match").font(.caption)
                                }
                            }
                        }
                    }
                }
                if let show = model.resolvedShow {
                    Section {
                        ForEach(Array(show.episodes.enumerated()), id: \.offset) { _, episode in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(episode.title)
                                    if let date = episode.pubDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button("Transcribe") { model.enqueue(episode) }
                            }
                        }
                    } header: { Text(show.title) }
                }
            }
        }
    }
}


struct SettingsSection: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $model.engineChoice) {
                    Text("On this Mac").tag("native")
                    Text("My Scriberr server").tag("scriberr")
                }
                if model.engineChoice == "scriberr" {
                    TextField("Server URL", text: $model.scriberrURL)
                    SecureField("API key (saved in Keychain)", text: $model.scriberrKey)
                }
                Button("Save Engine", action: model.saveEngine)
                Text("Transcription pauses on battery and in Low Power Mode. Jobs resume from saved checkpoints.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Models on this Mac") {
                Button("Install Transcription Models") { model.installModels("native") }
                Text(model.modelStatus).font(.caption).textSelection(.enabled)
            }.disabled(model.isInstalling)
            Section("Network log") {
                Text("Audio stays on this Mac unless you select your own Scriberr server. Model downloads and feed requests are listed below.").font(.caption)
                ForEach(model.networkEntries.suffix(80).reversed()) { entry in
                    HStack {
                        Text(entry.date, style: .time).monospacedDigit()
                        Text("\(entry.method) \(entry.host)")
                        Spacer()
                        Text(entry.purpose)
                        if let status = entry.status { Text(String(status)) }
                    }.font(.caption)
                }
            }
        }.formStyle(.grouped)
    }
}
