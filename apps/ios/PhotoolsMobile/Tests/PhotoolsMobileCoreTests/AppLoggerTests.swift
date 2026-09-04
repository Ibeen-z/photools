import XCTest
@testable import PhotoolsMobileCore

final class AppLoggerTests: XCTestCase {
    func testAppLoggerLogDoesNotCrash() {
        // 验证各等级日志调用安全且格式化正常
        AppLogger.log(level: .info, message: "测试普通消息", cameraName: "Z8")
        AppLogger.log(level: .success, message: "测试成功消息", cameraName: "Z6_3")
        AppLogger.log(level: .warning, message: "测试警告消息", cameraName: nil)
        AppLogger.log(level: .error, message: "测试错误消息", cameraName: "D850")
    }

    @MainActor
    func testCoordinatorAppendLogIntegration() {
        let coordinator = CameraSyncCoordinator.shared
        let initialCount = coordinator.logs.count
        coordinator.appendLog(level: .info, message: "单元测试写入日志", cameraName: "Z9")
        XCTAssertEqual(coordinator.logs.count, min(initialCount + 1, 150))
        XCTAssertEqual(coordinator.logs.first?.message, "单元测试写入日志")
        XCTAssertEqual(coordinator.logs.first?.cameraName, "Z9")
    }

    func testMotionStateTransitionLogging() {
        let tracker = MotionActivityTracker.shared
        var receivedLogs: [String] = []
        tracker.onLog = { level, msg in
            receivedLogs.append(msg)
            AppLogger.log(level: level, message: msg, category: "Motion")
        }

        // 1. 静止 ➔ 徒步中
        tracker.simulateStateChange(newState: .walking)
        XCTAssertTrue(receivedLogs.contains(where: { $0.contains("运动模式感知切换") && $0.contains("徒步中") }))

        // 2. 徒步中 ➔ 乘车转场
        tracker.simulateStateChange(newState: .automotive)
        XCTAssertTrue(receivedLogs.contains(where: { $0.contains("乘车转场") }))

        // 3. 乘车转场 ➔ 静止休整 (动转静：新机位停步瞬态)
        tracker.simulateStateChange(newState: .stationary)
        XCTAssertTrue(receivedLogs.contains(where: { $0.contains("捕捉到摄影师停步瞬态") && $0.contains("到达新机位") }))
    }
}
