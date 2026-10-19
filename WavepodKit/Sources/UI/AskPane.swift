import Library
import SwiftUI

struct AskPane: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @State private var draft = ""
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxLength = 2000

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Ask this episode", systemImage: "bubble.left.and.text.bubble.right")
                    .font(type.paneTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().overlay(Palette.rule)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.chat.isEmpty {
                            Text("Ask anything about this episode. Answers quote the transcript and link to the moment it was said.")
                                .font(type.callout)
                                .foregroundStyle(Palette.inkMuted)
                                .padding(.top, 8)
                        }
                        ForEach(model.chat) { message in
                            MessageView(message: message) { model.play(from: $0) }
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.chat.count) {
                    if let last = model.chat.last {
                        withAnimation(motion(.default, reduced: reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if model.isAnswering {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.askProgress).font(type.caption)
                    Spacer()
                    Button("Stop", action: model.cancelAnswer)
                }.padding(12)
            }
            Divider().overlay(Palette.rule)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("What do you want to know about this episode?", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(type.body)
                        .lineLimit(1...5)
                        .focused(focus, equals: .ask)
                        .onSubmit(send)
                        .onChange(of: draft) { _, new in
                            if new.count > Self.maxLength { draft = String(new.prefix(Self.maxLength)) }
                        }
                        .accessibilityLabel("Question")
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 26, height: 26)
                            .background(canSend ? Palette.accent : Palette.inkMuted.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send question")
                }
                .padding(10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.rule))

                HStack {
                    Button(model.askProvider == "chatgpt" ? "ChatGPT plan" : model.askProvider == "claude" ? "Claude plan" : "Local model") { model.openSettings(.ask) }
                        .font(type.caption).buttonStyle(.plain).foregroundStyle(Palette.inkMuted)
                        .help("Choose where answers run")
                    Picker(selection: $model.askLanguage) {
                        ForEach(AppModel.AskLanguage.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Image(systemName: "globe")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("Answer language")
                    Spacer()
                    Text("\(draft.count)/\(Self.maxLength)")
                        .font(type.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkMuted)
                        .accessibilityHidden(true)
                }
                Text("Answers come only from this transcript and can be wrong. Check the linked moments.")
                    .font(type.caption)
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .pane()
    }

    private var canSend: Bool { !model.isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        model.ask(draft)
        draft = ""
    }
}

struct MessageView: View {
    let message: ChatMessage
    let onSeek: (Double) -> Void
    @Environment(\.typography) private var type

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(type.body)
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You asked: \(message.text)")
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text)
                    .font(type.body)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(message.citations, id: \.self) { citation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TimestampPill(time: citation.start) { onSeek(citation.start) }
                        Text("“\(citation.quote)”")
                            .font(type.callout.italic())
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}
