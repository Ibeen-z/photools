import XCTest
@testable import PhotoolsMobileCore

final class TimePayloadTests: XCTestCase {
    func testTimePayloadEncodingAndDecoding() {
        let payload = TimePayload(
            year: 2026,
            month: 10,
            day: 12,
            hour: 8,
            minute: 30,
            second: 45,
            dstOffset: 0,
            tzOffsetHours: 8,
            tzOffsetMinutes: 0
        )

        let encoded = payload.encode()
        XCTAssertEqual(encoded.count, 10, "时间报文长度必须恒为 10 字节")

        // 验证年份小端序: 2026 = 0x07EA -> [0xEA, 0x07]
        XCTAssertEqual(encoded[0], 0xEA)
        XCTAssertEqual(encoded[1], 0x07)
        XCTAssertEqual(encoded[2], 10)
        XCTAssertEqual(encoded[3], 12)
        XCTAssertEqual(encoded[4], 8)
        XCTAssertEqual(encoded[5], 30)
        XCTAssertEqual(encoded[6], 45)
        XCTAssertEqual(encoded[7], 0)
        XCTAssertEqual(Int8(bitPattern: encoded[8]), 8)
        XCTAssertEqual(Int8(bitPattern: encoded[9]), 0)

        // 反序列化校验
        guard let decoded = TimePayload(data: encoded) else {
            XCTFail("无法解析编码后的时间报文")
            return
        }

        XCTAssertEqual(decoded, payload)
    }

    func testNegativeTimeZoneOffset() {
        let payload = TimePayload(
            year: 2026,
            month: 1,
            day: 1,
            hour: 12,
            minute: 0,
            second: 0,
            dstOffset: 1,
            tzOffsetHours: -5,
            tzOffsetMinutes: 0
        )

        let encoded = payload.encode()
        guard let decoded = TimePayload(data: encoded) else {
            XCTFail("无法解析负时区报文")
            return
        }

        XCTAssertEqual(decoded.tzOffsetHours, -5)
        XCTAssertEqual(decoded.dstOffset, 1)
    }
}
