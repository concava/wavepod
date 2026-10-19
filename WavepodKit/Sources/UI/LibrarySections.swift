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
        case .search: SearchSection(model: model)
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
                Button("Check for Episodes", action: model.refreshShows).disabled(model.isRefreshing)
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
                        Button("Subscribe to \(show.title)", action: model.subscribe)
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
                Section("Subscriptions") {
                    ForEach(model.subscriptions) { show in
                        HStack {
                            VStack(alignment: .leading) {
                                Button(show.title) { model.commandText = show.feedURL.absoluteString; model.submitCommand() }.buttonStyle(.plain)
                                if let checked = show.checked { Text("Checked \(checked.formatted())").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Toggle("Transcribe new episodes", isOn: Binding(get: { show.autoTranscribe }, set: { _ in model.toggleAuto(show) }))
                                .fixedSize()
                            Button("Unsubscribe", role: .destructive) { model.unsubscribe(show) }
                        }
                    }
                    if model.subscriptions.isEmpty { Text("Paste a show's feed or website link to subscribe.").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct SearchSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search every episode", text: $model.commandText).onSubmit(model.performSearch)
                Toggle("Meaning", isOn: $model.meaningSearch).fixedSize()
                Button("Search", action: model.performSearch)
            }.padding()
            if model.searchHits.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Search saved transcripts by keyword or meaning."))
            } else {
                List(model.searchHits) { hit in
                    Button { model.openHit(hit) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(hit.title).font(.headline); Text(Timecode.format(hit.start)).monospacedDigit().foregroundStyle(Palette.accent) }
                            Text(hit.text).lineLimit(4).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
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
                Button("Install Local Language Model") { model.installModels("language") }
                Button("Install Meaning Search Model") { model.installModels("embeddings") }
                Text(model.modelStatus).font(.caption).textSelection(.enabled)
                Button(model.isIndexing ? "Indexing…" : "Rebuild Meaning Search Index", action: model.indexLibrary).disabled(model.isIndexing)
            }.disabled(model.isInstalling)
            Section("Shows") {
                Toggle("Check shows in the background", isOn: Binding(get: { model.backgroundChecks }, set: model.setBackgroundChecks))
                Text("Checks hourly with conditional requests. New episodes are transcribed only for shows where you enable it.").font(.caption).foregroundStyle(.secondary)
            }
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
