import XCTest
import Combine
@testable import PhotoolsMobileCore

final class CameraPowerStateAndFreshnessTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// 1. 测试删除轨迹后，CameraSyncCoordinator 能够响应并联动发布 objectWillChange，保证 Dashboard 轨迹档案数字即时刷新
    @MainActor
    func testTrackDeletionTriggersCoordinatorObjectWillChange() {
        let coordinator = CameraSyncCoordinator.shared
        let recorder = GPXRecorderService.shared

        // 构造虚拟会话并入库
        recorder.startSession()
        guard let created = recorder.stopSession() else {
            XCTFail("无法生成测试会话")
            return
        }

        // 等待并消费掉前面 stopSession 异步发出的通知
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var changeReceived = false
        let exp = expectation(description: "Coordinator should receive objectWillChange on track deletion")

        let sub = coordinator.objectWillChange
            .first()
            .sink { _ in
                changeReceived = true
                exp.fulfill()
            }
        sub.store(in: &cancellables)

        // 执行删除单次会话
        recorder.deleteSession(created)

        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(changeReceived, "删除轨迹后，CameraSyncCoordinator 必须自动派发 objectWillChange 触发 Dashboard 刷新")
    }

    /// 2. 测试相机关机/未连接状态下的状态描述与信号强度 (严禁显示待机休眠与残留 RSSI)
    @MainActor
    func testPoweredOffCameraShowsDisconnectedAndNilRSSI() {
        let coordinator = CameraSyncCoordinator.shared
        let camUUID = UUID()
        let deviceID: UInt32 = 0xAA886644
        let cam = CameraDevice(
            name: "NIKON Z 8_TEST",
            bleIdentifier: camUUID.uuidString,
            deviceID: deviceID,
            nonce: 0x11223344
        )

        // 确保清除任何残存状态
        coordinator.purgeStaleAdvertisements(timeout: 0)

        // 相机未开机/关机状态断言
        let status = coordinator.cameraConnectionStatusDesc(for: cam)
        XCTAssertEqual(status.text, "已断开 ⚪️", "相机关机且未在广播时，状态必须显示为已断开，严禁误报为待机休眠")
        XCTAssertFalse(status.isReady)

        let rssi = coordinator.rssi(for: cam)
        XCTAssertNil(rssi, "相机关机或断开时，信号强度必须为 nil，严禁显示残留虚假信号")
        XCTAssertNil(coordinator.bleSignalQuality(for: cam))
    }

    /// 3. 测试活跃待机广播 (0x1D) 在保鲜期内正确显示待机休眠与信号强度，超时后自动判定为关机
    @MainActor
    func testStandbyBroadcastFreshnessAndTimeoutTransitions() {
        let coordinator = CameraSyncCoordinator.shared
        let camUUID = UUID()
        let deviceID: UInt32 = 0x55667788
        let cam = CameraDevice(
            name: "NIKON Z 6_3_TEST",
            bleIdentifier: camUUID.uuidString,
            deviceID: deviceID,
            nonce: 0x99887766
        )

        coordinator.purgeStaleAdvertisements(timeout: 0)

        // 1. 模拟捕获到新鲜广播 (0x1D 待机广播)
        coordinator.recordAdvertisement(
            cameraDeviceID: deviceID,
            peripheralID: camUUID,
            rssi: -68,
            statusByte: 0x1D,
            timestamp: Date()
        )

        let status = coordinator.cameraConnectionStatusDesc(for: cam)
        XCTAssertEqual(status.text, "待机休眠 💤", "新鲜广播 0x1D 必须判定为待机休眠")
        let rssi = coordinator.rssi(for: cam)
        XCTAssertEqual(rssi, -68, "待机休眠时必须能够读取到当前广播的真实信号强度")

        // 2. 模拟相机关机：时间流逝超过 8 秒未收到广播包
        coordinator.recordAdvertisement(
            cameraDeviceID: deviceID,
            peripheralID: camUUID,
            rssi: -68,
            statusByte: 0x1D,
            timestamp: Date().addingTimeInterval(-10.0) // 10 秒前已停止广播
        )

        // 触发保鲜检查
        coordinator.purgeStaleAdvertisements(timeout: 8.0)

        let statusAfterTimeout = coordinator.cameraConnectionStatusDesc(for: cam)
        XCTAssertEqual(statusAfterTimeout.text, "已断开 ⚪️", "相机关机导致广播超时后，状态必须自动流转为已断开")
        XCTAssertNil(coordinator.rssi(for: cam), "相机关机导致广播超时后，信号强度必须清空为 nil")
    }

    /// 4. 测试唤醒就绪广播 (0x1C) 正确识别为唤醒待连
    @MainActor
    func testAwakeBroadcastRecognition() {
        let coordinator = CameraSyncCoordinator.shared
        let camUUID = UUID()
        let deviceID: UInt32 = 0x99AABBCC
        let cam = CameraDevice(
            name: "NIKON Z 9_TEST",
            bleIdentifier: camUUID.uuidString,
            deviceID: deviceID,
            nonce: 0x12345678
        )

        coordinator.recordAdvertisement(
            cameraDeviceID: deviceID,
            peripheralID: camUUID,
            rssi: -52,
            statusByte: 0x1C,
            timestamp: Date()
        )

        let status = coordinator.cameraConnectionStatusDesc(for: cam)
        XCTAssertEqual(status.text, "唤醒待连 ⚡️", "唤醒就绪广播 0x1C 必须识别为唤醒待连")
        XCTAssertEqual(coordinator.rssi(for: cam), -52)
    }
}
