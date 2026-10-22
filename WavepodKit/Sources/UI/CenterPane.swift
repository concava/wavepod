import LLM
import Library
import SwiftUI

// MARK: - Transcript

struct TranscriptView: View {
    let model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                // A reading column, as wide as a book page, centred in whatever room the side pane leaves.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .focusable()
            .focused(focus, equals: .transcript)
            .focusEffectDisabled()
            .onChange(of: model.transcriptLocation, initial: true) { _, location in
                guard let location, let index = model.paragraphs.index(at: location.time) else { return }
                proxy.scrollTo(model.paragraphs[index].id, anchor: .init(x: 0.5, y: 0.3))
            }
            .onChange(of: current) { _, new in
                guard model.followPlayback, model.player.isPlaying, let new else { return }
                withAnimation(motion(.easeInOut(duration: 0.35), reduced: reduceMotion)) {
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

// MARK: - Summary

struct SummaryView: View {
    let model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            AnswersSection(model: model)
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 18) {
                    if !summary.overview.isEmpty {
                        Text(summary.overview)
                            .font(type.reading)
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }

                    ForEach(summary.sections ?? [SummarySection(title: "Key points", points: summary.points)]) { section in
                        SectionHeading(section.title)
                        ForEach(section.points) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                TimestampPill(time: point.citation.start) { model.play(from: point.citation.start) }
                                Text(.init(point.text))
                                    .font(type.reading)
                                    .foregroundStyle(Palette.ink)
                                    .lineSpacing(5)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !summary.quotes.isEmpty { SectionHeading("Quotes") }
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
                    Text("Every point links to the moment in the episode that supports it.")
                        .font(type.caption)
                        .foregroundStyle(Palette.inkMuted)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.arrive(reduced: reduceMotion))
            } else {
                if model.isGenerating {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.answerProvider == .local ? "Writing the summary on this Mac…"
                             : "Writing the summary with \(model.answerProvider.shortTitle)…").font(type.callout).foregroundStyle(Palette.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ContentUnavailableView {
                        Label("No summary yet", systemImage: "text.append")
                    } description: {
                        Text(model.answerReadiness.isReady || !model.isPersistent
                             ? "Your answer model writes a summary when a transcription finishes."
                             : "To get a summary of every episode, install the Ask model or choose your ChatGPT or Claude plan in Settings → Ask.")
                    } actions: {
                        if model.isPersistent && !model.answerReadiness.isReady {
                            Button("Set Up Answers") { model.openSettings(.ask) }.buttonStyle(PrimaryButtonStyle())
                        } else if model.isPersistent && !model.transcript.segments.isEmpty {
                            Button("Write Summary") { model.generateNotes() }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.enter, value: model.summary != nil)
    }
}

/// Questions asked in the middle card's Ask field, newest first, above the summary.
struct AnswersSection: View {
    let model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each question with the answer that followed it.
    private var exchanges: [(question: ChatMessage, answer: ChatMessage?)] {
        var result: [(ChatMessage, ChatMessage?)] = []
        for message in model.chat {
            if message.role == .user { result.append((message, nil)) }
            else if let last = result.indices.last, result[last].1 == nil { result[last].1 = message }
        }
        return result.reversed()
    }

    var body: some View {
        if !model.chat.isEmpty || model.isAnswering {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("Answers")
                if model.isAnswering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.askProgress.isEmpty ? "Answering…" : model.askProgress)
                            .font(type.callout).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Stop", action: model.cancelAnswer).buttonStyle(ChipStyle(prominent: false))
                    }
                }
                ForEach(exchanges, id: \.question.id) { exchange in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(exchange.question.text)
                            .font(type.episodeTitle)
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .accessibilityLabel("You asked: \(exchange.question.text)")
                        if let answer = exchange.answer {
                            MessageView(message: answer) { model.play(from: $0) }
                                .transition(.arrive(reduced: reduceMotion))
                        }
                    }
                    .transition(.arrive(reduced: reduceMotion))
                }
                Divider().overlay(Palette.rule).padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? Motion.fade : Motion.enter, value: model.chat.count)
            .animation(Motion.fade, value: model.isAnswering)
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
