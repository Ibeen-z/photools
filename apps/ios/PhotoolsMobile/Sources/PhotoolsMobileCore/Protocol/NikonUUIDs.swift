import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// 尼康 SnapBridge BLE 协议中使用的服务和特征 UUID
public enum NikonUUIDs {
    public static let serviceString        = "0000de00-3dd4-4255-8d62-6dc7b9bd5561"
    public static let pairString           = "00002000-3dd4-4255-8d62-6dc7b9bd5561"
    public static let deviceNameString     = "00002002-3dd4-4255-8d62-6dc7b9bd5561"
    public static let timeString           = "00002006-3dd4-4255-8d62-6dc7b9bd5561"
    public static let geoString            = "00002007-3dd4-4255-8d62-6dc7b9bd5561"

    public static let not1String           = "00002008-3dd4-4255-8d62-6dc7b9bd5561"
    public static let serialNumberString   = "0000200b-3dd4-4255-8d62-6dc7b9bd5561"
    public static let statusControlString  = "00002020-3dd4-4255-8d62-6dc7b9bd5561"
    public static let controlPointString   = "00002021-3dd4-4255-8d62-6dc7b9bd5561"

    /// 尼康公司 Manufacturer Data 识别前缀: 0x0399 (小端序为 [0x99, 0x03])
    public static let nikonCompanyID: UInt16 = 0x0399

    #if canImport(CoreBluetooth)
    public static let service        = CBUUID(string: serviceString)
    public static let pair           = CBUUID(string: pairString)
    public static let not1           = CBUUID(string: not1String)
    public static let deviceName     = CBUUID(string: deviceNameString)
    public static let time           = CBUUID(string: timeString)
    public static let geo            = CBUUID(string: geoString)
    public static let serialNumber   = CBUUID(string: serialNumberString)
    public static let statusControl  = CBUUID(string: statusControlString)
    public static let controlPoint   = CBUUID(string: controlPointString)
    #endif
}
