import XCTest
@testable import PhotoolsMobileCore

final class CameraDeviceMatchingTests: XCTestCase {
    
    func testCanonicalNameExtraction() {
        XCTAssertEqual(CameraDevice.canonicalName("Nikon Z 6_2_1234"), "z6_2_1234")
        XCTAssertEqual(CameraDevice.canonicalName("NIKON Z6_3_1234567"), "z6_3_1234567")
        XCTAssertEqual(CameraDevice.canonicalName("nikon_Z8_112233"), "z8_112233")
        XCTAssertEqual(CameraDevice.canonicalName("  Z 7_2  "), "z7_2")
        XCTAssertEqual(CameraDevice.canonicalName(""), "")
        XCTAssertEqual(CameraDevice.canonicalName(nil), "")
    }

    func testFirstTierHardwareDeviceIDMatch() {
        let cam = CameraDevice(
            name: "Z 6_2",
            bleIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceID: 0x1234567
        )

        // 即使 UUID 和名称全不匹配，硬件 DeviceID 命中依然是唯一且最高优先级的
        XCTAssertTrue(cam.matches(
            discoveredDeviceID: 0x1234567,
            peripheralUUID: UUID(),
            peripheralName: "Unknown Device"
        ))

        // DeviceID 为 0 时不参与误判
        XCTAssertFalse(cam.matches(
            discoveredDeviceID: 0,
            peripheralUUID: UUID(),
            peripheralName: "Unknown Device"
        ))
    }

    func testSecondTierPeripheralUUIDMatch() {
        let targetUUID = UUID()
        let cam = CameraDevice(
            name: "Z 6_2",
            bleIdentifier: targetUUID.uuidString.lowercased(),
            deviceID: 0x12345678
        )

        // 大小写不敏感匹配
        XCTAssertTrue(cam.matches(peripheralUUID: targetUUID))
    }

    func testThirdTierStrictCanonicalNameMatch() {
        let cam = CameraDevice(
            name: "Nikon Z 6_3_1234567",
            bleIdentifier: nil,
            deviceID: 0x1234567
        )

        // 规范化名称匹配：支持跨空格差异匹配 ("Z 6_3_1234567" vs "Z6_3_1234567")
        XCTAssertTrue(cam.matches(peripheralName: "Z6_3_1234567"))
        XCTAssertTrue(cam.matches(peripheralName: "Z 6_3_1234567"))

        // 绝不发生 contains 串机：Z 6_3_1234567 不能匹配 Z 6_3_1234568
        XCTAssertFalse(cam.matches(peripheralName: "Z 6_3_1234568"))
    }

    func testPlaceholderCameraNameSafety() {
        let cam = CameraDevice(
            name: "尼康相机",
            bleIdentifier: nil,
            deviceID: 0
        )

        // 占位符 "尼康相机" 绝不能通过第三阶名称匹配命中任何外设
        XCTAssertFalse(cam.matches(peripheralName: "尼康相机"))
        XCTAssertFalse(cam.matches(peripheralName: "Z 6_3_1234567"))
    }

    func testNilAndEmptyPeripheralNameSafety() {
        let cam = CameraDevice(
            name: "Z 6_3_1234567",
            bleIdentifier: nil,
            deviceID: 0x1234567
        )

        // 传入 nil 或空字符串绝不能触发任何异常，且安全返回 false
        XCTAssertFalse(cam.matches())
        let nilName: String? = nil
        XCTAssertFalse(cam.matches(peripheralName: nilName))
        XCTAssertFalse(cam.matches(peripheralName: ""))
        XCTAssertFalse(cam.matches(peripheralName: "   "))
    }
}
