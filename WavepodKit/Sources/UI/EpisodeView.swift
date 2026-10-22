import LLM
import Library
import SwiftUI

/// One episode as two cards: the episode (its podcast, the Ask field, answers and summary) and a card on the right
/// with the transcript or the episode's details, which closes to leave the episode alone.
struct EpisodeCards: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("detailWidth") private var detailWidth = EpisodeCards.defaultDetailWidth
    static let defaultDetailWidth = 460.0
    static let minSummary = 420.0, minDetail = 340.0

    var body: some View {
        GeometryReader { proxy in
            let maxDetail = max(EpisodeCards.minDetail, proxy.size.width - EpisodeCards.minSummary - CardDivider.width)
            HStack(spacing: 0) {
                SummaryCard(model: model, focus: focus)
                    .frame(minWidth: EpisodeCards.minSummary, maxWidth: .infinity)
                    .elevated(cornerRadius: 14)
                if model.showSidePane {
                    CardDivider(width: $detailWidth, range: EpisodeCards.minDetail...maxDetail, reset: EpisodeCards.defaultDetailWidth)
                        .transition(.opacity)
                    DetailCard(model: model, focus: focus)
                        .frame(width: min(max(detailWidth, EpisodeCards.minDetail), maxDetail))
                        .elevated(cornerRadius: 14)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.standard, value: model.showSidePane)
    }
}

/// The gap between the two cards. Drag it to resize the side card, double-click it to go back to the default width.
/// A grip shows on hover and grows while you drag. The cards follow the pointer with no animation.
struct CardDivider: View {
    static let width = 8.0
    @Binding var width: Double
    let range: ClosedRange<Double>
    let reset: Double
    @State private var hovering = false
    @State private var start: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dragging: Bool { start != nil }

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(dragging ? Palette.accent : Palette.inkMuted.opacity(0.5))
                .frame(width: dragging ? 4 : 3, height: dragging ? 56 : 36)
                .opacity(hovering || dragging ? 1 : 0)
                .scaleEffect(reduceMotion || hovering || dragging ? 1 : 0.6)
        }
        .frame(width: CardDivider.width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { if !dragging { NSCursor.resizeLeftRight.push() } } else if !dragging { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = width }
                    width = min(max((start ?? width) - value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    start = nil
                    if !hovering { NSCursor.pop() }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(motion(Motion.standard, reduced: reduceMotion)) { width = min(max(reset, range.lowerBound), range.upperBound) }
        }
        .animation(motion(Motion.fade, reduced: reduceMotion), value: hovering)
        .animation(motion(Motion.fade, reduced: reduceMotion), value: dragging)
        .accessibilityElement()
        .accessibilityLabel("Side card width")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: width = min(width + 40, range.upperBound)
            case .decrement: width = max(width - 40, range.lowerBound)
            @unknown default: break
            }
        }
        .help("Drag to resize. Double-click to reset.")
    }
}

/// The podcast's name, opening a menu of its other episodes in the library and its page.
struct PodcastMenu: View {
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
        PreviewSelector(title: "In your library",
                        options: episodes.map {
                            SelectorOption(id: $0.id, title: $0.episode.title,
                                           subtitle: "\($0.episode.pubDate.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.format($0.episode.duration))")
                        },
                        selection: model.episode.id,
                        onSelect: { id in episodes.first { $0.id == id }.map { model.open($0) } },
                        footer: model.feedURL == nil ? [] : [(isFollowing ? "All Episodes" : "All Episodes and Follow", model.openPodcast)]) {
            HStack(spacing: 4) {
                Text(model.episode.showName).lineLimit(1).truncationMode(.tail)
                if isFollowing { Image(systemName: "checkmark.circle.fill").imageScale(.small).accessibilityLabel("Following") }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(type.label)
            .foregroundStyle(Palette.accent)
            .contentShape(Rectangle())
        } preview: { id in
            EpisodePreview(model: model, id: id)
        }
        // Only the height is fixed. A long podcast name shortens instead of widening the summary card.
        .fixedSize(horizontal: false, vertical: true)
        .disabled(episodes.count <= 1 && model.feedURL == nil)
        .help("Episodes of this podcast")
    }
}

/// The preview beside an episode choice: artwork, title, date and length, and the start of its summary.
struct EpisodePreview: View {
    let model: AppModel
    let id: String
    @Environment(\.typography) private var type

    private var listing: EpisodeListing? { model.savedEpisodes.first { $0.id == id } }
    private var summary: String? {
        guard let summary = (try? model.services?.store.episode(id))??.summary else { return nil }
        if !summary.overview.isEmpty { return summary.overview }
        return (summary.sections?.flatMap(\.points) ?? summary.points).prefix(3).map(\.text).joined(separator: " ")
    }

    var body: some View {
        if let listing {
            VStack(alignment: .leading, spacing: 12) {
                ArtworkView(hue: listing.episode.artworkHue, url: listing.episode.artworkURL, cornerRadius: 10)
                    .frame(width: 64, height: 64)
                Text(listing.episode.title).font(type.episodeTitle).foregroundStyle(Palette.ink)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("\(listing.episode.pubDate.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.format(listing.episode.duration))\(listing.downloaded ? " · Downloaded" : "")")
                    .font(type.caption).foregroundStyle(Palette.inkMuted)
                Text(summary ?? "No summary yet.")
                    .font(type.callout).foregroundStyle(summary == nil ? Palette.inkMuted : Palette.ink)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
        }
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
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(hue: episode.artworkHue, url: episode.artworkURL, cornerRadius: 10)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    PodcastMenu(model: model)
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
            // Play's centre line meets the Transcript and About tabs in the card beside it (DetailCard.headerHeight).
            .padding(.top, DetailCard.headerHeight / 2 - 15)
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
            AskProviderMenu(model: model)
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

/// Where answers run, switchable from the Ask field: a panel of the three choices with a preview of the one under
/// the pointer. The preview says where it runs and what leaves the Mac, and a plan's model and effort can be set
/// there. Picking a choice that isn't set up opens Settings → Ask.
struct AskProviderMenu: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    static let claudeModels = [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    var body: some View {
        PreviewSelector(title: "Answers run on",
                        options: AnswerProvider.allCases.map {
                            SelectorOption(id: $0, symbol: Self.symbol($0), title: $0.title, subtitle: detail($0))
                        },
                        selection: model.answerProvider,
                        onSelect: choose,
                        footer: [("Ask Settings…", { model.openSettings(.ask) })]) {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(model.answerProvider)).imageScale(.small)
                Text(model.answerProvider.shortTitle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(type.caption.weight(.medium))
            .foregroundStyle(model.answerReadiness.isReady ? Palette.inkMuted : Palette.danger)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Palette.surface.opacity(0.7), in: Capsule())
            .contentShape(Capsule())
        } preview: { provider in
            AnswerModelPreview(model: model, provider: provider)
        }
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Answers run on")
        .accessibilityValue(model.answerProvider.title)
        .task { await model.refreshChatGPTProfiles() }
    }

    static func symbol(_ provider: AnswerProvider) -> String {
        switch provider {
        case .local: "laptopcomputer"
        case .chatgpt: "bubble.left.and.bubble.right"
        case .claude: "sparkle"
        }
    }

    /// The line under each choice: what it would use, or what it still needs.
    private func detail(_ provider: AnswerProvider) -> String {
        var choice = model.answerChoice
        choice.provider = provider
        if case .needsSetup = model.services?.answers.readiness(choice) ?? .ready {
            return provider == .local ? "Download needed" : "Set up in Settings"
        }
        switch provider {
        case .local: return "Private. Nothing leaves this Mac"
        case .chatgpt: return model.chatGPTSummary
        case .claude: return model.claudeSummary
        }
    }

    private var helpText: String {
        if case .needsSetup(let reason) = model.answerReadiness { return reason }
        return "Choose where answers run"
    }

    private func choose(_ provider: AnswerProvider) {
        model.answerProvider = provider
        if !model.answerReadiness.isReady { model.openSettings(.ask) }
    }
}

/// The preview beside the answer-model choices.
struct AnswerModelPreview: View {
    @Bindable var model: AppModel
    let provider: AnswerProvider
    @Environment(\.typography) private var type

    private var readiness: AnswerReadiness {
        var choice = model.answerChoice
        choice.provider = provider
        return model.services?.answers.readiness(choice) ?? .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: AskProviderMenu.symbol(provider))
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(type.episodeTitle)
                    status
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                fact("Runs", runs)
                fact("Leaves your Mac", leaves)
                fact("Speed", speed)
            }
            if provider == .chatgpt, !model.chatGPTModels.isEmpty {
                Divider().overlay(Palette.rule)
                compactPicker("Model", selection: $model.chatGPTModelID) {
                    ForEach(model.chatGPTModels) { Text($0.display_name).tag($0.id) }
                }
                let efforts = model.chatGPTModels.first { $0.id == model.chatGPTModelID }?.efforts ?? []
                if !efforts.isEmpty { effort($model.chatGPTEffort, efforts) }
            }
            if provider == .claude {
                Divider().overlay(Palette.rule)
                compactPicker("Model", selection: $model.claudeModel) {
                    ForEach(AskProviderMenu.claudeModels, id: \.0) { Text($0.1).tag($0.0) }
                }
                let efforts = ClaudePlan.efforts(for: model.claudeModel)
                if !efforts.isEmpty { effort($model.claudeEffort, efforts) }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch readiness {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").font(type.caption).foregroundStyle(Palette.accent)
        case .needsSetup(let reason):
            Text(reason).font(type.caption).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runs: String {
        switch provider {
        case .local: "On this Mac, with the Ask model (2.3 GB)."
        case .chatgpt: "On OpenAI's servers, with your ChatGPT plan. Your plan's limits apply."
        case .claude: "On Anthropic's servers, through Claude Code and your Claude plan."
        }
    }
    private var leaves: String {
        provider == .local ? "Nothing." : "Your question, recent answers and transcript text. Never audio."
    }
    private var speed: String {
        provider == .local ? "Slower on long episodes: it reads every part of the transcript." : "Fast. It reads the transcript in larger parts."
    }

    private func fact(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(type.eyebrow).tracking(0.8).foregroundStyle(Palette.inkMuted)
            Text(text).font(type.callout).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compactPicker<Content: View>(_ title: String, selection: Binding<String>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(type.callout).foregroundStyle(Palette.inkMuted)
            Spacer()
            Picker(title, selection: selection, content: content).labelsHidden().fixedSize()
        }
    }

    private func effort(_ selection: Binding<String>, _ efforts: [String]) -> some View {
        compactPicker("Effort", selection: selection) {
            Text("Default").tag("")
            ForEach(efforts, id: \.self) { Text(AppModel.effortTitle($0)).tag($0) }
        }
    }
}

// MARK: - Right: transcript or details

struct DetailCard: View {
    /// The tab row's height. The summary card's Play button is centred on the same line.
    static let headerHeight: CGFloat = 54
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
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help("Close this card")
                .accessibilityLabel("Close the right card")
            }
            .padding(.horizontal, 12)
            .frame(height: DetailCard.headerHeight)
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
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.copyTranscript) { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle())
                .help("Copy transcript")
                .accessibilityLabel("Copy transcript")
            Menu {
                Section("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button { model.export(format) } label: {
                            Text(format.title)
                            if !format.isAvailable { Text("Coming soon") }
                        }
                        .disabled(!format.isAvailable)
                    }
                }
                Section {
                    Menu("Translate To") {
                        ForEach(AppModel.AskLanguage.allCases.dropFirst()) { language in
                            Button(language.title) { model.translate(to: language) }
                        }
                    }
                }
                Section("View") {
                    Toggle("Speaker Labels", isOn: $model.showSpeakerLabels)
                    Toggle("Merge Lines", isOn: $model.mergeLines)
                    Toggle("Follow Playback", isOn: $model.followPlayback)
                }
                if model.isPersistent && !model.episode.id.isEmpty {
                    Section {
                        Button("Delete Episode…", role: .destructive) { confirmingDelete = true }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .help("Export, translate, view options and delete")
                .accessibilityLabel("Transcript options")
                .confirmationDialog("Delete “\(model.episode.title)”?", isPresented: $confirmingDelete) {
                    Button("Delete Episode", role: .destructive, action: model.deleteEpisode)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Wavepod deletes its transcript, summary, answers and downloaded audio. You can't undo this. To get it back, add the episode again and transcribe it.")
                }
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
