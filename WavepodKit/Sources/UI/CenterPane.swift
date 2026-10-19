import Library
import SwiftUI

struct CenterPane: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.typography) private var type

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(selection: $model.centerTab)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            Divider().overlay(Palette.rule)
            switch model.centerTab {
            case .transcript:
                TranscriptToolbar(model: model)
                Divider().overlay(Palette.rule)
                TranscriptView(model: model, focus: focus)
                Divider().overlay(Palette.rule)
                TranscriptFooter(model: model)
            case .summary:
                SummaryView(model: model)
            case .chapters:
                ChaptersView(model: model)
            }
        }
        .pane()
    }
}

struct TabStrip: View {
    @Binding var selection: AppModel.CenterTab
    @Environment(\.typography) private var type
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 22) {
            ForEach(AppModel.CenterTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.title)
                            .font(type.label)
                            .foregroundStyle(selection == tab ? Palette.ink : Palette.inkMuted)
                        Rectangle()
                            .fill(selection == tab ? Palette.accent : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Views")
    }
}

// MARK: - Transcript

struct TranscriptToolbar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button(action: model.copyTranscript) { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle())
                .help("Copy transcript")
                .accessibilityLabel("Copy transcript")
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.isAvailable ? format.title : "\(format.title) — coming soon") {
                        model.export(format)
                    }
                    .disabled(!format.isAvailable)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle())
            .fixedSize()
            .help("Export")
            .accessibilityLabel("Export transcript")
            Menu {
                ForEach(AppModel.AskLanguage.allCases.dropFirst()) { language in
                    Button(language.title) {
                        model.askLanguage = language
                        model.translate()
                    }
                }
            } label: {
                Image(systemName: "character.bubble")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle())
            .fixedSize()
            .help("Translate")
            .accessibilityLabel("Translate transcript")
            Spacer()
            Button {
                model.centerTab = .summary
                if model.summary == nil { model.generateNotes() }
            } label: {
                Label("Summarize", systemImage: "text.append")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TranscriptView: View {
    let model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding

    var body: some View {
        let current = model.currentParagraphIndex
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        ParagraphView(
                            paragraph: paragraph,
                            speaker: model.speaker(paragraph.speaker),
                            showSpeaker: model.showSpeakerLabels,
                            currentTime: index == current ? model.player.currentTime : nil,
                            onSeek: { model.play(from: $0) },
                            evidence: model.speakerEvidence[paragraph.speaker] ?? [],
                            onRename: { model.rename(paragraph.speaker, to: $0) }
                        )
                        .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .focusable()
            .focused(focus, equals: .transcript)
            .focusEffectDisabled()
            .onChange(of: current) { _, new in
                guard model.followPlayback, model.player.isPlaying, let new else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(model.paragraphs[new].id, anchor: .init(x: 0.5, y: 0.3))
                }
            }
        }
        .accessibilityLabel("Transcript")
    }
}

struct ParagraphView: View {
    let paragraph: Paragraph
    let speaker: Speaker
    let showSpeaker: Bool
    /// Set only on the paragraph being played, so only that one re-renders as time moves.
    let currentTime: Double?
    let onSeek: (Double) -> Void
    var evidence: [SpeakerEvidence] = []
    let onRename: (String) -> Void
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TimestampPill(time: paragraph.start, isActive: currentTime != nil) { onSeek(paragraph.start) }
                if showSpeaker {
                    SpeakerLabel(speaker: speaker, evidence: evidence, onSeek: onSeek, onRename: onRename)
                }
            }
            Text(attributedText)
                .font(type.reading)
                .foregroundStyle(Palette.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(currentTime != nil ? Palette.highlight : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(showSpeaker ? speaker.name + ", " : "")at \(Timecode.spoken(paragraph.start))")
        .accessibilityValue(paragraph.text)
        .accessibilityAction(named: "Play from here") { onSeek(paragraph.start) }
    }

    /// The paragraph text with the word being spoken highlighted and overlapping speech set in italics.
    private var attributedText: AttributedString {
        var result = AttributedString()
        for (i, word) in paragraph.words.enumerated() {
            var run = AttributedString(i == 0 ? word.text : " " + word.text)
            if word.overlap { run.inlinePresentationIntent = .emphasized }
            if let t = currentTime, word.start <= t, t < word.end + 0.05 {
                var plain = AttributedString(word.text)
                plain.backgroundColor = Palette.wordHighlight
                if word.overlap { plain.inlinePresentationIntent = .emphasized }
                run = i == 0 ? plain : AttributedString(" ") + plain
            }
            result += run
        }
        return result
    }
}

struct SpeakerLabel: View {
    let speaker: Speaker
    var evidence: [SpeakerEvidence] = []
    var onSeek: (Double) -> Void = { _ in }
    let onRename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @Environment(\.typography) private var type

    var body: some View {
        Button {
            draft = speaker.name
            editing = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Palette.speaker(speaker.colorIndex)).frame(width: 7, height: 7)
                Text(speaker.name)
                    .font(type.speaker)
                    .foregroundStyle(Palette.speaker(speaker.colorIndex))
                if !speaker.isConfirmed, let confidence = speaker.suggestionConfidence {
                    Text("suggested · \(Int(confidence * 100))%")
                        .font(type.caption)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename this speaker everywhere")
        .accessibilityLabel("Speaker \(speaker.name)\(speaker.isConfirmed ? "" : ", not confirmed")")
        .accessibilityHint("Rename this speaker everywhere")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speaker name").font(type.label)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(commit)
                ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Use \(item.name) · \(item.source) · \(Int(item.confidence * 100))%") {
                            draft = item.name
                            commit()
                        }
                        if let citation = item.citation {
                            Text("“\(citation.quote)”").font(type.caption).lineLimit(5)
                            Button("Play evidence at \(Timecode.format(citation.start))") { onSeek(citation.start) }
                        }
                    }.frame(maxWidth: 280, alignment: .leading)
                }
                Text("Applies to every line of this speaker in this episode.")
                    .font(type.caption)
                    .foregroundStyle(Palette.inkMuted)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                        .keyboardShortcut(.cancelAction)
                    Button(speaker.isConfirmed ? "Rename" : "Confirm", action: commit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func commit() {
        onRename(draft)
        editing = false
    }
}

struct TranscriptFooter: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        HStack(spacing: 18) {
            Toggle("Speaker labels", isOn: $model.showSpeakerLabels).fixedSize()
            Toggle("Merge lines", isOn: $model.mergeLines).fixedSize()
            Spacer(minLength: 8)
            Toggle("Follow", isOn: $model.followPlayback).fixedSize()
                .help("Keep the spoken paragraph in view while playing")
                .accessibilityLabel("Follow playback")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(type.callout)
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Summary

struct SummaryView: View {
    let model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        ScrollView {
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 18) {
                    Text(summary.overview)
                        .font(type.reading)
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)

                    SectionHeading("Key points")
                    ForEach(summary.points) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TimestampPill(time: point.citation.start) { model.play(from: point.citation.start) }
                            Text(point.text)
                                .font(type.reading)
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SectionHeading("Quotes")
                    ForEach(summary.quotes, id: \.self) { quote in
                        HStack(alignment: .top, spacing: 12) {
                            Rectangle().fill(Palette.accent).frame(width: 3)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("“\(quote.quote)”")
                                    .font(type.reading.italic())
                                    .foregroundStyle(Palette.ink)
                                TimestampPill(time: quote.start) { model.play(from: quote.start) }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Written on this Mac from the transcript. Every point links to where it is said.")
                        .font(type.caption)
                        .foregroundStyle(Palette.inkMuted)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("No summary yet", systemImage: "text.append",
                                       description: Text("Summaries are written on this Mac by the local model."))
            }
        }
    }
}

struct SectionHeading: View {
    let title: String
    @Environment(\.typography) private var type
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(type.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Palette.inkMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Chapters

struct ChaptersView: View {
    let model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        let current = model.currentChapterIndex
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        model.play(from: chapter.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Timecode.format(chapter.start))
                                .font(type.timestamp)
                                .monospacedDigit()
                                .foregroundStyle(Palette.accent)
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapter.title)
                                    .font(type.reading.weight(.semibold))
                                    .foregroundStyle(Palette.ink)
                                Text(chapter.summary)
                                    .font(type.callout)
                                    .foregroundStyle(Palette.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(index == current ? Palette.highlight : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(chapter.title), at \(Timecode.spoken(chapter.start))")
                    .accessibilityHint("Play from this chapter")
                }
            }
            .padding(12)
        }
    }
}
