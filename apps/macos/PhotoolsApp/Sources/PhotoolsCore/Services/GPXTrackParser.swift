import Foundation
import CoreLocation

private final class TrackSummaryBox: @unchecked Sendable {
    let summary: GPXTrackSummary
    init(_ summary: GPXTrackSummary) {
        self.summary = summary
    }
}

/// 极速 GPX 流式解析与空间指标计算服务
public final class GPXTrackParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    public static let shared = GPXTrackParser()

    private let cache: NSCache<NSString, TrackSummaryBox> = {
        let c = NSCache<NSString, TrackSummaryBox>()
        c.countLimit = 120
        return c
    }()

    public override init() {
        super.init()
    }

    /// 异步解析本地 GPX 文件并生成轨迹摘要与抽稀后的渲染点位
    /// - Parameters:
    ///   - filePath: GPX 文件绝对路径
    ///   - maxRenderPoints: 最大保留的渲染点位数量（默认 2000 点，兼顾细腻度与 WebGL 60fps 渲染性能）
    ///   - progressHandler: 可选的进度回调闭包 (进度百分比 0.0~1.0, 阶段状态文案)
    public func parse(
        filePath: String,
        maxRenderPoints: Int = 2000,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async -> GPXTrackSummary? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
        let modDate = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let cacheKey = "\(filePath)_\(modDate)_\(fileSize)_\(maxRenderPoints)" as NSString

        if let cached = cache.object(forKey: cacheKey) {
            progressHandler?(1.0, "从高速内存缓存瞬时载入...")
            return cached.summary
        }

        if Task.isCancelled { return nil }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self, !Task.isCancelled else { return nil }
            progressHandler?(0.15, "正在读取本地 GPX 轨迹数据...")

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                return nil
            }

            if Task.isCancelled { return nil }
            progressHandler?(0.30, "正在解析 XML 航点与时间轴...")

            let internalParser = InternalXMLParser(
                data: data,
                shouldCancel: { Task.isCancelled },
                onBatch: { parsedCount in
                    if parsedCount % 800 == 0 {
                        let estProgress = min(0.30 + Double(parsedCount) / 8000.0 * 0.35, 0.65)
                        progressHandler?(estProgress, "已解析 \(parsedCount) 个三维航点...")
                    }
                }
            )
            let parseResult = internalParser.parseData()
            let rawPoints = parseResult.trackPoints
            let waypoints = parseResult.waypoints
            if Task.isCancelled || rawPoints.isEmpty { return nil }
            let trackName = parseResult.trackName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

            progressHandler?(0.70, "已解析全部 \(rawPoints.count) 个航点与 \(waypoints.count) 个打卡点，正在计算高程剖面...")

            let summary = self.buildSummary(
                filePath: filePath,
                name: trackName,
                rawPoints: rawPoints,
                waypoints: waypoints,
                maxRenderPoints: maxRenderPoints
            )

            if Task.isCancelled { return nil }
            self.cache.setObject(TrackSummaryBox(summary), forKey: cacheKey)

            progressHandler?(1.0, "轨迹空间档案就绪，即将载入 3D 地形！")
            return summary
        }.value
    }

    private func buildSummary(
        filePath: String,
        name: String,
        rawPoints: [GPXTrackPoint],
        waypoints: [GPXWaypoint],
        maxRenderPoints: Int
    ) -> GPXTrackSummary {
        var minLat = 90.0
        var maxLat = -90.0
        var minLng = 180.0
        var maxLng = -180.0

        var minEle: Double? = nil
        var maxEle: Double? = nil
        var totalDist = 0.0
        var prevPoint: GPXTrackPoint? = nil

        var pointsWithDist: [GPXTrackPoint] = []
        pointsWithDist.reserveCapacity(rawPoints.count)
        var heartRates: [Int] = []

        for point in rawPoints {
            // 统计外接边界
            if point.latitude < minLat { minLat = point.latitude }
            if point.latitude > maxLat { maxLat = point.latitude }
            if point.longitude < minLng { minLng = point.longitude }
            if point.longitude > maxLng { maxLng = point.longitude }

            // 统计海拔
            if let ele = point.elevation {
                if let curMin = minEle {
                    if ele < curMin { minEle = ele }
                } else {
                    minEle = ele
                }

                if let curMax = maxEle {
                    if ele > curMax { maxEle = ele }
                } else {
                    maxEle = ele
                }
            }

            // 累加实际距离并记录各点累计里程
            if let prev = prevPoint {
                totalDist += distanceBetween(lat1: prev.latitude, lon1: prev.longitude, lat2: point.latitude, lon2: point.longitude)
            }

            let pt = GPXTrackPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                elevation: point.elevation,
                time: point.time,
                heartRate: point.heartRate,
                distanceMeters: totalDist
            )
            pointsWithDist.append(pt)

            if let hr = point.heartRate, hr >= 30, hr <= 240 {
                heartRates.append(hr)
            }

            prevPoint = point
        }

        // 边界框同时容纳所有打卡点 (Waypoints)
        for wpt in waypoints {
            if wpt.latitude < minLat { minLat = wpt.latitude }
            if wpt.latitude > maxLat { maxLat = wpt.latitude }
            if wpt.longitude < minLng { minLng = wpt.longitude }
            if wpt.longitude > maxLng { maxLng = wpt.longitude }
        }

        // 核心：使用移动平均滤波 + 滞后门限算法计算真实累计爬升
        let totalGain = calculateElevationGain(points: pointsWithDist)

        // 心率统计
        let avgHR: Int? = heartRates.isEmpty ? nil : heartRates.reduce(0, +) / heartRates.count
        let maxHR: Int? = heartRates.max()
        let minHR: Int? = heartRates.min()

        let startTime = pointsWithDist.first?.time
        let endTime = pointsWithDist.last?.time
        let duration: TimeInterval?
        if let s = startTime, let e = endTime {
            duration = max(0, e.timeIntervalSince(s))
        } else {
            duration = nil
        }

        // 智能抽稀：均匀采样保留轮廓、首尾点与高程/心率剖面
        let renderedPoints: [GPXTrackPoint]
        if pointsWithDist.count <= maxRenderPoints {
            renderedPoints = pointsWithDist
        } else {
            let step = Double(pointsWithDist.count - 1) / Double(maxRenderPoints - 1)
            var sampled: [GPXTrackPoint] = []
            sampled.reserveCapacity(maxRenderPoints)

            for i in 0..<maxRenderPoints {
                let idx = min(Int(round(Double(i) * step)), pointsWithDist.count - 1)
                sampled.append(pointsWithDist[idx])
            }
            renderedPoints = sampled
        }

        let bbox = GPXBoundingBox(
            minLat: minLat,
            maxLat: maxLat,
            minLng: minLng,
            maxLng: maxLng
        )

        return GPXTrackSummary(
            name: name,
            filePath: filePath,
            rawPointCount: pointsWithDist.count,
            renderedPoints: renderedPoints,
            waypoints: waypoints,
            totalDistanceMeters: totalDist,
            minElevation: minEle,
            maxElevation: maxEle,
            elevationGain: totalGain,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            minHeartRate: minHR,
            startTime: startTime,
            endTime: endTime,
            durationSeconds: duration,
            boundingBox: bbox
        )
    }

    /// 工业级累计爬升算法：自适应移动窗口平滑 + 滞后门限波峰波谷波形分析 (彻底解决高频 GPS 漏计与漂移问题)
    private func calculateElevationGain(points: [GPXTrackPoint]) -> Double? {
        let validElevations = points.compactMap { $0.elevation }
        guard validElevations.count >= 2 else { return nil }

        // 点数极少时直接累加正向差值
        if validElevations.count < 10 {
            var gain = 0.0
            for i in 1..<validElevations.count {
                let d = validElevations[i] - validElevations[i-1]
                if d > 0 { gain += d }
            }
            return gain > 0 ? gain : nil
        }

        // 1. 移动平均平滑滤波 (自适应窗口 5~15 点)
        let windowSize = max(5, min(15, (validElevations.count / 200) | 1))
        let halfW = windowSize / 2
        var smoothed: [Double] = []
        smoothed.reserveCapacity(validElevations.count)

        for i in 0..<validElevations.count {
            let start = max(0, i - halfW)
            let end = min(validElevations.count, i + halfW + 1)
            var sum = 0.0
            for j in start..<end {
                sum += validElevations[j]
            }
            smoothed.append(sum / Double(end - start))
        }

        // 2. 滞后门限算法 (Hysteresis Peak-Valley, 门限 2.0 米)
        let threshold = 2.0
        var totalGain = 0.0
        var valley = smoothed[0]
        var peak = smoothed[0]
        var isClimbing = false

        for e in smoothed {
            if e > peak {
                peak = e
                if !isClimbing && (peak - valley >= threshold) {
                    isClimbing = true
                }
            } else if e < valley {
                valley = e
                if isClimbing && (peak - valley >= threshold) {
                    isClimbing = false
                    totalGain += (peak - valley)
                    peak = e
                }
            } else {
                if isClimbing && (peak - e >= threshold) {
                    totalGain += (peak - valley)
                    valley = e
                    peak = e
                    isClimbing = false
                } else if !isClimbing && (e - valley >= threshold) {
                    valley = e
                    peak = e
                    isClimbing = true
                }
            }
        }

        if isClimbing && (peak - valley >= threshold) {
            totalGain += (peak - valley)
        }

        return totalGain > 0 ? totalGain : nil
    }

    /// 计算两个经纬度之间的球面距离（Haversine 公式，单位：米）
    private func distanceBetween(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6371000.0 // 地球平均半径 (米)
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0

        let a = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2.0) * sin(dLon / 2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
        return earthRadius * c
    }
}

/// 内部 XML 解析结果模型
struct GPXInternalParseResult {
    let trackPoints: [GPXTrackPoint]
    let waypoints: [GPXWaypoint]
    let trackName: String?
}

/// 内部 XML 解析委托类（严格区分 trkpt 航迹点与 wpt 离散打卡点，彻底根治大飞线与里程翻倍）
private final class InternalXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var trackPoints: [GPXTrackPoint] = []
    private var routePoints: [GPXTrackPoint] = []
    private var waypoints: [GPXWaypoint] = []

    private let shouldCancel: (() -> Bool)?
    private let onBatch: ((Int) -> Void)?
    private weak var activeParser: XMLParser?
    var trackName: String? = nil

    private var currentElement = ""
    private var currentText = ""
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentHR: Int?
    private var currentTime: Date?
    private var currentWptName: String?
    private var currentWptCmt: String?

    private var isInsideTrk = false
    private var isInsideRte = false
    private var isInsideWpt = false
    private var hasParsedTrackName = false

    private static let isoFormatterWithMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(data: Data, shouldCancel: (() -> Bool)? = nil, onBatch: ((Int) -> Void)? = nil) {
        self.data = data
        self.shouldCancel = shouldCancel
        self.onBatch = onBatch
    }

    func parseData() -> GPXInternalParseResult {
        let parser = XMLParser(data: data)
        self.activeParser = parser
        parser.delegate = self
        parser.parse()
        self.activeParser = nil

        let chosenPoints: [GPXTrackPoint]
        if !trackPoints.isEmpty {
            chosenPoints = trackPoints
        } else if !routePoints.isEmpty {
            chosenPoints = routePoints
        } else if waypoints.count >= 2 {
            // 仅在完全缺失 trk 与 rte 时，才允许降级将离散打卡点作为连线折线
            chosenPoints = waypoints.map {
                GPXTrackPoint(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    elevation: $0.elevation,
                    time: $0.time
                )
            }
        } else {
            chosenPoints = []
        }

        return GPXInternalParseResult(
            trackPoints: chosenPoints,
            waypoints: waypoints,
            trackName: trackName
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if shouldCancel?() == true {
            activeParser?.abortParsing()
            return
        }
        currentElement = elementName
        currentText = ""

        if elementName == "trk" {
            isInsideTrk = true
        } else if elementName == "rte" {
            isInsideRte = true
        } else if elementName == "wpt" {
            isInsideWpt = true
            if let latStr = attributeDict["lat"], let lat = Double(latStr),
               let lonStr = attributeDict["lon"], let lon = Double(lonStr) {
                currentLat = lat
                currentLon = lon
            }
            currentEle = nil
            currentTime = nil
            currentWptName = nil
            currentWptCmt = nil
        } else if elementName == "trkpt" || elementName == "rtept" {
            if let latStr = attributeDict["lat"], let lat = Double(latStr),
               let lonStr = attributeDict["lon"], let lon = Double(lonStr) {
                currentLat = lat
                currentLon = lon
            }
            currentEle = nil
            currentHR = nil
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInsideWpt && elementName == "name" {
            if !trimmed.isEmpty {
                currentWptName = trimmed
            }
        } else if isInsideWpt && (elementName == "cmt" || elementName == "desc") {
            if !trimmed.isEmpty && currentWptCmt == nil {
                currentWptCmt = trimmed
            }
        } else if isInsideTrk && !hasParsedTrackName && elementName == "name" {
            if !trimmed.isEmpty {
                trackName = trimmed
                hasParsedTrackName = true
            }
        } else if elementName == "ele" {
            currentEle = Double(trimmed)
        } else if elementName == "gpxtpx:hr" || elementName == "hr" || elementName == "heartrate" {
            currentHR = Int(trimmed)
        } else if elementName == "time" {
            if let d = Self.isoFormatterWithMillis.date(from: trimmed) ?? Self.isoFormatterBasic.date(from: trimmed) {
                currentTime = d
            }
        } else if elementName == "wpt" {
            if shouldCancel?() == true {
                activeParser?.abortParsing()
                return
            }
            if let lat = currentLat, let lon = currentLon {
                waypoints.append(GPXWaypoint(
                    name: currentWptName,
                    comment: currentWptCmt,
                    latitude: lat,
                    longitude: lon,
                    elevation: currentEle,
                    time: currentTime
                ))
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentTime = nil
            currentWptName = nil
            currentWptCmt = nil
            isInsideWpt = false
        } else if elementName == "trkpt" {
            if shouldCancel?() == true {
                activeParser?.abortParsing()
                return
            }
            if let lat = currentLat, let lon = currentLon {
                trackPoints.append(GPXTrackPoint(
                    latitude: lat,
                    longitude: lon,
                    elevation: currentEle,
                    time: currentTime,
                    heartRate: currentHR
                ))
                onBatch?(trackPoints.count)
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentHR = nil
            currentTime = nil
        } else if elementName == "rtept" {
            if shouldCancel?() == true {
                activeParser?.abortParsing()
                return
            }
            if let lat = currentLat, let lon = currentLon {
                routePoints.append(GPXTrackPoint(
                    latitude: lat,
                    longitude: lon,
                    elevation: currentEle,
                    time: currentTime
                ))
                onBatch?(routePoints.count)
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentTime = nil
        } else if elementName == "trk" {
            isInsideTrk = false
        } else if elementName == "rte" {
            isInsideRte = false
        }
    }
}
