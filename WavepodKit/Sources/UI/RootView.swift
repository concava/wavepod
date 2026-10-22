import AppKit
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
            VStack(spacing: 8) {
                Group {
                    switch model.section {
                    // The episode view is its own row of cards, so it sits straight on the paper.
                    case .library: Workspace(model: model, focus: $focus)
                    case .home: HomeView(model: model).elevated(cornerRadius: 14)
                    default: LibrarySection(model: model).elevated(cornerRadius: 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.section == .library || model.player.duration > 0 {
                    PlayerBar(player: model.player)
                        .elevated(cornerRadius: 14)
                }
            }
            .padding([.trailing, .bottom], 8)
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    NoticeBar(text: notice).padding(.top, 10)
                }
            }
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
                CommandField(model: model)
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
        .overlay {
            // Settings floats over a dimmed window instead of a sheet, so a click outside it closes it.
            if model.showSettings {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { model.showSettings = false }
                        .accessibilityHidden(true)
                    SettingsView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                        .accessibilityAddTraits(.isModal)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.98).combined(with: .opacity))
                }
                .transition(.opacity)
            }
            if model.showOnboarding {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea().accessibilityHidden(true)
                    OnboardingView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                        .accessibilityAddTraits(.isModal)
                }
                .transition(.opacity)
            }
        }
        .animation(model.showSettings ? Motion.enter : Motion.exit, value: model.showSettings)
        .animation(motion(.easeOut(duration: 0.15), reduced: reduceMotion), value: model.showOnboarding)
        .sheet(isPresented: $model.showTranslation) {
            VStack(alignment: .leading) {
                HStack { Text("Translation · \(model.translationLanguage.title)").font(.headline); Spacer(); Button("Done") { model.showTranslation = false } }
                ScrollView { Text(model.translationText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding().frame(width: 640, height: 560)
        }
        .environment(\.typography, Typography(scale: model.textScale))
        .environment(\.artworkCache, model.services?.artwork)
        .preferredColorScheme(model.appearance == .system ? nil : (model.appearance == .dark ? .dark : .light))
        .tint(Palette.accent)
        .onChange(of: model.focusRequest) { _, request in
            // The command field lives in the toolbar, a focus scope of its own, and takes ⌘K itself.
            guard let request, request != .command else { return }
            if request == .ask { model.section = .library }
            focus = request
            model.focusRequest = nil
        }
    }
}

struct CommandField: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool
    @Environment(\.typography) private var type

    var body: some View {
        let field = HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
            TextField(Self.placeholder, text: $model.commandText)
                .textFieldStyle(.plain)
                .font(type.body)
                .focused($isFocused)
                .onSubmit { model.submitCommand() }
                .onExitCommand { model.commandText = ""; isFocused = false }
                .accessibilityLabel("Search or open a link")
            if model.commandText.isEmpty {
                Text("⌘K")
                    .font(type.caption.weight(.medium))
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Button {
                    model.commandText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.inkMuted)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: 460, height: 30)

        Group {
        if #available(macOS 26, *) {
            // The toolbar already draws a capsule around principal items; a second shape inside it would double the edge.
            field
        } else {
            field
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isFocused ? Palette.accent : Palette.rule))
        }
        }
        .onChange(of: model.focusRequest) { _, request in
            guard request == .command else { return }
            isFocused = true
            model.focusRequest = nil
            // SwiftUI focus does not always reach a toolbar item, so also hand the field to AppKit directly.
            DispatchQueue.main.async { Self.focusInToolbar(placeholder: Self.placeholder) }
        }
    }

    static let placeholder = "Search or paste a podcast, Spotify or YouTube link"

    static func focusInToolbar(placeholder: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let frame = window.contentView?.superview,
              let field = find(in: frame, placeholder: placeholder) else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    private static func find(in view: NSView, placeholder: String) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder { return field }
        for subview in view.subviews {
            if let found = find(in: subview, placeholder: placeholder) { return found }
        }
        return nil
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
            .font(type.label)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Palette.surface)
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            )
            .accessibilityAddTraits(.updatesFrequently)
    }
}
