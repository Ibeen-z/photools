import Foundation
import AppKit
import QuickLookThumbnailing
import ImageIO

public enum ThumbnailQuality: String, Sendable {
    case list = "list"       // 列表小缩略图 (优化并发性能，优先直接读取 160px 内嵌小图)
    case detail = "detail"   // 详情高清预览 (优化清晰度画质，强制全高清解码，杜绝马赛克模糊)
    case auto = "auto"       // 自动判定 (> 260 为 detail，<= 260 为 list)
}

public final class PhotoThumbnailLoader: @unchecked Sendable {
    public typealias Quality = ThumbnailQuality
    public static let shared = PhotoThumbnailLoader()

    private struct SendableImageResult: @unchecked Sendable {
        let image: NSImage?
    }

    private final class ImageTaskBox: @unchecked Sendable {
        let task: Task<SendableImageResult, Never>
        init(task: Task<SendableImageResult, Never>) { self.task = task }
    }

    private let memoryCache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlightTasks: [NSString: ImageTaskBox] = [:]
    private let diskCacheURL: URL?

    public init() {
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 300 * 1024 * 1024 // 300MB

        if let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            // 使用 v2 隔离目录，彻底废弃老版本低质量缩略图缓存
            let thumbDir = baseCaches.appendingPathComponent("photools/thumbnails/v2", isDirectory: true)
            try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
            self.diskCacheURL = thumbDir
        } else {
            self.diskCacheURL = nil
        }
    }

    public func loadThumbnail(
        for asset: PhotoAssetGroup,
        targetSize: CGSize = CGSize(width: 300, height: 300),
        quality: ThumbnailQuality = .auto
    ) async -> NSImage? {
        let effectiveQuality: ThumbnailQuality
        switch quality {
        case .list:
            effectiveQuality = .list
        case .detail:
            effectiveQuality = .detail
        case .auto:
            effectiveQuality = max(targetSize.width, targetSize.height) > 260 ? .detail : .list
        }

        let modTime = asset.fileModificationDate?.timeIntervalSince1970 ?? 0
        // 缓存键明确区分 list 与 detail 质量等级，彻底杜绝小图缓存污染详情大图
        let cacheKey = "\(asset.id)::\(effectiveQuality.rawValue)::\(Int(targetSize.width))x\(Int(targetSize.height))::\(Int(modTime))" as NSString

        // 1. 内存高速缓存命中（纳秒级）
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // 2. 任务合并去重（同步 scoped 锁内检查/注册）
        let (task, isNew) = getOrStartTask(cacheKey: cacheKey, asset: asset, targetSize: targetSize, quality: effectiveQuality)
        let result = (await task.value).image

        if isNew {
            finishTask(cacheKey: cacheKey)
        }

        return result
    }

    private func getOrStartTask(
        cacheKey: NSString,
        asset: PhotoAssetGroup,
        targetSize: CGSize,
        quality: ThumbnailQuality
    ) -> (task: Task<SendableImageResult, Never>, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let ongoing = inFlightTasks[cacheKey] {
            return (ongoing.task, false)
        }
        let task = Task<SendableImageResult, Never> { [weak self] in
            guard let self else { return SendableImageResult(image: nil) }
            let img = await self.performLoadThumbnail(for: asset, targetSize: targetSize, quality: quality, cacheKey: cacheKey)
            return SendableImageResult(image: img)
        }
        inFlightTasks[cacheKey] = ImageTaskBox(task: task)
        return (task, true)
    }

    private func finishTask(cacheKey: NSString) {
        lock.lock()
        defer { lock.unlock() }
        inFlightTasks.removeValue(forKey: cacheKey)
    }

    private func performLoadThumbnail(
        for asset: PhotoAssetGroup,
        targetSize: CGSize,
        quality: ThumbnailQuality,
        cacheKey: NSString
    ) async -> NSImage? {
        // 3. 磁盘二级缓存命中（毫秒级）
        if let diskImage = loadFromDiskCache(key: cacheKey as String) {
            memoryCache.setObject(diskImage, forKey: cacheKey)
            return diskImage
        }

        // 针对详情大图给予更充分的超采样像素（2.5倍），列表给予 2.0 倍
        let maxPixel = max(targetSize.width, targetSize.height) * (quality == .detail ? 2.5 : 2.0)
        let allowLowResEmbedded = (quality == .list)
        var resolvedImage: NSImage?

        // 4. 存在配对 JPG 时：
        if let jpgPath = asset.jpgPath, FileManager.default.fileExists(atPath: jpgPath) {
            if let image = createThumbnail(at: jpgPath, maxPixelSize: maxPixel, allowLowResEmbedded: allowLowResEmbedded) {
                resolvedImage = image
            }
        }

        // 5. 纯 RAW / NEF 模式：优先使用 QLThumbnailGenerator 提取 RAW 预览（detail 模式下提取高质量大预览）
        if resolvedImage == nil, let rawPath = asset.rawPath, FileManager.default.fileExists(atPath: rawPath) {
            if let image = await generateQuickLookThumbnail(at: rawPath, targetSize: targetSize, quality: quality) {
                resolvedImage = image
            } else if let image = createThumbnail(at: rawPath, maxPixelSize: maxPixel, allowLowResEmbedded: allowLowResEmbedded) {
                resolvedImage = image
            }
        }

        // 6. 兜底主路径
        if resolvedImage == nil, let primary = asset.primaryPath, FileManager.default.fileExists(atPath: primary) {
            if let image = await generateQuickLookThumbnail(at: primary, targetSize: targetSize, quality: quality) {
                resolvedImage = image
            } else if let image = createThumbnail(at: primary, maxPixelSize: maxPixel, allowLowResEmbedded: allowLowResEmbedded) {
                resolvedImage = image
            }
        }

        if let finalImage = resolvedImage {
            memoryCache.setObject(finalImage, forKey: cacheKey)
            saveToDiskCache(image: finalImage, key: cacheKey as String, quality: quality)
            return finalImage
        }

        return nil
    }

    private func generateQuickLookThumbnail(at filePath: String, targetSize: CGSize, quality: ThumbnailQuality) async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let reqSize = (quality == .detail) ? CGSize(width: max(targetSize.width, 800), height: max(targetSize.height, 600)) : targetSize
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: reqSize,
            scale: scale,
            representationTypes: quality == .detail ? .all : .thumbnail
        )

        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep.nsImage
        } catch {
            return nil
        }
    }

    /// 分级 ImageIO 提取：列表模式允许直接使用内嵌缩略图；详情模式强制从原图完整高质量解码
    private func createThumbnail(at filePath: String, maxPixelSize: CGFloat, allowLowResEmbedded: Bool) -> NSImage? {
        let url = URL(fileURLWithPath: filePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

        // 阶段一：仅在允许低分辨率内嵌（列表场景）下尝试提取内嵌缩略图（< 1ms）
        if allowLowResEmbedded {
            let fastOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, fastOptions as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        // 阶段二：详情高清模式或无内嵌图时：强制完整原图高清解码（Retina 级别高清晰度，绝不模糊）
        let highQualityOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, highQualityOptions as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    private func diskCacheFileURL(for key: String) -> URL? {
        guard let diskCacheURL else { return nil }
        var safeKey = 5381
        for byte in key.utf8 {
            safeKey = ((safeKey << 5) &+ safeKey) &+ Int(byte)
        }
        let filename = "\(abs(safeKey)).jpg"
        return diskCacheURL.appendingPathComponent(filename)
    }

    private func loadFromDiskCache(key: String) -> NSImage? {
        guard let fileURL = diskCacheFileURL(for: key), FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return NSImage(contentsOf: fileURL)
    }

    private func saveToDiskCache(image: NSImage, key: String, quality: ThumbnailQuality) {
        guard let fileURL = diskCacheFileURL(for: key) else { return }
        let compression: CGFloat = (quality == .detail) ? 0.92 : 0.80
        Task.detached(priority: .background) {
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
                return
            }
            try? jpegData.write(to: fileURL, options: .atomic)
        }
    }

    /// 清空所有内存与磁盘缩略图缓存
    public func clearAllCaches() {
        memoryCache.removeAllObjects()
        if let diskCacheURL {
            try? FileManager.default.removeItem(at: diskCacheURL)
            try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        }
    }
}
