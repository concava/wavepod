import Foundation
import IOKit.ps

/// When transcription waits for power. It runs on battery until the charge drops below 20 %, then waits until the
/// Mac is plugged in or charged back to 25 % (the gap keeps a job from flapping around one percentage point).
/// Low Power Mode always waits, because the user asked the Mac to save energy.
public enum PowerPolicy {
    public static let pauseBelow = 20
    public static let resumeFrom = 25

    public static func shouldPause(currentlyPaused: Bool) -> Bool {
        let battery = batteryState()
        return decide(onBattery: battery.onBattery, charge: battery.charge,
                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, currentlyPaused: currentlyPaused)
    }

    public static func decide(onBattery: Bool, charge: Int?, lowPowerMode: Bool, currentlyPaused: Bool) -> Bool {
        if lowPowerMode { return true }
        guard onBattery, let charge else { return false }
        return charge < (currentlyPaused ? resumeFrom : pauseBelow)
    }

    /// Whether the Mac runs on its battery, and the battery's charge in percent (nil without a battery).
    static func batteryState() -> (onBattery: Bool, charge: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (providing == kIOPSBatteryPowerValue, current * 100 / max)
        }
        return (providing == kIOPSBatteryPowerValue, nil)
    }
}
