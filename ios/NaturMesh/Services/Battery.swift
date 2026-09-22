import UIKit

enum Battery {
    /// 0...100, or 255 when unknown.
    static func level() -> UInt8 {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        guard l >= 0 else { return 255 }
        return UInt8((l * 100).rounded())
    }
}
