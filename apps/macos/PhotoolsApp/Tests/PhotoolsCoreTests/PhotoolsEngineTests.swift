import XCTest
@testable import PhotoolsCore

final class PhotoolsEngineTests: XCTestCase {
    func testEngineLoadingAndLookup() {
        let repoRoot = RepositoryLocator().locateRepositoryRoot()
        let dylibPath = (repoRoot as NSString).appendingPathComponent("dist/libphotools.dylib")

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            // 如果是在纯隔离环境且未编译 dylib 则跳过真实 FFI
            return
        }

        let engine = PhotoolsEngine(customDylibPath: dylibPath)
        XCTAssertTrue(engine.isLoaded, "应该成功加载 libphotools.dylib")

        // 1. 测试初始化
        var initReports: [PhotoolsInitReport] = []
        engine.initialize { rep in
            initReports.append(rep)
        }
        XCTAssertTrue(engine.isInitialized)

        // 2. 测试内存经纬度高精反查 (上海 31.2304, 121.4737)
        let result = engine.lookupCoordinates(latitude: 31.2304, longitude: 121.4737)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.country, "中国")
        XCTAssertEqual(result?.province, "上海市")

        // 3. 测试大洲数据包列表
        let packs = engine.listGeodataPacks()
        XCTAssertFalse(packs.isEmpty)
        XCTAssertTrue(packs.contains { $0.code == "china" })
    }

    func testEngineBackupAndRestoreFFI() async throws {
        let repoRoot = RepositoryLocator().locateRepositoryRoot()
        let dylibPath = (repoRoot as NSString).appendingPathComponent("dist/libphotools.dylib")

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            return
        }

        let engine = PhotoolsEngine(customDylibPath: dylibPath)
        guard engine.isLoaded else { return }

        // 创建临时测试目录
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        let backupDir = tempDir.appendingPathComponent("Inbox_bak")
        let processedDir = tempDir.appendingPathComponent("Processed")

        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processedDir, withIntermediateDirectories: true)

        let dummyFile = inboxDir.appendingPathComponent("test.jpg")
        try "dummy photo".write(to: dummyFile, atomically: true, encoding: .utf8)

        // 1. 测试 C ABI createBackup
        let backupCount = try await engine.createBackup(sourceDir: inboxDir.path, backupDir: backupDir.path)
        XCTAssertEqual(backupCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("test.jpg").path))

        // 模拟清空 Inbox 并测试 restoreBackup FFI (4 个参数正确匹配)
        try FileManager.default.removeItem(at: dummyFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dummyFile.path))

        let restoreCount = try await engine.restoreBackup(
            baseDirectory: tempDir.path,
            backupDir: backupDir.path,
            targetDir: inboxDir.path,
            cleanProcessed: true
        )
        XCTAssertEqual(restoreCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dummyFile.path))

        // 清理临时测试目录
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEngineInspectOrientationAndFOV() {
        let repoRoot = RepositoryLocator().locateRepositoryRoot()
        let dylibPath = (repoRoot as NSString).appendingPathComponent("dist/libphotools.dylib")
        guard FileManager.default.fileExists(atPath: dylibPath) else { return }

        let testPhoto = (repoRoot as NSString).appendingPathComponent("test/Inbox_bak/DSC_2026-05-29_7400.jpg")
        guard FileManager.default.fileExists(atPath: testPhoto) else { return }

        let engine = PhotoolsEngine(customDylibPath: dylibPath)
        guard engine.isLoaded else { return }

        let meta = engine.inspectPhotoMetadata(filePath: testPhoto)
        XCTAssertNotNil(meta)

        // 验证机身陀螺仪偏航角 (YawAngle: 89.3)
        if let yaw = meta?.gyroYawAngle {
            XCTAssertEqual(yaw, 89.3, accuracy: 0.1, "机身陀螺仪偏航角应为 89.3°")
        }

        // 验证视场角 (FOV: 55.7)
        if let fov = meta?.fieldOfView {
            XCTAssertEqual(fov, 55.7, accuracy: 0.5, "34mm 镜头视场角应约为 55.7°")
        }

        // 验证俯仰角与对焦距离
        if let pitch = meta?.pitchAngle {
            XCTAssertEqual(pitch, 6.5, accuracy: 0.1, "相机俯仰仰角应为 6.5°")
        }
        XCTAssertEqual(meta?.focusDistance, "17.4 m")
    }

    func testWriteCameraPerspectiveFFI() throws {
        let repoRoot = RepositoryLocator().locateRepositoryRoot()
        let dylibPath = (repoRoot as NSString).appendingPathComponent("dist/libphotools.dylib")
        guard FileManager.default.fileExists(atPath: dylibPath) else { return }

        let engine = PhotoolsEngine(customDylibPath: dylibPath)
        guard engine.isLoaded else { return }

        // 使用临时目录创建测试图片与 XMP
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let samplePhoto = (repoRoot as NSString).appendingPathComponent("test/Inbox_bak/DSC_2026-05-29_7400.jpg")
        guard FileManager.default.fileExists(atPath: samplePhoto) else { return }

        let targetPhoto = tempDir.appendingPathComponent("test_perspective.jpg").path
        try FileManager.default.copyItem(atPath: samplePhoto, toPath: targetPhoto)

        // 1. 调用 writeCameraPerspective 写入 3D 视角参数 (Heading=123.4, Pitch=15.0, Roll=-2.5, ViewDistance=4500.0)
        let writeOK = engine.writeCameraPerspective(
            primaryPath: targetPhoto,
            heading: 123.4,
            pitch: 15.0,
            roll: -2.5,
            viewDistance: 4500.0,
            sidecarPolicy: "smart"
        )
        XCTAssertTrue(writeOK, "writeCameraPerspective 应当成功执行")

        // 2. 二次回读检查闭环
        let inspected = engine.inspectPhotoMetadata(filePath: targetPhoto)
        XCTAssertNotNil(inspected)
        if let dir = inspected?.gpsImgDirection {
            XCTAssertEqual(dir, 123.4, accuracy: 0.2)
        }
        if let pitchVal = inspected?.pitchAngle {
            XCTAssertEqual(pitchVal, 15.0, accuracy: 0.2)
        }
        if let rollVal = inspected?.rollAngle {
            XCTAssertEqual(rollVal, -2.5, accuracy: 0.2)
        }
        if let distVal = inspected?.viewDistance {
            XCTAssertEqual(distVal, 4500.0, accuracy: 1.0)
        }
    }

    func testEngineBatchPhotoIndexFFI() {
        let repoRoot = RepositoryLocator().locateRepositoryRoot()
        let dylibPath = (repoRoot as NSString).appendingPathComponent("dist/libphotools.dylib")

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            return
        }

        let engine = PhotoolsEngine(customDylibPath: dylibPath)
        guard engine.isLoaded else { return }

        // 空入参安全返回
        let emptyResult = engine.readBatchPhotoIndex(paths: [])
        XCTAssertEqual(emptyResult?.count, 0)

        // 模拟路径测试
        let mockPaths = ["/tmp/non_existent_1.jpg", "/tmp/non_existent_2.nef"]
        let batchResult = engine.readBatchPhotoIndex(paths: mockPaths)
        XCTAssertNotNil(batchResult)
        XCTAssertEqual(batchResult?.count, 2)
        XCTAssertEqual(batchResult?["/tmp/non_existent_1.jpg"]?.hasGPS, false)
    }
}
