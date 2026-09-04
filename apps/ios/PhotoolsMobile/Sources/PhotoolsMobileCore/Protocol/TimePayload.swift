import Foundation

/// 尼康 SnapBridge 10 字节时间与时区同步报文
/// Offset 0 (2B): year (小端序)
/// Offset 2 (1B): month (1-12)
/// Offset 3 (1B): day (1-31)
/// Offset 4 (1B): hour (0-23 UTC)
/// Offset 5 (1B): minute (0-59)
/// Offset 6 (1B): second (0-59)
/// Offset 7 (1B): dst offset (0: 关闭, 1: 启用)
/// Offset 8 (1B): tz offset hours (有符号整数, 如 +8, -5)
/// Offset 9 (1B): tz offset minutes (分钟偏移, 如 0, 30, 45)
public struct TimePayload: Equatable, Sendable {
    public static let size = 10

    public let year: UInt16
    public let month: UInt8
    public let day: UInt8
    public let hour: UInt8
    public let minute: UInt8
    public let second: UInt8
    public let dstOffset: UInt8
    public let tzOffsetHours: Int8
    public let tzOffsetMinutes: Int8

    public init(
        year: UInt16,
        month: UInt8,
        day: UInt8,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
        dstOffset: UInt8,
        tzOffsetHours: Int8,
        tzOffsetMinutes: Int8
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.dstOffset = dstOffset
        self.tzOffsetHours = tzOffsetHours
        self.tzOffsetMinutes = tzOffsetMinutes
    }

    /// 静态常驻 UTC 日历单例 (避免重复实例化 ICU 对象)
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 根据指定时刻和时区自动构建 UTC 时间报文
    public init(date: Date = Date(), timeZone: TimeZone = .current) {
        let comps = Self.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.year = UInt16(comps.year ?? 2026)
        self.month = UInt8(comps.month ?? 1)
        self.day = UInt8(comps.day ?? 1)
        self.hour = UInt8(comps.hour ?? 0)
        self.minute = UInt8(comps.minute ?? 0)
        self.second = UInt8(comps.second ?? 0)

        let totalOffsetSeconds = timeZone.secondsFromGMT(for: date)
        let hours = Int8(totalOffsetSeconds / 3600)
        let minutes = Int8((abs(totalOffsetSeconds) % 3600) / 60)

        self.dstOffset = timeZone.isDaylightSavingTime(for: date) ? 1 : 0
        self.tzOffsetHours = hours
        self.tzOffsetMinutes = minutes
    }

    /// 从 10 字节数据解析
    public init?(data: Data) {
        guard data.count >= Self.size else { return nil }
        var y: UInt16 = 0
        y = UInt16(data[0]) | (UInt16(data[1]) << 8)
        self.year = y
        self.month = data[2]
        self.day = data[3]
        self.hour = data[4]
        self.minute = data[5]
        self.second = data[6]
        self.dstOffset = data[7]
        self.tzOffsetHours = Int8(bitPattern: data[8])
        self.tzOffsetMinutes = Int8(bitPattern: data[9])
    }

    /// 编码为 10 字节二进制数据
    public func encode() -> Data {
        var data = Data(capacity: Self.size)
        var yLE = year.littleEndian
        data.append(Data(bytes: &yLE, count: 2))
        data.append(month)
        data.append(day)
        data.append(hour)
        data.append(minute)
        data.append(second)
        data.append(dstOffset)
        data.append(UInt8(bitPattern: tzOffsetHours))
        data.append(UInt8(bitPattern: tzOffsetMinutes))
        return data
    }
}
