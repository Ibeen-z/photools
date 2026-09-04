import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// 运动感知置信度
public enum MotionConfidence: Int, Sendable, Comparable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: MotionConfidence, rhs: MotionConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

#if canImport(CoreMotion)
extension MotionConfidence {
    public init(_ confidence: CMMotionActivityConfidence) {
        switch confidence {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        @unknown default: self = .low
        }
    }
}
#endif

/// 原始运动活动输入快照 (解耦硬件，支持跨平台与确定性测试)
public struct RawMotionActivity: Sendable, Equatable {
    public var stationary: Bool
    public var walking: Bool
    public var running: Bool
    public var automotive: Bool
    public var cycling: Bool
    public var unknown: Bool
    public var confidence: MotionConfidence
    public var timestamp: Date

    public init(
        stationary: Bool = false,
        walking: Bool = false,
        running: Bool = false,
        automotive: Bool = false,
        cycling: Bool = false,
        unknown: Bool = false,
        confidence: MotionConfidence = .high,
        timestamp: Date = Date()
    ) {
        self.stationary = stationary
        self.walking = walking
        self.running = running
        self.automotive = automotive
        self.cycling = cycling
        self.unknown = unknown
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// 运动状态滤波仲裁器 (抗抖动、置信度过滤与迟滞判定)
public final class MotionActivityFilter: @unchecked Sendable {
    public struct Config: Sendable {
        /// 从静止脱离进入待定(unknown)的去抖确认窗口 (秒)，默认 2.5s。
        /// 手机在床上/桌上被轻点、翻身或微碰引发的瞬态 unknown 在此时间内自动被静止吸收
        public var unknownDebounceSeconds: TimeInterval
        /// 过滤低置信度未知杂波：处于静止状态下丢弃所有 confidence == .low 的 unknown 扰动
        public var suppressLowConfidenceUnknown: Bool

        public init(
            unknownDebounceSeconds: TimeInterval = 2.5,
            suppressLowConfidenceUnknown: Bool = true
        ) {
            self.unknownDebounceSeconds = unknownDebounceSeconds
            self.suppressLowConfidenceUnknown = suppressLowConfidenceUnknown
        }
    }

    public var config: Config
    private let lock = NSRecursiveLock()

    private var _currentState: PhotographerMotionState = .unknown
    public var currentState: PhotographerMotionState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }
    private var previousState: PhotographerMotionState = .unknown
    private var pendingUnknownStartTime: Date?

    public init(config: Config = Config(), initialState: PhotographerMotionState = .unknown) {
        self.config = config
        self._currentState = initialState
        self.previousState = initialState
    }

    /// 核心处理函数：接收原始采样，返回状态变更结果 (若被滤波平滑吸收则返回 nil)
    public func process(raw: RawMotionActivity) -> (newState: PhotographerMotionState, isStationaryTransition: Bool)? {
        lock.lock()
        defer { lock.unlock() }

        // 1. 提取物理候选状态
        let candidateState: PhotographerMotionState
        if raw.stationary {
            candidateState = .stationary
        } else if raw.walking {
            candidateState = .walking
        } else if raw.running {
            candidateState = .running
        } else if raw.automotive {
            candidateState = .automotive
        } else if raw.cycling {
            candidateState = .cycling
        } else {
            candidateState = .unknown
        }

        // 2. 状态平滑与抗抖过滤
        // 场景 A: 手机处于静止中 (如在床上/桌面)
        if currentState == .stationary {
            // A1: 收到低置信度未知扰动 (如手指轻点屏幕、床垫轻微弹性晃动) -> 彻底过滤并保持静止
            if candidateState == .unknown && raw.confidence == .low && config.suppressLowConfidenceUnknown {
                pendingUnknownStartTime = nil
                return nil
            }

            // A2: 收到中/高置信度的未知状态 -> 启动去抖计时，防止短时把玩手机频繁跳出静止
            if candidateState == .unknown {
                if let startTime = pendingUnknownStartTime {
                    if raw.timestamp.timeIntervalSince(startTime) >= config.unknownDebounceSeconds {
                        // 持续超过去抖门限，确认脱离静止转入待定
                        pendingUnknownStartTime = nil
                        return applyTransition(to: .unknown)
                    } else {
                        // 仍在去抖窗口观察期，平滑吸收
                        return nil
                    }
                } else {
                    pendingUnknownStartTime = raw.timestamp
                    return nil
                }
            }

            // A3: 恢复静止或持续静止 -> 清除去抖挂起计时
            if candidateState == .stationary {
                pendingUnknownStartTime = nil
                return nil
            }

            // A4: 检测到明确运动 (走路/跑步/骑车/驾车)
            if candidateState.isMoving {
                // 如果是低置信度运动，且处于静止中，进行保护，要求至少 medium 置信度才脱离静止
                if raw.confidence == .low {
                    return nil
                }
                pendingUnknownStartTime = nil
                return applyTransition(to: candidateState)
            }
        }

        // 场景 B: 手机处于未知状态 (unknown)
        if currentState == .unknown {
            // 收到静止确认
            if candidateState == .stationary {
                if raw.confidence == .low {
                    return nil
                }
                pendingUnknownStartTime = nil
                return applyTransition(to: .stationary)
            }
            // 收到明确运动
            if candidateState.isMoving && raw.confidence >= .medium {
                pendingUnknownStartTime = nil
                return applyTransition(to: candidateState)
            }
            return nil
        }

        // 场景 C: 处于运动中 (walking / running / automotive / cycling)
        if currentState.isMoving {
            // 动转静瞬态判断 (停步到达新机位，至少需要 medium 置信度)
            if candidateState == .stationary && raw.confidence >= .medium {
                pendingUnknownStartTime = nil
                return applyTransition(to: .stationary)
            }

            // 运动模式之间切换 (例如走动转乘车)
            if candidateState.isMoving && candidateState != currentState && raw.confidence >= .medium {
                pendingUnknownStartTime = nil
                return applyTransition(to: candidateState)
            }

            // 运动中出现短时未知杂波 (例如走路时掏出手机看了一眼)
            if candidateState == .unknown {
                // 不立刻打断运动状态
                return nil
            }
        }

        return nil
    }

    private func applyTransition(to newState: PhotographerMotionState) -> (PhotographerMotionState, Bool)? {
        let wasMoving = _currentState.isMoving
        let isNowStationary = (newState == .stationary)
        let isStationaryTransition = wasMoving && isNowStationary

        if newState != _currentState || isStationaryTransition {
            previousState = _currentState
            _currentState = newState
            return (newState, isStationaryTransition)
        }
        return nil
    }

    /// 手动重置或强制同步状态 (用于测试或初始化)
    public func reset(to state: PhotographerMotionState) {
        lock.lock()
        defer { lock.unlock() }
        previousState = _currentState
        _currentState = state
        pendingUnknownStartTime = nil
    }
}
