import Library
import Player
import SwiftUI

/// The single window: collapsible sidebar, top bar with the command field, three resizable panes and the player bar.
public struct RootView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: AppModel.FocusTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            VStack(spacing: 0) {
                if let notice = model.notice {
                    NoticeBar(text: notice)
                }
                Group {
                    switch model.section {
                    case .home: HomeView(model: model)
                    case .library: Workspace(model: model, focus: $focus)
                    default: LibrarySection(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.section == .library || model.player.duration > 0 {
                    PlayerBar(model: model, player: model.player)
                }
            }
            .elevated(cornerRadius: 14)
            .padding([.trailing, .bottom], 8)
        }
        .background(Palette.paper)
        .animation(motion(.snappy(duration: 0.2), reduced: reduceMotion), value: model.sidebarCollapsed)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.sidebarCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(model.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(model.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            }
            ToolbarItem(placement: .principal) {
                CommandField(model: model, focus: $focus)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isPersistent && model.section == .library && !model.transcript.segments.isEmpty {
                    Menu("Generate", systemImage: "sparkles") {
                        Button("Summary") { model.generateNotes() }
                        Button("Chapters") { model.generateNotes(chaptersOnly: true) }
                    }.disabled(model.isGenerating)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                AppearanceButton(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { model.openSettings() }
                    .help("Settings (⌘,)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for file in files { model.importFile(file) }
            return !files.isEmpty
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showTranslation) {
            VStack(alignment: .leading) {
                HStack { Text("Translation · \(model.askLanguage.title)").font(.headline); Spacer(); Button("Done") { model.showTranslation = false } }
                ScrollView { Text(model.translationText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding().frame(width: 640, height: 560)
        }
        .environment(\.typography, Typography(scale: model.textScale))
        .preferredColorScheme(model.appearance == .system ? nil : (model.appearance == .dark ? .dark : .light))
        .tint(Palette.accent)
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            if request == .ask { model.section = .library }
            focus = request
            model.focusRequest = nil
        }
    }
}

struct Workspace: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding

    var body: some View {
        HSplitView {
            EpisodePane(model: model)
                .padding(6)
                .frame(minWidth: 230, idealWidth: 290, maxWidth: 380)
            CenterPane(model: model, focus: focus)
                .padding(6)
                .frame(minWidth: 380, idealWidth: 560)
            AskPane(model: model, focus: focus)
                .padding(6)
                .frame(minWidth: 250, idealWidth: 310, maxWidth: 440)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

struct CommandField: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.typography) private var type

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
            TextField("Search or paste a podcast, Spotify or YouTube link", text: $model.commandText)
                .textFieldStyle(.plain)
                .font(type.body)
                .focused(focus, equals: .command)
                .onSubmit { model.submitCommand() }
                .accessibilityLabel("Search or open a link")
            Text("⌘K")
                .font(type.caption)
                .foregroundStyle(Palette.inkMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(width: 440, height: 28)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.rule))
    }
}

struct AppearanceButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.cycleAppearance()
        } label: {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Appearance: \(model.appearance.rawValue.capitalized)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(model.appearance.rawValue.capitalized)
    }

    var symbol: String {
        switch model.appearance {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

struct NoticeBar: View {
    let text: String
    @Environment(\.typography) private var type

    var body: some View {
        Text(text)
            .font(type.callout)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Palette.accentSoft)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
