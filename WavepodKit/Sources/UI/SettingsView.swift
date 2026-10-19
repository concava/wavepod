import Library
import Pipeline
import SwiftUI

/// Settings as a sheet over the window: a list of panes on the left, rows of title, explanation and control on the right.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.dismiss) private var dismiss

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
                Text("wavepod \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
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
                        Button("Done") { dismiss() }
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
        case .queue: queue
        case .models: models
        case .shows: shows
        case .privacy: privacy
        }
    }

    private var general: some View {
        SettingsGroup(title: "Appearance") {
            SettingRow(title: "Theme", detail: "Follow the system, or always use light or dark.") {
                Picker("Theme", selection: $model.appearance) {
                    Text("System").tag(AppModel.Appearance.system)
                    Text("Light").tag(AppModel.Appearance.light)
                    Text("Dark").tag(AppModel.Appearance.dark)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingRow(title: "Text size", detail: "Scales every text in the window. Also ⌘+ and ⌘−.", last: true) {
                Picker("Text size", selection: $model.textScale) {
                    ForEach(Typography.scales, id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private var transcription: some View {
        SettingsGroup(title: "Engine") {
            SettingRow(title: "Where audio is transcribed",
                       detail: "On this Mac, audio never leaves it. A Scriberr server you run yourself receives the audio.",
                       last: model.engineChoice != "scriberr") {
                Picker("Engine", selection: $model.engineChoice) {
                    Text("On this Mac").tag("native")
                    Text("My Scriberr server").tag("scriberr")
                }
                .labelsHidden().fixedSize()
            }
            if model.engineChoice == "scriberr" {
                SettingRow(title: "Server", detail: "The API key is saved in the Keychain.", last: true) {
                    VStack(alignment: .trailing) {
                        TextField("Server URL", text: $model.scriberrURL).frame(width: 260)
                        SecureField("API key", text: $model.scriberrKey).frame(width: 260)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 14) {
            HStack {
                Label("On battery, transcription pauses below 20 % and in Low Power Mode, and resumes from saved checkpoints.", systemImage: "battery.75percent")
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
                Spacer()
                Button("Save Engine", action: model.saveEngine).buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isPowerPaused && !model.jobs.contains(where: { $0.state == .running }) {
                Label("Paused: battery below 20 % or Low Power Mode. Jobs resume when the Mac is plugged in.", systemImage: "battery.50percent")
                    .font(type.callout).foregroundStyle(Palette.inkMuted)
            }
            SettingsGroup(title: "Transcriptions") {
                if model.jobs.isEmpty {
                    Text("Nothing is being transcribed. Paste a podcast link or open an audio file.")
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

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Models on this Mac") {
                ModelRow(model: model, title: "Transcription and speakers", detail: "Parakeet, Whisper for Catalan and other languages, voice activity and speaker detection.",
                         kind: "native", folder: "parakeet")
                ModelRow(model: model, title: "Ask, summaries and chapters", detail: "A 4-billion-parameter language model, about 2.3 GB. Uses about 3.6 GB of memory while answering.",
                         kind: "language", folder: "language")
                ModelRow(model: model, title: "Search by meaning", detail: "Finds passages that say the same thing in other words or languages.",
                         kind: "embeddings", folder: "embeddings", last: true)
            }
            HStack {
                Text(model.modelStatus).font(type.callout).foregroundStyle(Palette.inkMuted).textSelection(.enabled)
                Spacer()
                Button(model.isIndexing ? "Indexing…" : "Rebuild Search Index", action: model.indexLibrary)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isIndexing)
            }
        }
    }

    private var shows: some View {
        SettingsGroup(title: "Followed podcasts") {
            SettingRow(title: "Check podcasts in the background",
                       detail: "Checks hourly, also while wavepod is closed. New episodes are transcribed only for podcasts where you turn it on.",
                       last: true) {
                Toggle("Check podcasts in the background", isOn: Binding(get: { model.backgroundChecks }, set: model.setBackgroundChecks))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio, transcripts and answers stay on this Mac unless you choose your own Scriberr server. These are the requests wavepod made: model downloads, feeds and link lookups.")
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
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.episode.title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer()
                Text(job.state.rawValue.capitalized).font(type.callout).foregroundStyle(Palette.inkMuted)
            }
            if job.state == .running || job.state == .queued || job.state == .paused {
                ProgressView(value: job.fraction).tint(Palette.accent)
            }
            Text(job.batteryPaused ? "Paused to save battery. Resumes when the Mac is plugged in." : job.stage)
                .font(type.callout).foregroundStyle(Palette.inkMuted)
            if let error = job.error {
                Text(error).font(type.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if job.state == .running || job.state == .queued {
                    Button("Pause") { model.manageJob(job, action: "pause") }.buttonStyle(SecondaryButtonStyle())
                    Button("Cancel") { model.manageJob(job, action: "cancel") }.buttonStyle(SecondaryButtonStyle())
                } else if job.state != .completed {
                    Button("Resume") { model.manageJob(job, action: "resume") }.buttonStyle(SecondaryButtonStyle())
                } else if let record = model.savedEpisodes.first(where: { $0.id == JobQueue.episodeID(job.episode) }) {
                    Button("Open Transcript") { model.showSettings = false; model.open(record) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Divider().overlay(Palette.rule).padding(.horizontal, 18) }
        }
    }
}
