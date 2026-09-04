import XCTest
@testable import PhotoolsMobileCore

@MainActor
final class GPXRecorderTests: XCTestCase {

    override func setUp() async throws {
        // 清理当前测试状态
        let service = GPXRecorderService.shared
        if service.isRecording {
            service.stopSession(flushSync: true)
        }
        service.flushPendingWritesSync()
        for s in service.recordedSessions {
            service.deleteSession(s)
        }
        service.flushPendingWritesSync()
        let dir = service.tracksDirectoryURL
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("active_session_snapshot.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("active_session_meta.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("active_points.wal"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("active_points.bin"))
    }

    func testSessionStartAndStopLifecycle() {
        let service = GPXRecorderService.shared
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.currentSession)

        // 1. 开启巡航录制
        service.startSession()
        XCTAssertTrue(service.isRecording)
        XCTAssertNotNil(service.currentSession)
        XCTAssertEqual(service.currentPoints.count, 0)

        // 2. 注入有效机位点
        let t0 = Date()
        let pt1 = GPXRecordedPoint(
            latitude: 31.2304,
            longitude: 121.4737,
            elevation: 10.0,
            timestamp: t0,
            horizontalAccuracy: 5.0
        )
        service.recordPoint(pt1)
        XCTAssertEqual(service.currentPoints.count, 1)

        // 3. 注入相距 100 米的第二个机位点
        let pt2 = GPXRecordedPoint(
            latitude: 31.2313,
            longitude: 121.4737,
            elevation: 15.0,
            timestamp: t0.addingTimeInterval(20),
            horizontalAccuracy: 5.0
        )
        service.recordPoint(pt2)
        XCTAssertEqual(service.currentPoints.count, 2)
        XCTAssertGreaterThan(service.currentSession?.totalDistanceMeters ?? 0, 50.0)
        XCTAssertEqual(service.currentSession?.elevationGain ?? 0, 5.0)

        // 4. 停止巡航录制 (同步等待落盘以便立即断言物理文件)
        let savedSession = service.stopSession(flushSync: true)
        XCTAssertFalse(service.isRecording)
        XCTAssertNotNil(savedSession)
        XCTAssertEqual(savedSession?.pointCount, 2)
        XCTAssertTrue(savedSession?.isCompleted ?? false)

        // 5. 校验物理文件落盘
        if let session = savedSession {
            let fileURL = service.gpxFileURL(for: session)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            let content = try? String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertNotNil(content)
            XCTAssertTrue(content!.contains("<gpx version=\"1.1\""))
            XCTAssertTrue(content!.contains("<trkpt lat=\"31.230400\" lon=\"121.473700\">"))

            // 清理
            service.deleteSession(session)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testInaccuratePointsAreFiltered() {
        let service = GPXRecorderService.shared
        service.startSession()

        // 精度为 80 米 (超过 50 米门限)
        let badPoint = GPXRecordedPoint(
            latitude: 31.0,
            longitude: 121.0,
            elevation: 10.0,
            timestamp: Date(),
            horizontalAccuracy: 80.0
        )
        service.recordPoint(badPoint)
        XCTAssertEqual(service.currentPoints.count, 0, "超限精度点位必须被过滤")

        // 合法点位 (精度 10 米)
        let goodPoint = GPXRecordedPoint(
            latitude: 31.0,
            longitude: 121.0,
            elevation: 10.0,
            timestamp: Date(),
            horizontalAccuracy: 10.0
        )
        service.recordPoint(goodPoint)
        XCTAssertEqual(service.currentPoints.count, 1, "有效精度点位应成功记录")

        service.stopSession()
    }

    func testStationaryDriftFiltering() {
        let service = GPXRecorderService.shared
        service.startSession()

        let baseTime = Date()
        let p1 = GPXRecordedPoint(
            latitude: 39.9042,
            longitude: 116.4074,
            elevation: 50.0,
            timestamp: baseTime,
            horizontalAccuracy: 5.0
        )
        service.recordPoint(p1)
        XCTAssertEqual(service.currentPoints.count, 1)

        // 5 秒后原地微动 1 米 (位移 < 3m 且时间 < 15s)
        let p2 = GPXRecordedPoint(
            latitude: 39.904205,
            longitude: 116.407405,
            elevation: 50.0,
            timestamp: baseTime.addingTimeInterval(5),
            horizontalAccuracy: 5.0
        )
        service.recordPoint(p2)
        XCTAssertEqual(service.currentPoints.count, 1, "静止微抖动点位必须被过滤以防蜘蛛网噪点")

        // 20 秒后心跳采样 (虽然微动，但已超过 15 秒心跳保活间隔)
        let p3 = GPXRecordedPoint(
            latitude: 39.904205,
            longitude: 116.407405,
            elevation: 50.0,
            timestamp: baseTime.addingTimeInterval(20),
            horizontalAccuracy: 5.0
        )
        service.recordPoint(p3)
        XCTAssertEqual(service.currentPoints.count, 2, "超时心跳点位应被记录以维持时间轴连续")

        service.stopSession()
    }

    func testBatchDeleteSessionsAtOffsets() {
        let service = GPXRecorderService.shared
        // 模拟生成两条轨迹
        service.startSession()
        let pt1 = GPXRecordedPoint(latitude: 30.0, longitude: 120.0, timestamp: Date(), horizontalAccuracy: 5.0)
        service.recordPoint(pt1)
        guard let s1 = service.stopSession() else {
            XCTFail("停止会话应返回有效会话")
            return
        }

        service.startSession()
        let pt2 = GPXRecordedPoint(latitude: 30.1, longitude: 120.1, timestamp: Date(), horizontalAccuracy: 5.0)
        service.recordPoint(pt2)
        guard let s2 = service.stopSession() else {
            XCTFail("停止会话应返回有效会话")
            return
        }

        XCTAssertTrue(service.recordedSessions.contains(where: { $0.id == s1.id }))
        XCTAssertTrue(service.recordedSessions.contains(where: { $0.id == s2.id }))

        // 批量删除第 0 条
        service.deleteSessions(at: IndexSet(integer: 0))
        XCTAssertEqual(service.recordedSessions.count, 1)

        // 清理剩余
        service.deleteSessions(at: IndexSet(integer: 0))
        XCTAssertEqual(service.recordedSessions.count, 0)
    }

    func testGPXTrackHistoryViewModelReactiveSync() {
        let service = GPXRecorderService.shared
        let viewModel = GPXTrackHistoryViewModel(recorder: service)
        XCTAssertEqual(viewModel.sessions.count, service.recordedSessions.count)

        // 录制一条新轨迹
        service.startSession()
        let pt = GPXRecordedPoint(latitude: 31.0, longitude: 121.0, timestamp: Date(), horizontalAccuracy: 5.0)
        service.recordPoint(pt)
        let s = service.stopSession()
        XCTAssertNotNil(s)

        // 校验 ViewModel 自动反应同步
        XCTAssertEqual(viewModel.sessions.count, service.recordedSessions.count)
        if let s = s {
            viewModel.deleteSession(s)
            XCTAssertEqual(viewModel.sessions.count, 0)
        }
    }

    /// 校验增量 WAL 机制在异常断电/崩溃后的自愈恢复能力
    func testIncrementalWALCrashRecovery() {
        let service = GPXRecorderService.shared
        let dir = service.tracksDirectoryURL
        let metaURL = dir.appendingPathComponent("active_session_meta.json")
        let walURL = dir.appendingPathComponent("active_points.wal")

        // 1. 模拟未正常退出的会话元数据
        let now = Date()
        let fakeSession = GPXTrackSession(
            sessionName: "WAL自愈测试巡航",
            startTime: now,
            gpxFileName: "Track_WAL_Test.gpx",
            isCompleted: false
        )
        let metaData = try! JSONEncoder().encode(fakeSession)
        try! metaData.write(to: metaURL, options: .atomic)

        // 2. 模拟增量追加写入 3 个点位 (JSON Lines)
        var walBuffer = Data()
        let encoder = JSONEncoder()
        for i in 0..<3 {
            let pt = GPXRecordedPoint(
                latitude: 31.0 + Double(i) * 0.001,
                longitude: 121.0 + Double(i) * 0.001,
                elevation: 20.0,
                timestamp: now.addingTimeInterval(Double(i) * 10),
                horizontalAccuracy: 5.0
            )
            let lineData = try! encoder.encode(pt)
            walBuffer.append(lineData)
            walBuffer.append(0x0A)
        }
        try! walBuffer.write(to: walURL, options: .atomic)

        // 3. 触发崩溃自愈流程并同步等待写盘
        service.recoverInterruptedSessionIfNeeded()
        service.flushPendingWritesSync()

        // 4. 校验自愈恢复结果
        let recovered = service.recordedSessions.first(where: { $0.id == fakeSession.id })
        XCTAssertNotNil(recovered, "崩溃后再次启动必须从 WAL 自愈恢复出完整轨迹")
        XCTAssertEqual(recovered?.pointCount, 3, "自愈恢复的点数必须与 WAL 记录一致")
        XCTAssertTrue(recovered?.isCompleted ?? false, "自愈后必须标记为已完成")

        // 5. 校验物理 GPX 文件已合法生成且临时 WAL 已清除
        if let rec = recovered {
            let gpxURL = service.gpxFileURL(for: rec)
            XCTAssertTrue(FileManager.default.fileExists(atPath: gpxURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path), "自愈完成后 meta 临时文件必须被清除")
            XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path), "自愈完成后 WAL 临时文件必须被清除")

            // 清理测试产物
            service.deleteSession(rec)
            service.flushPendingWritesSync()
        }
    }

    /// 校验全新 32 字节定长二进制 WAL 机制在异常断电/崩溃后的纳秒级自愈恢复能力
    func testBinaryWALCrashRecovery() {
        let service = GPXRecorderService.shared
        let dir = service.tracksDirectoryURL
        let metaURL = dir.appendingPathComponent("active_session_meta.json")
        let binURL = dir.appendingPathComponent("active_points.bin")

        // 1. 模拟未正常退出的会话元数据
        let now = Date()
        let fakeSession = GPXTrackSession(
            sessionName: "二进制WAL自愈测试巡航",
            startTime: now,
            gpxFileName: "Track_Binary_WAL_Test.gpx",
            isCompleted: false
        )
        let metaData = try! JSONEncoder().encode(fakeSession)
        try! metaData.write(to: metaURL, options: .atomic)

        // 2. 模拟增量追加写入 5 个 32 字节紧凑定长二进制点位
        var binBuffer = Data()
        for i in 0..<5 {
            let pt = GPXRecordedPoint(
                latitude: 43.1234 + Double(i) * 0.001,
                longitude: 82.6543 + Double(i) * 0.001,
                elevation: 2150.0 + Double(i) * 5.0,
                timestamp: now.addingTimeInterval(Double(i) * 10),
                horizontalAccuracy: 4.5,
                speed: 2.0,
                course: 90.0
            )
            let compact = CompactTrackPointRecord(point: pt)
            binBuffer.append(compact.serialize())
        }
        XCTAssertEqual(binBuffer.count, 5 * 32, "5 个点物理大小严格等于 160 字节")
        try! binBuffer.write(to: binURL, options: .atomic)

        // 3. 触发崩溃自愈流程并同步等待写盘
        service.recoverInterruptedSessionIfNeeded()
        service.flushPendingWritesSync()

        // 4. 校验自愈恢复结果
        let recovered = service.recordedSessions.first(where: { $0.id == fakeSession.id })
        XCTAssertNotNil(recovered, "崩溃后必须从 32B 二进制 WAL 秒级自愈恢复")
        XCTAssertEqual(recovered?.pointCount, 5, "自愈恢复的点数必须与二进制点数严格一致")
        XCTAssertTrue(recovered?.isCompleted ?? false, "自愈后必须标记为已完成")

        // 5. 校验物理 GPX 文件已流式生成且临时 bin 文件已清除
        if let rec = recovered {
            let gpxURL = service.gpxFileURL(for: rec)
            XCTAssertTrue(FileManager.default.fileExists(atPath: gpxURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: binURL.path), "自愈完成后二进制 WAL 文件必须被清除")

            // 校验文件内容合法
            let content = try? String(contentsOf: gpxURL, encoding: .utf8)
            XCTAssertNotNil(content)
            XCTAssertTrue(content!.contains("<gpx version=\"1.1\""))
            XCTAssertTrue(content!.contains("<ele>2150.00</ele>"))

            // 清理测试产物
            service.deleteSession(rec)
            service.flushPendingWritesSync()
        }
    }
}
