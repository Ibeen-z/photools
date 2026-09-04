import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

/// 尼康 SnapBridge 41 字节地理位置注入报文 (WGS-84)
public struct GeoPayload: Equatable, Sendable {
    public static let size = 41
    public static let headerConstant: UInt16 = 0x007F

    public let latDirection: UInt8      // 'N' (0x4E) 或 'S' (0x53)
    public let latDegrees: UInt8        // 0-90
    public let latMinutes: UInt8        // 0-59
    public let latSubmin1: UInt8        // 0-99 (分的小数前两位)
    public let latSubmin2: UInt8        // 0-99 (分的小数后两位)

    public let lonDirection: UInt8      // 'E' (0x45) 或 'W' (0x57)
    public let lonDegrees: UInt8        // 0-180
    public let lonMinutes: UInt8        // 0-59
    public let lonSubmin1: UInt8        // 0-99
    public let lonSubmin2: UInt8        // 0-99

    public let satellites: UInt8        // 卫星颗数
    public let altDirection: UInt8      // 'P' (0x50: 正) 或 'M' (0x4D: 负)
    public let altitude: UInt16         // 海拔绝对值 (米，小端序)

    public let year: UInt16             // GPS UTC 年份 (小端序)
    public let month: UInt8             // 1-12
    public let day: UInt8               // 1-31
    public let hour: UInt8              // 0-23
    public let minute: UInt8            // 0-59
    public let second: UInt8            // 0-59
    public let subseconds: UInt8        // 0-99 厘秒

    public let isValid: Bool            // 0x01: 有效 fix; 0x00: 无效

    public init(
        latDirection: UInt8,
        latDegrees: UInt8,
        latMinutes: UInt8,
        latSubmin1: UInt8,
        latSubmin2: UInt8,
        lonDirection: UInt8,
        lonDegrees: UInt8,
        lonMinutes: UInt8,
        lonSubmin1: UInt8,
        lonSubmin2: UInt8,
        satellites: UInt8,
        altDirection: UInt8,
        altitude: UInt16,
        year: UInt16,
        month: UInt8,
        day: UInt8,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
        subseconds: UInt8 = 0,
        isValid: Bool = true
    ) {
        self.latDirection = latDirection
        self.latDegrees = latDegrees
        self.latMinutes = latMinutes
        self.latSubmin1 = latSubmin1
        self.latSubmin2 = latSubmin2
        self.lonDirection = lonDirection
        self.lonDegrees = lonDegrees
        self.lonMinutes = lonMinutes
        self.lonSubmin1 = lonSubmin1
        self.lonSubmin2 = lonSubmin2
        self.satellites = satellites
        self.altDirection = altDirection
        self.altitude = altitude
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.subseconds = subseconds
        self.isValid = isValid
    }

    /// 静态常驻 UTC 日历单例 (避免每次报文生成重复实例化 ICU 对象)
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static let wgs84Bytes: [UInt8] = [0x57, 0x47, 0x53, 0x2D, 0x38, 0x34] // "WGS-84"
    private static let paddingBytes = [UInt8](repeating: 0x00, count: 10)

    /// 从经纬度数值、海拔、UTC 时间直接构造
    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        satellites: UInt8 = 8,
        date: Date = Date(),
        isValid: Bool = true
    ) {
        // 纬度拆解
        self.latDirection = latitude >= 0 ? 0x4E : 0x53 // 'N' : 'S'
        let absLat = abs(latitude)
        let latDeg = UInt8(min(floor(absLat), 90.0))
        let latMinTotal = (absLat - Double(latDeg)) * 60.0
        let latMin = UInt8(min(floor(latMinTotal), 59.0))
        let latSubminTotal = (latMinTotal - Double(latMin)) * 10000.0
        let latSubClamped = max(0.0, min(latSubminTotal, 9999.0))
        self.latDegrees = latDeg
        self.latMinutes = latMin
        self.latSubmin1 = UInt8(floor(latSubClamped / 100.0))
        self.latSubmin2 = UInt8(Int(latSubClamped) % 100)

        // 经度拆解
        self.lonDirection = longitude >= 0 ? 0x45 : 0x57 // 'E' : 'W'
        let absLon = abs(longitude)
        let lonDeg = UInt8(min(floor(absLon), 180.0))
        let lonMinTotal = (absLon - Double(lonDeg)) * 60.0
        let lonMin = UInt8(min(floor(lonMinTotal), 59.0))
        let lonSubminTotal = (lonMinTotal - Double(lonMin)) * 10000.0
        let lonSubClamped = max(0.0, min(lonSubminTotal, 9999.0))
        self.lonDegrees = lonDeg
        self.lonMinutes = lonMin
        self.lonSubmin1 = UInt8(floor(lonSubClamped / 100.0))
        self.lonSubmin2 = UInt8(Int(lonSubClamped) % 100)

        self.satellites = satellites
        self.altDirection = altitude >= 0 ? 0x50 : 0x4D // 'P' : 'M'
        self.altitude = UInt16(min(max(abs(altitude), 0.0), 65535.0))

        let comps = Self.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.year = UInt16(comps.year ?? 2026)
        self.month = UInt8(comps.month ?? 1)
        self.day = UInt8(comps.day ?? 1)
        self.hour = UInt8(comps.hour ?? 0)
        self.minute = UInt8(comps.minute ?? 0)
        self.second = UInt8(comps.second ?? 0)
        self.subseconds = 0
        self.isValid = isValid
    }

    #if canImport(CoreLocation)
    public init(location: CLLocation, satellites: UInt8? = nil) {
        let valid = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 65
        let satCount = satellites ?? (location.horizontalAccuracy < 10 ? 8 : 4)
        // 关键时序与有效性保护：若 CLLocation 的 timestamp 与当前时刻相差超过 15 秒 (例如来自系统旧缓存)，
        // 报文内必须强制采用当前时刻 Date()，彻底杜绝因陈旧时间戳引发尼康相机 ATT 0x80 拒写！
        let safeDate = abs(Date().timeIntervalSince(location.timestamp)) > 15.0 ? Date() : location.timestamp
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            satellites: satCount,
            date: safeDate,
            isValid: valid
        )
    }
    #endif

    /// 生成丢弃已存位置的无效标记报文 (仅允许下发一次)
    public static func makeInvalidPayload(date: Date = Date()) -> GeoPayload {
        GeoPayload(latitude: 0, longitude: 0, altitude: 0, satellites: 0, date: date, isValid: false)
    }

    /// 编码为 41 字节二进制数据
    public func encode() -> Data {
        var data = Data(capacity: Self.size)

        var header = Self.headerConstant.littleEndian
        data.append(Data(bytes: &header, count: 2))

        data.append(latDirection)
        data.append(latDegrees)
        data.append(latMinutes)
        data.append(latSubmin1)
        data.append(latSubmin2)

        data.append(lonDirection)
        data.append(lonDegrees)
        data.append(lonMinutes)
        data.append(lonSubmin1)
        data.append(lonSubmin2)

        data.append(satellites)
        data.append(altDirection)

        var altLE = altitude.littleEndian
        data.append(Data(bytes: &altLE, count: 2))

        var yLE = year.littleEndian
        data.append(Data(bytes: &yLE, count: 2))

        data.append(month)
        data.append(day)
        data.append(hour)
        data.append(minute)
        data.append(second)
        data.append(subseconds)

        data.append(isValid ? 0x01 : 0x00)

        // 6 字节 "WGS-84"
        data.append(contentsOf: Self.wgs84Bytes)

        // 10 字节 0x00 padding
        data.append(contentsOf: Self.paddingBytes)

        return data
    }
}
