import XCTest
import CoreLocation
@testable import PhotoolsCore

final class CoordinateConverterTests: XCTestCase {
    // 北京天安门广场 WGS-84 原始真实坐标
    private let beijingWGS84Lat = 39.908722
    private let beijingWGS84Lng = 116.397499

    // 巴黎埃菲尔铁塔 WGS-84 真实坐标 (境外)
    private let parisWGS84Lat = 48.858370
    private let parisWGS84Lng = 2.294481

    // 东京塔 WGS-84 真实坐标 (境外)
    private let tokyoWGS84Lat = 35.658581
    private let tokyoWGS84Lng = 139.745433

    func testOutOfChinaDetection() {
        // 境内点
        XCTAssertFalse(CoordinateConverter.isOutOfChina(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng))
        XCTAssertFalse(CoordinateConverter.isOutOfChina(latitude: 31.2304, longitude: 121.4737)) // 上海
        XCTAssertFalse(CoordinateConverter.isOutOfChina(latitude: 22.5431, longitude: 114.0579)) // 深圳

        // 境外点
        XCTAssertTrue(CoordinateConverter.isOutOfChina(latitude: parisWGS84Lat, longitude: parisWGS84Lng))
        XCTAssertTrue(CoordinateConverter.isOutOfChina(latitude: tokyoWGS84Lat, longitude: tokyoWGS84Lng))
        XCTAssertTrue(CoordinateConverter.isOutOfChina(latitude: 40.7128, longitude: -74.0060)) // 纽约
    }

    func testWGS84ToGCJ02AndBack() {
        let (gcjLat, gcjLng) = CoordinateConverter.wgs84ToGCJ02(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)

        // 境内点经纬度必须有非零偏移
        XCTAssertNotEqual(gcjLat, beijingWGS84Lat)
        XCTAssertNotEqual(gcjLng, beijingWGS84Lng)

        // 反算回 WGS84
        let (backLat, backLng) = CoordinateConverter.gcj02ToWGS84(latitude: gcjLat, longitude: gcjLng)
        XCTAssertEqual(backLat, beijingWGS84Lat, accuracy: 0.00005, "还原后纬度误差应小于 5 米")
        XCTAssertEqual(backLng, beijingWGS84Lng, accuracy: 0.00005, "还原后经度误差应小于 5 米")
    }

    func testGCJ02ToBD09AndBack() {
        let (gcjLat, gcjLng) = CoordinateConverter.wgs84ToGCJ02(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)
        let (bdLat, bdLng) = CoordinateConverter.gcj02ToBD09(latitude: gcjLat, longitude: gcjLng)

        let (backGcjLat, backGcjLng) = CoordinateConverter.bd09ToGCJ02(latitude: bdLat, longitude: bdLng)
        XCTAssertEqual(backGcjLat, gcjLat, accuracy: 0.00001)
        XCTAssertEqual(backGcjLng, gcjLng, accuracy: 0.00001)
    }

    func testWGS84ToBD09AndBack() {
        let (bdLat, bdLng) = CoordinateConverter.wgs84ToBD09(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)
        let (backWgsLat, backWgsLng) = CoordinateConverter.bd09ToWGS84(latitude: bdLat, longitude: bdLng)

        XCTAssertEqual(backWgsLat, beijingWGS84Lat, accuracy: 0.00005)
        XCTAssertEqual(backWgsLng, beijingWGS84Lng, accuracy: 0.00005)
    }

    func testAppleMapsCoordinatePolicy() {
        // 境内点必须加偏转为 GCJ-02 (匹配高德底图)
        let (chinaMapLat, chinaMapLng) = CoordinateConverter.appleMapsCoordinate(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)
        let (expectedGcjLat, expectedGcjLng) = CoordinateConverter.wgs84ToGCJ02(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)
        XCTAssertEqual(chinaMapLat, expectedGcjLat)
        XCTAssertEqual(chinaMapLng, expectedGcjLng)

        // 境外点必须保持原始 WGS-84 (境外 Apple Maps 原生国际底图)
        let (abroadMapLat, abroadMapLng) = CoordinateConverter.appleMapsCoordinate(latitude: parisWGS84Lat, longitude: parisWGS84Lng)
        XCTAssertEqual(abroadMapLat, parisWGS84Lat)
        XCTAssertEqual(abroadMapLng, parisWGS84Lng)
    }

    func testCLLocationCoordinate2DExtension() {
        let coord = CLLocationCoordinate2D(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng)
        XCTAssertFalse(coord.isOutOfChina)

        let appleCoord = coord.toAppleMapsCoordinate()
        XCTAssertEqual(appleCoord.latitude, CoordinateConverter.appleMapsCoordinate(latitude: beijingWGS84Lat, longitude: beijingWGS84Lng).latitude)

        let gcjCoord = coord.toGCJ02()
        let restoredWgs = gcjCoord.toWGS84FromGCJ02()
        XCTAssertEqual(restoredWgs.latitude, beijingWGS84Lat, accuracy: 0.00005)
    }

    func testCalculateFOV() {
        // 34mm 焦距 (用户实拍照片实测参数)
        let fov34 = CoordinateConverter.calculateFOV(focalLength: 34.0)
        XCTAssertEqual(fov34, 55.7, accuracy: 0.5, "34mm 全画幅视场角应约为 55.7°")

        // 86mm 焦距 (用户雪山照片实测参数)
        let fov86 = CoordinateConverter.calculateFOV(focalLength: 86.0)
        XCTAssertEqual(fov86, 23.6, accuracy: 0.5, "86mm 全画幅视场角应约为 23.6°")

        // 24mm 广角端
        let fov24 = CoordinateConverter.calculateFOV(focalLength: 24.0)
        XCTAssertEqual(fov24, 73.7, accuracy: 0.5, "24mm 广角视场角应约为 73.7°")

        // 120mm 长焦端
        let fov120 = CoordinateConverter.calculateFOV(focalLength: 120.0)
        XCTAssertEqual(fov120, 17.1, accuracy: 0.5, "120mm 长焦视场角应约为 17.1°")
    }

    func testGenerateViewConeCoordinates() {
        let center = CLLocationCoordinate2D(latitude: 42.671969, longitude: 80.591589)
        let heading = 89.3 // 正东略偏南
        let fov = 55.7     // 34mm 视锥
        let steps = 16

        let coords = CoordinateConverter.generateViewConeCoordinates(
            center: center,
            heading: heading,
            fov: fov,
            distanceMeters: 2000.0,
            steps: steps
        )

        // 点数应为 steps + 3 (起点 + steps+1 个弧点 + 回到起点)
        XCTAssertEqual(coords.count, steps + 3)

        // 起点与终点必须严格等于机位中心 (构成闭合多边形)
        XCTAssertEqual(coords.first?.latitude, center.latitude)
        XCTAssertEqual(coords.first?.longitude, center.longitude)
        XCTAssertEqual(coords.last?.latitude, center.latitude)
        XCTAssertEqual(coords.last?.longitude, center.longitude)
    }

    func testLogDistanceProgressMapping() {
        // 1. 默认 150km (150000m) 极远眺雪山尺度测试
        let pMin = CoordinateConverter.distanceToLogProgress(15.0)
        XCTAssertEqual(pMin, 0.0, accuracy: 0.001)

        let pMax = CoordinateConverter.distanceToLogProgress(CoordinateConverter.maxViewDistance)
        XCTAssertEqual(pMax, 1.0, accuracy: 0.001)

        // 2. 单调递增性验证 (涵盖中近景与远山尺度)
        let d50 = CoordinateConverter.distanceToLogProgress(50.0)
        let d500 = CoordinateConverter.distanceToLogProgress(500.0)
        let d5000 = CoordinateConverter.distanceToLogProgress(5000.0)
        let dBogda = CoordinateConverter.distanceToLogProgress(60000.0) // 乌鲁木齐远眺博格达峰 (~60km)
        XCTAssertTrue(d50 < d500)
        XCTAssertTrue(d500 < d5000)
        XCTAssertTrue(d5000 < dBogda)
        XCTAssertTrue(dBogda < 1.0)

        // 3. 反向映射闭环测试
        let restored15 = CoordinateConverter.logProgressToDistance(0.0)
        XCTAssertEqual(restored15, 15.0, accuracy: 1.0)

        let restoredMax = CoordinateConverter.logProgressToDistance(1.0)
        XCTAssertEqual(restoredMax, CoordinateConverter.maxViewDistance, accuracy: 500.0)

        let restored500 = CoordinateConverter.logProgressToDistance(d500)
        XCTAssertEqual(restored500, 500.0, accuracy: 25.0)

        let restoredBogda = CoordinateConverter.logProgressToDistance(dBogda)
        XCTAssertEqual(restoredBogda, 60000.0, accuracy: 500.0)

        // 4. 自定义 maxDistance 兼容性测试
        let pCustomMax = CoordinateConverter.distanceToLogProgress(12000.0, maxDistance: 12000.0)
        XCTAssertEqual(pCustomMax, 1.0, accuracy: 0.001)
        let restoredCustom = CoordinateConverter.logProgressToDistance(1.0, maxDistance: 12000.0)
        XCTAssertEqual(restoredCustom, 12000.0, accuracy: 100.0)
    }

    func testSuggestedDistanceWithAltitudeHeuristic() {
        // 白云山远眺场景实测 (海拔 137m, 52mm 焦距, 俯仰角接近水平 5°)
        let distBaiyun = CoordinateConverter.suggestedDistance(
            focalLength35mm: 52.0,
            focusDistanceMeters: nil,
            altitudeMeters: 137.0,
            pitchDegrees: 5.0
        )
        // 应当自适应拓展至 7200m 覆盖广州塔视距
        XCTAssertEqual(distBaiyun, 7200.0, accuracy: 1.0)

        // 纯平地场景 (海拔 10m, 52mm 焦距)
        let distFlat = CoordinateConverter.suggestedDistance(
            focalLength35mm: 52.0,
            focusDistanceMeters: nil,
            altitudeMeters: 10.0,
            pitchDegrees: 5.0
        )
        // 维持标准 3500m
        XCTAssertEqual(distFlat, 3500.0, accuracy: 1.0)
    }

    func testDistanceMetersToMapZoom() {
        // 近距离 15m 对应高缩放级别
        let zoomNear = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: 15.0)
        XCTAssertEqual(zoomNear, 18.5, accuracy: 0.1)

        // 远距离 10000m 对应低缩放级别
        let zoomFar = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: 10000.0)
        XCTAssertTrue(zoomFar < 11.5)
        XCTAssertTrue(zoomFar > 9.5)

        // 递减单调性断言
        let zoom100 = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: 100.0)
        let zoom1000 = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: 1000.0)
        XCTAssertTrue(zoomNear > zoom100)
        XCTAssertTrue(zoom100 > zoom1000)
        XCTAssertTrue(zoom100 > zoomFar)
    }

    func testMapZoomToDistanceMetersAndQuantize() {
        // 1. 缩放反向映射闭环测试
        let distAtMaxZoom = CoordinateConverter.mapZoomToDistanceMeters(zoom: 18.5)
        XCTAssertEqual(distAtMaxZoom, 15.0, accuracy: 1.0, "最高缩放级别应对应最近视距 ~15m")

        let distAtZoom15 = CoordinateConverter.mapZoomToDistanceMeters(zoom: 15.0)
        let zoomReconverted = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: distAtZoom15)
        XCTAssertEqual(zoomReconverted, 15.0, accuracy: 0.5, "反向推导视距再转回 zoom 应高度逼近原值")

        // 2. 单调性验证：zoom 越大，视距越小
        let distHighZoom = CoordinateConverter.mapZoomToDistanceMeters(zoom: 17.0)
        let distLowZoom = CoordinateConverter.mapZoomToDistanceMeters(zoom: 12.0)
        XCTAssertTrue(distHighZoom < distLowZoom)

        // 3. quantizeDistance 优雅取整测试 (覆盖中近景与远眺雪山尺度)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(34.2), 34.0)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(123.4), 125.0)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(456.7), 460.0)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(2340.0), 2350.0)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(7830.0), 7800.0)
        XCTAssertEqual(CoordinateConverter.quantizeDistance(58320.0), 58250.0, "58km 远眺博格达雪山应按 250m 优雅取整")
        XCTAssertEqual(CoordinateConverter.quantizeDistance(120340.0), 120500.0, "120km 超远眺应按 500m 优雅取整")

        // 4. 超远眺 150km 缩放级别边界测试
        let zoom150km = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: 150000.0)
        XCTAssertTrue(zoom150km >= 4.0 && zoom150km <= 8.0, "150km 应映射至 WebGL 瓦片安全缩放区间")
    }
}

