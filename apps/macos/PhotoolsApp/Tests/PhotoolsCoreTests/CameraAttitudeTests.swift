import XCTest
import CoreLocation
@testable import PhotoolsCore

final class CameraAttitudeTests: XCTestCase {

    func testAppleAttitudeStrategyRealWorldIPhone() {
        let dict: [String: Any] = [
            "Make": "Apple",
            "Model": "iPhone 13 Pro",
            "GPS:GPSImgDirection": 72.69711311,
            "GPS:GPSImgDirectionRef": "True North",
            "MakerNotes:AccelerationVector": "-0.9796136019 0.01809608005 0.1817096768",
            "Composite:FOV": "76.1 deg",
            "EXIF:FocalLengthIn35mmFormat": 23.0
        ]

        let strategy = AppleAttitudeStrategy()
        XCTAssertTrue(strategy.canHandle(make: "Apple", model: "iPhone 13 Pro", dict: dict))

        let attitude = strategy.extractAttitude(from: dict, make: "Apple", model: "iPhone 13 Pro")
        XCTAssertEqual(attitude.strategyName, "AppleAttitude")
        XCTAssertNotNil(attitude.heading)
        XCTAssertEqual(attitude.heading!, 72.69711311, accuracy: 0.001)

        // 验证物理仰角计算: atan2(0.1817, sqrt((-0.9796)^2 + 0.0181^2)) * 180 / pi ≈ 10.5°
        XCTAssertNotNil(attitude.pitch)
        XCTAssertEqual(attitude.pitch!, 10.51, accuracy: 0.2)

        // 验证视场角
        XCTAssertNotNil(attitude.fov)
        XCTAssertEqual(attitude.fov!, 76.1, accuracy: 0.1)

        // 验证 23mm 视距建议
        XCTAssertEqual(attitude.suggestedDistanceMeters, 2500.0)

        // 验证注册中心自动分发
        let resolved = CameraAttitudeRegistry.shared.resolve(from: dict, make: "Apple", model: "iPhone 13 Pro")
        XCTAssertEqual(resolved.strategyName, "AppleAttitude")
    }

    func testIPhoneDestBearingWhenImgDirectionMissing() {
        // 模拟 DSC_2024-10-06_2582.jpeg 真实场景：仅含 GPSDestBearing，无 GPSImgDirection
        let dict: [String: Any] = [
            "Make": "Apple",
            "Model": "iPhone 14 Pro",
            "GPS:GPSDestBearing": 291.8980084,
            "GPS:GPSDestBearingRef": "True North",
            "MakerNotes:AccelerationVector": "0.9786688093 0.03133243322 0.1529765277",
            "Composite:FOV": "31.9 deg",
            "EXIF:FocalLengthIn35mmFormat": 63.0
        ]

        let strategy = AppleAttitudeStrategy()
        XCTAssertTrue(strategy.canHandle(make: "Apple", model: "iPhone 14 Pro", dict: dict))

        let attitude = strategy.extractAttitude(from: dict, make: "Apple", model: "iPhone 14 Pro")
        XCTAssertEqual(attitude.strategyName, "AppleAttitude")
        XCTAssertNotNil(attitude.heading)
        // 关键断言：正确解析出 291.898° 航向角（红色箭头），绝非 0.0° 正北
        XCTAssertEqual(attitude.heading!, 291.8980084, accuracy: 0.001)

        // 验证视场角
        XCTAssertEqual(attitude.fov!, 31.9, accuracy: 0.1)

        // 验证 63mm 焦距视距建议 (35mm~70mm 为 3500m)
        XCTAssertEqual(attitude.suggestedDistanceMeters, 3500.0)

        // 验证注册中心解析
        let resolved = CameraAttitudeRegistry.shared.resolve(from: dict, make: "Apple", model: "iPhone 14 Pro")
        XCTAssertEqual(resolved.heading!, 291.8980084, accuracy: 0.001)
    }

    func testNikonAttitudeStrategyWithVRGyro() {
        let dict: [String: Any] = [
            "Make": "NIKON CORPORATION",
            "Model": "NIKON Z 8",
            "MakerNotes:PitchAngle": -4.8,
            "MakerNotes:RollAngle": 0.5,
            "MakerNotes:YawAngle": 15.2,
            "EXIF:FocalLengthIn35mmFormat": 85.0
        ]

        let strategy = NikonAttitudeStrategy()
        XCTAssertTrue(strategy.canHandle(make: "NIKON CORPORATION", model: "NIKON Z 8", dict: dict))

        let attitude = strategy.extractAttitude(from: dict, make: "NIKON CORPORATION", model: "NIKON Z 8")
        XCTAssertEqual(attitude.strategyName, "NikonAttitude")
        XCTAssertNil(attitude.heading) // 尼康机内陀螺仪无绝对真北
        XCTAssertEqual(attitude.pitch!, -4.8, accuracy: 0.01)
        XCTAssertEqual(attitude.roll!, 0.5, accuracy: 0.01)
        XCTAssertEqual(attitude.yaw!, 15.2, accuracy: 0.01)

        // 85mm 镜头视距建议为 6000m
        XCTAssertEqual(attitude.suggestedDistanceMeters, 6000.0)
    }

    func testNikonZ6WithFocusDistanceAndHeading() {
        // 模拟 DSC_2025-10-07_260_008_edit_nx 真实场景：93mm 镜头拍摄 17.4m 处的马
        let dict: [String: Any] = [
            "Make": "NIKON CORPORATION",
            "Model": "NIKON Z6_3",
            "GPS:GPSImgDirection": 195.0,
            "GPS:GPSImgDirectionRef": "True North",
            "MakerNotes:FocusDistance": "17.4 m",
            "EXIF:FocalLengthIn35mmFormat": 93.0
        ]

        let attitude = NikonAttitudeStrategy().extractAttitude(from: dict, make: "NIKON CORPORATION", model: "NIKON Z6_3")
        XCTAssertEqual(attitude.strategyName, "NikonAttitude")
        XCTAssertEqual(attitude.heading, 195.0)
        XCTAssertEqual(attitude.focusDistanceMeters, 17.4)
        // 关键断言：视距智能锚定于真实主体对焦距离 (17.4 * 2 = 34.8 -> 35.0m)，绝非机械的 6000m
        XCTAssertEqual(attitude.suggestedDistanceMeters, 35.0)
    }

    func testStandardExifFallback() {
        let dict: [String: Any] = [
            "Make": "FUJIFILM",
            "Model": "X-T5",
            "GPSImgDirection": 180.0,
            "FocalLengthIn35mmFormat": 35.0
        ]

        let resolved = CameraAttitudeRegistry.shared.resolve(from: dict, make: "FUJIFILM", model: "X-T5")
        XCTAssertEqual(resolved.strategyName, "StandardExif")
        XCTAssertEqual(resolved.heading, 180.0)
        XCTAssertEqual(resolved.suggestedDistanceMeters, 3500.0)
    }

    func testCoordinateTargetProjectionAndBearing() {
        let start = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074) // 北京天安门
        // 沿正东 (90°) 投射 1000 米
        let targetEast = CoordinateConverter.projectTargetCoordinate(from: start, heading: 90.0, distanceMeters: 1000.0)
        XCTAssertEqual(targetEast.latitude, start.latitude, accuracy: 0.0001)
        XCTAssertGreaterThan(targetEast.longitude, start.longitude)

        // 计算反向航向
        let bearing = CoordinateConverter.calculateBearing(from: start, to: targetEast)
        XCTAssertEqual(bearing, 90.0, accuracy: 0.1)

        // 沿正北 (0°) 投射 1000 米
        let targetNorth = CoordinateConverter.projectTargetCoordinate(from: start, heading: 0.0, distanceMeters: 1000.0)
        XCTAssertGreaterThan(targetNorth.latitude, start.latitude)
        XCTAssertEqual(targetNorth.longitude, start.longitude, accuracy: 0.0001)

        let bearingNorth = CoordinateConverter.calculateBearing(from: start, to: targetNorth)
        XCTAssertEqual(bearingNorth, 0.0, accuracy: 0.1)
    }
}
