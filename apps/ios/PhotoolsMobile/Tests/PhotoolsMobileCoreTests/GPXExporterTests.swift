import XCTest
@testable import PhotoolsMobileCore

final class GPXExporterTests: XCTestCase {

    func testGPX11XMLValidStructure() {
        let startTime = Date(timeIntervalSince1970: 1776000000) // 固定时间
        let session = GPXTrackSession(
            sessionName: "喀拉峻草原&雪山摄影",
            startTime: startTime,
            gpxFileName: "Track_20260412_132000.gpx"
        )

        let points = [
            GPXRecordedPoint(
                latitude: 43.123456,
                longitude: 82.654321,
                elevation: 2150.5,
                timestamp: startTime,
                horizontalAccuracy: 5.0,
                speed: 1.5,
                course: 90.0
            ),
            GPXRecordedPoint(
                latitude: 43.123500,
                longitude: 82.654400,
                elevation: 2155.0,
                timestamp: startTime.addingTimeInterval(10),
                horizontalAccuracy: 4.5,
                speed: 1.8,
                course: 95.0
            )
        ]

        let xml = GPXExporter.export(session: session, points: points)

        // 断言 XML 头与合法根节点
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<gpx version=\"1.1\" creator=\"NikonGPS for iOS\""))
        XCTAssertTrue(xml.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        XCTAssertTrue(xml.contains("http://www.topografix.com/GPX/1/1/gpx.xsd"))

        // 断言元数据
        XCTAssertTrue(xml.contains("<name>喀拉峻草原&amp;雪山摄影</name>"))
        XCTAssertTrue(xml.contains("<desc>NikonGPS for iOS 摄影巡航轨迹记录</desc>"))

        // 断言点位
        XCTAssertTrue(xml.contains("<trkpt lat=\"43.123456\" lon=\"82.654321\">"))
        XCTAssertTrue(xml.contains("<ele>2150.50</ele>"))
        XCTAssertTrue(xml.contains("<speed>1.50</speed>"))
        XCTAssertTrue(xml.contains("<course>90.0</course>"))
        XCTAssertTrue(xml.contains("<hdop>5.0</hdop>"))

        // 断言闭合标签
        XCTAssertTrue(xml.contains("</trkseg>"))
        XCTAssertTrue(xml.contains("</trk>"))
        XCTAssertTrue(xml.contains("</gpx>"))
    }

    func testISO8601UTCTimeFormatting() {
        // 验证不论当前机器处于什么本地时区，GPX 中的时间必须是 UTC 零时区且以 Z 结尾
        let fixedUTC = Date(timeIntervalSince1970: 1774408557) // 对应 2026-03-25T03:15:57Z
        let session = GPXTrackSession(
            sessionName: "时区测试",
            startTime: fixedUTC,
            gpxFileName: "test.gpx"
        )
        let pt = GPXRecordedPoint(
            latitude: 23.0,
            longitude: 113.0,
            elevation: 10.0,
            timestamp: fixedUTC
        )

        let xml = GPXExporter.export(session: session, points: [pt])
        XCTAssertTrue(xml.contains("<time>2026-03-25T03:15:57Z</time>"))
    }

    func testXMLEscaping() {
        let raw = "<Nikon> \"Z6 III\" & 'Z8' >"
        let escaped = GPXExporter.escapeXML(raw)
        XCTAssertEqual(escaped, "&lt;Nikon&gt; &quot;Z6 III&quot; &amp; &apos;Z8&apos; &gt;")
    }

    func testDistanceCalculationHaversine() {
        // 北京天安门 (39.9087, 116.3975) 到 王府井 (39.9142, 116.4116)
        let p1 = GPXRecordedPoint(latitude: 39.9087, longitude: 116.3975)
        let p2 = GPXRecordedPoint(latitude: 39.9142, longitude: 116.4116)

        let dist = p1.distance(to: p2)
        // 距离约在 1300 米 ~ 1400 米区间
        XCTAssertGreaterThan(dist, 1300)
        XCTAssertLessThan(dist, 1400)
    }

    func testNegativeCoordinatesAndMissingElevation() {
        let session = GPXTrackSession(sessionName: "南美与大洋洲", gpxFileName: "test.gpx")
        let pt = GPXRecordedPoint(
            latitude: -33.8688,
            longitude: -70.6693,
            elevation: nil,
            timestamp: Date(),
            horizontalAccuracy: 10.0
        )
        let xml = GPXExporter.export(session: session, points: [pt])
        XCTAssertTrue(xml.contains("<trkpt lat=\"-33.868800\" lon=\"-70.669300\">"))
        XCTAssertFalse(xml.contains("<ele>")) // 无海拔时不应出现空 ele 标签
    }

    /// 校验万级轨迹点大规模流式分块写盘正确性与毫秒级极速性能
    func testExportStreamLargeDatasetPerformance() throws {
        let count = 10000
        let startTime = Date(timeIntervalSince1970: 1776000000)
        let session = GPXTrackSession(
            sessionName: "超长摄影巡航10000点压测",
            startTime: startTime,
            gpxFileName: "Track_StressTest.gpx"
        )

        var points: [GPXRecordedPoint] = []
        points.reserveCapacity(count)
        for i in 0..<count {
            let pt = GPXRecordedPoint(
                latitude: 31.0 + Double(i) * 0.0001,
                longitude: 121.0 + Double(i) * 0.0001,
                elevation: 50.0 + Double(i % 100),
                timestamp: startTime.addingTimeInterval(Double(i)),
                horizontalAccuracy: 4.0,
                speed: 1.5,
                course: 90.0
            )
            points.append(pt)
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Track_StressTest_\(UUID().uuidString).gpx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let t0 = CFAbsoluteTimeGetCurrent()
        try GPXExporter.exportStream(session: session, points: points, to: tempURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // 校验生成的文件存在且具备合法结构
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        // 10000 点约 2.2MB 左右
        XCTAssertGreaterThan(fileSize, 2_000_000, "10000 点 GPX 大小应在 2MB 以上")

        // 性能断言：10000 点流式写入耗时必须 < 0.25 秒（此前 DateFormatter 需要 2 秒以上）
        XCTAssertLessThan(elapsed, 0.25, "10000 点流式生成与落盘耗时应在 250ms 以内，实际耗时: \(elapsed)s")
    }
}
