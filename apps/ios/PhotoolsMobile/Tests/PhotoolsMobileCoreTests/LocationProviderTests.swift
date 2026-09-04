import XCTest
import CoreLocation
@testable import PhotoolsMobileCore

final class LocationProviderTests: XCTestCase {
    
    func testCruiseModeConfigurationSwitch() {
        let provider = LocationProvider()
        
        // 默认非巡航状态
        provider.setCruiseModeActive(false)
        XCTAssertFalse(provider.isLocationFresh())
        
        // 激活巡航模式
        provider.setCruiseModeActive(true)
        // 退出巡航模式
        provider.setCruiseModeActive(false)
    }

    func testLocationFreshnessThreshold() {
        let provider = LocationProvider()
        
        // 未收到定位前，判定为不新鲜
        XCTAssertFalse(provider.isLocationFresh(maxAge: 60.0))
    }
}
