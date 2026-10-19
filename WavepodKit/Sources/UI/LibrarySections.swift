import Library
import Pipeline
import Resolver
import SwiftUI

struct LibrarySection: View {
    @Bindable var model: AppModel
    var body: some View {
        switch model.section {
        case .shows: ShowsSection(model: model)
        case .search: SearchSection(model: model)
        case .home, .library: EmptyView()
        }
    }
}

struct ShowsSection: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Podcasts").font(.title2)
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
                                    let status = model.episodeStatus(JobQueue.episodeID(episode))
                                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(Palette.accent) }
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
                            Menu {
                                Toggle("Download for offline playback", isOn: Binding(get: { show.autoDownload }, set: { model.updateSubscription(show, download: $0) }))
                                Toggle("Transcribe new episodes", isOn: Binding(get: { show.autoTranscribe || show.autoSummarize }, set: { model.updateSubscription(show, transcribe: $0) }))
                                Toggle("Summarize and create chapters", isOn: Binding(get: { show.autoSummarize }, set: { model.updateSubscription(show, summarize: $0) }))
                                Menu("Keep downloaded episodes") {
                                    Button(show.keepLatest == nil ? "Unlimited ✓" : "Unlimited") { model.updateSubscription(show, setRetention: true) }
                                    ForEach([1, 3, 5, 10, 20, 50], id: \.self) { count in
                                        Button("Latest \(count)\(show.keepLatest == count ? " ✓" : "")") { model.updateSubscription(show, keepLatest: count, setRetention: true) }
                                    }
                                }
                            } label: { Label("Automation", systemImage: "gearshape") }.fixedSize()
                            Button("Unsubscribe", role: .destructive) { model.unsubscribe(show) }
                        }
                    }
                    if model.subscriptions.isEmpty { Text("Paste a podcast's feed or website link to follow it.").foregroundStyle(.secondary) }
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
