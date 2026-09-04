import Foundation

/// 纳秒级零锁高效 UTC ISO 8601 格式化引擎 (避免 DateFormatter 互斥锁与日历计算开销)
public enum FastTimeFormatter {
    /// 格式化 UTC 时间为 yyyy-MM-ddTHH:mm:ssZ (例如 2026-10-15T02:22:21Z)
    @inline(__always)
    public static func formatUTCISO8601(date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        gmtime_r(&t, &tmVal)

        let year = Int(tmVal.tm_year) + 1900
        let mon = Int(tmVal.tm_mon) + 1
        let day = Int(tmVal.tm_mday)
        let hour = Int(tmVal.tm_hour)
        let min = Int(tmVal.tm_min)
        let sec = Int(tmVal.tm_sec)

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            year, mon, day, hour, min, sec
        )
    }

    /// 直接将 UTC ISO 8601 格式化写入 UTF-8 字节缓冲区 (零中间 String 对象申请)
    @inline(__always)
    public static func appendUTCISO8601(date: Date, to data: inout Data) {
        var t = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        gmtime_r(&t, &tmVal)

        let year = Int(tmVal.tm_year) + 1900
        let mon = Int(tmVal.tm_mon) + 1
        let day = Int(tmVal.tm_mday)
        let hour = Int(tmVal.tm_hour)
        let min = Int(tmVal.tm_min)
        let sec = Int(tmVal.tm_sec)

        // yyyy-MM-ddTHH:mm:ssZ 固定 20 字节
        var chars = [UInt8](repeating: 0, count: 20)
        chars[0] = UInt8(48 + (year / 1000) % 10)
        chars[1] = UInt8(48 + (year / 100) % 10)
        chars[2] = UInt8(48 + (year / 10) % 10)
        chars[3] = UInt8(48 + year % 10)
        chars[4] = 0x2D // '-'
        chars[5] = UInt8(48 + mon / 10)
        chars[6] = UInt8(48 + mon % 10)
        chars[7] = 0x2D // '-'
        chars[8] = UInt8(48 + day / 10)
        chars[9] = UInt8(48 + day % 10)
        chars[10] = 0x54 // 'T'
        chars[11] = UInt8(48 + hour / 10)
        chars[12] = UInt8(48 + hour % 10)
        chars[13] = 0x3A // ':'
        chars[14] = UInt8(48 + min / 10)
        chars[15] = UInt8(48 + min % 10)
        chars[16] = 0x3A // ':'
        chars[17] = UInt8(48 + sec / 10)
        chars[18] = UInt8(48 + sec % 10)
        chars[19] = 0x5A // 'Z'

        data.append(contentsOf: chars)
    }
}
