import Combine
import Sparkle
import SwiftUI

/// Sparkle updates (docs/decisions/0005). A build without `SPARKLE_PUBLIC_KEY` (every local and ad-hoc build) has
/// an empty `SUPublicEDKey`, so the updater never starts and "Check for Updates…" stays disabled.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

struct UpdateCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheck)
        }
    }
}
