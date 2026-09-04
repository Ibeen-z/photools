import XCTest
#if canImport(CoreLocation)
import CoreLocation
#endif
@testable import PhotoolsMobileCore

final class StandbyFreshnessArbiterTests: XCTestCase {
    var arbiter: StandbyFreshnessArbiter!
    let cameraID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUp() {
        super.setUp()
        let config = StandbyFreshnessArbiter.Config(
            cooldownSeconds: 5.0,
            displacementThresholdMeters: 30.0,
            stationaryWindowSeconds: 1200.0, // 20m
            movingWindowSeconds: 300.0,     // 5m
            defaultWindowSeconds: 600.0     // 10m
        )
        arbiter = StandbyFreshnessArbiter(config: config)
    }

    /// 1. 验证刚断开进入待机休眠的防抖冷静期 (5 秒) 内拦截残余包，5 秒后允许快门唤醒重连
    func testCooldownRejectsReconnectWithinFiveSecondsAndAllowsAfter() {
        let baseDate = Date()
        arbiter.recordDisconnection(cameraID: cameraID, at: baseDate)

        // 1.5 秒后 (断开瞬态残余包) -> 必须被 5 秒冷静期拦截
        let decisionAt1Sec = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(1.5))
        XCTAssertFalse(decisionAt1Sec.isAllowed, "1.5秒后处于防抖冷静期，必须禁止重连")

        // 4.5 秒后 -> 依然拦截
        let decisionAt4Sec = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(4.5))
        XCTAssertFalse(decisionAt4Sec.isAllowed, "4.5秒后仍处于防抖冷静期")

        // 5.5 秒后且位移达到门限 -> 冷静期已过，允许重连
        #if canImport(CoreLocation)
        let startLoc = CLLocation(latitude: 39.9042, longitude: 116.4074)
        let movedLoc = CLLocation(latitude: 39.9050, longitude: 116.4074) // 约 88 米
        arbiter.recordInjection(cameraID: cameraID, location: startLoc, at: baseDate)
        arbiter.updateCurrentLocation(movedLoc)
        let decisionAt6Sec = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(6.0))
        XCTAssertTrue(decisionAt6Sec.isAllowed, "5秒冷静期过后且有位移，允许保鲜重连")
        #endif
    }

    /// 1.1 验证无参默认配置下，防抖冷静期严格为 5.0 秒
    func testDefaultConfigUsesFiveSecondCooldown() {
        let defaultArbiter = StandbyFreshnessArbiter()
        XCTAssertEqual(defaultArbiter.config.cooldownSeconds, 5.0, "默认冷静期必须为 5.0 秒以支持快门快速唤醒")
    }

    /// 2. 验证原地静止状态下，滑动窗口自动延长至 20 分钟
    func testStationaryStateExtendsWindowToTwentyMinutes() {
        let baseDate = Date()
        arbiter.recordDisconnection(cameraID: cameraID, at: baseDate)
        arbiter.updateMotionState(.stationary, isTransition: false)

        // 5 分钟后 (静止状态下未达 20 分钟) -> 拦截
        let decisionAt5Min = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(300.0))
        XCTAssertFalse(decisionAt5Min.isAllowed, "静止状态下5分钟未满20分钟，应拦截以省电")

        // 15 分钟后 -> 拦截
        let decisionAt15Min = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(900.0))
        XCTAssertFalse(decisionAt15Min.isAllowed, "静止状态下15分钟未满20分钟，应拦截")

        // 20 分钟后 -> 允许保鲜
        let decisionAt20Min = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(1201.0))
        XCTAssertTrue(decisionAt20Min.isAllowed, "静止状态已满20分钟，允许保鲜注入")
    }

    /// 3. 验证运动状态 (徒步/乘车) 下，滑动窗口为 5 分钟动态跟随
    func testMovingStateEnablesFiveMinuteWindow() {
        let baseDate = Date()
        arbiter.recordDisconnection(cameraID: cameraID, at: baseDate)
        arbiter.updateMotionState(.walking, isTransition: false)

        // 3 分钟后 (未满 5 分钟) -> 拦截
        let decisionAt3Min = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(180.0))
        XCTAssertFalse(decisionAt3Min.isAllowed, "步行状态下未满5分钟，应拦截")

        // 5 分钟后 -> 允许保鲜
        let decisionAt5Min = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(301.0))
        XCTAssertTrue(decisionAt5Min.isAllowed, "步行状态已达5分钟，应允许保鲜重连")
    }

    /// 4. 验证显著物理位移触发保鲜重连
    #if canImport(CoreLocation)
    func testSignificantDisplacementTriggersReconnectAfterCooldown() {
        let baseDate = Date()
        let startLoc = CLLocation(latitude: 39.9042, longitude: 116.4074)
        arbiter.recordDisconnection(cameraID: cameraID, at: baseDate)
        arbiter.recordInjection(cameraID: cameraID, location: startLoc, at: baseDate)

        // 冷静期过后 (如 130 秒后)，位移不足 30 米 (例如微移 5 米)
        let microMovedLoc = CLLocation(latitude: 39.90424, longitude: 116.4074) // 约 4.4 米
        arbiter.updateCurrentLocation(microMovedLoc)
        let decisionMicro = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(130.0))
        XCTAssertFalse(decisionMicro.isAllowed, "微小位移不应触发重连")

        // 显著位移 (例如移动 50 米)
        let significantlyMovedLoc = CLLocation(latitude: 39.9047, longitude: 116.4074) // 约 55.6 米
        arbiter.updateCurrentLocation(significantlyMovedLoc)
        let decisionMoved = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(130.0))
        XCTAssertTrue(decisionMoved.isAllowed, "显著位移 (>30m) 且已过冷静期，应允许主动重连保鲜")
    }
    #endif

    /// 5. 验证停步瞬态 (动转静 · 到达新机位) 立即触发优先保鲜
    func testTransitionToStationaryTriggersImmediateReconnect() {
        let baseDate = Date()
        arbiter.recordDisconnection(cameraID: cameraID, at: baseDate)
        // 摄影师此前在徒步，此时停步到达机位
        arbiter.updateMotionState(.stationary, isTransition: true)

        // 刚断开 2 秒时停步，处于 5s 防抖冷静期内 -> 依然受到冷静期保护
        let decisionInCooldown = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(2.0))
        XCTAssertFalse(decisionInCooldown.isAllowed, "处于 5s 冷静期内，即使停步也应保护相机")

        // 冷静期过后且间隔满足门限 (如 35 秒后) -> 动转静瞬态捕获成功，判定为新拍摄机位，应允许立即刷新
        let decisionTransition = arbiter.shouldAllowStandbyReconnect(cameraID: cameraID, now: baseDate.addingTimeInterval(35.0))
        XCTAssertTrue(decisionTransition.isAllowed, "冷静期后停步瞬态判定为新机位，应允许优先保鲜注入")
    }

    /// 6. 验证 MotionActivityTracker 状态模拟器逻辑
    func testMotionActivityTrackerStateSimulation() {
        let tracker = MotionActivityTracker.shared
        var transitionCaptured = false

        tracker.onMotionStateChanged = { state, isTransition in
            if isTransition {
                transitionCaptured = true
            }
        }

        tracker.simulateStateChange(newState: .walking)
        XCTAssertTrue(tracker.currentState.isMoving)

        tracker.simulateStateChange(newState: .stationary)
        XCTAssertFalse(tracker.currentState.isMoving)
        XCTAssertTrue(transitionCaptured, "由 walking 转为 stationary 应触发 isTransition = true")
    }
}
