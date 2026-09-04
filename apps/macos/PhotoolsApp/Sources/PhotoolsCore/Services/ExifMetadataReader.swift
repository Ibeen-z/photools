import Foundation

public final class ExifMetadataReader: Sendable {
    private final class CacheBox: @unchecked Sendable {
        let metadata: ExifMetadata
        init(_ metadata: ExifMetadata) { self.metadata = metadata }
    }
    private static let metadataCache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 600
        return cache
    }()

    public init() {}

    /// 清空元数据缓存
    public static func clearCache() {
        metadataCache.removeAllObjects()
    }

    public func readMetadata(for filePath: String) async throws -> ExifMetadata {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "ExifMetadataReader", code: 404, userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(filePath)"])
        }

        // 1. 纳秒级 LRU 内存缓存检查（以路径 + 修改时间为复合 Key）
        let url = URL(fileURLWithPath: filePath)
        let modTime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(filePath)::\(Int(modTime))" as NSString

        if let cachedBox = Self.metadataCache.object(forKey: cacheKey) {
            return cachedBox.metadata
        }

        var metadata: ExifMetadata
        // 2. 优先使用进程内 FFI 引擎极速直通读取
        if PhotoolsEngine.shared.isLoaded,
           let meta = PhotoolsEngine.shared.inspectPhotoMetadata(filePath: filePath) {
            metadata = meta
        } else {
            // 3. Fallback: 外部子进程模式
            metadata = readMetadataViaCLI(filePath: filePath)
        }

        // 4. 同组 RAW 姿态无损穿透增强 (Primary Asset Model)
        let enriched = enrichWithCompanionRAWIfNeeded(meta: metadata, filePath: filePath)
        Self.metadataCache.setObject(CacheBox(enriched), forKey: cacheKey)
        return enriched
    }

    private func readMetadataViaCLI(filePath: String) -> ExifMetadata {
        let exiftoolPath = Self.findExifToolPath()
        guard let exiftoolPath, FileManager.default.isExecutableFile(atPath: exiftoolPath) else {
            return fallbackMetadata(for: filePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)

        var args = ["-m", "-q", "-j", "-G1", "-a", "-s", "-c", "%.6f", filePath]
        let sidecarCandidates = [
            filePath + ".xmp",
            filePath + ".XMP",
            (filePath as NSString).deletingPathExtension + ".xmp",
            (filePath as NSString).deletingPathExtension + ".XMP"
        ]
        var foundSidecar: String?
        for cand in sidecarCandidates {
            if FileManager.default.fileExists(atPath: cand) && cand != filePath {
                foundSidecar = cand
                args.append(cand)
                break
            }
        }
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return fallbackMetadata(for: filePath)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard !data.isEmpty,
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstItem = jsonArray.first else {
            return fallbackMetadata(for: filePath)
        }

        var merged = firstItem
        if jsonArray.count > 1 {
            let xmpDict = jsonArray[1]
            for (k, v) in xmpDict {
                if merged[k] == nil {
                    merged[k] = v
                }
            }
            if let sidecar = foundSidecar {
                merged["sidecar_path"] = sidecar
                merged["geocode_source"] = "xmp"
            }
        }

        return ExifMetadata.parse(from: merged, fallbackPath: filePath)
    }

    private func enrichWithCompanionRAWIfNeeded(meta: ExifMetadata, filePath: String) -> ExifMetadata {
        // 若已具备机身 Pitch 与 Roll，无需穿透
        if meta.pitchAngle != nil && meta.rollAngle != nil && meta.focusDistance != nil {
            return meta
        }

        let ext = (filePath as NSString).pathExtension.lowercased()
        let rawExts = ["nef", "dng", "raw", "cr2", "cr3", "arw", "orf", "rw2", "pef", "raf"]
        if rawExts.contains(ext) {
            // 本身即是 RAW 主文件，无需穿透寻找其他 RAW
            return meta
        }

        let baseWithoutExt = (filePath as NSString).deletingPathExtension
        var companionRawPath: String?

        // 1. 优先寻找标准同名伴随 RAW
        for rawExt in rawExts {
            let cand1 = "\(baseWithoutExt).\(rawExt)"
            let cand2 = "\(baseWithoutExt).\(rawExt.uppercased())"
            if FileManager.default.fileExists(atPath: cand1) {
                companionRawPath = cand1
                break
            }
            if FileManager.default.fileExists(atPath: cand2) {
                companionRawPath = cand2
                break
            }
        }

        // 2. 启发式兼容常见后期软件导出后缀 (如 DSC_xxxx_edit_nx -> DSC_xxxx)
        if companionRawPath == nil {
            let filename = (filePath as NSString).lastPathComponent
            let editSuffixes = ["_edit_nx", "_edit", "-Edit", "_DxO", "_acr"]
            for suffix in editSuffixes {
                if let range = filename.range(of: suffix, options: .caseInsensitive) {
                    let rawBase = String(filename[..<range.lowerBound])
                    let dir = (filePath as NSString).deletingLastPathComponent
                    for rawExt in rawExts {
                        let cand1 = (dir as NSString).appendingPathComponent("\(rawBase).\(rawExt)")
                        let cand2 = (dir as NSString).appendingPathComponent("\(rawBase).\(rawExt.uppercased())")
                        if FileManager.default.fileExists(atPath: cand1) {
                            companionRawPath = cand1
                            break
                        }
                        if FileManager.default.fileExists(atPath: cand2) {
                            companionRawPath = cand2
                            break
                        }
                    }
                    if companionRawPath != nil { break }
                }
            }
        }

        guard let rawPath = companionRawPath else {
            return meta
        }

        // 读取同组伴随 RAW 的完整元数据
        let rawMeta: ExifMetadata?
        if PhotoolsEngine.shared.isLoaded, let m = PhotoolsEngine.shared.inspectPhotoMetadata(filePath: rawPath) {
            rawMeta = m
        } else {
            rawMeta = readMetadataViaCLI(filePath: rawPath)
        }

        guard let raw = rawMeta else {
            return meta
        }

        // 从 RAW 穿透补全缺失的五轴陀螺仪姿态与光学机身数据
        let enrichedPitch = meta.pitchAngle ?? raw.pitchAngle
        let enrichedRoll = meta.rollAngle ?? raw.rollAngle
        let enrichedYaw = meta.yawAngle ?? raw.yawAngle
        let enrichedFocusDist = meta.focusDistance ?? raw.focusDistance
        let enrichedFOV = meta.rawFOV ?? raw.rawFOV
        let enrichedFocal35mm = meta.focalLengthIn35mm ?? raw.focalLengthIn35mm
        let enrichedAttitude = meta.cameraAttitude ?? raw.cameraAttitude

        return ExifMetadata(
            filePath: meta.filePath,
            fileName: meta.fileName,
            fileSize: meta.fileSize,
            fileModifyDate: meta.fileModifyDate,
            cameraMake: meta.cameraMake ?? raw.cameraMake,
            cameraModel: meta.cameraModel ?? raw.cameraModel,
            lensModel: meta.lensModel ?? raw.lensModel,
            dateTimeOriginal: meta.dateTimeOriginal ?? raw.dateTimeOriginal,
            exposureTime: meta.exposureTime ?? raw.exposureTime,
            fNumber: meta.fNumber ?? raw.fNumber,
            iso: meta.iso ?? raw.iso,
            focalLength: meta.focalLength ?? raw.focalLength,
            exposureProgram: meta.exposureProgram ?? raw.exposureProgram,
            latitude: meta.latitude ?? raw.latitude,
            longitude: meta.longitude ?? raw.longitude,
            altitude: meta.altitude ?? raw.altitude,
            gpsPosition: meta.gpsPosition ?? raw.gpsPosition,
            gpsImgDirection: meta.gpsImgDirection ?? raw.gpsImgDirection,
            gpsImgDirectionRef: meta.gpsImgDirectionRef ?? raw.gpsImgDirectionRef,
            focalLengthIn35mm: enrichedFocal35mm,
            yawAngle: enrichedYaw,
            pitchAngle: enrichedPitch,
            rollAngle: enrichedRoll,
            rawFOV: enrichedFOV,
            focusDistance: enrichedFocusDist,
            viewDistance: meta.viewDistance ?? raw.viewDistance,
            country: meta.country ?? raw.country,
            province: meta.province ?? raw.province,
            city: meta.city ?? raw.city,
            district: meta.district ?? raw.district,
            title: meta.title ?? raw.title,
            description: meta.description ?? raw.description,
            gpsSource: meta.gpsSource ?? raw.gpsSource,
            gpsMatchMethod: meta.gpsMatchMethod ?? raw.gpsMatchMethod,
            interpolateWindow: meta.interpolateWindow ?? raw.interpolateWindow,
            processor: meta.processor ?? raw.processor,
            processedDate: meta.processedDate ?? raw.processedDate,
            geocodeSource: meta.geocodeSource ?? raw.geocodeSource,
            sidecarPath: meta.sidecarPath ?? raw.sidecarPath,
            cameraAttitude: enrichedAttitude,
            rawTags: meta.rawTags
        )
    }

    public static func findExifToolPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
            "/usr/bin/exiftool",
            Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("vendor/exiftool/exiftool") } ?? ""
        ]
        for path in candidates where !path.isEmpty {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func fallbackMetadata(for filePath: String) -> ExifMetadata {
        let fileURL = URL(fileURLWithPath: filePath)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
        let sizeBytes = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        let sizeStr = formatter.string(fromByteCount: sizeBytes)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return ExifMetadata(
            filePath: filePath,
            fileName: fileURL.lastPathComponent,
            fileSize: sizeStr,
            fileModifyDate: dateFmt.string(from: modDate)
        )
    }

    /// 极速并发批量提取轻量级元数据索引 (拍摄时间与 GPS 状态)
    public func readBatchIndex(for filePaths: [String]) async -> [String: BatchPhotoIndexItem] {
        guard !filePaths.isEmpty else { return [:] }

        // 1. 优先使用进程内 FFI 极速批量直通
        if PhotoolsEngine.shared.isLoaded,
           let dict = PhotoolsEngine.shared.readBatchPhotoIndex(paths: filePaths) {
            return dict
        }

        // 2. Fallback: 外部 CLI 批量分批读取
        return await Task.detached(priority: .userInitiated) {
            Self.readBatchIndexViaCLI(filePaths: filePaths)
        }.value
    }

    private static func readBatchIndexViaCLI(filePaths: [String]) -> [String: BatchPhotoIndexItem] {
        let exiftoolPath = Self.findExifToolPath()
        guard let exiftoolPath, FileManager.default.isExecutableFile(atPath: exiftoolPath) else {
            return [:]
        }

        var results: [String: BatchPhotoIndexItem] = [:]
        let chunkSize = 200
        for i in stride(from: 0, to: filePaths.count, by: chunkSize) {
            let chunk = Array(filePaths[i..<min(i + chunkSize, filePaths.count)])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exiftoolPath)
            var args = ["-m", "-q", "-j", "-DateTimeOriginal", "-OffsetTimeOriginal", "-GPSPosition"]
            args.append(contentsOf: chunk)
            process.arguments = args

            let outputPipe = Pipe()
            process.standardOutput = outputPipe

            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in jsonArray {
                        guard let src = item["SourceFile"] as? String else { continue }
                        let dateStr = item["DateTimeOriginal"] as? String
                        let offsetStr = item["OffsetTimeOriginal"] as? String
                        let posStr = item["GPSPosition"] as? String
                        let hasGPS = (posStr != nil && !posStr!.isEmpty)
                        results[src] = BatchPhotoIndexItem(
                            dateTimeOriginal: dateStr,
                            offsetTimeOriginal: offsetStr,
                            hasGPS: hasGPS,
                            gpsPosition: posStr
                        )
                    }
                }
            } catch {
                continue
            }
        }
        return results
    }
}
