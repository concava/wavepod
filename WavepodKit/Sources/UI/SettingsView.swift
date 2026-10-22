import Library
import Pipeline
import SwiftUI

/// Settings as a sheet over the window: a list of panes on the left, rows of title, explanation and control on the right.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(type.eyebrow).tracking(1.1)
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                ForEach(AppModel.SettingsPane.allCases) { pane in
                    NavRow(title: pane.title, symbol: pane.symbol, isSelected: model.settingsPane == pane) {
                        model.settingsPane = pane
                    }
                }
                Spacer()
                Text("Wavepod \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(type.caption)
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 10)
            }
            .padding(16)
            .frame(width: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.paper)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.settingsPane.title).font(type.display).foregroundStyle(Palette.ink)
                        Spacer()
                        Button("Done") { model.showSettings = false }
                            .buttonStyle(SecondaryButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
                    content
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.surface)
        }
        .frame(width: 900, height: 620)
    }

    @ViewBuilder private var content: some View {
        switch model.settingsPane {
        case .general: general
        case .transcription: transcription
        case .ask: AskSettings(model: model)
        case .queue: queue
        case .privacy: privacy
        }
    }

    @ViewBuilder private var general: some View {
        SettingsGroup(title: "Appearance") {
            SettingRow(title: "Theme", detail: "Follow the system, or always use light or dark.") {
                Picker("Theme", selection: $model.appearance) {
                    Text("System").tag(AppModel.Appearance.system)
                    Text("Light").tag(AppModel.Appearance.light)
                    Text("Dark").tag(AppModel.Appearance.dark)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingRow(title: "Text size", detail: "Changes the size of all text in the window. You can also use ⌘+ and ⌘−.") {
                Picker("Text size", selection: $model.textScale) {
                    ForEach(Typography.scales, id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: "Reading font", detail: "The font of the transcript, answers, summary and About text.") {
                Picker("Reading font", selection: $model.readingFont) {
                    ForEach(ReadingFont.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(title: "Reading size", detail: "The size of the transcript, answers, summary and About text.") {
                Picker("Reading size", selection: $model.readingSize) {
                    ForEach(Typography.readingSizes, id: \.self) { Text("\($0.formatted()) pt").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text("The quick brown fox jumps over the lazy dog.")
                .font(type.reading)
                .foregroundStyle(Palette.ink)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .accessibilityHidden(true)
        }
        SettingsGroup(title: "Podcasts") {
            SettingRow(title: "Check podcasts in the background",
                       detail: "Checks every hour, also when Wavepod is closed. Wavepod transcribes new episodes only for podcasts where you turn on Auto-transcribe.",
                       last: true) {
                Toggle("Check podcasts in the background", isOn: Binding(get: { model.backgroundChecks }, set: model.setBackgroundChecks))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var transcription: some View {
        SettingsGroup(title: "Engine") {
            SettingRow(title: "Where audio is transcribed",
                       detail: "With On this Mac, the audio stays on this Mac. With your own Scriberr server, the audio goes to that server.",
                       last: model.engineChoice != "scriberr") {
                Picker("Engine", selection: $model.engineChoice) {
                    Text("On this Mac").tag("native")
                    Text("My Scriberr server").tag("scriberr")
                }
                .labelsHidden().fixedSize()
            }
            if model.engineChoice == "scriberr" {
                SettingRow(title: "Server", detail: "Wavepod saves the API key in the Keychain.", last: true) {
                    VStack(alignment: .trailing) {
                        TextField("Server URL", text: $model.scriberrURL).frame(width: 260)
                        SecureField("API key", text: $model.scriberrKey).frame(width: 260)
                    }
                }
            } else {
                ModelRow(model: model, title: "Transcription and speakers", detail: "Parakeet, Whisper for Catalan and other languages, voice activity and speaker detection.",
                         kind: "native", folder: "parakeet", last: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 14) {
            HStack {
                Label("On battery power, transcription pauses below 20 % and in Low Power Mode. It continues from the last checkpoint.", systemImage: "battery.75percent")
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
                Spacer()
                Button("Save Engine", action: model.saveEngine).buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isPowerPaused && !model.jobs.contains(where: { $0.state == .running }) {
                Label("Paused: battery below 20 % or Low Power Mode. Jobs continue when you connect the Mac to power.", systemImage: "battery.50percent")
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
            }
            SettingsGroup(title: "Transcriptions") {
                if model.jobs.isEmpty {
                    Text("The queue is empty. Paste a podcast link or open an audio file.")
                        .font(type.callout).foregroundStyle(Palette.inkMuted).padding(18)
                }
                ForEach(model.jobs) { job in
                    QueueRow(model: model, job: job, last: job.id == model.jobs.last?.id)
                }
            }
            HStack {
                Spacer()
                Button("Open Audio…", action: model.chooseFile).buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio and transcripts stay on this Mac unless you choose your own Scriberr server. Answers stay on this Mac unless you choose a ChatGPT or Claude plan. This list shows every request that Wavepod made: model downloads, feeds, artwork, link lookups and answers.")
                .font(type.body).foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            SettingsGroup(title: "Network log") {
                if model.networkEntries.isEmpty {
                    Text("No requests yet.").font(type.callout).foregroundStyle(Palette.inkMuted).padding(16)
                }
                ForEach(model.networkEntries.suffix(80).reversed()) { entry in
                    HStack(spacing: 12) {
                        Text(entry.date, style: .time).monospacedDigit().foregroundStyle(Palette.inkMuted)
                        Text(entry.method).font(type.timestamp)
                        Text(entry.host).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(entry.purpose).foregroundStyle(Palette.inkMuted)
                        if let status = entry.status { Text(String(status)).monospacedDigit() }
                    }
                    .font(type.callout)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
            }
        }
    }
}

/// A titled, rounded group of setting rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(type.paneTitle).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var last = false
    @ViewBuilder let control: Control
    @Environment(\.typography) private var type

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text(detail).font(type.callout).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if !last { Divider().overlay(Palette.rule).padding(.horizontal, 18) }
        }
    }
}

struct ModelRow: View {
    let model: AppModel
    let title: String
    let detail: String
    let kind: String
    let folder: String
    var last = false

    var body: some View {
        SettingRow(title: title, detail: detail, last: last) {
            if model.installedModels.contains(folder) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.accent)
            } else {
                Button("Install") { model.installModels(kind) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isInstalling)
            }
        }
    }
}

struct QueueRow: View {
    let model: AppModel
    let job: TranscriptionJob
    var last = false
    @State private var hovering = false
    @Environment(\.typography) private var type

    private var record: EpisodeListing? {
        guard job.state == .completed else { return nil }
        return model.savedEpisodes.first { $0.id == JobQueue.episodeID(job.episode) }
    }

    var body: some View {
        Group {
            if let record {
                // A finished job is one line: the whole row opens its transcript.
                Button { model.showSettings = false; model.open(record) } label: { content }
                    .buttonStyle(.plain)
                    .background(hovering ? Palette.sunken : .clear)
                    .onHover { hovering = $0 }
                    .help("Open the transcript")
                    .accessibilityHint("Opens the transcript")
            } else {
                content
            }
        }
        .overlay(alignment: .bottom) {
            if !last { Divider().overlay(Palette.rule).padding(.horizontal, 18) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.episode.title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer()
                if record != nil {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkMuted).opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                } else {
                    Text(job.state.rawValue.capitalized).font(type.callout).foregroundStyle(Palette.inkMuted)
                }
            }
            if job.state == .completed {
                Text(job.episode.showTitle ?? "Completed").font(type.callout).foregroundStyle(Palette.inkMuted).lineLimit(1)
            } else {
                if job.state == .running || job.state == .queued || job.state == .paused {
                    ProgressView(value: job.fraction).tint(Palette.accent)
                }
                Text(job.batteryPaused ? "Paused to save battery. Continues when you connect the Mac to power." : job.stage)
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
                if let error = job.error {
                    Text(error).font(type.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if job.state == .running || job.state == .queued {
                        Button("Pause") { model.manageJob(job, action: "pause") }.buttonStyle(SecondaryButtonStyle())
                        Button("Cancel") { model.manageJob(job, action: "cancel") }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Resume") { model.manageJob(job, action: "resume") }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
