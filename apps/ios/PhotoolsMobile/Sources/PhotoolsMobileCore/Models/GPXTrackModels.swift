import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// 单个高精记录点模型
public struct GPXRecordedPoint: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?           // 海拔 (米)
    public let timestamp: Date              // 记录时间 (UTC)
    public let horizontalAccuracy: Double   // 水平精度 (米)
    public let speed: Double?               // 移动速度 (m/s)
    public let course: Double?              // 航向角度 (0-360)

    public init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        timestamp: Date = Date(),
        horizontalAccuracy: Double = 0.0,
        speed: Double? = nil,
        course: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = (speed != nil && speed! >= 0) ? speed : nil
        self.course = (course != nil && course! >= 0) ? course : nil
    }

    #if canImport(CoreLocation)
    public init(location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.elevation = location.altitude
        self.timestamp = location.timestamp
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speed = location.speed >= 0 ? location.speed : nil
        self.course = location.course >= 0 ? location.course : nil
    }
    #endif

    /// 计算两点间的大圆距离 (Haversine 算法，单位：米)
    public func distance(to other: GPXRecordedPoint) -> Double {
        let earthRadiusMeters = 6371000.0
        let lat1 = self.latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLat = (other.latitude - self.latitude) * .pi / 180.0
        let dLon = (other.longitude - self.longitude) * .pi / 180.0

        let a = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2.0) * sin(dLon / 2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        return earthRadiusMeters * c
    }
}

/// 摄影巡航轨迹会话元数据模型
public struct GPXTrackSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var sessionName: String
    public let startTime: Date
    public var endTime: Date?
    public var pointCount: Int
    public var totalDistanceMeters: Double
    public var elevationGain: Double
    public var gpxFileName: String
    public var isCompleted: Bool

    public init(
        id: UUID = UUID(),
        sessionName: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        pointCount: Int = 0,
        totalDistanceMeters: Double = 0.0,
        elevationGain: Double = 0.0,
        gpxFileName: String,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.sessionName = sessionName
        self.startTime = startTime
        self.endTime = endTime
        self.pointCount = pointCount
        self.totalDistanceMeters = totalDistanceMeters
        self.elevationGain = elevationGain
        self.gpxFileName = gpxFileName
        self.isCompleted = isCompleted
    }

    /// 持续时长 (秒)
    public var durationSeconds: TimeInterval {
        let end = endTime ?? Date()
        return max(0, end.timeIntervalSince(startTime))
    }

    /// 格式化耗时 (如 "01小时24分" 或 "45分钟")
    public var formattedDuration: String {
        let sec = Int(durationSeconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let seconds = sec % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// 格式化总里程 (如 "4.25 km" 或 "850 m")
    public var formattedDistance: String {
        if totalDistanceMeters >= 1000 {
            return String(format: "%.2f km", totalDistanceMeters / 1000.0)
        } else {
            return String(format: "%.0f m", totalDistanceMeters)
        }
    }

    /// 格式化点数展示
    public var formattedPointCount: String {
        return "\(pointCount) 点"
    }

    /// 格式化累计爬升 (如 "+120m")
    public var formattedElevationGain: String {
        return String(format: "+%.0fm", elevationGain)
    }
}

/// 录制中实时统计数据 (供 UI 高频轻量响应)
public struct GPXRecordingStats: Equatable, Sendable {
    public let sessionID: UUID
    public let pointCount: Int
    public let distanceMeters: Double
    public let elevationGain: Double
    public let durationSeconds: TimeInterval
    public let latestAccuracy: Double

    public init(
        sessionID: UUID,
        pointCount: Int,
        distanceMeters: Double,
        elevationGain: Double,
        durationSeconds: TimeInterval,
        latestAccuracy: Double
    ) {
        self.sessionID = sessionID
        self.pointCount = pointCount
        self.distanceMeters = distanceMeters
        self.elevationGain = elevationGain
        self.durationSeconds = durationSeconds
        self.latestAccuracy = latestAccuracy
    }

    public var formattedDistance: String {
        if distanceMeters >= 1000 {
            return String(format: "%.2f km", distanceMeters / 1000.0)
        } else {
            return String(format: "%.0f m", distanceMeters)
        }
    }

    public var formattedDuration: String {
        let sec = Int(durationSeconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let seconds = sec % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
