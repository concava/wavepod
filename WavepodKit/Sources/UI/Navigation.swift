import AppKit
import Resolver

/// One screen the person can go back to: a section, with the episode or podcast page it showed.
struct Place: Equatable {
    var section: AppModel.Section
    var episodeID: String? = nil
    var show: ResolvedShow? = nil

    static func == (a: Place, b: Place) -> Bool {
        a.section == b.section && a.episodeID == b.episodeID && a.show?.feedURL == b.show?.feedURL
    }
}

/// Back and Forward through the screens, like a browser. Each change to the section, the open episode or the
/// podcast page is recorded once the run loop settles, so opening an episode (which sets both) is one step.
@MainActor
final class NavigationHistory {
    var back: [Place] = []
    var forward: [Place] = []
    var current: Place
    var commitScheduled = false
    static let limit = 50

    init(_ start: Place) { current = start }
}

extension AppModel {
    var place: Place {
        Place(section: section,
              episodeID: section == .library && !episode.id.isEmpty ? episode.id : nil,
              show: section == .shows ? resolvedShow : nil)
    }

    public var canGoBack: Bool { _ = historyVersion; return !history.back.isEmpty }
    public var canGoForward: Bool { _ = historyVersion; return !history.forward.isEmpty }

    /// Called when anything that makes up the screen changes.
    func placeDidChange() {
        guard !history.commitScheduled else { return }
        history.commitScheduled = true
        Task { @MainActor in
            history.commitScheduled = false
            let now = place
            guard now != history.current else { return }
            history.back.append(history.current)
            if history.back.count > NavigationHistory.limit { history.back.removeFirst() }
            history.forward = []
            history.current = now
            historyVersion += 1
        }
    }

    public func goBack() {
        guard let target = history.back.popLast() else { return }
        history.forward.append(history.current)
        go(to: target)
    }

    public func goForward() {
        guard let target = history.forward.popLast() else { return }
        history.back.append(history.current)
        go(to: target)
    }

    private func go(to target: Place) {
        // Recorded first, so the change below is not recorded as a new step.
        history.current = target
        if let id = target.episodeID, id != episode.id {
            guard let record = try? services?.store.episode(id) else {
                // The episode was deleted. Skip it.
                history.current = place
                historyVersion += 1
                return
            }
            install(record)
        }
        if target.section == .shows { resolvedShow = target.show }
        section = target.section
        history.current = place
        historyVersion += 1
    }
}

/// Two-finger swipes, three-finger swipes and the side buttons of a mouse go Back and Forward.
@MainActor
final class NavigationGestures {
    private var monitor: Any?
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var tracking = false
    /// How far the fingers travel, in points, before a swipe counts.
    static let threshold: CGFloat = 90

    func install(back: @escaping @MainActor () -> Void, forward: @escaping @MainActor () -> Void,
                 isEnabled: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseUp]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, isEnabled() else { return false }
                switch event.type {
                case .otherMouseUp:
                    if event.buttonNumber == 3 { back(); return true }
                    if event.buttonNumber == 4 { forward(); return true }
                case .swipe:
                    // deltaX is +1 for a swipe to the right on a three-finger setup.
                    if event.deltaX > 0 { back(); return true }
                    if event.deltaX < 0 { forward(); return true }
                case .scrollWheel:
                    self.track(event, back: back, forward: forward)
                default: break
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func track(_ event: NSEvent, back: () -> Void, forward: () -> Void) {
        // Only trackpad gestures, and only when "Swipe between pages" is on in System Settings.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }
        if event.phase.contains(.began) {
            tracking = true; swipeX = 0; swipeY = 0
        }
        guard tracking else { return }
        // In the fingers' direction, whatever the scroll direction setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeX += event.scrollingDeltaX * sign
        swipeY += abs(event.scrollingDeltaY)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            tracking = false
            guard !event.phase.contains(.cancelled), abs(swipeX) > Self.threshold, abs(swipeX) > swipeY * 2 else { return }
            // Fingers to the right go back, as in Safari and Finder.
            if swipeX > 0 { back() } else { forward() }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
