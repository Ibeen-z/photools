import XCTest
@testable import PhotoolsMobileCore

final class FastTimeFormatterTests: XCTestCase {

    func testStandardUTCFormatting() {
        // 2026-04-12 13:20:00 UTC (1776000000)
        let date = Date(timeIntervalSince1970: 1776000000)
        let str = FastTimeFormatter.formatUTCISO8601(date: date)
        XCTAssertEqual(str, "2026-04-12T13:20:00Z")
    }

    func testMidnightAndNewYearFormatting() {
        // 2026-01-01 00:00:00 UTC
        let date = Date(timeIntervalSince1970: 1767225600)
        let str = FastTimeFormatter.formatUTCISO8601(date: date)
        XCTAssertEqual(str, "2026-01-01T00:00:00Z")
    }

    func testBufferAppendEquivalence() {
        let date = Date(timeIntervalSince1970: 1774408557)
        var buffer = Data()
        FastTimeFormatter.appendUTCISO8601(date: date, to: &buffer)

        let strFromBuffer = String(data: buffer, encoding: .utf8)
        let directStr = FastTimeFormatter.formatUTCISO8601(date: date)

        XCTAssertEqual(strFromBuffer, directStr)
        XCTAssertEqual(strFromBuffer, "2026-03-25T03:15:57Z")
    }

    func testComparisonWithDateFormatter() {
        let testDates: [TimeInterval] = [
            0,                  // 1970-01-01T00:00:00Z
            1609459200,         // 2021-01-01T00:00:00Z
            1776000000,         // 2026-04-12T13:20:00Z
            1788000000,         // 2026-08-29T10:40:00Z
            2000000000          // 2033-05-18T03:33:20Z
        ]

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        for t in testDates {
            let date = Date(timeIntervalSince1970: t)
            let standard = df.string(from: date)
            let fast = FastTimeFormatter.formatUTCISO8601(date: date)
            XCTAssertEqual(fast, standard, "对于时间戳 \(t)，FastTimeFormatter 必须与 DateFormatter 输出完全一致")
        }
    }
}
