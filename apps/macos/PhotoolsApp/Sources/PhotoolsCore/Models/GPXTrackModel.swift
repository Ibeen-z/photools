import Foundation
import CoreLocation

/// GPX 轨迹单个点位模型
public struct GPXTrackPoint: Sendable, Identifiable {
    public var id: String { "\(latitude)_\(longitude)_\(elevation ?? 0)_\(time?.timeIntervalSince1970 ?? 0)" }
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?        // 海拔（米）
    public let time: Date?               // 记录时间戳
    public let heartRate: Int?           // 心率（bpm）
    public let distanceMeters: Double    // 距起点累计里程（米）

    public init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil,
        heartRate: Int? = nil,
        distanceMeters: Double = 0.0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
        self.heartRate = heartRate
        self.distanceMeters = distanceMeters
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// GPX 轨迹地理外接边界矩形
public struct GPXBoundingBox: Sendable {
    public let minLat: Double
    public let maxLat: Double
    public let minLng: Double
    public let maxLng: Double

    public init(minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
    }

    public var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2.0,
            longitude: (minLng + maxLng) / 2.0
        )
    }

    public var spanLat: Double {
        abs(maxLat - minLat)
    }

    public var spanLng: Double {
        abs(maxLng - minLng)
    }
}

/// GPX 离散兴趣点/打卡点模型 (Waypoints / POI)
public struct GPXWaypoint: Sendable, Identifiable {
    public var id: String { "\(latitude)_\(longitude)_\(elevation ?? 0)_\(name ?? "")" }
    public let name: String?
    public let comment: String?
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?        // 海拔（米）
    public let time: Date?               // 打卡时间戳

    public init(
        name: String? = nil,
        comment: String? = nil,
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil
    ) {
        self.name = name
        self.comment = comment
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// GPX 轨迹全景摘要与空间统计数据
public struct GPXTrackSummary: Sendable {
    public let name: String
    public let filePath: String
    public let rawPointCount: Int
    public let renderedPoints: [GPXTrackPoint]
    public let waypoints: [GPXWaypoint]
    public let totalDistanceMeters: Double
    public let minElevation: Double?
    public let maxElevation: Double?
    public let elevationGain: Double?
    public let avgHeartRate: Int?
    public let maxHeartRate: Int?
    public let minHeartRate: Int?
    public let startTime: Date?
    public let endTime: Date?
    public let durationSeconds: TimeInterval?
    public let boundingBox: GPXBoundingBox

    public init(
        name: String,
        filePath: String,
        rawPointCount: Int,
        renderedPoints: [GPXTrackPoint],
        waypoints: [GPXWaypoint] = [],
        totalDistanceMeters: Double,
        minElevation: Double?,
        maxElevation: Double?,
        elevationGain: Double?,
        avgHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        minHeartRate: Int? = nil,
        startTime: Date?,
        endTime: Date?,
        durationSeconds: TimeInterval?,
        boundingBox: GPXBoundingBox
    ) {
        self.name = name
        self.filePath = filePath
        self.rawPointCount = rawPointCount
        self.renderedPoints = renderedPoints
        self.waypoints = waypoints
        self.totalDistanceMeters = totalDistanceMeters
        self.minElevation = minElevation
        self.maxElevation = maxElevation
        self.elevationGain = elevationGain
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.minHeartRate = minHeartRate
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.boundingBox = boundingBox
    }

    /// 是否包含心率监测数据
    public var hasHeartRateData: Bool {
        avgHeartRate != nil
    }

    /// 格式化心率概要
    public var formattedHeartRateSummary: String {
        guard let avg = avgHeartRate, let maxH = maxHeartRate else { return "--" }
        return "\(avg) bpm (最高 \(maxH))"
    }

    /// 格式化总里程 (km)
    public var formattedDistance: String {
        if totalDistanceMeters >= 1000 {
            return String(format: "%.2f km", totalDistanceMeters / 1000.0)
        } else {
            return String(format: "%.0f m", totalDistanceMeters)
        }
    }

    /// 格式化海拔区间与累计爬升
    public var formattedElevationSummary: String {
        guard let minE = minElevation, let maxE = maxElevation else {
            return "--"
        }
        let gainStr = elevationGain.map { String(format: " (+%.0fm)", $0) } ?? ""
        return "\(Int(minE))m ~ \(Int(maxE))m\(gainStr)"
    }

    /// 格式化耗时
    public var formattedDuration: String {
        guard let sec = durationSeconds, sec > 0 else { return "--" }
        let hours = Int(sec) / 3600
        let minutes = (Int(sec) % 3600) / 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分"
        } else {
            return "\(minutes)分钟"
        }
    }

    /// 起点坐标
    public var startPoint: GPXTrackPoint? {
        renderedPoints.first
    }

    /// 终点坐标
    public var endPoint: GPXTrackPoint? {
        renderedPoints.last
    }
}
