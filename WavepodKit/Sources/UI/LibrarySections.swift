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

/// Podcasts: the one just opened from a link, then every followed podcast, each with its latest five episodes.
struct ShowsSection: View {
    let model: AppModel
    @Environment(\.typography) private var type

    private var followed: [Subscription] {
        model.subscriptions.filter { $0.feedURL != model.resolvedShow?.feedURL }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !model.resolutionCandidates.isEmpty { candidates }
                if let show = model.resolvedShow {
                    PodcastFeedCard(model: model, title: show.title, feedURL: show.feedURL,
                                episodes: show.episodes, subscription: model.subscriptions.first { $0.feedURL == show.feedURL },
                                onClose: { model.resolvedShow = nil })
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("FOLLOWING")
                    if followed.isEmpty {
                        emptyFollowing
                    } else {
                        ForEach(followed) { show in
                            PodcastFeedCard(model: model, title: show.title, feedURL: show.feedURL,
                                        episodes: model.podcastEpisodes[show.id], subscription: show)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear(perform: model.loadPodcastEpisodes)
        .onChange(of: model.subscriptions.count) { model.loadPodcastEpisodes() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Podcasts").font(type.display).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: model.refreshShows) {
                HStack(spacing: 6) {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(model.isRefreshing ? "Checking…" : "Check for New Episodes")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isRefreshing || model.subscriptions.isEmpty)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("CHOOSE THE MATCHING EPISODE")
            VStack(spacing: 0) {
                let list = Array(model.resolutionCandidates.enumerated())
                ForEach(list, id: \.offset) { index, candidate in
                    FeedRow(leading: "\(Int(candidate.confidence * 100)) %", title: candidate.candidate.title,
                            detail: candidate.candidate.showTitle ?? "", isLast: index == list.count - 1) {
                        model.choose(candidate)
                    }
                }
            }
            .feedCard()
        }
    }

    private var emptyFollowing: some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22)).foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
            Text("No podcasts yet").font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text("Paste a podcast link with ⌘K. Then follow the podcast to see its newest episodes here.")
                .font(type.callout).foregroundStyle(Palette.inkMuted)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .feedCard()
        .accessibilityElement(children: .combine)
    }
}

/// One podcast: artwork, title and follow controls, then its five newest episodes.
struct PodcastFeedCard: View {
    let model: AppModel
    let title: String
    let feedURL: URL
    /// nil while the feed is loading.
    let episodes: [ResolvedEpisode]?
    let subscription: Subscription?
    var onClose: (() -> Void)?
    @Environment(\.typography) private var type

    private var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.rule)
            if let episodes {
                if episodes.isEmpty {
                    Text("No episodes in this feed yet.").font(type.callout).foregroundStyle(Palette.inkMuted)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let latest = ResolvedShow.latest(episodes)
                    ForEach(Array(latest.enumerated()), id: \.offset) { index, episode in
                        PodcastEpisodeRow(model: model, episode: episode, isLast: index == latest.count - 1)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading episodes…").font(type.callout).foregroundStyle(Palette.inkMuted)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .feedCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(hue: hue, url: episodes?.lazy.compactMap(\.artwork).first, cornerRadius: 9).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(type.episodeTitle).foregroundStyle(Palette.ink).lineLimit(1)
                Text(subtitle).font(type.callout).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let subscription {
                Toggle("Auto-transcribe", isOn: Binding(get: { subscription.autoTranscribe || subscription.autoSummarize },
                                                        set: { model.updateSubscription(subscription, transcribe: $0) }))
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.accent)
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
                    .fixedSize()
                    .help("Transcribe each new episode when the podcast publishes it")
                Menu {
                    Section("New episodes") {
                        Toggle("Summarize", isOn: Binding(get: { subscription.autoSummarize },
                                                          set: { model.updateSubscription(subscription, summarize: $0) }))
                        Toggle("Download for Offline Playback", isOn: Binding(get: { subscription.autoDownload },
                                                                              set: { model.updateSubscription(subscription, download: $0) }))
                    }
                    Section("Downloads") {
                        Picker("Keep", selection: Binding(get: { subscription.keepLatest ?? 0 },
                                                          set: { model.updateSubscription(subscription, keepLatest: $0 == 0 ? nil : $0, setRetention: true) })) {
                            Text("All").tag(0)
                            ForEach([1, 3, 5, 10, 20, 50], id: \.self) { Text("Latest \($0)").tag($0) }
                        }
                    }
                    Section {
                        Button("Unfollow", role: .destructive) { model.unsubscribe(subscription) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(IconButtonStyle())
                    .fixedSize()
                    .accessibilityLabel("More for \(title)")
            } else {
                Button(action: model.subscribe) { Label("Follow", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .help("Close")
                    .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let episodes, !episodes.isEmpty {
            parts.append(episodes.count > 5 ? "Latest 5 of \(episodes.count) episodes" : "\(episodes.count) episodes")
        }
        if subscription != nil {
            if let checked = subscription?.checked {
                parts.append("checked \(checked.formatted(.relative(presentation: .named)))")
            } else { parts.append("Following") }
        }
        return parts.isEmpty ? feedURL.host() ?? "" : parts.joined(separator: " · ")
    }
}

/// One feed episode: date, title and length; its action follows where it stands.
struct PodcastEpisodeRow: View {
    let model: AppModel
    let episode: ResolvedEpisode
    var isLast = false
    @State private var hovering = false
    @Environment(\.typography) private var type

    var body: some View {
        let status = model.status(of: episode)
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(episode.pubDate.map(Self.shortDate) ?? "")
                    .font(type.callout).monospacedDigit()
                    .foregroundStyle(Palette.inkMuted)
                    .frame(width: 76, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    let detail = [episode.duration.flatMap { $0 > 0 ? Timecode.format($0) : nil },
                                  model.episodeStatus(JobQueue.episodeID(episode)).nilIfEmpty]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(type.callout).monospacedDigit().foregroundStyle(Palette.inkMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                trailing(status)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if !isLast { Divider().overlay(Palette.rule).padding(.leading, 116) }
        }
        .background(hovering ? Palette.sunken : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if case .saved(let listing) = status { model.open(listing) } }
        .accessibilityElement(children: .combine)
    }

    /// "12 Oct" this year, "12 Oct 2024" before it.
    static func shortDate(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    @ViewBuilder private func trailing(_ status: PodcastEpisodeStatus) -> some View {
        switch status {
        case .saved(let listing):
            Button { model.open(listing) } label: { Label("Open", systemImage: "text.quote") }
                .buttonStyle(RowActionStyle(prominent: false))
        case .running(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).tint(Palette.accent).frame(width: 60)
                Text("\(Int(fraction * 100)) %").font(type.callout).monospacedDigit().foregroundStyle(Palette.accent)
            }
            .accessibilityLabel("Transcribing, \(Int(fraction * 100)) percent")
        case .waiting(let label):
            Text(label).font(type.callout).foregroundStyle(Palette.inkMuted)
        case .new:
            Button { model.enqueue(episode) } label: { Label("Transcribe", systemImage: "waveform") }
                .buttonStyle(RowActionStyle(prominent: true))
                .opacity(hovering ? 1 : 0.85)
        }
    }
}

/// The compact pill a list row ends with.
struct RowActionStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.typography) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(type.label)
            .foregroundStyle(prominent ? Palette.accent : Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(prominent ? Palette.accentSoft : Palette.sunken, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .pressScale(configuration.isPressed)
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
