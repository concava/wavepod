import SwiftUI

/// The first-run welcome: what wavepod does, the one-time model download, and a first episode. Shown over the
/// window until finished or skipped; Help → Welcome to wavepod brings it back.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0
    @State private var link = ""
    @FocusState private var linkFocused: Bool
    @Environment(\.typography) private var type
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                Button("Skip") { model.finishOnboarding() }
                    .buttonStyle(.plain)
                    .font(type.label)
                    .foregroundStyle(Palette.inkMuted)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the welcome. Help → Welcome to wavepod opens it again.")
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
            .transition(.opacity)
            .id(step)

            HStack {
                if step > 0 {
                    Button("Back") { go(step - 1) }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                primaryButton
            }
            .overlay {
                // Centred on the card whichever buttons are showing.
                HStack(spacing: 7) {
                    ForEach(0..<steps, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? Palette.accent : Palette.rule)
                            .frame(width: index == step ? 18 : 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(steps)")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 680, height: 540)
        .background(Palette.surface)
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
        withAnimation(motion(.easeOut(duration: 0.2), reduced: reduceMotion)) { step = next }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Every podcast, transcribed on this Mac")
                .font(type.display)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "text.quote", title: "Transcripts with speakers",
                        detail: "Paste a Spotify, Apple Podcasts, YouTube or RSS link, or drop an audio file. Name a voice once and wavepod recognises it in the next episode.")
                Feature(symbol: "text.append", title: "A summary of every episode",
                        detail: "Written when the transcription finishes. Ask questions and every answer links to the moment it was said.")
                Feature(symbol: "lock", title: "Private by design",
                        detail: "Audio, transcripts and answers never leave this Mac. Settings lists every network request.")
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download the models once")
                .font(type.display)
                .foregroundStyle(Palette.ink)
            Text("They run on this Mac, so they download one time. Transcription works without the Ask model; add it now or later in Settings.")
                .font(type.body)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ModelRow(model: model, title: "Transcription and speakers", detail: "Needed to transcribe. Recognises who speaks.",
                         kind: "native", folder: "parakeet")
                ModelRow(model: model, title: "Ask and summaries", detail: "About 2.3 GB. Writes summaries and answers questions.",
                         kind: "language", folder: "language", last: true)
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
            Text("Paste a link to an episode or a show. Spotify, Apple Podcasts, YouTube and RSS links all work.")
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
                } label: { Label("Open an Audio File", systemImage: "waveform") }
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

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.typography) private var type

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 36, height: 36)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(type.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(type.callout).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lets one button switch between two styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
