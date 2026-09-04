import XCTest
import CoreLocation
@testable import PhotoolsCore

final class MapTileProviderTests: XCTestCase {

    func testTileProviderCasesAndProperties() {
        XCTAssertEqual(MapTileProvider.allCases.count, 4)

        for provider in MapTileProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.shortName.isEmpty)
            XCTAssertFalse(provider.subtitle.isEmpty)
            XCTAssertFalse(provider.tileURLs.isEmpty)
            XCTAssertGreaterThanOrEqual(provider.maxZoom, 18)

            for url in provider.tileURLs {
                XCTAssertTrue(url.contains("{z}"))
                XCTAssertTrue(url.contains("{x}"))
                XCTAssertTrue(url.contains("{y}"))
            }
        }
    }

    func testCoordinateSystemMapping() {
        XCTAssertEqual(MapTileProvider.googleSatellite.coordinateSystem, .wgs84)
        XCTAssertEqual(MapTileProvider.googleHybrid.coordinateSystem, .wgs84)
        XCTAssertEqual(MapTileProvider.esriSatellite.coordinateSystem, .wgs84)
        XCTAssertEqual(MapTileProvider.autoNaviSatellite.coordinateSystem, .gcj02)
    }

    func testRenderCoordinateInsideChina() {
        // 广州天河坐标 (境内)
        let wgs = CLLocationCoordinate2D(latitude: 23.128782, longitude: 113.397693)

        // Google 与 ESRI 必须原样输出 WGS-84，零偏移
        let googleCoord = MapTileProvider.googleSatellite.renderCoordinate(for: wgs)
        XCTAssertEqual(googleCoord.latitude, wgs.latitude, accuracy: 0.000001)
        XCTAssertEqual(googleCoord.longitude, wgs.longitude, accuracy: 0.000001)

        let esriCoord = MapTileProvider.esriSatellite.renderCoordinate(for: wgs)
        XCTAssertEqual(esriCoord.latitude, wgs.latitude, accuracy: 0.000001)
        XCTAssertEqual(esriCoord.longitude, wgs.longitude, accuracy: 0.000001)

        // 高德图源必须输出 GCJ-02 纠偏坐标以匹配切片
        let autoNaviCoord = MapTileProvider.autoNaviSatellite.renderCoordinate(for: wgs)
        XCTAssertNotEqual(autoNaviCoord.latitude, wgs.latitude)
        XCTAssertNotEqual(autoNaviCoord.longitude, wgs.longitude)
        XCTAssertEqual(autoNaviCoord.latitude, 23.126287, accuracy: 0.0001)
        XCTAssertEqual(autoNaviCoord.longitude, 113.403218, accuracy: 0.0001)
    }

    func testRenderCoordinateOutsideChina() {
        // 日本东京坐标 (境外)
        let tokyo = CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917)

        for provider in MapTileProvider.allCases {
            let rendered = provider.renderCoordinate(for: tokyo)
            XCTAssertEqual(rendered.latitude, tokyo.latitude, accuracy: 0.000001)
            XCTAssertEqual(rendered.longitude, tokyo.longitude, accuracy: 0.000001)
        }
    }
}
