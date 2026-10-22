import Foundation

/// Where Wavepod keeps small settings: `UserDefaults` in the app and the feed checker, a dictionary in tests.
/// Both processes read the same defaults, so a choice made in Settings applies to background work too.
public protocol SettingsStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: SettingsStore {}

/// Settings kept in memory, for tests and previews.
public final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    public func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value as? String } }
}

/// The folder that holds everything Wavepod keeps: the library, models, artwork, audio, logs and sign-ins.
public enum WavepodFolder {
    public static var `default`: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wavepod")
    }
}
