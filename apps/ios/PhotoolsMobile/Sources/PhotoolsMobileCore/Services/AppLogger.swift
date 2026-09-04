import Foundation
import os

/// 尼康 GPS 统一业务日志管理中枢 (输出至系统 os.Logger 与 Xcode 控制台)
public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private static let subsystem = "com.vincentchyu.photools.mobile"
    public static let sync = Logger(subsystem: subsystem, category: "Sync")
    public static let ble = Logger(subsystem: subsystem, category: "Bluetooth")
    public static let location = Logger(subsystem: subsystem, category: "Location")
    public static let gpx = Logger(subsystem: subsystem, category: "GPX")
    public static let motion = Logger(subsystem: subsystem, category: "Motion")

    private static func logger(for category: String) -> Logger {
        switch category {
        case "Bluetooth": return ble
        case "Location":  return location
        case "GPX":       return gpx
        case "Motion":    return motion
        default:          return sync
        }
    }

    private init() {}

    /// 统一日志打印接口：采用苹果原生 Unified Logging System (os.Logger)，杜绝 Xcode 15+ 控制台双重输出
    public static func log(
        level: SyncLogLevel,
        message: String,
        cameraName: String? = nil,
        category: String = "Sync"
    ) {
        let maskedCam = cameraName != nil ? CameraDevice.maskName(cameraName) : nil
        let maskedMsg = CameraDevice.maskText(message)
        let camPrefix = (maskedCam != nil && !maskedCam!.isEmpty) ? "[\(maskedCam!)] " : ""
        let tag: String
        switch level {
        case .info:    tag = "ℹ️ [INFO]"
        case .success: tag = "🟢 [SUCCESS]"
        case .warning: tag = "⚠️ [WARN]"
        case .error:   tag = "❌ [ERROR]"
        }

        let fullMessage = "\(tag) \(camPrefix)\(maskedMsg)"
        let targetLogger = logger(for: category)

        // 统一由系统 os.Logger 驱动控制台与 Console.app (Xcode 15+ 会自动捕获并展示，严禁叠加 print 导致重复双份输出)
        switch level {
        case .info:
            targetLogger.info("\(fullMessage, privacy: .public)")
        case .success:
            targetLogger.notice("\(fullMessage, privacy: .public)")
        case .warning:
            targetLogger.warning("\(fullMessage, privacy: .public)")
        case .error:
            targetLogger.error("\(fullMessage, privacy: .public)")
        }
    }
}
