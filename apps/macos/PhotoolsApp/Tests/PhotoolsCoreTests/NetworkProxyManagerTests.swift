import XCTest
@testable import PhotoolsCore

final class NetworkProxyManagerTests: XCTestCase {
    func testNetworkProxyManagerApplyAndClear() {
        let manager = NetworkProxyManager.shared

        // 1. 启用 HTTP 代理
        manager.applyProxy(enabled: true, type: "http", host: "127.0.0.1", port: 7890)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(manager.proxyType, "http")
        XCTAssertEqual(manager.proxyHost, "127.0.0.1")
        XCTAssertEqual(manager.proxyPort, 7890)

        // 验证环境变量注入
        if let httpProxy = getenv("HTTP_PROXY") {
            XCTAssertEqual(String(cString: httpProxy), "http://127.0.0.1:7890")
        } else {
            XCTFail("HTTP_PROXY 环境变量未设置")
        }

        if let allProxy = getenv("ALL_PROXY") {
            XCTAssertEqual(String(cString: allProxy), "http://127.0.0.1:7890")
        } else {
            XCTFail("ALL_PROXY 环境变量未设置")
        }

        // 验证 URLSessionConfiguration
        let sessionConfig = manager.makeSessionConfiguration()
        let proxyDict = sessionConfig.connectionProxyDictionary
        XCTAssertNotNil(proxyDict)
        XCTAssertEqual(proxyDict?[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxyDict?[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)

        // 2. 禁用代理与清理
        manager.applyProxy(enabled: false, type: "http", host: "127.0.0.1", port: 7890)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(getenv("HTTP_PROXY"))
        XCTAssertNil(getenv("ALL_PROXY"))

        let cleanConfig = manager.makeSessionConfiguration()
        XCTAssertNil(cleanConfig.connectionProxyDictionary)
    }

    func testNetworkProxyManagerSocks5() {
        let manager = NetworkProxyManager.shared

        // 启用 SOCKS5 代理
        manager.applyProxy(enabled: true, type: "socks5", host: "10.0.0.1", port: 1080)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(manager.proxyType, "socks5")

        if let allProxy = getenv("ALL_PROXY") {
            XCTAssertEqual(String(cString: allProxy), "socks5://10.0.0.1:1080")
        } else {
            XCTFail("ALL_PROXY 未设置")
        }

        let sessionConfig = manager.makeSessionConfiguration()
        let proxyDict = sessionConfig.connectionProxyDictionary
        XCTAssertNotNil(proxyDict)
        XCTAssertEqual(proxyDict?[kCFNetworkProxiesSOCKSProxy as String] as? String, "10.0.0.1")
        XCTAssertEqual(proxyDict?[kCFNetworkProxiesSOCKSPort as String] as? Int, 1080)

        // 清理恢复
        manager.applyProxy(enabled: false, type: "socks5", host: "10.0.0.1", port: 1080)
    }

    func testProxyPresets() {
        let presets = ProxyPreset.commonPresets
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.contains { $0.id == "clash" && $0.port == 7890 })
        XCTAssertTrue(presets.contains { $0.id == "v2ray" && $0.port == 10809 })
        XCTAssertTrue(presets.contains { $0.id == "surge" && $0.port == 6152 })
        XCTAssertTrue(presets.contains { $0.id == "shadowsocks" && $0.type == "socks5" && $0.port == 1080 })
    }

    func testDiskGlobalSettingsProxyCodable() throws {
        let settings = DiskGlobalSettings(
            gpxDir: "~/.config/gpx",
            logDir: "~/.logs/photools",
            sidecarPolicy: "smart",
            workers: 8,
            language: "zh-CN",
            proxyEnabled: true,
            proxyType: "http",
            proxyHost: "127.0.0.1",
            proxyPort: 7890
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DiskGlobalSettings.self, from: data)

        XCTAssertEqual(decoded.proxyEnabled, true)
        XCTAssertEqual(decoded.proxyType, "http")
        XCTAssertEqual(decoded.proxyHost, "127.0.0.1")
        XCTAssertEqual(decoded.proxyPort, 7890)
    }
}
