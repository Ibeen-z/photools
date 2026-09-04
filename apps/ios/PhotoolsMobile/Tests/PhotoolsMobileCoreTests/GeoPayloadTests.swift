import XCTest
import CoreLocation
@testable import PhotoolsMobileCore

final class GeoPayloadTests: XCTestCase {
    func testGeoPayloadEncodingLengthAndStructure() {
        // 比如北京坐标：39.9042° N, 116.4074° E, 海拔 45m
        let payload = GeoPayload(
            latitude: 39.9042,
            longitude: 116.4074,
            altitude: 45.0,
            satellites: 9,
            isValid: true
        )

        let encoded = payload.encode()
        XCTAssertEqual(encoded.count, 41, "尼康 GEO 报文长度必须恒为 41 字节")

        // 验证 Header: 0x007F 小端序 -> [0x7F, 0x00]
        XCTAssertEqual(encoded[0], 0x7F)
        XCTAssertEqual(encoded[1], 0x00)

        // 验证纬度方向: 'N' (0x4E)
        XCTAssertEqual(encoded[2], 0x4E)
        XCTAssertEqual(encoded[3], 39) // 39度

        // 验证经度方向: 'E' (0x45)
        XCTAssertEqual(encoded[7], 0x45)
        XCTAssertEqual(encoded[8], 116) // 116度

        // 验证卫星数与高度方向: 'P' (0x50: 正海拔)
        XCTAssertEqual(encoded[12], 9)
        XCTAssertEqual(encoded[13], 0x50)

        // 验证 valid 标识
        XCTAssertEqual(encoded[24], 0x01)

        // 验证 "WGS-84" 标识 (Offset 25..31)
        let wgsData = encoded.subdata(in: 25..<31)
        XCTAssertEqual(String(data: wgsData, encoding: .ascii), "WGS-84")

        // 验证 10 字节 padding 为 0 (Offset 31..41)
        let padding = encoded.subdata(in: 31..<41)
        XCTAssertEqual(padding, Data(repeating: 0x00, count: 10))
    }

    func testNegativeCoordinatesAndAltitude() {
        // 南半球西经与负海拔：-33.8688° S, -151.2093° W, 海拔 -12m
        let payload = GeoPayload(
            latitude: -33.8688,
            longitude: -151.2093,
            altitude: -12.0,
            satellites: 6,
            isValid: true
        )

        let encoded = payload.encode()
        XCTAssertEqual(encoded[2], 0x53, "南纬必须为 'S'")
        XCTAssertEqual(encoded[3], 33)
        XCTAssertEqual(encoded[7], 0x57, "西经必须为 'W'")
        XCTAssertEqual(encoded[8], 151)
        XCTAssertEqual(encoded[13], 0x4D, "负海拔必须为 'M'")

        // 海拔绝对值小端序: 12 -> [0x0C, 0x00]
        XCTAssertEqual(encoded[14], 0x0C)
        XCTAssertEqual(encoded[15], 0x00)
    }

    func testInvalidFixPayload() {
        let invalid = GeoPayload.makeInvalidPayload()
        let encoded = invalid.encode()
        XCTAssertEqual(encoded.count, 41)
        XCTAssertEqual(encoded[24], 0x00, "无效位置的 valid 标识必须为 0x00")
    }

    func testStaleLocationTimestampAutoAlignedToCurrentDate() {
        // 模拟两小时前的历史旧坐标 (如 7200 秒前)
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        let clLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 20.0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            timestamp: twoHoursAgo
        )
        let payload = GeoPayload(location: clLoc)
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nowYear = UInt16(calendar.component(.year, from: now))
        let nowHour = UInt8(calendar.component(.hour, from: now))

        XCTAssertEqual(payload.year, nowYear)
        XCTAssertEqual(payload.hour, nowHour, "陈旧时间戳必须自动对齐至当前时刻 UTC 小时，杜绝相机 ATT 0x80 拒写")
    }
}

