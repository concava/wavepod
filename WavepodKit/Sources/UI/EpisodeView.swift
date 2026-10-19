import Library
import SwiftUI

/// One episode as a row of cards: the podcast and its episodes, the summary with an Ask field, and a card on the
/// right that shows the transcript, answers, chapters or details, or closes to leave two cards.
struct Workspace: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding

    var body: some View {
        HStack(spacing: 8) {
            PodcastCard(model: model)
                .frame(width: 250)
                .elevated(cornerRadius: 14)
            SummaryCard(model: model, focus: focus)
                .frame(minWidth: 380, maxWidth: .infinity)
                .elevated(cornerRadius: 14)
            if model.showSidePane {
                DetailCard(model: model, focus: focus)
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 520)
                    .elevated(cornerRadius: 14)
            }
        }
    }
}

// MARK: - Left: the podcast

struct PodcastCard: View {
    let model: AppModel
    @Environment(\.typography) private var type

    private var episodes: [EpisodeListing] {
        model.savedEpisodes.filter { $0.episode.showName == model.episode.showName }
    }
    private var isFollowing: Bool {
        guard let feed = model.feedURL else { return false }
        return model.subscriptions.contains { $0.feedURL == feed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(hue: model.episode.artworkHue, cornerRadius: 10)
                    .frame(width: 64, height: 64)
                Text(model.episode.showName)
                    .font(type.episodeTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(episodes.count == 1 ? "1 episode in your library" : "\(episodes.count) episodes in your library")
                    .font(type.caption)
                    .foregroundStyle(Palette.inkMuted)
                if model.feedURL != nil {
                    HStack(spacing: 6) {
                        if isFollowing {
                            Label("Following", systemImage: "checkmark")
                                .font(type.label)
                                .foregroundStyle(Palette.accent)
                        }
                        Button(isFollowing ? "All Episodes" : "All Episodes and Follow", action: model.openPodcast)
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isResolving)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(16)
            Divider().overlay(Palette.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(episodes) { item in
                        let current = item.id == model.episode.id
                        Button { model.open(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.episode.title)
                                    .font(type.callout.weight(current ? .semibold : .regular))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(item.episode.pubDate.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.format(item.episode.duration))")
                                    .font(type.caption)
                                    .foregroundStyle(Palette.inkMuted)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(current ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Middle: the summary and the Ask field

struct SummaryCard: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.typography) private var type

    private var episode: Episode { model.episode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(type.readingTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(episode.pubDate.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.format(episode.duration))")
                        .font(type.caption)
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 8)
                Button {
                    model.toggleEpisodePlayback()
                } label: {
                    Label(model.isViewedEpisodePlaying ? "Pause" : "Play",
                          systemImage: model.isViewedEpisodePlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PrimaryButtonStyle())
                if !model.showSidePane {
                    Button { model.showSidePane = true } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(IconButtonStyle())
                        .help("Show the transcript card")
                        .accessibilityLabel("Show the right card")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            AskField(model: model, focus: focus)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            Divider().overlay(Palette.rule)
            SummaryView(model: model)
        }
    }
}

/// A search-style field that asks the episode a question; answers appear under it, above the summary.
struct AskField: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @State private var draft = ""
    @Environment(\.typography) private var type

    static let maxLength = 2000

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            TextField("Ask or search this episode", text: $draft)
                .textFieldStyle(.plain)
                .font(type.body)
                .focused(focus, equals: .ask)
                .onSubmit(send)
                .onChange(of: draft) { _, new in
                    if new.count > Self.maxLength { draft = String(new.prefix(Self.maxLength)) }
                }
                .accessibilityLabel("Ask this episode")
            if model.isAnswering {
                ProgressView().controlSize(.small).accessibilityLabel("Answering")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 26, height: 26)
                        .background(canSend ? Palette.accent : Palette.inkMuted.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Ask (Return)")
                .accessibilityLabel("Send question")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(Palette.sunken, in: Capsule())
    }

    private var canSend: Bool {
        !model.isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        model.ask(draft)
        draft = ""
    }
}

// MARK: - Right: transcript, answers, chapters or details

struct DetailCard: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.typography) private var type

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Show", selection: $model.sidePane) {
                    ForEach(AppModel.SidePane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Right card shows")
                Spacer(minLength: 4)
                if model.sidePane == .transcript { TranscriptActions(model: model) }
                Button { model.showSidePane = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help("Close this card")
                .accessibilityLabel("Close the right card")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider().overlay(Palette.rule)
            Group {
                switch model.sidePane {
                case .transcript:
                    TranscriptView(model: model, focus: focus)
                        .overlay(alignment: .bottom) {
                            if !model.followPlayback && model.isViewedEpisodePlaying {
                                Button { model.followPlayback = true } label: {
                                    Label("Follow Playback", systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(ChipStyle(prominent: true))
                                .padding(.bottom, 10)
                            }
                        }
                case .chapters:
                    if model.chapters.isEmpty {
                        ContentUnavailableView {
                            Label(model.isGenerating ? "Writing chapters…" : "No chapters yet", systemImage: "list.number")
                        } description: {
                            Text("Chapters are written on this Mac by the local model.")
                        } actions: {
                            if model.isPersistent && !model.isGenerating && model.installedModels.contains("language") {
                                Button("Write Chapters") { model.generateNotes(chaptersOnly: true) }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    } else {
                        ChaptersView(model: model)
                    }
                case .about: EpisodeAbout(model: model)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Copy, export, translate and view options for the transcript, shown while the right card holds it.
struct TranscriptActions: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.copyTranscript) { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle())
                .help("Copy transcript")
                .accessibilityLabel("Copy transcript")
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.isAvailable ? format.title : "\(format.title) — coming soon") { model.export(format) }
                        .disabled(!format.isAvailable)
                }
                Divider()
                Menu("Translate") {
                    ForEach(AppModel.AskLanguage.allCases.dropFirst()) { language in
                        Button(language.title) { model.translate(to: language) }
                    }
                }
                Divider()
                Toggle("Speaker Labels", isOn: $model.showSpeakerLabels)
                Toggle("Merge Lines", isOn: $model.mergeLines)
                Toggle("Follow Playback", isOn: $model.followPlayback)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .help("Export, translate and view options")
                .accessibilityLabel("Transcript options")
        }
    }
}

/// A small rounded control for options inside the composer and floating actions.
struct ChipStyle: ButtonStyle {
    var prominent = false
    @Environment(\.typography) private var type

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.label)
            .foregroundStyle(prominent ? Palette.onAccent : Palette.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(prominent ? Palette.accent : (configuration.isPressed ? Palette.rule : Palette.sunken), in: Capsule())
            .contentShape(Capsule())
            .pressScale(configuration.isPressed)
    }
}
