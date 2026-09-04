import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// 仲裁决策结果
public enum FreshnessDecision: Equatable, Sendable {
    case allow(reason: String)
    case suppress(reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// 尼康相机待机低功耗保鲜仲裁引擎
public final class StandbyFreshnessArbiter: @unchecked Sendable {
    public struct Config: Sendable {
        /// 刚断开时的防抖冷静期 (秒)，默认 5s，彻底过滤断开瞬态的残余广播震荡，同时确保摄影师半按快门即可秒级响应
        public var cooldownSeconds: TimeInterval = 5.0
        /// 显著位移触发阈值 (米)，默认 30m
        public var displacementThresholdMeters: Double = 30.0
        /// 原地静止状态下的保鲜滑动窗口 (秒)，默认 20 分钟 (1200s)，极致节电
        public var stationaryWindowSeconds: TimeInterval = 1200.0
        /// 运动中 (徒步/乘车) 的动态保鲜滑动窗口 (秒)，默认 5 分钟 (300s)
        public var movingWindowSeconds: TimeInterval = 300.0
        /// 未知运动状态下的默认保鲜滑动窗口 (秒)，默认 10 分钟 (600s)
        public var defaultWindowSeconds: TimeInterval = 600.0
        /// 允许注入的最大水平定位误差 (米)，默认 25m，若信号弱超过此门限则放弃注入以防漂移
        public var maxAccuracyThresholdMeters: Double = 25.0

        public init(
            cooldownSeconds: TimeInterval = 5.0,
            displacementThresholdMeters: Double = 30.0,
            stationaryWindowSeconds: TimeInterval = 1200.0,
            movingWindowSeconds: TimeInterval = 300.0,
            defaultWindowSeconds: TimeInterval = 600.0,
            maxAccuracyThresholdMeters: Double = 25.0
        ) {
            self.cooldownSeconds = cooldownSeconds
            self.displacementThresholdMeters = displacementThresholdMeters
            self.stationaryWindowSeconds = stationaryWindowSeconds
            self.movingWindowSeconds = movingWindowSeconds
            self.defaultWindowSeconds = defaultWindowSeconds
            self.maxAccuracyThresholdMeters = maxAccuracyThresholdMeters
        }
    }

    public var config: Config
    private let lock = NSLock()

    // 状态记录
    private var lastDisconnectTimes: [UUID: Date] = [:]
    private var lastInjectedTimes: [UUID: Date] = [:]
    private var lastAttemptTimes: [UUID: Date] = [:]
    #if canImport(CoreLocation)
    private var lastInjectedLocations: [UUID: CLLocation] = [:]
    private var latestKnownLocation: CLLocation?
    #endif
    private var currentMotionState: PhotographerMotionState = .unknown
    private var pendingStationaryTransition: Bool = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 记录相机断开连接时间
    public func recordDisconnection(cameraID: UUID, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastDisconnectTimes[cameraID] = date
        lastAttemptTimes[cameraID] = nil
    }

    /// 记录向相机成功注入 GPS 坐标的时间与机位
    #if canImport(CoreLocation)
    public func recordInjection(cameraID: UUID, location: CLLocation, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastInjectedTimes[cameraID] = date
        lastInjectedLocations[cameraID] = location
        lastAttemptTimes[cameraID] = nil
        pendingStationaryTransition = false
    }
    #else
    public func recordInjection(cameraID: UUID, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastInjectedTimes[cameraID] = date
        pendingStationaryTransition = false
    }
    #endif

    /// 更新当前最新的设备定位
    #if canImport(CoreLocation)
    public func updateCurrentLocation(_ location: CLLocation) {
        lock.lock()
        defer { lock.unlock() }
        self.latestKnownLocation = location
    }
    #endif

    /// 更新当前运动状态
    public func updateMotionState(_ state: PhotographerMotionState, isTransition: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.currentMotionState = state
        if isTransition {
            self.pendingStationaryTransition = true
        }
    }

    /// 核心裁决函数：相机在待机低功耗发射广播时，是否允许手机发起重连？
    public func shouldAllowStandbyReconnect(cameraID: UUID, now: Date = Date()) -> FreshnessDecision {
        lock.lock()
        defer { lock.unlock() }

        // 0. GPS 精度门限过滤：若当前 GPS 精度劣于门限 (如室内漂移 > 25m)，跳过待机保鲜，坚决不污染相机内的高精坐标
        #if canImport(CoreLocation)
        if let current = latestKnownLocation {
            if current.horizontalAccuracy < 0 || current.horizontalAccuracy > config.maxAccuracyThresholdMeters {
                let acc = Int(current.horizontalAccuracy)
                return .suppress(reason: "当前 GPS 精度不足 (±\(acc)m > \(Int(config.maxAccuracyThresholdMeters))m)，跳过待机重连以防污染坐标")
            }
        }
        #endif

        // 1. 防抖冷静期校验：刚断开几秒内，过滤链路瞬态残余包
        if let disTime = lastDisconnectTimes[cameraID] {
            let elapsedSinceDis = now.timeIntervalSince(disTime)
            if elapsedSinceDis < config.cooldownSeconds {
                let remain = max(1, Int(ceil(config.cooldownSeconds - elapsedSinceDis)))
                return .suppress(reason: "处于刚断开防抖冷静期内 (还剩 \(remain) 秒)，相机深睡中，禁止打扰")
            }
        }

        // 1.1 并发尝试防抖：若在 15 秒内已有正在激活中的保鲜连接，压制同秒连续轰炸
        if let lastAttempt = lastAttemptTimes[cameraID] {
            let elapsedAttempt = now.timeIntervalSince(lastAttempt)
            if elapsedAttempt < 15.0 {
                return .suppress(reason: "保鲜连接激活中 (\(Int(elapsedAttempt))s/15s)，避免并发重复发起")
            }
        }

        let lastInject: Date
        if let injected = lastInjectedTimes[cameraID] {
            lastInject = injected
        } else if let disconnected = lastDisconnectTimes[cameraID] {
            lastInject = disconnected
        } else {
            // 冷启动：初始化基准时间为当前时刻，赋予完整的首轮滑动窗口，严禁远古时间戳雪崩
            lastInjectedTimes[cameraID] = now
            lastInject = now
        }
        let elapsedSinceInject = now.timeIntervalSince(lastInject)

        // 2. 停步瞬态（动转静）：捕捉摄影师停下脚步、到达新机位的黄金瞬间
        if pendingStationaryTransition && elapsedSinceInject >= 30.0 {
            lastAttemptTimes[cameraID] = now
            return .allow(reason: "捕捉到停步到达新机位瞬态，立即唤醒相机刷新当前机位坐标 📍")
        }

        // 3. 显著物理位移触发
        #if canImport(CoreLocation)
        if let current = latestKnownLocation, let lastLoc = lastInjectedLocations[cameraID] {
            let distance = current.distance(from: lastLoc)
            if distance >= config.displacementThresholdMeters {
                lastAttemptTimes[cameraID] = now
                return .allow(reason: "检测到显著位移 (\(Int(distance))m >= \(Int(config.displacementThresholdMeters))m)，机位已变动，主动保鲜注入")
            }
        }
        #endif

        // 4. 自适应时间滑动窗口裁决
        let targetWindow: TimeInterval
        switch currentMotionState {
        case .stationary:
            targetWindow = config.stationaryWindowSeconds
        case .walking, .running, .automotive, .cycling:
            targetWindow = config.movingWindowSeconds
        case .unknown:
            targetWindow = config.defaultWindowSeconds
        }

        if elapsedSinceInject >= targetWindow {
            let windowMin = Int(targetWindow / 60)
            lastAttemptTimes[cameraID] = now
            return .allow(reason: "[\(currentMotionState.rawValue)] 状态滑动窗口已达 \(windowMin) 分钟，执行周期性静默保鲜")
        }

        let remainSeconds = Int(targetWindow - elapsedSinceInject)
        let remainMin = max(1, remainSeconds / 60)
        return .suppress(reason: "[\(currentMotionState.rawValue)] 状态保鲜窗口期内 (约剩 \(remainMin) 分钟)，相机保持省电休眠")
    }
}
