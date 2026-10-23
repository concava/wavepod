import SwiftUI

/// The first-run welcome: what wavepod does, the one-time model download, and a first episode. Shown over the
/// window until finished or skipped; Help → Welcome to wavepod brings it back.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0
    /// The direction of the last step change, so the next step slides in from the side it comes from.
    @State private var forward = true
    @State private var link = ""
    @FocusState private var linkFocused: Bool
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps = ["Welcome", "Models", "First episode"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                stepNames
                Spacer()
                Button("Skip") { model.finishOnboarding() }
                    .buttonStyle(.plain)
                    .font(type.label)
                    .foregroundStyle(Palette.inkMuted)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the welcome. Help → Welcome to Wavepod opens it again.")
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Group {
                switch step {
                case 0: welcome
                case 1: models
                default: firstEpisode
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.top, 26)
            .transition(.step(forward: forward, reduced: reduceMotion))
            .id(step)

            HStack {
                if step > 0 {
                    Button("Back") { go(step - 1) }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 680, height: 540)
        .background(Palette.surface)
    }

    /// The step names, the current one in ink with an accent rule under it. They say where you are and what comes
    /// next, which page dots do not.
    private var stepNames: some View {
        HStack(spacing: 18) {
            ForEach(steps.indices, id: \.self) { index in
                Text(steps[index])
                    .font(type.label)
                    .foregroundStyle(index == step ? Palette.ink : Palette.inkMuted)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Palette.accent).frame(height: 2).opacity(index == step ? 1 : 0)
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(steps.count): \(steps[step])")
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case 0:
            Button("Get Started") { go(1) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        case 1:
            Button(model.installedModels.contains("parakeet") ? "Continue" : "Later") { go(2) }
                .buttonStyle(model.installedModels.contains("parakeet") ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                .keyboardShortcut(.defaultAction)
        default:
            Button("Finish") { model.finishOnboarding() }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func go(_ next: Int) {
        forward = next > step
        withAnimation(reduceMotion ? Motion.fade : Motion.standard) { step = next }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read any podcast, ask it anything.")
                .font(type.display)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Wavepod writes the transcript on this Mac, names each speaker and summarizes the episode. Your audio stays on this Mac.")
                .font(type.body)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            Specimen()
                .padding(.top, 10)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download the models")
                .font(type.display)
                .foregroundStyle(Palette.ink)
            Text("The models run on this Mac, so you download them one time. You need the transcription models to start. The Ask model can wait until later, in Settings.")
                .font(type.body)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ModelRow(model: model, title: "Transcription and speakers", detail: "Needed to transcribe. Recognises who speaks.",
                         kind: .native)
                ModelRow(model: model, title: "Ask model", detail: "About 2.3 GB. Writes summaries and answers questions on this Mac.",
                         kind: .language, last: true)
            }
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if model.isInstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.modelStatus).font(type.callout).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
            }
        }
    }

    private var firstEpisode: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add your first episode")
                .font(type.display)
                .foregroundStyle(Palette.ink)
            Text("Paste a link to an episode or a show from Spotify, Apple Podcasts, YouTube or an RSS feed.")
                .font(type.body)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(Palette.inkMuted).accessibilityHidden(true)
                TextField("https://open.spotify.com/episode/…", text: $link)
                    .textFieldStyle(.plain)
                    .font(type.body)
                    .focused($linkFocused)
                    .onSubmit(transcribe)
                    .accessibilityLabel("Episode or show link")
                Button("Transcribe", action: transcribe)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 44)
            .background(Palette.sunken, in: Capsule())
            HStack(spacing: 8) {
                Text("Or").font(type.callout).foregroundStyle(Palette.inkMuted)
                Button {
                    model.finishOnboarding()
                    model.chooseFile()
                } label: { Label("Add an Audio File", systemImage: "waveform") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !model.installedModels.contains("parakeet") {
                Label("Install the transcription models first (previous step), or the episode waits in the queue.",
                      systemImage: "exclamationmark.circle")
                    .font(type.callout)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .onAppear { linkFocused = true }
    }

    private func transcribe() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.commandText = text
        model.submitCommand()
        model.commandText = ""
        model.finishOnboarding()
    }
}

/// A few seconds of the sample episode as Wavepod shows it: a named speaker, the word that is playing, and the
/// summary point that cites it. It shows what the app does instead of describing it.
private struct Specimen: View {
    @Environment(\.typography) private var type
    private let words = "Everything that could go wrong. Wind direction, visibility, every ship that passed, and how much oil the lamp burned."
    private let playing = "oil"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Timestamp("00:36")
                    Circle().fill(Palette.speaker(1)).frame(width: 6, height: 6)
                    Text("Jordi Serra").font(type.label).foregroundStyle(Palette.speaker(1))
                    Text("Low Tide").font(type.caption).foregroundStyle(Palette.inkMuted)
                }
                transcriptLine
                    .font(.system(size: 16, design: .serif))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Palette.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("SUMMARY").font(type.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Palette.inkMuted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text("Logbooks as audits: ").bold() +
                     Text("keepers wrote down the oil the lamp burned, and an inspector checked the numbers."))
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Timestamp("00:41")
                }
            }
            .padding(16)
        }
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rule))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example from the sample episode Low Tide: a transcript line by Jordi Serra at 36 seconds, and the summary point that cites it.")
    }

    /// The sentence with the playing word highlighted, as the transcript does during playback.
    private var transcriptLine: Text {
        let parts = words.components(separatedBy: playing)
        var attributed = AttributedString(parts[0])
        var word = AttributedString(playing)
        word.backgroundColor = Palette.wordHighlight
        attributed += word + AttributedString(parts.dropFirst().joined(separator: playing))
        return Text(attributed).foregroundStyle(Palette.ink)
    }
}

private struct Timestamp: View {
    let text: String
    init(_ text: String) { self.text = text }
    @Environment(\.typography) private var type

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Lets one button switch between two styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
