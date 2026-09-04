import XCTest
@testable import PhotoolsMobileCore

final class MotionActivityFilterTests: XCTestCase {
    var filter: MotionActivityFilter!

    override func setUp() {
        super.setUp()
        filter = MotionActivityFilter(
            config: MotionActivityFilter.Config(unknownDebounceSeconds: 2.5, suppressLowConfidenceUnknown: true),
            initialState: .stationary
        )
    }

    /// 1. 核心场景验证：手机放在床上/桌面处于静止，手指轻点屏幕产生低置信度未知扰动，必须 100% 被过滤保持静止
    func testBedFingerTapLowConfidenceIgnoredWhenStationary() {
        let now = Date()
        // 模拟手指点按屏幕产生的典型 CoreMotion 杂波采样 (unknown + low confidence)
        let tapJitter = RawMotionActivity(
            stationary: false,
            walking: false,
            running: false,
            automotive: false,
            cycling: false,
            unknown: true,
            confidence: .low,
            timestamp: now
        )

        let result = filter.process(raw: tapJitter)
        XCTAssertNil(result, "手指轻点床上手机构成的低置信度未知扰动，必须被平滑过滤")
        XCTAssertEqual(filter.currentState, .stationary, "状态必须坚固维持在静止休整，严禁跳变为待定")
    }

    /// 2. 场景验证：床垫晃动产生短暂中置信度扰动，但在 2.5 秒去抖窗口内平息并恢复静止，必须被吸收而不跳变
    func testShortBedJitterDebouncedAndAbsorbed() {
        let t0 = Date()
        // t0: 床垫晃动，CoreMotion 报 medium confidence unknown
        let jitter1 = RawMotionActivity(unknown: true, confidence: .medium, timestamp: t0)
        let res1 = filter.process(raw: jitter1)
        XCTAssertNil(res1, "首次中置信度 unknown 必须进入去抖观察窗口，不立即跳变")
        XCTAssertEqual(filter.currentState, .stationary)

        // t0 + 1.0s: 仍有微弱余震
        let jitter2 = RawMotionActivity(unknown: true, confidence: .medium, timestamp: t0.addingTimeInterval(1.0))
        let res2 = filter.process(raw: jitter2)
        XCTAssertNil(res2, "1秒内仍在去抖窗口中，保持平滑")
        XCTAssertEqual(filter.currentState, .stationary)

        // t0 + 1.5s: 震动平息，恢复静止
        let backToStationary = RawMotionActivity(stationary: true, confidence: .high, timestamp: t0.addingTimeInterval(1.5))
        let res3 = filter.process(raw: backToStationary)
        XCTAssertNil(res3, "恢复静止清除去抖计时")
        XCTAssertEqual(filter.currentState, .stationary, "全程未发生误跳变，保持静止休整")
    }

    /// 3. 场景验证：持续把玩或长程未知运动超过去抖门限 (2.5s)，才正式转为待定
    func testSustainedUnknownExceedingDebounceWindowTransitions() {
        let t0 = Date()
        let jitterStart = RawMotionActivity(unknown: true, confidence: .medium, timestamp: t0)
        _ = filter.process(raw: jitterStart)

        // 持续 2.6 秒后的未知状态
        let sustainedUnknown = RawMotionActivity(unknown: true, confidence: .medium, timestamp: t0.addingTimeInterval(2.6))
        let result = filter.process(raw: sustainedUnknown)

        XCTAssertNotNil(result, "持续超过去抖窗口的未知活动，应正式生效")
        XCTAssertEqual(result?.newState, .unknown)
        XCTAssertFalse(result?.isStationaryTransition ?? true)
        XCTAssertEqual(filter.currentState, .unknown)
    }

    /// 4. 场景验证：摄影师真正起身走动 (walking + medium/high)，必须立即脱离静止进入徒步模式
    func testRealWalkingTransitionsImmediately() {
        let t0 = Date()
        let walkingActivity = RawMotionActivity(walking: true, confidence: .medium, timestamp: t0)

        let result = filter.process(raw: walkingActivity)
        XCTAssertNotNil(result, "中/高置信度的明确徒步，必须毫秒级响应")
        XCTAssertEqual(result?.newState, .walking)
        XCTAssertFalse(result?.isStationaryTransition ?? true)
        XCTAssertEqual(filter.currentState, .walking)
    }

    /// 5. 场景验证：徒步到达新机位停步 (walking -> stationary)，必须立即捕捉动转静停步瞬态
    func testArrivalAtNewHotspotTransitionCaptured() {
        filter.reset(to: .walking)
        XCTAssertTrue(filter.currentState.isMoving)

        let t0 = Date()
        let stoppedActivity = RawMotionActivity(stationary: true, confidence: .high, timestamp: t0)

        let result = filter.process(raw: stoppedActivity)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.newState, .stationary)
        XCTAssertTrue(result?.isStationaryTransition ?? false, "由移动转为静止必须触发 isStationaryTransition = true，供保鲜引擎立即刷新机位")
        XCTAssertEqual(filter.currentState, .stationary)
    }

    /// 6. 场景验证：静止状态下，低置信度走动 (如在床上翻身微动) 不会误触发脱离静止
    func testLowConfidenceWalkingIgnoredWhenStationary() {
        let lowConfWalking = RawMotionActivity(walking: true, confidence: .low, timestamp: Date())
        let result = filter.process(raw: lowConfWalking)
        XCTAssertNil(result, "静止状态下低置信度运动应被抑制，防止翻身等动作误判")
        XCTAssertEqual(filter.currentState, .stationary)
    }
}
