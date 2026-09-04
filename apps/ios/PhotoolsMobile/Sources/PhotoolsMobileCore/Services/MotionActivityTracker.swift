import Foundation
#if os(iOS) && canImport(CoreMotion)
import CoreMotion
#endif

/// 摄影师物理运动状态枚举
public enum PhotographerMotionState: String, Sendable, CaseIterable {
    case stationary = "静止休整"
    case walking    = "徒步中"
    case running    = "跑步中"
    case automotive = "乘车转场"
    case cycling    = "骑行中"
    case unknown    = "待定"

    public var icon: String {
        switch self {
        case .stationary: return "figure.stand"
        case .walking:    return "figure.walk"
        case .running:    return "figure.run"
        case .automotive: return "car.fill"
        case .cycling:    return "bicycle"
        case .unknown:    return "questionmark.circle"
        }
    }

    public var isMoving: Bool {
        switch self {
        case .walking, .running, .automotive, .cycling:
            return true
        case .stationary, .unknown:
            return false
        }
    }
}

/// 运动与健身状态追踪器 (基于微安级苹果运动协处理器 + 抗抖滤波仲裁)
public final class MotionActivityTracker: @unchecked Sendable {
    public static let shared = MotionActivityTracker()

    #if os(iOS) && canImport(CoreMotion)
    private let activityManager = CMMotionActivityManager()
    private let operationQueue = OperationQueue()
    #endif

    /// 运动滤波与防抖仲裁引擎
    public let filter: MotionActivityFilter

    public var currentState: PhotographerMotionState {
        filter.currentState
    }
    private var previousState: PhotographerMotionState = .unknown

    /// 运动状态变更回调: (新状态, 是否为动转静停步瞬态)
    public var onMotionStateChanged: ((PhotographerMotionState, Bool) -> Void)?
    public var onLog: ((SyncLogLevel, String) -> Void)?

    public init(filter: MotionActivityFilter = MotionActivityFilter()) {
        self.filter = filter
        #if os(iOS) && canImport(CoreMotion)
        operationQueue.name = "com.vincentchyu.photools.mobile.motionQueue"
        operationQueue.maxConcurrentOperationCount = 1
        #endif
    }

    /// 检查硬件是否支持运动状态感应
    public var isActivityAvailable: Bool {
        #if os(iOS) && canImport(CoreMotion)
        return CMMotionActivityManager.isActivityAvailable()
        #else
        return false
        #endif
    }

    /// 启动运动状态后台监听
    public func startTracking() {
        #if os(iOS) && canImport(CoreMotion)
        guard CMMotionActivityManager.isActivityAvailable() else {
            onLog?(.info, "当前设备不支持运动协处理器，自动降级为纯 GPS 位移模式")
            return
        }

        activityManager.startActivityUpdates(to: operationQueue) { [weak self] activity in
            guard let self = self, let act = activity else { return }

            let raw = RawMotionActivity(
                stationary: act.stationary,
                walking: act.walking,
                running: act.running,
                automotive: act.automotive,
                cycling: act.cycling,
                unknown: act.unknown,
                confidence: MotionConfidence(act.confidence),
                timestamp: act.startDate
            )

            self.handleRawActivity(raw)
        }
        onLog?(.success, "CoreMotion 运动感知引擎已就绪 (微安级超低功耗后台守护 + 抗抖滤波防杂波) 🛡️")
        #else
        onLog?(.info, "平台不支持 CoreMotion，已自动降级为 GPS 物理位移保鲜模式")
        #endif
    }

    /// 停止监听
    public func stopTracking() {
        #if os(iOS) && canImport(CoreMotion)
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.stopActivityUpdates()
        }
        #endif
    }

    /// 处理原始采样并经滤波器抗抖仲裁
    private func handleRawActivity(_ raw: RawMotionActivity) {
        let oldState = self.currentState
        if let transition = self.filter.process(raw: raw) {
            let newState = transition.newState
            let isStationaryTransition = transition.isStationaryTransition
            self.previousState = oldState
            self.onMotionStateChanged?(newState, isStationaryTransition)

            let strategyDesc = newState == .stationary ? "20m 深度休眠保鲜" : (newState.isMoving ? "5m 动态跟随" : "10m 默认保鲜")
            if isStationaryTransition {
                self.onLog?(.info, "🚶➔⏸️ 捕捉到摄影师停步瞬态: [\(oldState.rawValue) ➔ \(newState.rawValue)]，判定到达新机位！保鲜仲裁引擎优先授权机位刷新 📍")
            } else if oldState != newState {
                self.onLog?(.info, "🏃 运动模式感知切换: [\(oldState.rawValue) ➔ \(newState.rawValue)] (策略: \(strategyDesc))")
            }
        }
    }

    /// 模拟原始采样输入 (用于确定性抗抖与置信度测试)
    public func simulateRawActivity(_ raw: RawMotionActivity) {
        handleRawActivity(raw)
    }

    /// 手动模拟直接状态变更 (保留向后兼容性)
    public func simulateStateChange(newState: PhotographerMotionState) {
        let oldState = self.currentState
        let wasMoving = oldState.isMoving
        let isStationaryTransition = wasMoving && (newState == .stationary)
        self.previousState = oldState
        self.filter.reset(to: newState)
        self.onMotionStateChanged?(newState, isStationaryTransition)

        let strategyDesc = newState == .stationary ? "20m 深度休眠保鲜" : (newState.isMoving ? "5m 动态跟随" : "10m 默认保鲜")
        if isStationaryTransition {
            self.onLog?(.info, "🚶➔⏸️ 捕捉到摄影师停步瞬态: [\(oldState.rawValue) ➔ \(newState.rawValue)]，判定到达新机位！保鲜仲裁引擎优先授权机位刷新 📍")
        } else if oldState != newState {
            self.onLog?(.info, "🏃 运动模式感知切换: [\(oldState.rawValue) ➔ \(newState.rawValue)] (策略: \(strategyDesc))")
        }
    }
}
