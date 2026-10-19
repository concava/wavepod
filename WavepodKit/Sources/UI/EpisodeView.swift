import Library
import SwiftUI

/// One episode: a header with the episode and its actions, the transcript as the main column with the Ask
/// composer under it, and a side pane for answers, summary, chapters or details that opens and closes.
struct Workspace: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            EpisodeHeader(model: model)
            Divider().overlay(Palette.rule)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TranscriptView(model: model, focus: focus)
                        .overlay(alignment: .bottom) {
                            if !model.followPlayback && model.player.isPlaying {
                                Button { model.followPlayback = true } label: {
                                    Label("Follow Playback", systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(ChipStyle(prominent: true))
                                .padding(.bottom, 8)
                            }
                        }
                    AskComposer(model: model, focus: focus)
                }
                .frame(maxWidth: .infinity)
                if model.showSidePane {
                    Divider().overlay(Palette.rule)
                    SidePaneView(model: model)
                        .frame(width: 360)
                }
            }
        }
    }
}

struct EpisodeHeader: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    private var episode: Episode { model.episode }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(hue: episode.artworkHue, cornerRadius: 8)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(type.episodeTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(episode.showName) · \(episode.pubDate.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.format(episode.duration))")
                    .font(type.caption)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Button {
                    model.player.isPlaying ? model.player.pause() : model.play(from: model.player.currentTime)
                } label: {
                    Label(model.player.isPlaying ? "Pause" : "Play",
                          systemImage: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.trailing, 4)

                Button(action: model.copyTranscript) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle())
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.isAvailable ? format.title : "\(format.title) — coming soon") { model.export(format) }
                            .disabled(!format.isAvailable)
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .iconMenu(help: "Export transcript")
                Menu {
                    ForEach(AppModel.AskLanguage.allCases.dropFirst()) { language in
                        Button(language.title) {
                            model.askLanguage = language
                            model.translate()
                        }
                    }
                } label: { Image(systemName: "character.bubble") }
                    .iconMenu(help: "Translate transcript")
                Menu {
                    Toggle("Speaker Labels", isOn: $model.showSpeakerLabels)
                    Toggle("Merge Lines", isOn: $model.mergeLines)
                    Toggle("Follow Playback", isOn: $model.followPlayback)
                } label: { Image(systemName: "text.alignleft") }
                    .iconMenu(help: "Transcript view options")
                if model.isPersistent && !model.transcript.segments.isEmpty {
                    Menu {
                        Button("Summary") { model.generateNotes(); model.sidePane = .summary; model.showSidePane = true }
                        Button("Chapters") { model.generateNotes(chaptersOnly: true); model.sidePane = .chapters; model.showSidePane = true }
                    } label: { Image(systemName: "sparkles") }
                        .iconMenu(help: "Write a summary or chapters on this Mac")
                        .disabled(model.isGenerating)
                }

                Rectangle().fill(Palette.rule).frame(width: 1, height: 20).padding(.horizontal, 4)

                ForEach(AppModel.SidePane.allCases) { pane in
                    let isOn = model.showSidePane && model.sidePane == pane
                    Button { model.toggleSidePane(pane) } label: { Image(systemName: pane.symbol) }
                        .buttonStyle(IconButtonStyle(isActive: isOn))
                        .help(isOn ? "Hide \(pane.title)" : pane.title)
                        .accessibilityLabel(pane.title)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private extension View {
    func iconMenu(help: String) -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle())
            .fixedSize()
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The question box under the transcript, in the manner of a chat prompt: text on top, options and send below.
struct AskComposer: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @State private var draft = ""
    @Environment(\.typography) private var type

    static let maxLength = 2000

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask anything about this episode", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(type.body)
                    .lineLimit(1...6)
                    .focused(focus, equals: .ask)
                    .onSubmit(send)
                    .onChange(of: draft) { _, new in
                        if new.count > Self.maxLength { draft = String(new.prefix(Self.maxLength)) }
                    }
                    .accessibilityLabel("Question")
                HStack(spacing: 8) {
                    Menu {
                        Picker("Answer language", selection: $model.askLanguage) {
                            ForEach(AppModel.AskLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.askLanguage == .auto ? "Same language" : model.askLanguage.title, systemImage: "globe")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(ChipStyle())
                    .fixedSize()
                    .help("Answer language")
                    .accessibilityLabel("Answer language")
                    .accessibilityValue(model.askLanguage.title)
                    Spacer()
                    if draft.count > Self.maxLength - 200 {
                        Text("\(draft.count)/\(Self.maxLength)")
                            .font(type.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkMuted)
                    }
                    if model.isAnswering {
                        ProgressView().controlSize(.small).accessibilityLabel("Answering")
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 28, height: 28)
                            .background(canSend ? Palette.accent : Palette.inkMuted.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Ask (Return)")
                    .accessibilityLabel("Send question")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .elevated(cornerRadius: 16)
            Text("Answers come only from this transcript and can be wrong. Check the linked moments.")
                .font(type.caption)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !model.isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        model.ask(draft)
        draft = ""
        model.sidePane = .ask
        model.showSidePane = true
    }
}

struct SidePaneView: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(model.sidePane.title, systemImage: model.sidePane.symbol)
                    .font(type.paneTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.showSidePane = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help("Close")
                .accessibilityLabel("Close \(model.sidePane.title)")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider().overlay(Palette.rule)
            Group {
                switch model.sidePane {
                case .ask: AskThread(model: model)
                case .summary: SummaryView(model: model)
                case .chapters:
                    if model.chapters.isEmpty {
                        ContentUnavailableView {
                            Label("No chapters yet", systemImage: "list.number")
                        } description: {
                            Text("Chapters are written on this Mac by the local model.")
                        } actions: {
                            if model.isPersistent && !model.transcript.segments.isEmpty {
                                Button(model.isGenerating ? "Writing…" : "Write Chapters") { model.generateNotes(chaptersOnly: true) }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .disabled(model.isGenerating)
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
        .background(Palette.surface)
    }
}

struct AskThread: View {
    let model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.chat.isEmpty {
                        Text("Ask anything about this episode in the box under the transcript. Answers quote the transcript and link to the moment it was said.")
                            .font(type.callout)
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.chat) { message in
                        MessageView(message: message) { model.play(from: $0) }
                            .id(message.id)
                    }
                    if model.isAnswering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working on this Mac…").font(type.caption).foregroundStyle(Palette.inkMuted)
                        }
                        .id("answering")
                    }
                }
                .padding(14)
            }
            .onChange(of: model.chat.count) {
                if let last = model.chat.last {
                    withAnimation(motion(.default, reduced: reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
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
