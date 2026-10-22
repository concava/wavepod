import SwiftUI
import UI

@main
struct WavepodApp: App {
    /// `-WavepodSampleData YES` opens the built-in sample episode instead of the library, for demos and screenshots.
    @State private var model: AppModel = {
        let sample = UserDefaults.standard.bool(forKey: "WavepodSampleData")
        let model = AppModel(persistent: !sample)
        if sample { model.section = .library }
        return model
    }()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Wavepod", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1080, minHeight: 640)
                .onOpenURL { url in
                    if url.isFileURL { model.importFile(url) }
                    else { model.commandText = url.absoluteString; model.submitCommand() }
                }
        }
        .defaultSize(width: 1440, height: 880)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            WavepodCommands(model: model)
            UpdateCommands(updater: updater)
        }
    }
}
