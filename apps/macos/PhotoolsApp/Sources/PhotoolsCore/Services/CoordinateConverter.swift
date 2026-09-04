import Foundation
import CoreLocation
import AppKit

/// 地理坐标转换中枢 (WGS-84 / GCJ-02 / BD-09)
/// 针对中国大陆境内地图偏转法规与 Apple 地图（高德底图）自适应纠偏设计
public enum CoordinateConverter {
    private static let xPI = Double.pi * 3000.0 / 180.0
    private static let ee = 0.00669342162296594323 // 椭球偏心率平方
    private static let a = 6378245.0               // 椭球长半轴 (米)

    /// 判断坐标是否在中国境外 (境外不应加偏)
    public static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        if longitude < 72.004 || longitude > 137.8347 { return true }
        if latitude < 0.8293 || latitude > 55.8271 { return true }
        return false
    }

    /// WGS-84 (真实 GPS) -> GCJ-02 (高德/腾讯/国测局火星坐标)
    public static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        let (dLat, dLng) = delta(latitude: latitude, longitude: longitude)
        return (latitude + dLat, longitude + dLng)
    }

    /// GCJ-02 (高德/火星坐标) -> WGS-84 (真实 GPS，误差约 1~2 米)
    public static func gcj02ToWGS84(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        let (dLat, dLng) = delta(latitude: latitude, longitude: longitude)
        return (latitude - dLat, longitude - dLng)
    }

    /// GCJ-02 (高德) -> BD-09 (百度地图)
    public static func gcj02ToBD09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let z = sqrt(longitude * longitude + latitude * latitude) + 0.00002 * sin(latitude * xPI)
        let theta = atan2(latitude, longitude) + 0.000003 * cos(longitude * xPI)
        let bdLng = z * cos(theta) + 0.0065
        let bdLat = z * sin(theta) + 0.006
        return (bdLat, bdLng)
    }

    /// BD-09 (百度地图) -> GCJ-02 (高德)
    public static func bd09ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let x = longitude - 0.0065
        let y = latitude - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * xPI)
        let theta = atan2(y, x) - 0.000003 * cos(x * xPI)
        let gcjLng = z * cos(theta)
        let gcjLat = z * sin(theta)
        return (gcjLat, gcjLng)
    }

    /// WGS-84 -> BD-09 (百度地图)
    public static func wgs84ToBD09(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let (gcjLat, gcjLng) = wgs84ToGCJ02(latitude: latitude, longitude: longitude)
        return gcj02ToBD09(latitude: gcjLat, longitude: gcjLng)
    }

    /// BD-09 (百度地图) -> WGS-84 (真实 GPS)
    public static func bd09ToWGS84(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let (gcjLat, gcjLng) = bd09ToGCJ02(latitude: latitude, longitude: longitude)
        return gcj02ToWGS84(latitude: gcjLat, longitude: gcjLng)
    }

    /// 转换为适合在 macOS 系统地图(Apple Maps)中呈现的坐标
    /// - 注：中国大陆境内 Apple Maps 底图采用高德 GCJ-02，境外保持原始 WGS-84
    public static func appleMapsCoordinate(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        return wgs84ToGCJ02(latitude: latitude, longitude: longitude)
    }

    /// 在 macOS 系统自带地图 (Apple Maps) 中精准打开该机位
    /// - Parameters:
    ///   - latitude: 原始 WGS-84 纬度
    ///   - longitude: 原始 WGS-84 经度
    ///   - label: 地图标记标题（如照片文件名或拍摄地名）
    @discardableResult
    public static func openInAppleMaps(latitude: Double, longitude: Double, label: String? = nil) -> Bool {
        let (mapLat, mapLng) = appleMapsCoordinate(latitude: latitude, longitude: longitude)
        let title = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        var urlString = "http://maps.apple.com/?ll=\(mapLat),\(mapLng)&q="
        if !encodedTitle.isEmpty {
            urlString += encodedTitle
        } else {
            urlString += "\(mapLat),\(mapLng)"
        }

        if let url = URL(string: urlString) {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - 摄影视场角 (FOV) 与视锥几何计算

    /// 根据镜头等效焦距计算水平视场角 (Field of View，单位：角度)
    /// - Parameters:
    ///   - focalLength: 35mm 等效焦距 (毫米，如 24.0, 86.0)
    ///   - sensorWidth: 传感器宽度 (全画幅默认为 36.0mm)
    public static func calculateFOV(focalLength: Double, sensorWidth: Double = 36.0) -> Double {
        guard focalLength > 1.0 else { return 60.0 }
        let rad = 2.0 * atan(sensorWidth / (2.0 * focalLength))
        return rad * 180.0 / Double.pi
    }

    /// 根据机位坐标、镜头朝向角度与视场角生成闭合扇形视锥多边形点集
    /// - Parameters:
    ///   - center: 机位经纬度 (如已纠偏的高德坐标)
    ///   - heading: 镜头成像朝向 (0~360°，0 为正北，90 为正东)
    ///   - fov: 水平视场角 (度数，如 86mm 对应 23.6°)
    ///   - distanceMeters: 视锥投射视距 (米，默认 1500 米)
    ///   - steps: 扇形弧线采样点数 (平滑度)
    public static func generateViewConeCoordinates(
        center: CLLocationCoordinate2D,
        heading: Double,
        fov: Double,
        distanceMeters: Double = 1500.0,
        steps: Int = 16
    ) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = [center]

        let halfFov = fov / 2.0
        let startAngle = heading - halfFov
        let endAngle = heading + halfFov
        let stepDelta = (endAngle - startAngle) / Double(max(steps, 4))

        let metersPerLat = 111132.954 - 559.822 * cos(2.0 * center.latitude * Double.pi / 180.0)
        let metersPerLng = 111412.84 * cos(center.latitude * Double.pi / 180.0)

        for i in 0...steps {
            let angleDeg = startAngle + Double(i) * stepDelta
            let angleRad = angleDeg * Double.pi / 180.0

            // 0度为正北(Y轴正向)，90度为正东(X轴正向)
            let dx = distanceMeters * sin(angleRad)
            let dy = distanceMeters * cos(angleRad)

            let pLat = center.latitude + (dy / metersPerLat)
            let pLng = center.longitude + (dx / metersPerLng)
            coords.append(CLLocationCoordinate2D(latitude: pLat, longitude: pLng))
        }

        // 闭合多边形回到机位中心
        coords.append(center)
        return coords
    }

    /// 根据 35mm 等效焦距、真实对焦距离与机位高程智能给出推荐的 3D 地图观察视距 (米)
    public static func suggestedDistance(
        focalLength35mm: Double?,
        focusDistanceMeters: Double? = nil,
        altitudeMeters: Double? = nil,
        pitchDegrees: Double? = nil
    ) -> Double {
        // 若存在机身物理对焦距离且在近景/中景合理范围 (0.5m ~ 500m)，视距精准锚定于主体对焦范围 (主体距离的 2 倍)
        if let fd = focusDistanceMeters, fd >= 0.5 && fd <= 500.0 {
            return max(fd * 2.0, 35.0)
        }
        guard let fl = focalLength35mm, fl > 1.0 else { return 3000.0 }

        // 高海拔/高地远眺启发式模型 (High-Altitude Overlook Heuristic)
        // 例如白云山 (137m)、景山、高楼顶层远眺天际线，焦点在无穷远，视野向远方城市或山川延展
        if let alt = altitudeMeters, alt >= 80.0, fl >= 35.0 {
            let p = pitchDegrees ?? 0.0
            if p <= 15.0 { // 平视或俯视远眺
                return 7200.0 // 默认推荐 7.2km，完美覆盖远方核心天际线 (如中信至广州塔)
            }
        }

        switch fl {
        case ..<20.0:
            return 1500.0 // 超广角：贴近近景
        case 20.0..<35.0:
            return 2500.0 // 广角：大环境呈现
        case 35.0..<70.0:
            return 3500.0 // 标准人文
        case 70.0..<200.0:
            return 6000.0 // 中长焦：山川地貌压缩
        default:
            return 10000.0 // 超长焦：远眺数公里外雪山/山脉
        }
    }

    /// 默认最小 3D 观察视距 (米)
    public static let minViewDistance: Double = 15.0

    /// 默认最大 3D 观察视距 (米)，150km (150,000m) 充分覆盖超远眺博格达峰、四姑娘山、川西及西藏雪山群峰与天际线
    public static let maxViewDistance: Double = 150000.0

    /// 对数视距映射：将真实米数 (15m ~ 150000m) 映射为归一化滑块进度 (0.0 ~ 1.0)
    public static func distanceToLogProgress(
        _ distance: Double,
        minDistance: Double = minViewDistance,
        maxDistance: Double = maxViewDistance
    ) -> Double {
        let clamped = max(minDistance, min(maxDistance, distance))
        let logMin = log(minDistance)
        let logMax = log(maxDistance)
        return (log(clamped) - logMin) / (logMax - logMin)
    }

    /// 对数视距反向映射：将归一化滑块进度 (0.0 ~ 1.0) 还原为平滑取整的真实米数 (15m ~ 150000m)
    public static func logProgressToDistance(
        _ progress: Double,
        minDistance: Double = minViewDistance,
        maxDistance: Double = maxViewDistance
    ) -> Double {
        let p = max(0.0, min(1.0, progress))
        let logMin = log(minDistance)
        let logMax = log(maxDistance)
        let rawDist = exp(logMin + p * (logMax - logMin))
        return quantizeDistance(rawDist)
    }

    /// 依据人类空间尺度进行整洁优雅取整
    public static func quantizeDistance(_ rawDist: Double) -> Double {
        if rawDist < 50.0 {
            return rawDist.rounded()
        } else if rawDist < 200.0 {
            return (rawDist / 5.0).rounded() * 5.0
        } else if rawDist < 1000.0 {
            return (rawDist / 20.0).rounded() * 20.0
        } else if rawDist < 5000.0 {
            return (rawDist / 50.0).rounded() * 50.0
        } else if rawDist < 20000.0 {
            return (rawDist / 100.0).rounded() * 100.0
        } else if rawDist < 60000.0 {
            return (rawDist / 250.0).rounded() * 250.0
        } else {
            return (rawDist / 500.0).rounded() * 500.0
        }
    }

    /// 将视距米数平滑映射为 MapLibre / Web 墨卡托缩放级别 (Zoom Level 4.0 ~ 18.5)
    public static func distanceMetersToMapZoom(distanceMeters: Double) -> Double {
        let d = max(minViewDistance, min(maxViewDistance, distanceMeters))
        let zoom = 18.5 - log2(d / minViewDistance) * 0.85
        return max(4.0, min(18.5, zoom))
    }

    /// 将地图缩放级别逆向映射为视距米数 (15m ~ 150000m)
    public static func mapZoomToDistanceMeters(zoom: Double) -> Double {
        let clampedZoom = max(4.0, min(18.5, zoom))
        let exponent = (18.5 - clampedZoom) / 0.85
        let dist = minViewDistance * pow(2.0, exponent)
        return quantizeDistance(dist)
    }

    /// 根据起点坐标、航向角 (真北顺时针) 和距离投射前方目标点的经纬度
    public static func projectTargetCoordinate(
        from start: CLLocationCoordinate2D,
        heading: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let angleRad = heading * Double.pi / 180.0
        let metersPerLat = 111132.954 - 559.822 * cos(2.0 * start.latitude * Double.pi / 180.0)
        let metersPerLng = 111412.84 * cos(start.latitude * Double.pi / 180.0)

        let dx = distanceMeters * sin(angleRad)
        let dy = distanceMeters * cos(angleRad)

        let lat = start.latitude + (dy / metersPerLat)
        let lng = start.longitude + (dx / metersPerLng)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// 计算两点间的大圆初始航向角 (Bearing / Course，0~360°，0 为正北)
    public static func calculateBearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * Double.pi / 180.0
        let lon1 = start.longitude * Double.pi / 180.0
        let lat2 = end.latitude * Double.pi / 180.0
        let lon2 = end.longitude * Double.pi / 180.0

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)
        let degrees = radiansBearing * 180.0 / Double.pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    // MARK: - 私有数学变换

    private static func delta(latitude: Double, longitude: Double) -> (dLat: Double, dLng: Double) {
        var dLat = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var dLng = transformLng(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * Double.pi)
        return (dLat, dLng)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return ret
    }
}

// MARK: - CLLocationCoordinate2D 扩展便捷语法
extension CLLocationCoordinate2D {
    /// 判断是否在中国境外
    public var isOutOfChina: Bool {
        CoordinateConverter.isOutOfChina(latitude: latitude, longitude: longitude)
    }

    /// 转换为 Apple Maps 坐标 (境内高德火星偏转，境外标准 WGS-84)
    public func toAppleMapsCoordinate() -> CLLocationCoordinate2D {
        let (lat, lng) = CoordinateConverter.appleMapsCoordinate(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// WGS-84 -> GCJ-02 (高德)
    public func toGCJ02() -> CLLocationCoordinate2D {
        let (lat, lng) = CoordinateConverter.wgs84ToGCJ02(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// GCJ-02 -> WGS-84
    public func toWGS84FromGCJ02() -> CLLocationCoordinate2D {
        let (lat, lng) = CoordinateConverter.gcj02ToWGS84(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// WGS-84 -> BD-09 (百度)
    public func toBD09() -> CLLocationCoordinate2D {
        let (lat, lng) = CoordinateConverter.wgs84ToBD09(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// BD-09 -> WGS-84
    public func toWGS84FromBD09() -> CLLocationCoordinate2D {
        let (lat, lng) = CoordinateConverter.bd09ToWGS84(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// 打开系统自带地图
    @discardableResult
    public func openInAppleMaps(label: String? = nil) -> Bool {
        CoordinateConverter.openInAppleMaps(latitude: latitude, longitude: longitude, label: label)
    }
}
