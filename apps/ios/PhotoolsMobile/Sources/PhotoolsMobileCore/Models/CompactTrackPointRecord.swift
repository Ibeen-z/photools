import Foundation

/// 32 字节紧凑定长轨迹点物理记录 (面向超长巡航高效 WAL 追加写与 0 拷贝持久化)
public struct CompactTrackPointRecord: Sendable, Equatable {
    public static let recordSize: Int = 32

    public let timestampMs: Int64      // 8B: 毫秒级 Unix 时间戳
    public let latE7: Int32            // 4B: 纬度 * 1e7 (-90.0 ~ +90.0)
    public let lonE7: Int32            // 4B: 经度 * 1e7 (-180.0 ~ +180.0)
    public let elevationCm: Int32      // 4B: 海拔高度以厘米存储 (无海拔时为 Int32.min)
    public let accuracyCm: UInt16      // 2B: 水平精度以厘米存储 (0 ~ 65535 cm)
    public let speedCms: UInt16        // 2B: 速度以 cm/s 存储 (无速度时为 UInt16.max)
    public let courseDeg10: UInt16     // 2B: 航向角度 * 10 (无航向时为 UInt16.max)
    public let flags: UInt16           // 2B: 状态标志位
    public let reserved: UInt32        // 4B: 预留对齐填充字段 (凑齐 32 字节)

    public init(point: GPXRecordedPoint) {
        self.timestampMs = Int64(point.timestamp.timeIntervalSince1970 * 1000.0)
        self.latE7 = Int32(clamping: Int64(round(point.latitude * 10_000_000.0)))
        self.lonE7 = Int32(clamping: Int64(round(point.longitude * 10_000_000.0)))

        if let ele = point.elevation {
            self.elevationCm = Int32(clamping: Int64(round(ele * 100.0)))
        } else {
            self.elevationCm = Int32.min
        }

        let accCm = Int(round(max(0, point.horizontalAccuracy) * 100.0))
        self.accuracyCm = UInt16(clamping: accCm)

        if let spd = point.speed, spd >= 0 {
            self.speedCms = UInt16(clamping: Int(round(spd * 100.0)))
        } else {
            self.speedCms = UInt16.max
        }

        if let crs = point.course, crs >= 0 {
            self.courseDeg10 = UInt16(clamping: Int(round(crs * 10.0)))
        } else {
            self.courseDeg10 = UInt16.max
        }

        var f: UInt16 = 0
        if point.elevation != nil { f |= 0x01 }
        if point.speed != nil { f |= 0x02 }
        if point.course != nil { f |= 0x04 }
        self.flags = f
        self.reserved = 0
    }

    public init(
        timestampMs: Int64,
        latE7: Int32,
        lonE7: Int32,
        elevationCm: Int32,
        accuracyCm: UInt16,
        speedCms: UInt16,
        courseDeg10: UInt16,
        flags: UInt16,
        reserved: UInt32 = 0
    ) {
        self.timestampMs = timestampMs
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.elevationCm = elevationCm
        self.accuracyCm = accuracyCm
        self.speedCms = speedCms
        self.courseDeg10 = courseDeg10
        self.flags = flags
        self.reserved = reserved
    }

    /// 转换为高精业务点位模型
    public func toRecordedPoint() -> GPXRecordedPoint {
        let lat = Double(latE7) / 10_000_000.0
        let lon = Double(lonE7) / 10_000_000.0
        let ele: Double? = (elevationCm != Int32.min && (flags & 0x01 != 0)) ? (Double(elevationCm) / 100.0) : nil
        let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        let accuracy = Double(accuracyCm) / 100.0
        let speed: Double? = (speedCms != UInt16.max && (flags & 0x02 != 0)) ? (Double(speedCms) / 100.0) : nil
        let course: Double? = (courseDeg10 != UInt16.max && (flags & 0x04 != 0)) ? (Double(courseDeg10) / 10.0) : nil

        return GPXRecordedPoint(
            latitude: lat,
            longitude: lon,
            elevation: ele,
            timestamp: timestamp,
            horizontalAccuracy: accuracy,
            speed: speed,
            course: course
        )
    }

    /// 序列化为 32 字节二进制 Data
    public func serialize() -> Data {
        var data = Data(capacity: CompactTrackPointRecord.recordSize)
        var tMs = timestampMs.littleEndian
        var lat = latE7.littleEndian
        var lon = lonE7.littleEndian
        var ele = elevationCm.littleEndian
        var acc = accuracyCm.littleEndian
        var spd = speedCms.littleEndian
        var crs = courseDeg10.littleEndian
        var flg = flags.littleEndian
        var res = reserved.littleEndian

        withUnsafeBytes(of: &tMs) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ele) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &acc) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &spd) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &crs) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &flg) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &res) { data.append(contentsOf: $0) }

        return data
    }

    /// 从 32 字节切片反序列化单个记录
    public static func deserialize(from data: Data, offset: Int = 0) -> CompactTrackPointRecord? {
        guard offset + recordSize <= data.count else { return nil }

        return data.withUnsafeBytes { rawBuffer -> CompactTrackPointRecord? in
            guard let base = rawBuffer.baseAddress?.advanced(by: offset) else { return nil }
            let tMs = base.load(fromByteOffset: 0, as: Int64.self).littleEndian
            let lat = base.load(fromByteOffset: 8, as: Int32.self).littleEndian
            let lon = base.load(fromByteOffset: 12, as: Int32.self).littleEndian
            let ele = base.load(fromByteOffset: 16, as: Int32.self).littleEndian
            let acc = base.load(fromByteOffset: 20, as: UInt16.self).littleEndian
            let spd = base.load(fromByteOffset: 22, as: UInt16.self).littleEndian
            let crs = base.load(fromByteOffset: 24, as: UInt16.self).littleEndian
            let flg = base.load(fromByteOffset: 26, as: UInt16.self).littleEndian
            let res = base.load(fromByteOffset: 28, as: UInt32.self).littleEndian

            return CompactTrackPointRecord(
                timestampMs: tMs,
                latE7: lat,
                lonE7: lon,
                elevationCm: ele,
                accuracyCm: acc,
                speedCms: spd,
                courseDeg10: crs,
                flags: flg,
                reserved: res
            )
        }
    }

    /// 批量反序列化全部二进制数据为点位数组
    public static func deserializeAll(from data: Data) -> [GPXRecordedPoint] {
        let totalCount = data.count / recordSize
        guard totalCount > 0 else { return [] }

        var points: [GPXRecordedPoint] = []
        points.reserveCapacity(totalCount)

        for i in 0..<totalCount {
            if let record = deserialize(from: data, offset: i * recordSize) {
                points.append(record.toRecordedPoint())
            }
        }
        return points
    }
}
