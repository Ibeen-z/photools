import Foundation

/// GPS 信号与定位质量等级
public enum GPSFixQuality: String, CaseIterable, Sendable {
    case excellent = "极佳"  // <= 5m (5格信号)
    case good      = "良好"  // 5m ~ 15m (4格信号)
    case moderate  = "一般"  // 15m ~ 35m (3格信号)
    case weak      = "较弱"  // 35m ~ 65m (2格信号)
    case poor      = "极弱"  // > 65m (1格信号)
    case invalid   = "失锁"  // < 0 或无效 (0格信号)

    public static func from(accuracy: Double) -> GPSFixQuality {
        if accuracy < 0 {
            return .invalid
        } else if accuracy <= 5.0 {
            return .excellent
        } else if accuracy <= 15.0 {
            return .good
        } else if accuracy <= 35.0 {
            return .moderate
        } else if accuracy <= 65.0 {
            return .weak
        } else {
            return .poor
        }
    }

    /// 对应 0~5 的信号格数
    public var signalBars: Int {
        switch self {
        case .excellent: return 5
        case .good: return 4
        case .moderate: return 3
        case .weak: return 2
        case .poor: return 1
        case .invalid: return 0
        }
    }

    /// 简短评级标题
    public var title: String {
        self.rawValue
    }

    /// 完整状态摘要 (供 UI 详情展示)
    public var summary: String {
        switch self {
        case .excellent: return "极佳 (5格 · 精度≤5m)"
        case .good:      return "良好 (4格 · 精度≤15m)"
        case .moderate:  return "一般 (3格 · 精度≤35m)"
        case .weak:      return "较弱 (2格 · 遮挡或多径)"
        case .poor:      return "极弱 (1格 · 精度超标)"
        case .invalid:   return "失锁 (0格 · 无效信号)"
        }
    }
}

/// 蓝牙无线链路信号质量等级 (单位 dBm，负数越接近 0 信号越强越稳)
public enum BLESignalQuality: String, CaseIterable, Sendable {
    case excellent = "极强"  // >= -60 dBm (贴身/1米内，无阻挡)
    case good      = "良好"  // -61 ~ -75 dBm (常态手持与挂绳拍摄距离)
    case fair      = "一般"  // -76 ~ -85 dBm (相距较远或隔摄影背包)
    case poor      = "微弱"  // < -85 dBm (微弱，易断连)

    public static func from(rssi: Int) -> BLESignalQuality {
        if rssi >= -60 {
            return .excellent
        } else if rssi >= -75 {
            return .good
        } else if rssi >= -85 {
            return .fair
        } else {
            return .poor
        }
    }

    public var title: String {
        self.rawValue
    }

    /// 对应 1~4 的信号格数
    public var bars: Int {
        switch self {
        case .excellent: return 4
        case .good: return 3
        case .fair: return 2
        case .poor: return 1
        }
    }

    /// 格式化说明
    public func formattedDescription(rssi: Int) -> String {
        return "\(rssi) dBm (\(self.title))"
    }
}

/// 实时位置快照
public struct LocationSnapshot: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let accuracy: Double
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        accuracy: Double,
        timestamp: Date = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

    /// 当前位置的 GPS 信号质量评估
    public var fixQuality: GPSFixQuality {
        GPSFixQuality.from(accuracy: accuracy)
    }
}

/// 同步事件日志等级
public enum SyncLogLevel: String, Codable, Sendable {
    case info    = "信息"
    case success = "成功"
    case warning = "警告"
    case error   = "错误"
}

/// 实时日志项
public struct SyncLogItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: SyncLogLevel
    public let message: String
    public let cameraName: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: SyncLogLevel,
        message: String,
        cameraName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = CameraDevice.maskText(message)
        self.cameraName = cameraName != nil ? CameraDevice.maskName(cameraName) : nil
    }
}
