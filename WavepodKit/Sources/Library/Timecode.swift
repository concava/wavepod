import Foundation

public enum Timecode {
    /// `"4:07"`, `"38:12"`, `"1:02:03"`. Negative values are clamped to zero.
    public static func format(_ seconds: Seconds) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Spoken form for VoiceOver: "1 hour 2 minutes 3 seconds".
    public static func spoken(_ seconds: Seconds) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? format(seconds)
    }
}
