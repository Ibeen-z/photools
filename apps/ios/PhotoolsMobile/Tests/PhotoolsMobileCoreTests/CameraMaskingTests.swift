import XCTest
@testable import PhotoolsMobileCore

final class CameraMaskingTests: XCTestCase {

    // MARK: - 纯数字序列号脱敏测试 (4 位脱敏)
    func testMaskSerialNumber() {
        // 7 位尼康主流机身号：前 2 位 + **** + 后 1 位
        XCTAssertEqual(CameraDevice.maskSerialNumber("7001234"), "70****4")
        XCTAssertEqual(CameraDevice.maskSerialNumber("2001234"), "20****4")

        // 6 位机身号：前 1 位 + **** + 后 1 位
        XCTAssertEqual(CameraDevice.maskSerialNumber("123456"), "1****6")

        // 8 位机身号：前 2 位 + **** + 后 2 位
        XCTAssertEqual(CameraDevice.maskSerialNumber("12345678"), "12****78")

        // 4 位机身号：全部替换为 ****
        XCTAssertEqual(CameraDevice.maskSerialNumber("1234"), "****")

        // 5 位机身号：前 1 位 + ****
        XCTAssertEqual(CameraDevice.maskSerialNumber("12345"), "1****")

        // 小于 4 位：全部打码
        XCTAssertEqual(CameraDevice.maskSerialNumber("123"), "***")
        XCTAssertEqual(CameraDevice.maskSerialNumber(""), "")
    }

    // MARK: - 相机名称脱敏测试 (针对型号_序列号)
    func testMaskCameraName() {
        // 尼康常见型号带下划线/空格序列号
        XCTAssertEqual(CameraDevice.maskName("Z6_3_7001234"), "Z6_3_70****4")
        XCTAssertEqual(CameraDevice.maskName("Nikon Z6_3_7001234"), "Nikon Z6_3_70****4")
        XCTAssertEqual(CameraDevice.maskName("NIKON Z 8_1234567"), "NIKON Z 8_12****7")
        XCTAssertEqual(CameraDevice.maskName("Z 50_2_2001234"), "Z 50_2_20****4")
        XCTAssertEqual(CameraDevice.maskName("Z9_6001234"), "Z9_60****4")
        XCTAssertEqual(CameraDevice.maskName("D850_1234567"), "D850_12****7")

        // 纯数字名称
        XCTAssertEqual(CameraDevice.maskName("7001234"), "70****4")

        // 无序列号或纯型号名称保持不变
        XCTAssertEqual(CameraDevice.maskName("NIKON Z 9"), "NIKON Z 9")
        XCTAssertEqual(CameraDevice.maskName("尼康相机"), "尼康相机")
        XCTAssertEqual(CameraDevice.maskName(""), "")
        XCTAssertEqual(CameraDevice.maskName(nil), "")
    }

    // MARK: - 模型层 displayName 计算属性测试
    func testCameraDeviceDisplayName() {
        let cam = CameraDevice(name: "Z6_3_7001234", deviceID: 0x7001234)
        // 原始 name 保持不变用于底层匹配
        XCTAssertEqual(cam.name, "Z6_3_7001234")
        // UI 显示使用脱敏名称
        XCTAssertEqual(cam.displayName, "Z6_3_70****4")
    }

    // MARK: - 日志正文中的序列号自动脱敏测试
    func testMaskTextInLogMessages() {
        // 1. 发现相机广播
        let log1 = "发现相机广播: [Z6_3_7001234] (RSSI: -82 dBm) 📡"
        XCTAssertEqual(CameraDevice.maskText(log1), "发现相机广播: [Z6_3_70****4] (RSSI: -82 dBm) 📡")

        // 2. 快门唤醒广播
        let log2 = "[Nikon Z6_3_7001234] 📷 捕获到快门唤醒广播 (0x1C 就绪)，正在极速秒连..."
        XCTAssertEqual(CameraDevice.maskText(log2), "[Nikon Z6_3_70****4] 📷 捕获到快门唤醒广播 (0x1C 就绪)，正在极速秒连...")

        // 3. 配对成功
        let log3 = "已成功配对并保存相机: Z6_3_7001234 📷"
        XCTAssertEqual(CameraDevice.maskText(log3), "已成功配对并保存相机: Z6_3_70****4 📷")

        // 4. 系统预连
        let log4 = "检测到系统已预连相机: Z6_3_7001234 📷，正在无缝激活同步链路..."
        XCTAssertEqual(CameraDevice.maskText(log4), "检测到系统已预连相机: Z6_3_70****4 📷，正在无缝激活同步链路...")

        // 5. 坐标、十六进制 DeviceID、时区、状态码防误伤校验
        let complexLog = "相机 Z6_3_7001234 同步坐标: 39.908721, 116.397488, DeviceID: 0x7001234, 累计 1 次, 状态: 0x1C"
        let maskedComplex = CameraDevice.maskText(complexLog)
        XCTAssertTrue(maskedComplex.contains("Z6_3_70****4"))
        XCTAssertTrue(maskedComplex.contains("39.908721, 116.397488"), "经纬度绝不能被误伤脱敏")
        XCTAssertTrue(maskedComplex.contains("0x7001234"), "十六进制 DeviceID 绝不能被误伤脱敏")
        XCTAssertTrue(maskedComplex.contains("0x1C"), "十六进制状态字节绝不能被误伤脱敏")
    }

    // MARK: - SyncLogItem 自动脱敏闭环测试
    func testSyncLogItemAutoMasking() {
        let item = SyncLogItem(
            level: .info,
            message: "发现相机广播: [Z6_3_7001234]",
            cameraName: "Z6_3_7001234"
        )
        XCTAssertEqual(item.message, "发现相机广播: [Z6_3_70****4]")
        XCTAssertEqual(item.cameraName, "Z6_3_70****4")
    }
}
