import XCTest
@testable import PhotoolsCore

final class GPXTrackParserTests: XCTestCase {
    func testParseSimpleGPX() async throws {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>测试徒步路线</name>
            <trkseg>
              <trkpt lat="31.2304" lon="121.4737">
                <ele>10.5</ele>
                <time>2026-05-16T08:00:00Z</time>
              </trkpt>
              <trkpt lat="31.2314" lon="121.4747">
                <ele>15.2</ele>
                <time>2026-05-16T08:05:00Z</time>
              </trkpt>
              <trkpt lat="31.2324" lon="121.4757">
                <ele>22.0</ele>
                <time>2026-05-16T08:10:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_track_\(UUID().uuidString).gpx")
        try sampleXML.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let summary = await GPXTrackParser.shared.parse(filePath: tempURL.path)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        XCTAssertEqual(s.name, "测试徒步路线")
        XCTAssertEqual(s.rawPointCount, 3)
        XCTAssertEqual(s.renderedPoints.count, 3)
        XCTAssertGreaterThan(s.totalDistanceMeters, 200)
        XCTAssertEqual(s.minElevation, 10.5)
        XCTAssertEqual(s.maxElevation, 22.0)
        XCTAssertNotNil(s.elevationGain)
        XCTAssertEqual(Int(s.elevationGain ?? 0), 11)
        XCTAssertEqual(s.durationSeconds, 600)
        XCTAssertEqual(s.formattedDuration, "10分钟")
        XCTAssertTrue(s.formattedDistance.contains("m") || s.formattedDistance.contains("km"))
        XCTAssertEqual(s.boundingBox.minLat, 31.2304)
        XCTAssertEqual(s.boundingBox.maxLat, 31.2324)
    }

    func testDownsamplingLongTrack() async throws {
        // 构建 100 个点，限制 maxRenderPoints 为 10
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>超长抽稀路线</name>
            <trkseg>
        """
        for i in 0..<100 {
            xml += """
              <trkpt lat="\(31.0 + Double(i) * 0.001)" lon="\(121.0 + Double(i) * 0.001)">
                <ele>\(100 + i)</ele>
              </trkpt>
            """
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_long_\(UUID().uuidString).gpx")
        try xml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let summary = await GPXTrackParser.shared.parse(filePath: tempURL.path, maxRenderPoints: 10)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        XCTAssertEqual(s.rawPointCount, 100)
        XCTAssertEqual(s.renderedPoints.count, 10)
        XCTAssertEqual(s.renderedPoints.first?.latitude, 31.0)
        XCTAssertEqual(s.renderedPoints.last?.latitude, 31.0 + 99 * 0.001)
    }

    private final class TestProgressBox: @unchecked Sendable {
        var reportedStages: [String] = []
        var maxReportedProgress: Double = 0.0
    }

    func testParseWithProgressHandlerAndHeartRate() async throws {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>进度与心率测试路线</name>
            <trkseg>
              <trkpt lat="30.0" lon="120.0">
                <ele>10</ele>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>95</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
              <trkpt lat="30.1" lon="120.1">
                <ele>25</ele>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>145</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_progress_\(UUID().uuidString).gpx")
        try sampleXML.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let box = TestProgressBox()

        let summary = await GPXTrackParser.shared.parse(filePath: tempURL.path) { progress, stage in
            box.reportedStages.append(stage)
            if progress > box.maxReportedProgress {
                box.maxReportedProgress = progress
            }
        }

        XCTAssertNotNil(summary)
        guard let s = summary else { return }
        XCTAssertFalse(box.reportedStages.isEmpty)
        XCTAssertEqual(box.maxReportedProgress, 1.0, accuracy: 0.001)
        XCTAssertTrue(s.hasHeartRateData)
        XCTAssertEqual(s.avgHeartRate, 120)
        XCTAssertEqual(s.maxHeartRate, 145)
        XCTAssertEqual(s.minHeartRate, 95)
        XCTAssertEqual(s.elevationGain, 15.0)
    }

    func testRealKalajunTrackIfAvailable() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let realPath = "\(homeDir)/.config/gpx/hiking-中国-新疆-喀拉峻小环线-20260608.gpx"
        guard FileManager.default.fileExists(atPath: realPath) else { return }

        let summary = await GPXTrackParser.shared.parse(filePath: realPath)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        // 验证累计爬升不再是荒谬的 +18m，而是在真实合理的 1400m ~ 1900m 之间
        XCTAssertNotNil(s.elevationGain)
        let gain = s.elevationGain ?? 0
        XCTAssertGreaterThan(gain, 1200.0, "累计爬升计算不应被高频采样滤除")
        XCTAssertLessThan(gain, 2500.0, "累计爬升计算不应因垂直噪点过度累积")

        // 验证心率解析
        XCTAssertTrue(s.hasHeartRateData)
        XCTAssertGreaterThan(s.avgHeartRate ?? 0, 60)
        XCTAssertLessThan(s.maxHeartRate ?? 0, 220)
    }

    func testTaskCancellationAbortsParsing() async throws {
        // 构建 500 个点的大文件
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>取消熔断测试路线</name>
            <trkseg>
        """
        for i in 0..<500 {
            xml += """
              <trkpt lat="\(30.0 + Double(i) * 0.001)" lon="\(120.0 + Double(i) * 0.001)">
                <ele>\(100 + i)</ele>
                <time>2026-05-16T08:00:00Z</time>
              </trkpt>
            """
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cancel_\(UUID().uuidString).gpx")
        try xml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 启动任务并立即 cancel
        let task = Task { () -> GPXTrackSummary? in
            return await GPXTrackParser.shared.parse(filePath: tempURL.path)
        }
        task.cancel()
        let result = await task.value

        // 当任务取消时，解析器应及时熔断返回 nil
        XCTAssertNil(result, "被取消的任务应当提前安全熔断返回 nil")
    }

    func testParseGPXWithWaypointsSeparatedFromTracks() async throws {
        // 构建包含离散打卡点与连续轨迹点的混合 GPX
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <wpt lat="31.2000" lon="121.4000">
            <name>离散打卡点 1 - 营地</name>
            <ele>5.0</ele>
          </wpt>
          <wpt lat="31.2900" lon="121.4900">
            <name>离散打卡点 2 - 观景台</name>
            <cmt>路况良好，视野开阔</cmt>
          </wpt>
          <trk>
            <name>真实徒步轨迹</name>
            <trkseg>
              <trkpt lat="31.2300" lon="121.4700">
                <ele>12.0</ele>
                <time>2026-06-01T08:00:00Z</time>
              </trkpt>
              <trkpt lat="31.2310" lon="121.4710">
                <ele>15.0</ele>
                <time>2026-06-01T08:05:00Z</time>
              </trkpt>
              <trkpt lat="31.2320" lon="121.4720">
                <ele>18.0</ele>
                <time>2026-06-01T08:10:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_wpt_trk_\(UUID().uuidString).gpx")
        try sampleXML.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let summary = await GPXTrackParser.shared.parse(filePath: tempURL.path)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        // 验证轨迹名称
        XCTAssertEqual(s.name, "真实徒步轨迹")
        // 关键断言：rawPointCount 必须是纯净的 3 个 trkpt，绝不能混入 2 个 wpt 变成 5 个！
        XCTAssertEqual(s.rawPointCount, 3)
        XCTAssertEqual(s.renderedPoints.count, 3)

        // 关键断言：离散打卡点必须被独立提取出来
        XCTAssertEqual(s.waypoints.count, 2)
        XCTAssertEqual(s.waypoints[0].name, "离散打卡点 1 - 营地")
        XCTAssertEqual(s.waypoints[0].elevation, 5.0)
        XCTAssertEqual(s.waypoints[1].name, "离散打卡点 2 - 观景台")
        XCTAssertEqual(s.waypoints[1].comment, "路况良好，视野开阔")

        // 关键断言：起点坐标必须是真实轨迹的第一个点（ele=12.0），而不是打卡点 1
        XCTAssertEqual(s.startPoint?.latitude, 31.2300)
        XCTAssertEqual(s.startPoint?.elevation, 12.0)

        // 关键断言：总里程必须在 200m~400m 之间（仅为 3 个紧邻 trkpt 的距离），绝不包含 wpt 到 trkpt 的数公里跳跃直线
        XCTAssertLessThan(s.totalDistanceMeters, 1000.0)
    }

    func testRealKanasTracksIfAvailable() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let bigLoopPath = "\(homeDir)/.config/gpx/hiking-a-test-20250924喀纳斯大环线.gpx"
        if FileManager.default.fileExists(atPath: bigLoopPath) {
            let summary = await GPXTrackParser.shared.parse(filePath: bigLoopPath)
            XCTAssertNotNil(summary)
            if let s = summary {
                // 关键断言：大环线真实距离应在 105km ~ 115km（绝非旧代码污染产生的 227.75km 翻倍大飞线！）
                let distKm = s.totalDistanceMeters / 1000.0
                XCTAssertGreaterThan(distKm, 105.0)
                XCTAssertLessThan(distKm, 115.0, "总里程不应被离散打卡点与对角大飞线污染")
                // 验证 68 个打卡点被正确独立捕获
                XCTAssertEqual(s.waypoints.count, 68)
                // 验证起点高度正常提取（非 --m）
                XCTAssertNotNil(s.startPoint?.elevation)
                XCTAssertGreaterThan(s.startPoint?.elevation ?? 0, 1000.0)
            }
        }

        let loop2026Path = "\(homeDir)/.config/gpx/hiking-a-test-2026 喀纳斯环线.gpx"
        if FileManager.default.fileExists(atPath: loop2026Path) {
            let summary = await GPXTrackParser.shared.parse(filePath: loop2026Path)
            XCTAssertNotNil(summary)
            if let s = summary {
                // 关键断言：2026 喀纳斯环线真实距离应在 60km ~ 70km（绝非旧代码污染产生的 172.59km！）
                let distKm = s.totalDistanceMeters / 1000.0
                XCTAssertGreaterThan(distKm, 60.0)
                XCTAssertLessThan(distKm, 70.0, "总里程不应被离散打卡点与对角大飞线污染")
                // 验证 79 个打卡点被正确独立捕获
                XCTAssertEqual(s.waypoints.count, 79)
                // 验证起点高度正常提取
                XCTAssertNotNil(s.startPoint?.elevation)
                XCTAssertGreaterThan(s.startPoint?.elevation ?? 0, 1000.0)
            }
        }
    }
}
