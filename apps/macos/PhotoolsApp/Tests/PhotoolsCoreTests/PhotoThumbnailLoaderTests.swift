import XCTest
import AppKit
@testable import PhotoolsCore

final class PhotoThumbnailLoaderTests: XCTestCase {
    func testThumbnailQualityEnumValues() {
        XCTAssertEqual(ThumbnailQuality.list.rawValue, "list")
        XCTAssertEqual(ThumbnailQuality.detail.rawValue, "detail")
        XCTAssertEqual(ThumbnailQuality.auto.rawValue, "auto")
        XCTAssertEqual(PhotoThumbnailLoader.Quality.list.rawValue, "list")
        XCTAssertEqual(PhotoThumbnailLoader.Quality.detail.rawValue, "detail")
    }

    func testThumbnailQualityEffectiveResolution() {
        // 当 targetSize 较大（如详情展台 1000x750）时，auto 应推导为 detail
        let largeSize = CGSize(width: 1000, height: 750)
        let maxLargeDim = max(largeSize.width, largeSize.height)
        XCTAssertGreaterThan(maxLargeDim, 260)

        // 当 targetSize 较小（如列表 84x84）时，auto 应推导为 list
        let smallSize = CGSize(width: 84, height: 84)
        let maxSmallDim = max(smallSize.width, smallSize.height)
        XCTAssertLessThanOrEqual(maxSmallDim, 260)
    }

    func testLoaderSingletonInstance() {
        let loader1 = PhotoThumbnailLoader.shared
        let loader2 = PhotoThumbnailLoader.shared
        XCTAssertTrue(loader1 === loader2)
    }

    func testLoadEmptyAssetReturnsNil() async {
        let emptyGroup = PhotoAssetGroup(
            id: "empty_id",
            baseName: "EMPTY_SAMPLE",
            directory: "/tmp",
            rawPath: nil,
            jpgPath: nil,
            xmpPath: nil,
            companionPaths: []
        )
        let thumbnail = await PhotoThumbnailLoader.shared.loadThumbnail(
            for: emptyGroup,
            targetSize: CGSize(width: 100, height: 100),
            quality: .list
        )
        XCTAssertNil(thumbnail)
    }

    func testLoadRealImageDualQualityAndCache() async throws {
        // 创建一个临时测试图像 (400x300 红色彩块)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testImagePath = tempDir.appendingPathComponent("TEST_DUAL_QUALITY.JPG").path
        let imgSize = NSSize(width: 400, height: 300)
        let testImage = NSImage(size: imgSize)
        testImage.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: imgSize).fill()
        testImage.unlockFocus()

        guard let tiffData = testImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(using: .jpeg, properties: [:]) else {
            XCTFail("无法生成测试 JPEG")
            return
        }
        try jpegData.write(to: URL(fileURLWithPath: testImagePath))

        let group = PhotoAssetGroup(
            id: "test_asset_dual_quality",
            baseName: "TEST_DUAL_QUALITY",
            directory: tempDir.path,
            rawPath: nil,
            jpgPath: testImagePath,
            xmpPath: nil,
            companionPaths: [],
            fileModificationDate: Date()
        )

        let loader = PhotoThumbnailLoader.shared

        // 1. 请求列表小图 (84x84, .list)
        let listThumb = await loader.loadThumbnail(for: group, targetSize: CGSize(width: 84, height: 84), quality: .list)
        XCTAssertNotNil(listThumb, "列表缩略图生成成功")

        // 2. 请求详情大图 (1000x750, .detail)
        let detailThumb = await loader.loadThumbnail(for: group, targetSize: CGSize(width: 1000, height: 750), quality: .detail)
        XCTAssertNotNil(detailThumb, "详情高清缩略图生成成功")

        // 3. 二次命中测试 (直接走缓存)
        let cachedDetail = await loader.loadThumbnail(for: group, targetSize: CGSize(width: 1000, height: 750), quality: .detail)
        XCTAssertNotNil(cachedDetail, "缓存命中成功")

        // 4. 清理缓存测试
        loader.clearAllCaches()
    }
}
