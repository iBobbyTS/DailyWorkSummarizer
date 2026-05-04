import Foundation
import IOKit.ps

nonisolated struct DevicePowerState: Equatable, Sendable {
    let hasInternalBattery: Bool
    let isConnectedToCharger: Bool

    static func current() -> DevicePowerState {
        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return DevicePowerState(hasInternalBattery: false, isConnectedToCharger: false)
        }

        let powerSourceType = IOPSGetProvidingPowerSourceType(powerInfo)?.takeUnretainedValue() as String?
        let isConnectedToCharger = powerSourceType == kIOPMACPowerKey

        let powerSources = (IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let hasInternalBattery = powerSources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(powerInfo, source)?
                .takeUnretainedValue() as? [String: Any] else {
                return false
            }

            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }

        return DevicePowerState(
            hasInternalBattery: hasInternalBattery,
            isConnectedToCharger: isConnectedToCharger
        )
    }
}
