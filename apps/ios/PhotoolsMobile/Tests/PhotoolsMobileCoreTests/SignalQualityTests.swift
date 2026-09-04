import XCTest
@testable import PhotoolsMobileCore

final class SignalQualityTests: XCTestCase {

    // MARK: - GPS 信号质量分级测试
    func testGPSFixQualityThresholds() {
        // 无效/未定位
        XCTAssertEqual(GPSFixQuality.from(accuracy: -1.0), .invalid)
        XCTAssertEqual(GPSFixQuality.invalid.signalBars, 0)
        XCTAssertEqual(GPSFixQuality.invalid.title, "失锁")

        // 极佳 (<= 5m, 5格)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 0.0), .excellent)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 3.5), .excellent)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 5.0), .excellent)
        XCTAssertEqual(GPSFixQuality.excellent.signalBars, 5)
        XCTAssertEqual(GPSFixQuality.excellent.title, "极佳")

        // 良好 (5m ~ 15m, 4格)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 5.1), .good)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 10.0), .good)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 15.0), .good)
        XCTAssertEqual(GPSFixQuality.good.signalBars, 4)

        // 一般 (15m ~ 35m, 3格)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 15.1), .moderate)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 25.0), .moderate)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 35.0), .moderate)
        XCTAssertEqual(GPSFixQuality.moderate.signalBars, 3)

        // 较弱 (35m ~ 65m, 2格)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 35.1), .weak)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 50.0), .weak)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 65.0), .weak)
        XCTAssertEqual(GPSFixQuality.weak.signalBars, 2)

        // 极弱 (> 65m, 1格)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 65.1), .poor)
        XCTAssertEqual(GPSFixQuality.from(accuracy: 120.0), .poor)
        XCTAssertEqual(GPSFixQuality.poor.signalBars, 1)
    }

    func testLocationSnapshotFixQualityIntegration() {
        let accurateLoc = LocationSnapshot(
            latitude: 39.9042,
            longitude: 116.4074,
            altitude: 45.0,
            accuracy: 4.2
        )
        XCTAssertEqual(accurateLoc.fixQuality, .excellent)
        XCTAssertEqual(accurateLoc.fixQuality.signalBars, 5)

        let degradedLoc = LocationSnapshot(
            latitude: 39.9042,
            longitude: 116.4074,
            altitude: 45.0,
            accuracy: 42.0
        )
        XCTAssertEqual(degradedLoc.fixQuality, .weak)
        XCTAssertEqual(degradedLoc.fixQuality.signalBars, 2)
    }

    // MARK: - 蓝牙无线链路 RSSI 质量测试 (负数越接近 0 信号越好)
    func testBLESignalQualityThresholds() {
        // 极强 (>= -60 dBm, 贴身近距离)
        XCTAssertEqual(BLESignalQuality.from(rssi: -45), .excellent)
        XCTAssertEqual(BLESignalQuality.from(rssi: -60), .excellent)
        XCTAssertEqual(BLESignalQuality.excellent.bars, 4)
        XCTAssertEqual(BLESignalQuality.excellent.title, "极强")

        // 良好 (-61 ~ -75 dBm, 正常拍摄距离)
        XCTAssertEqual(BLESignalQuality.from(rssi: -61), .good)
        XCTAssertEqual(BLESignalQuality.from(rssi: -70), .good)
        XCTAssertEqual(BLESignalQuality.from(rssi: -75), .good)
        XCTAssertEqual(BLESignalQuality.good.bars, 3)
        XCTAssertEqual(BLESignalQuality.good.title, "良好")

        // 一般 (-76 ~ -85 dBm, 隔背包或阻挡)
        XCTAssertEqual(BLESignalQuality.from(rssi: -76), .fair)
        XCTAssertEqual(BLESignalQuality.from(rssi: -80), .fair)
        XCTAssertEqual(BLESignalQuality.from(rssi: -85), .fair)
        XCTAssertEqual(BLESignalQuality.fair.bars, 2)
        XCTAssertEqual(BLESignalQuality.fair.title, "一般")

        // 微弱 (< -85 dBm, 濒临断连)
        XCTAssertEqual(BLESignalQuality.from(rssi: -86), .poor)
        XCTAssertEqual(BLESignalQuality.from(rssi: -95), .poor)
        XCTAssertEqual(BLESignalQuality.poor.bars, 1)
        XCTAssertEqual(BLESignalQuality.poor.title, "微弱")

        // 描述格式化输出验证
        XCTAssertEqual(BLESignalQuality.excellent.formattedDescription(rssi: -55), "-55 dBm (极强)")
        XCTAssertEqual(BLESignalQuality.poor.formattedDescription(rssi: -90), "-90 dBm (微弱)")
    }
}
