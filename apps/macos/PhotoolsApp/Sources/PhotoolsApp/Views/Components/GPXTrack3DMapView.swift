import AppKit
import CoreLocation
import PhotoolsCore
import SwiftUI
import WebKit

/// 基于 MapLibre GL 3D Terrain 呈现真实高原山川与立体发光 GPX 轨迹的 3D 渲染视图
public struct GPXTrack3DMapView: NSViewRepresentable {
    public let summary: GPXTrackSummary
    public let tileProvider: MapTileProvider
    public var onFallbackToNative: (() -> Void)? = nil

    public init(
        summary: GPXTrackSummary,
        tileProvider: MapTileProvider = .googleSatellite,
        onFallbackToNative: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.tileProvider = tileProvider
        self.onFallbackToNative = onFallbackToNative
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "mapReady")
        contentController.add(context.coordinator, name: "mapConsoleLog")
        contentController.add(context.coordinator, name: "fallbackToNative")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let initialRect = NSRect(x: 0, y: 0, width: 980, height: 680)
        let webView = WKWebView(frame: initialRect, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(true, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor(red: 7/255.0, green: 10/255.0, blue: 18/255.0, alpha: 1.0).cgColor

        context.coordinator.webView = webView

        let html = generateHTMLTemplate()
        let localBaseURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        webView.loadHTMLString(html, baseURL: localBaseURL)

        return webView
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup(nsView)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let currentSize = nsView.bounds.size
        if currentSize != coordinator.lastBoundsSize && currentSize.width > 0 && currentSize.height > 0 {
            coordinator.lastBoundsSize = currentSize
            nsView.evaluateJavaScript("if (window.resizeMap) { window.resizeMap(); }")
        }

        // 若轨迹文件发生改变，重新生成 HTML 模版并刷新 WebKit 视图
        if coordinator.lastTrackFilePath != summary.filePath {
            coordinator.lastTrackFilePath = summary.filePath
            coordinator.lastTileProvider = tileProvider
            let html = generateHTMLTemplate()
            let localBaseURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            nsView.loadHTMLString(html, baseURL: localBaseURL)
            return
        }

        // 若图源改变，毫秒级热更新底图，无需销毁与重建 WebGL 上下文
        if coordinator.lastTileProvider != tileProvider {
            coordinator.lastTileProvider = tileProvider
            let tilesJson = try? JSONSerialization.data(withJSONObject: tileProvider.tileURLs)
            let tilesJsonString = tilesJson.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let js = "if (window.switchTileProvider) { window.switchTileProvider(\(tilesJsonString), \(tileProvider.maxZoom)); }"
            nsView.evaluateJavaScript(js)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GPXTrack3DMapView
        weak var webView: WKWebView?
        var lastBoundsSize: CGSize = .zero
        var lastTileProvider: MapTileProvider?
        var lastTrackFilePath: String?
        private var resetObserver: NSObjectProtocol?

        init(_ parent: GPXTrack3DMapView) {
            self.parent = parent
            self.lastTileProvider = parent.tileProvider
            self.lastTrackFilePath = parent.summary.filePath
            super.init()

            // 仅精准响应针对当前地图 summary.filePath 的复位指令，杜绝全局暴力跨窗口搜索
            self.resetObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ResetGPXCamera"),
                object: nil,
                queue: .main
            ) { [weak self] notif in
                guard let self = self else { return }
                if let targetPath = notif.object as? String, targetPath != self.parent.summary.filePath {
                    return
                }
                self.webView?.evaluateJavaScript("if (window.resetToOverview) { window.resetToOverview(); } else if (window.resetCamera) { window.resetCamera(); }")
            }
        }

        func cleanup(_ webView: WKWebView) {
            if let obs = resetObserver {
                NotificationCenter.default.removeObserver(obs)
                resetObserver = nil
            }
            // 彻底销毁 MapLibre 实例、清空 WebGL 显存纹理并停止所有 JS 定时器与 RAF
            webView.evaluateJavaScript("if (window.destroyMap) { window.destroyMap(); }")
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.navigationDelegate = nil
            self.webView = nil
        }

        deinit {
            if let obs = resetObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "fallbackToNative" {
                parent.onFallbackToNative?()
            } else if message.name == "mapConsoleLog" {
                #if DEBUG
                if let body = message.body as? String {
                    print("🗺️ [GPX 3D Web]: \(body)")
                }
                #endif
            }
        }
    }

    private static let cachedCSS: String? = {
        if let url = Bundle.main.url(forResource: "maplibre-gl", withExtension: "css", subdirectory: "maplibre"),
           let css = try? String(contentsOf: url, encoding: .utf8) {
            return css
        }
        let fallback = URL(fileURLWithPath: "macos/PhotoolsApp/Resources/maplibre/maplibre-gl.css")
        return try? String(contentsOf: fallback, encoding: .utf8)
    }()

    private static let cachedJS: String? = {
        if let url = Bundle.main.url(forResource: "maplibre-gl", withExtension: "js", subdirectory: "maplibre"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            return js
        }
        let fallback = URL(fileURLWithPath: "macos/PhotoolsApp/Resources/maplibre/maplibre-gl.js")
        return try? String(contentsOf: fallback, encoding: .utf8)
    }()

    private func generateHTMLTemplate() -> String {
        let localCSS = Self.cachedCSS
        let localJS = Self.cachedJS
        let hasLocalAssets = (localCSS != nil && localJS != nil)

        let bbox = summary.boundingBox
        // 投影坐标映射（高德卫星自动纠偏 GCJ-02，Google / ESRI 保持纯正 WGS-84）
        let renderedCoords = summary.renderedPoints.map { pt -> [Double] in
            let rc = tileProvider.renderCoordinate(for: pt.coordinate)
            return [rc.longitude, rc.latitude]
        }
        let coordsJSON = (try? JSONSerialization.data(withJSONObject: renderedCoords))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let startCoord = summary.startPoint.map { tileProvider.renderCoordinate(for: $0.coordinate) }
        let endCoord = summary.endPoint.map { tileProvider.renderCoordinate(for: $0.coordinate) }

        let minRenderCoord = tileProvider.renderCoordinate(for: CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLng))
        let maxRenderCoord = tileProvider.renderCoordinate(for: CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLng))

        let tilesJson = try? JSONSerialization.data(withJSONObject: tileProvider.tileURLs)
        let tilesJsonString = tilesJson.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let tileMaxZoom = tileProvider.maxZoom

        // 剖面图序列数据：含各点累计里程 (km)、海拔 (m)、心率 (bpm) 与投影坐标
        let profilePoints = summary.renderedPoints.map { pt -> [String: Any] in
            let rc = tileProvider.renderCoordinate(for: pt.coordinate)
            var dict: [String: Any] = [
                "dist": Double(round(pt.distanceMeters / 10.0) / 100.0),
                "lng": rc.longitude,
                "lat": rc.latitude
            ]
            if let ele = pt.elevation {
                dict["ele"] = Double(round(ele * 10.0) / 10.0)
            }
            if let hr = pt.heartRate {
                dict["hr"] = hr
            }
            return dict
        }
        let profileJSON = (try? JSONSerialization.data(withJSONObject: profilePoints))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let hasHeartRate = summary.hasHeartRateData
        let avgHR = summary.avgHeartRate ?? 0
        let maxHR = summary.maxHeartRate ?? 0

        // 离散打卡点 (Waypoints / POI) 空间投影与 GeoJSON 构造（对标 GPXSee 专业打卡点呈现）
        let waypointsData: [[String: Any]] = summary.waypoints.map { wpt in
            let rc = tileProvider.renderCoordinate(for: wpt.coordinate)
            var props: [String: Any] = [
                "name": wpt.name ?? "打卡点"
            ]
            if let ele = wpt.elevation {
                props["ele"] = String(format: "%.0fm", ele)
            }
            if let cmt = wpt.comment, !cmt.isEmpty {
                props["desc"] = cmt
            }
            return [
                "type": "Feature",
                "geometry": [
                    "type": "Point",
                    "coordinates": [rc.longitude, rc.latitude]
                ],
                "properties": props
            ]
        }
        let waypointsGeoJSON: String = {
            let fc: [String: Any] = [
                "type": "FeatureCollection",
                "features": waypointsData
            ]
            return (try? JSONSerialization.data(withJSONObject: fc))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"type\":\"FeatureCollection\",\"features\":[]}"
        }()

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <title>Photools 3D Track Terrain</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no" />
          \(hasLocalAssets ? "<style>\(localCSS!)</style>" : "<link rel=\"stylesheet\" href=\"https://registry.npmmirror.com/maplibre-gl/4.7.1/files/dist/maplibre-gl.css\" />")
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; overflow: hidden; background: #070a12; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
            #map { width: 100%; height: 100%; position: absolute; top: 0; left: 0; }

            .track-marker {
              padding: 4px 8px;
              border-radius: 12px;
              font-size: 11px;
              font-weight: bold;
              color: #ffffff;
              display: flex;
              align-items: center;
              gap: 4px;
              box-shadow: 0 0 12px rgba(0,0,0,0.6);
            }
            .marker-start {
              background: linear-gradient(135deg, #10b981, #059669);
              border: 1.5px solid #a7f3d0;
            }
            .marker-end {
              background: linear-gradient(135deg, #ef4444, #dc2626);
              border: 1.5px solid #fecaca;
            }

            /* 离散打卡点悬浮气泡 */
            .gpx-wpt-popup .maplibregl-popup-content {
              background: rgba(9, 13, 22, 0.92);
              border: 1px solid rgba(56, 189, 248, 0.45);
              border-radius: 8px;
              padding: 6px 10px;
              box-shadow: 0 4px 16px rgba(0,0,0,0.6);
              backdrop-filter: blur(8px);
              color: #f8fafc;
            }
            .gpx-wpt-popup .maplibregl-popup-tip {
              border-top-color: rgba(9, 13, 22, 0.92);
            }

            /* 两步路 & Strava 风格专业 3D 运动人物主体 (Avatar Puck) - 放大版高辨识度航向罗盘指针 */
            .avatar-puck {
              position: relative;
              width: 52px;
              height: 52px;
              display: flex;
              align-items: center;
              justify-content: center;
              pointer-events: none;
              transform: translate(-50%, -50%);
            }
            .puck-ripple {
              position: absolute;
              width: 52px;
              height: 52px;
              border-radius: 50%;
              background: rgba(255, 122, 0, 0.25);
              border: 1.5px solid rgba(255, 152, 0, 0.85);
              animation: puckPulse 1.8s infinite cubic-bezier(0.2, 0.8, 0.2, 1);
            }
            @keyframes puckPulse {
              0% { transform: scale(0.55); opacity: 0.95; }
              70% { transform: scale(1.45); opacity: 0.18; }
              100% { transform: scale(1.65); opacity: 0; }
            }
            .puck-core {
              position: relative;
              z-index: 2;
              width: 24px;
              height: 24px;
              border-radius: 50%;
              background: #ffffff;
              border: 3.5px solid #090d16;
              box-shadow: 0 0 16px rgba(255, 122, 0, 0.95), 0 3px 12px rgba(0, 0, 0, 0.8);
              display: flex;
              align-items: center;
              justify-content: center;
            }
            .puck-heading-arrow {
              position: absolute;
              z-index: 3;
              top: -15px;
              left: 5px;
              width: 0;
              height: 0;
              border-left: 7px solid transparent;
              border-right: 7px solid transparent;
              border-bottom: 15px solid #ff7a00;
              filter: drop-shadow(0 2px 5px rgba(0, 0, 0, 0.9)) drop-shadow(0 0 4px #ff7a00);
              transform-origin: 7px 27px;
              transition: transform 0.08s linear;
            }
            .puck-badge {
              position: absolute;
              top: -34px;
              left: 50%;
              transform: translateX(-50%);
              background: rgba(11, 17, 32, 0.94);
              border: 1px solid rgba(255, 122, 0, 0.85);
              border-radius: 6px;
              padding: 2.5px 8px;
              font-size: 11px;
              font-weight: 700;
              color: #f8fafc;
              white-space: nowrap;
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
              box-shadow: 0 4px 14px rgba(0, 0, 0, 0.75);
              display: flex;
              align-items: center;
              gap: 5px;
            }
            .puck-badge .badge-ele {
              color: #ff9800;
            }

            /* 底部悬浮海拔与心率剖面图看板 */
            .profile-card {
              position: absolute;
              bottom: 16px;
              left: 16px;
              right: 16px;
              background: rgba(11, 17, 32, 0.88);
              backdrop-filter: blur(18px);
              -webkit-backdrop-filter: blur(18px);
              border: 1px solid rgba(255, 255, 255, 0.12);
              border-radius: 12px;
              padding: 10px 14px;
              z-index: 50;
              box-shadow: 0 8px 32px rgba(0, 0, 0, 0.65);
              transition: all 0.25s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .profile-card.cruising {
              background: rgba(11, 17, 32, 0.72);
              border-color: rgba(6, 182, 212, 0.35);
              box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5), 0 0 16px rgba(6, 182, 212, 0.15);
            }
            .profile-card.collapsed .profile-chart-box {
              display: none;
            }
            .profile-card.collapsed {
              padding: 6px 14px;
              background: rgba(11, 17, 32, 0.75);
            }

            /* 右侧悬浮 3D 姿态云台控制台 (俯仰角拉杆 + 东西南北横杆) */
            .gimbal-cockpit {
              position: absolute;
              right: 16px;
              top: 76px;
              width: 172px;
              background: rgba(11, 17, 32, 0.84);
              backdrop-filter: blur(18px);
              -webkit-backdrop-filter: blur(18px);
              border: 1px solid rgba(255, 255, 255, 0.12);
              border-radius: 12px;
              padding: 10px 12px;
              z-index: 45;
              box-shadow: 0 8px 32px rgba(0, 0, 0, 0.6);
              color: #f8fafc;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              user-select: none;
              transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .gimbal-section {
              display: flex;
              flex-direction: column;
              gap: 5px;
            }
            .gimbal-title-row {
              display: flex;
              justify-content: space-between;
              align-items: center;
              font-size: 11px;
              font-weight: 600;
            }
            .gimbal-label {
              color: rgba(255, 255, 255, 0.85);
              display: flex;
              align-items: center;
              gap: 4px;
            }
            .gimbal-val-badge {
              font-size: 10px;
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
              color: #38bdf8;
              background: rgba(6, 182, 212, 0.15);
              border: 1px solid rgba(6, 182, 212, 0.3);
              border-radius: 4px;
              padding: 1px 5px;
            }
            .gimbal-quick-dirs {
              display: grid;
              grid-template-columns: repeat(4, 1fr);
              gap: 4px;
              margin-top: 2px;
            }
            .gimbal-quick-pitch {
              display: grid;
              grid-template-columns: repeat(3, 1fr);
              gap: 4px;
              margin-top: 2px;
            }
            .gimbal-btn {
              background: rgba(255, 255, 255, 0.08);
              border: 1px solid rgba(255, 255, 255, 0.14);
              color: rgba(255, 255, 255, 0.85);
              padding: 3px 2px;
              border-radius: 5px;
              font-size: 10px;
              font-weight: 500;
              cursor: pointer;
              transition: all 0.15s ease;
              text-align: center;
              white-space: nowrap;
            }
            .gimbal-btn:hover {
              background: rgba(255, 255, 255, 0.18);
              border-color: rgba(255, 255, 255, 0.3);
            }
            .gimbal-btn.north {
              border-color: rgba(239, 68, 68, 0.65);
              color: #fca5a5;
              font-weight: 700;
              background: rgba(239, 68, 68, 0.15);
            }
            .gimbal-btn.north:hover {
              background: rgba(239, 68, 68, 0.28);
            }
            .gimbal-slider {
              -webkit-appearance: none;
              appearance: none;
              width: 100%;
              height: 4px;
              background: rgba(255, 255, 255, 0.16);
              border-radius: 2px;
              outline: none;
              cursor: pointer;
              margin: 4px 0 2px 0;
            }
            .gimbal-slider::-webkit-slider-thumb {
              -webkit-appearance: none;
              appearance: none;
              width: 13px;
              height: 13px;
              border-radius: 50%;
              background: #ffffff;
              border: 2.5px solid #0284c7;
              box-shadow: 0 0 8px rgba(56, 189, 248, 0.8);
              cursor: pointer;
              transition: transform 0.1s ease;
            }
            .gimbal-slider::-webkit-slider-thumb:hover {
              transform: scale(1.25);
            }
            .gimbal-divider {
              height: 1px;
              background: rgba(255, 255, 255, 0.1);
              margin: 8px 0;
            }
            .profile-header {
              display: flex;
              justify-content: space-between;
              align-items: center;
              margin-bottom: 6px;
            }
            .profile-card.collapsed .profile-header {
              margin-bottom: 0;
            }
            .profile-legend {
              display: flex;
              align-items: center;
              gap: 14px;
              font-size: 11px;
              flex-shrink: 1;
              min-width: 0;
              overflow: hidden;
              white-space: nowrap;
              text-overflow: ellipsis;
            }
            .legend-item {
              display: flex;
              align-items: center;
              gap: 6px;
              flex-shrink: 0;
            }
            .legend-dot {
              width: 8px;
              height: 8px;
              border-radius: 50%;
            }
            .ele-dot {
              background: #06b6d4;
              box-shadow: 0 0 6px #06b6d4;
            }
            .hr-dot {
              background: #ef4444;
              box-shadow: 0 0 6px #ef4444;
            }
            .legend-label {
              color: rgba(255, 255, 255, 0.9);
              font-weight: 600;
            }
            .legend-val {
              color: rgba(255, 255, 255, 0.65);
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
            }
            .profile-actions {
              display: flex;
              align-items: center;
              gap: 5px;
              flex-shrink: 0;
              flex-wrap: nowrap;
            }
            .profile-toggle-btn {
              background: rgba(255, 255, 255, 0.08);
              border: 1px solid rgba(255, 255, 255, 0.14);
              color: rgba(255, 255, 255, 0.85);
              padding: 3px 8px;
              border-radius: 6px;
              font-size: 11px;
              font-weight: 500;
              cursor: pointer;
              transition: all 0.15s ease;
              white-space: nowrap;
              user-select: none;
            }
            .profile-toggle-btn:hover {
              background: rgba(255, 255, 255, 0.18);
              border-color: rgba(255, 255, 255, 0.25);
            }
            .profile-toggle-btn.active {
              background: rgba(6, 182, 212, 0.22);
              border-color: rgba(6, 182, 212, 0.7);
              color: #38bdf8;
              box-shadow: 0 0 8px rgba(6, 182, 212, 0.35);
            }
            .profile-toggle-btn.cruising {
              background: rgba(239, 68, 68, 0.25);
              border-color: #ef4444;
              color: #fca5a5;
              box-shadow: 0 0 10px rgba(239, 68, 68, 0.45);
            }
            .profile-chart-box {
              position: relative;
              width: 100%;
              height: 105px;
            }
            #profile-canvas {
              width: 100%;
              height: 100%;
              display: block;
              cursor: crosshair;
            }
            .profile-tooltip {
              position: absolute;
              top: 0;
              display: none;
              padding: 4px 8px;
              background: rgba(15, 23, 42, 0.95);
              border: 1px solid rgba(6, 182, 212, 0.6);
              border-radius: 6px;
              font-size: 11px;
              color: #ffffff;
              pointer-events: none;
              white-space: nowrap;
              box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
              transform: translateX(-50%);
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
            }

            #loading-overlay {
              position: absolute;
              top: 0; left: 0; right: 0; bottom: 0;
              background: rgba(7, 10, 18, 0.92);
              backdrop-filter: blur(20px);
              -webkit-backdrop-filter: blur(20px);
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              z-index: 999;
              transition: opacity 0.35s ease-out;
            }
            .hud-box {
              display: flex;
              flex-direction: column;
              align-items: center;
              padding: 28px 36px;
              background: rgba(15, 23, 42, 0.75);
              border: 1px solid rgba(255, 255, 255, 0.12);
              border-radius: 16px;
              box-shadow: 0 16px 40px rgba(0, 0, 0, 0.6), 0 0 30px rgba(6, 182, 212, 0.15);
              min-width: 320px;
            }
            .radar-scan {
              position: relative;
              width: 76px;
              height: 76px;
              margin-bottom: 16px;
              display: flex;
              align-items: center;
              justify-content: center;
            }
            .radar-circle {
              position: absolute;
              width: 100%;
              height: 100%;
              border-radius: 50%;
              border: 2px dashed rgba(6, 182, 212, 0.5);
              animation: radarSpin 6s linear infinite;
            }
            .radar-beam {
              position: absolute;
              width: 100%;
              height: 100%;
              border-radius: 50%;
              border-top: 3px solid #06b6d4;
              border-right: 3px solid transparent;
              animation: radarSpin 1.2s cubic-bezier(0.4, 0, 0.2, 1) infinite;
            }
            .radar-core {
              position: relative;
              z-index: 2;
              filter: drop-shadow(0 0 8px #06b6d4);
            }
            .hud-title {
              font-size: 15px;
              font-weight: 700;
              color: #f8fafc;
              letter-spacing: 0.5px;
              margin-bottom: 18px;
            }
            .hud-progress-wrap {
              width: 100%;
              display: flex;
              flex-direction: column;
              gap: 8px;
            }
            .hud-progress-track {
              width: 100%;
              height: 6px;
              background: rgba(255, 255, 255, 0.08);
              border-radius: 4px;
              overflow: hidden;
              position: relative;
            }
            .hud-progress-fill {
              height: 100%;
              width: 15%;
              background: linear-gradient(90deg, #06b6d4, #3b82f6);
              border-radius: 4px;
              box-shadow: 0 0 12px rgba(6, 182, 212, 0.8);
              transition: width 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
            }
            .hud-meta {
              display: flex;
              justify-content: space-between;
              align-items: center;
              font-size: 11px;
            }
            #hud-stage {
              color: rgba(255, 255, 255, 0.65);
              font-weight: 500;
            }
            .hud-pct-text {
              font-family: -apple-system, BlinkMacSystemFont, "SF Mono", monospace;
              color: #06b6d4;
              font-size: 12px;
            }
            @keyframes radarSpin {
              100% { transform: rotate(360deg); }
            }
          </style>
        </head>
        <body>
          <div id="loading-overlay">
            <div class="hud-box">
              <div class="radar-scan">
                <div class="radar-circle"></div>
                <div class="radar-beam"></div>
                <div class="radar-core">
                  <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#06b6d4" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <polygon points="12 2 2 7 12 12 22 7 12 2"></polygon>
                    <polyline points="2 17 12 22 22 17"></polyline>
                    <polyline points="2 12 12 17 22 12"></polyline>
                  </svg>
                </div>
              </div>
              <div class="hud-title">3D 真实高程地形与轨迹渲染</div>
              <div class="hud-progress-wrap">
                <div class="hud-progress-track">
                  <div id="hud-bar" class="hud-progress-fill"></div>
                </div>
                <div class="hud-meta">
                  <span id="hud-stage">正在启动 3D WebGL 渲染管线...</span>
                  <span class="hud-pct-text"><strong id="hud-pct">15</strong>%</span>
                </div>
              </div>
            </div>
          </div>
          <div id="map"></div>

          <!-- 右侧悬浮 3D 姿态云台控制台 (俯仰角拉杆 + 东西南北横杆) -->
          <div id="gimbal-cockpit" class="gimbal-cockpit">
            <div class="gimbal-section">
              <div class="gimbal-title-row">
                <span class="gimbal-label">🧭 方位角</span>
                <span id="bearing-val-badge" class="gimbal-val-badge">0° 正北</span>
              </div>
              <div class="gimbal-quick-dirs">
                <button class="gimbal-btn north" onclick="setBearingPreset(0)" title="一键回正正北 (0°)">北 N</button>
                <button class="gimbal-btn" onclick="setBearingPreset(90)" title="一键转向正东 (90°)">东 E</button>
                <button class="gimbal-btn" onclick="setBearingPreset(180)" title="一键转向正南 (180°)">南 S</button>
                <button class="gimbal-btn" onclick="setBearingPreset(270)" title="一键转向正西 (270°)">西 W</button>
              </div>
              <input id="bearing-slider" type="range" min="0" max="360" step="1" value="0" oninput="onBearingSliderInput(this.value)" class="gimbal-slider" title="拖拽旋转东西南北方位 (0°~360°)" />
            </div>

            <div class="gimbal-divider"></div>

            <div class="gimbal-section">
              <div class="gimbal-title-row">
                <span class="gimbal-label">📐 俯仰角</span>
                <span id="pitch-val-badge" class="gimbal-val-badge">55° 鸟瞰</span>
              </div>
              <div class="gimbal-quick-pitch">
                <button class="gimbal-btn" onclick="setPitchPreset(0)" title="0° 纯顶视上帝视角 (测绘宏观走线)">0° 顶视</button>
                <button class="gimbal-btn active" onclick="setPitchPreset(50)" title="50° 黄金直升机鸟瞰视角 (默认推荐)">50° 鸟瞰</button>
                <button class="gimbal-btn" onclick="setPitchPreset(75)" title="75° 贴地平视冲锋视角 (险峻山峦穿行)">75° 平视</button>
              </div>
              <input id="pitch-slider" type="range" min="0" max="80" step="1" value="55" oninput="onPitchSliderInput(this.value)" class="gimbal-slider" title="拖拽调节俯仰倾角 (0° 顶视 ~ 80° 平视)" />
            </div>
          </div>

          <!-- 底部悬浮专业海拔与心率双轴剖面看板 -->
          <div id="profile-container" class="profile-card">
            <div class="profile-header">
              <div class="profile-legend">
                <div class="legend-item">
                  <span class="legend-dot ele-dot"></span>
                  <span class="legend-label">海拔</span>
                  <span class="legend-val">\(Int(summary.minElevation ?? 0))m ~ \(Int(summary.maxElevation ?? 0))m (爬升 +\(Int(summary.elevationGain ?? 0))m)</span>
                </div>
                \(hasHeartRate ? """
                <div class="legend-item">
                  <span class="legend-dot hr-dot"></span>
                  <span class="legend-label">心率</span>
                  <span class="legend-val">均值 \(avgHR) bpm (最高 \(maxHR) bpm)</span>
                </div>
                """ : "")
              </div>
              <div class="profile-actions">
                <button id="cruise-btn" class="profile-toggle-btn" onclick="toggleCruise()" title="一键开启/暂停 3D 轨迹自动平滑巡航">▶ 沿线巡航</button>
                <button id="speed-btn" class="profile-toggle-btn" onclick="cycleCruiseSpeed()" title="切换巡航倍速 (1x / 2x / 4x)">1x</button>
                <button id="view-mode-btn" class="profile-toggle-btn active" onclick="toggleViewMode()" title="切换视角模式：正北鸟瞰（最稳不晕）/ 平滑追随（沿大山势缓转）">🧭 正北鸟瞰</button>
                <button id="follow-btn" class="profile-toggle-btn active" onclick="toggleFollowCamera()" title="开启/关闭相机居中跟随人物">🔭 跟随人物</button>
                <button id="reset-overview-btn" class="profile-toggle-btn" onclick="resetToOverview()" title="恢复整条山脉的 55° 全景黄金总览">⏮ 全景总览</button>
                <button id="toggle-profile-btn" class="profile-toggle-btn" onclick="toggleProfile()">▾ 折叠剖面</button>
              </div>
            </div>
            <div id="profile-chart-box" class="profile-chart-box">
              <canvas id="profile-canvas"></canvas>
              <div id="profile-tooltip" class="profile-tooltip"></div>
            </div>
          </div>

          \(hasLocalAssets ? "<script>\(localJS!)</script>" : "")

          <script>
            function logToSwift(msg) {
              if (window.webkit && window.webkit.messageHandlers.mapConsoleLog) {
                window.webkit.messageHandlers.mapConsoleLog.postMessage(String(msg));
              }
            }

            window.onerror = function(msg, url, lineNo, columnNo, error) {
              logToSwift('[JS Error] ' + msg + ' at ' + lineNo + ':' + (columnNo || 0));
              return false;
            };

            function loadScript(src, cb) {
              const el = document.createElement('script');
              el.src = src;
              el.onload = () => cb(true);
              el.onerror = () => cb(false);
              document.head.appendChild(el);
            }

            function checkAndStart() {
              const glLib = window.maplibregl || window.maplibre_gl;
              if (typeof glLib !== 'undefined') {
                initMap(glLib);
              } else {
                loadScript('https://registry.npmmirror.com/maplibre-gl/4.7.1/files/dist/maplibre-gl.js', (ok) => {
                  const lib = window.maplibregl || window.maplibre_gl;
                  if (lib) initMap(lib);
                });
              }
            }

            checkAndStart();

            function initMap(lib) {
              const bounds = [
                [\(minRenderCoord.longitude), \(minRenderCoord.latitude)],
                [\(maxRenderCoord.longitude), \(maxRenderCoord.latitude)]
              ];

              const allTrackCoords = \(coordsJSON);
              const profileData = \(profileJSON);

              function calculateBearing(p1, p2) {
                const lat1 = p1.lat * Math.PI / 180;
                const lat2 = p2.lat * Math.PI / 180;
                const dLng = (p2.lng - p1.lng) * Math.PI / 180;
                const y = Math.sin(dLng) * Math.cos(lat2);
                const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng);
                const rad = Math.atan2(y, x);
                return (rad * 180 / Math.PI + 360) % 360;
              }

              // 为轨迹上的各个航点预先计算：
              // 1. 微观前进航向 (heading, 前瞻 ~35m)：用于人物 Puck 罗盘箭头指向
              // 2. 宏观山脉切线 (macroBearing, 前瞻 ~200m)：彻底滤除盘山路折返锯齿，用于相机大平滑追随
              for (let i = 0; i < profileData.length; i++) {
                const curDist = profileData[i].dist;

                // 微观航向 (前方 35m)
                let microIdx = i;
                for (let j = i + 1; j < profileData.length; j++) {
                  if ((profileData[j].dist - curDist) >= 0.035 || j === profileData.length - 1) {
                    microIdx = j;
                    break;
                  }
                }
                if (microIdx === i && i > 0) {
                  profileData[i].heading = calculateBearing(profileData[i - 1], profileData[i]);
                } else {
                  profileData[i].heading = calculateBearing(profileData[i], profileData[microIdx]);
                }

                // 宏观航向 (前方 200m)
                let macroIdx = i;
                for (let k = i + 1; k < profileData.length; k++) {
                  if ((profileData[k].dist - curDist) >= 0.20 || k === profileData.length - 1) {
                    macroIdx = k;
                    break;
                  }
                }
                if (macroIdx === i && i > 0) {
                  profileData[i].macroBearing = calculateBearing(profileData[i - 1], profileData[i]);
                } else {
                  profileData[i].macroBearing = calculateBearing(profileData[i], profileData[macroIdx]);
                }
              }

              const map = new lib.Map({
                container: 'map',
                style: {
                  version: 8,
                  sources: {
                    'satellite-source': {
                      type: 'raster',
                      tiles: \(tilesJsonString),
                      tileSize: 256,
                      maxzoom: \(tileMaxZoom)
                    },
                    'terrain-source': {
                      type: 'raster-dem',
                      tiles: ['https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'],
                      tileSize: 256,
                      encoding: 'terrarium',
                      maxzoom: 15
                    }
                  },
                  layers: [
                    { id: 'bg', type: 'background', paint: { 'background-color': '#070a12' } },
                    { id: 'sat', type: 'raster', source: 'satellite-source' },
                    {
                      id: 'hills',
                      type: 'hillshade',
                      source: 'terrain-source',
                      paint: {
                        'hillshade-shadow-color': '#060a12',
                        'hillshade-highlight-color': '#f8fafc',
                        'hillshade-accent-color': '#1e293b',
                        'hillshade-exaggeration': 0.65
                      }
                    }
                  ]
                },
                bounds: bounds,
                fitBoundsOptions: {
                  padding: { top: 110, bottom: 220, left: 240, right: 80 },
                  pitch: 55,
                  bearing: 0,
                  maxZoom: 16
                },
                maxPitch: 85,
                dragRotate: true,
                pitchWithRotate: true,
                touchZoomRotate: true,
                attributionControl: false
              });

              window.mapInstance = map;

              // 0. 地图安全边界防御夹紧器 (Defensive Safe Padding Clamping)
              // 严格将 padding 总跨度限制在地图容器可视尺寸的 65% 以内，彻底根除 MapLibre 的
              // "Map padding is greater than canvas size" 致命崩溃！
              function clampPadding(pad) {
                const container = (map && map.getContainer()) ? map.getContainer() : document.getElementById('map');
                const w = container ? (container.clientWidth || window.innerWidth) : window.innerWidth;
                const h = container ? (container.clientHeight || window.innerHeight) : window.innerHeight;

                const maxH = Math.max(10, h * 0.65);
                const maxW = Math.max(10, w * 0.65);

                let top = Math.max(10, pad.top || 0);
                let bottom = Math.max(10, pad.bottom || 0);
                let left = Math.max(10, pad.left || 0);
                let right = Math.max(10, pad.right || 0);

                if (top + bottom > maxH) {
                  const scale = maxH / (top + bottom);
                  top = Math.floor(top * scale);
                  bottom = Math.floor(bottom * scale);
                }

                if (left + right > maxW) {
                  const scale = maxW / (left + right);
                  left = Math.floor(left * scale);
                  right = Math.floor(right * scale);
                }

                return { top, bottom, left, right };
              }

              // 1. 全景非对称安全区 (Asymmetric Overview Padding)
              // 避让顶部 macOS 标题栏、左上角 380px 浮动 HUD 看板与底部双轴剖面看板，让山川轨迹自然居中于右下方未遮挡区
              function getOverviewPadding() {
                const card = document.getElementById('profile-container');
                let bottomH = 44;
                if (!profileCollapsed) {
                  bottomH = (card && card.offsetHeight > 0) ? Math.min(card.offsetHeight, 180) : 165;
                }
                return clampPadding({
                  top: 110,
                  bottom: bottomH + 45,
                  left: 240, // 关键避让：左上角宽达 380px 的卡片，留足呼吸空间
                  right: 80
                });
              }

              // 2. 随行与特写相机安全区 (Follow Camera Padding)
              // 确保 3D 透视相机将目标对齐至未被底部面板遮挡的可视净空中心，彻底杜绝随行被遮挡
              function getCameraPadding(extraBottom = 32) {
                const card = document.getElementById('profile-container');
                let bottomH = 44;
                if (!profileCollapsed) {
                  bottomH = (card && card.offsetHeight > 0) ? Math.min(card.offsetHeight, 180) : 165;
                }
                return clampPadding({
                  top: 70,
                  bottom: bottomH + extraBottom,
                  left: 70,
                  right: 70
                });
              }

              window.resizeMap = function() {
                if (map) map.resize();
              };

              window.resetCamera = function() {
                if (map) {
                  const pad = getOverviewPadding();
                  map.fitBounds(bounds, {
                    padding: pad,
                    pitch: 55,
                    bearing: 0,
                    duration: 1200
                  });
                }
              };

              window.switchTileProvider = function(newTiles, newMaxZoom) {
                if (!map) return;
                try {
                  isSatelliteLoaded = false;
                  const src = map.getSource('satellite-source');
                  if (src && src.setTiles) {
                    src.setTiles(newTiles);
                  } else if (map.style) {
                    map.removeLayer('sat');
                    map.removeSource('satellite-source');
                    map.addSource('satellite-source', {
                      type: 'raster',
                      tiles: newTiles,
                      tileSize: 256,
                      maxzoom: newMaxZoom || 18
                    });
                    map.addLayer({ id: 'sat', type: 'raster', source: 'satellite-source' }, 'hills');
                  }
                } catch (e) {
                  console.error('switchTileProvider error:', e);
                }
              };

              let currentPct = 25.0;
              let dismissed = false;
              let isSatelliteLoaded = false;
              let isTerrainLoaded = false;
              let hasLayersReady = false;

              function updateProgressUI(pct, text) {
                currentPct = Math.min(100, Math.max(currentPct, pct));
                const bar = document.getElementById('hud-bar');
                const pctEl = document.getElementById('hud-pct');
                const stageEl = document.getElementById('hud-stage');
                if (bar) bar.style.width = currentPct + '%';
                if (pctEl) pctEl.innerText = String(Math.round(currentPct));
                if (text && stageEl) stageEl.innerText = text;
              }

              function finishLoading() {
                if (dismissed) return;
                dismissed = true;
                updateProgressUI(100, '3D 真实地形与轨迹渲染就绪！');
                if (map) map.resize();

                // 确定性淡出：停留 220ms 供用户确认 100% 就绪，随后平滑淡出并彻底关闭遮罩
                setTimeout(() => {
                  const overlay = document.getElementById('loading-overlay');
                  if (overlay) {
                    overlay.style.opacity = '0';
                    overlay.style.pointerEvents = 'none';
                    setTimeout(() => {
                      overlay.style.display = 'none';
                      if (map) map.resize();
                    }, 360);
                  }
                }, 220);
              }

              function checkReadyToDismiss() {
                // 必须满足：轨迹图层已构建完毕，且 (卫星切片已加载 或 视口切片已完全载入)
                const tilesReady = (map.areTilesLoaded && map.areTilesLoaded()) || isSatelliteLoaded;
                if (hasLayersReady && tilesReady) {
                  finishLoading();
                }
              }

              // 监听切片数据流式加载推进进度
              map.on('sourcedata', (e) => {
                if (e.sourceId === 'satellite-source') {
                  if (e.isSourceLoaded) {
                    isSatelliteLoaded = true;
                    updateProgressUI(95, '卫星遥感影像加载就绪...');
                    checkReadyToDismiss();
                  } else {
                    updateProgressUI(75, '正在流式拉取卫星遥感切片...');
                  }
                }
                if (e.sourceId === 'terrain-source' && e.isSourceLoaded) {
                  isTerrainLoaded = true;
                  updateProgressUI(65, 'DEM 真实高程地形网格就绪...');
                  checkReadyToDismiss();
                }
              });

              // 空闲状态：仅在切片已加载或确认有切片到达后才采纳 idle，杜绝初始化假空闲
              map.on('idle', () => {
                if (map) map.resize();
                if (isSatelliteLoaded || (map.areTilesLoaded && map.areTilesLoaded())) {
                  checkReadyToDismiss();
                }
              });

              // 兜底超时：3.5 秒强制就绪淡出，杜绝任何弱网或瓦片丢包导致的卡屏
              setTimeout(() => {
                if (!dismissed) {
                  finishLoading();
                }
              }, 3500);

              map.on('load', () => {
                updateProgressUI(60, '正在构建立体发光轨迹与空间地标...');
                try {
                  map.setTerrain({ source: 'terrain-source', exaggeration: 1.35 });
                } catch(e) {}

                if (map.setFog) {
                  map.setFog({
                    range: [-0.5, 12],
                    color: '#070a12',
                    'high-color': '#0284c7',
                    'space-color': '#030712',
                    'horizon-blend': 0.12
                  });
                }

                // 1. 全程底色轨迹源与图层 (Base Track)
                map.addSource('gpx-track-base-source', {
                  type: 'geojson',
                  data: {
                    type: 'Feature',
                    properties: { name: "\(summary.name)" },
                    geometry: {
                      type: 'LineString',
                      coordinates: \(coordsJSON)
                    }
                  }
                });

                // 1.1 宏观底轨 - 底层高对比度玄武黑轮廓描边 (彻底杜绝雪山、草甸与卫星地貌隐形撞色)
                map.addLayer({
                  id: 'gpx-track-base-casing',
                  type: 'line',
                  source: 'gpx-track-base-source',
                  layout: { 'line-join': 'round', 'line-cap': 'round' },
                  paint: {
                    'line-color': '#090d16',
                    'line-width': 7.5,
                    'line-opacity': 0.90,
                    'line-blur': 0.5
                  }
                });

                // 1.2 宏观底轨 - 顶层实体橙色主干线 (未走全貌线)
                map.addLayer({
                  id: 'gpx-track-base-line',
                  type: 'line',
                  source: 'gpx-track-base-source',
                  layout: { 'line-join': 'round', 'line-cap': 'round' },
                  paint: {
                    'line-color': '#ff7a00',
                    'line-width': 3.5,
                    'line-opacity': 0.75
                  }
                });

                // 2. 动态已走流光轨迹源与图层 (Traversed Trail - 实体亮橙 + 外部加重黑色描边 + 鲜艳光晕)
                const initialTraversedCoords = (allTrackCoords && allTrackCoords.length > 0) ? [allTrackCoords[0]] : [];
                map.addSource('gpx-track-traversed-source', {
                  type: 'geojson',
                  data: {
                    type: 'Feature',
                    properties: {},
                    geometry: {
                      type: 'LineString',
                      coordinates: initialTraversedCoords
                    }
                  }
                });

                // 2.1 已走流光 - 底层加重黑色高对比轮廓保护边 (参考 tracks.js 规范)
                map.addLayer({
                  id: 'gpx-track-traversed-casing',
                  type: 'line',
                  source: 'gpx-track-traversed-source',
                  layout: { 'line-join': 'round', 'line-cap': 'round' },
                  paint: {
                    'line-color': '#090d16',
                    'line-width': 9.5,
                    'line-opacity': 0.98,
                    'line-blur': 0.5
                  }
                });

                // 2.2 已走流光 - 中层鲜艳运动亮橙色光晕 (微光过渡)
                map.addLayer({
                  id: 'gpx-track-traversed-glow',
                  type: 'line',
                  source: 'gpx-track-traversed-source',
                  layout: { 'line-join': 'round', 'line-cap': 'round' },
                  paint: {
                    'line-color': '#ff7a00',
                    'line-width': 7.0,
                    'line-blur': 2.0,
                    'line-opacity': 0.85
                  }
                });

                // 2.3 已走流光 - 顶层高饱和实体亮橙核心主线
                map.addLayer({
                  id: 'gpx-track-traversed-line',
                  type: 'line',
                  source: 'gpx-track-traversed-source',
                  layout: { 'line-join': 'round', 'line-cap': 'round' },
                  paint: {
                    'line-color': '#ff7a00',
                    'line-width': 4.5,
                    'line-opacity': 1.0
                  }
                });

                // 起点 Marker
                \(startCoord != nil ? """
                const startEl = document.createElement('div');
                startEl.className = 'track-marker marker-start';
                startEl.innerHTML = '🟢 起点';
                new lib.Marker({ element: startEl })
                  .setLngLat([\(startCoord!.longitude), \(startCoord!.latitude)])
                  .addTo(map);
                """ : "")

                // 终点 Marker
                \(endCoord != nil ? """
                const endEl = document.createElement('div');
                endEl.className = 'track-marker marker-end';
                endEl.innerHTML = '🏁 终点';
                new lib.Marker({ element: endEl })
                  .setLngLat([\(endCoord!.longitude), \(endCoord!.latitude)])
                  .addTo(map);
                """ : "")

                // 3. 离散打卡点与兴趣点 (Waypoints / POI) 图层 - 对标 GPXSee 专业打卡点呈现
                const waypointsData = \(waypointsGeoJSON);
                if (waypointsData.features && waypointsData.features.length > 0) {
                  map.addSource('gpx-waypoints-source', {
                    type: 'geojson',
                    data: waypointsData
                  });

                  // 3.1 外层发光青蓝光晕
                  map.addLayer({
                    id: 'gpx-waypoints-glow',
                    type: 'circle',
                    source: 'gpx-waypoints-source',
                    paint: {
                      'circle-radius': 6.0,
                      'circle-color': '#06b6d4',
                      'circle-opacity': 0.85,
                      'circle-stroke-width': 1.5,
                      'circle-stroke-color': '#ffffff'
                    }
                  });

                  // 3.2 核心纯白实心小圆点
                  map.addLayer({
                    id: 'gpx-waypoints-core',
                    type: 'circle',
                    source: 'gpx-waypoints-source',
                    paint: {
                      'circle-radius': 2.5,
                      'circle-color': '#ffffff'
                    }
                  });

                  // 3.3 打卡点地名文本标签（带玄武黑 1.8px 轮廓保护防雪山底图撞色）
                  map.addLayer({
                    id: 'gpx-waypoints-label',
                    type: 'symbol',
                    source: 'gpx-waypoints-source',
                    layout: {
                      'text-field': ['get', 'name'],
                      'text-size': 11,
                      'text-offset': [0, 1.2],
                      'text-anchor': 'top',
                      'text-allow-overlap': false,
                      'text-ignore-placement': false
                    },
                    paint: {
                      'text-color': '#f8fafc',
                      'text-halo-color': '#090d16',
                      'text-halo-width': 1.8
                    }
                  });

                  // 3.4 鼠标悬停打卡点交互：高亮 Popup 提示打卡名称与海拔
                  const wptPopup = new lib.Popup({
                    closeButton: false,
                    closeOnClick: false,
                    offset: 10,
                    className: 'gpx-wpt-popup'
                  });

                  map.on('mouseenter', 'gpx-waypoints-glow', (e) => {
                    map.getCanvas().style.cursor = 'pointer';
                    if (e.features && e.features.length > 0) {
                      const feat = e.features[0];
                      const coords = feat.geometry.coordinates.slice();
                      const props = feat.properties || {};
                      const name = props.name || '打卡点';
                      const ele = props.ele ? ` <span style="color:#38bdf8;">(${props.ele})</span>` : '';
                      const desc = props.desc ? `<div style="font-size:10px;color:#94a3b8;margin-top:2px;">${props.desc}</div>` : '';
                      wptPopup.setLngLat(coords)
                        .setHTML(`<div style="font-weight:600;font-size:12px;color:#f8fafc;">📍 ${name}${ele}</div>${desc}`)
                        .addTo(map);
                    }
                  });

                  map.on('mouseleave', 'gpx-waypoints-glow', () => {
                    map.getCanvas().style.cursor = '';
                    wptPopup.remove();
                  });
                }

                // 两步路 & Strava 风格专业 3D 运动人物主体 (Avatar Puck)
                const puckEl = document.createElement('div');
                puckEl.className = 'avatar-puck';
                puckEl.innerHTML = `
                  <div class="puck-ripple"></div>
                  <div class="puck-core">
                    <div id="puck-arrow" class="puck-heading-arrow"></div>
                  </div>
                  <div id="puck-badge" class="puck-badge">
                    <span>🚩</span><span id="puck-dist">0.0km</span>
                    <span class="badge-ele" id="puck-ele">--m</span>
                  </div>
                `;
                const puckMarker = new lib.Marker({ element: puckEl, anchor: 'center' });
                if (profileData.length > 0) {
                  puckMarker.setLngLat([profileData[0].lng, profileData[0].lat]).addTo(map);
                }

                // 初始化并绑定海拔/心率剖面图绘制与 3D 鼠标联动
                initProfileChart(map, puckMarker, puckEl);
                hasLayersReady = true;
                checkReadyToDismiss();
              });

              // 触控板手势支持：原生捕获 gesturechange 双指轻旋旋转地图
              const mapContainer = document.getElementById('map');
              let initialGestureBearing = 0;
              mapContainer.addEventListener('gesturestart', (e) => {
                e.preventDefault();
                initialGestureBearing = map.getBearing();
              });
              mapContainer.addEventListener('gesturechange', (e) => {
                e.preventDefault();
                if (typeof e.rotation !== 'undefined') {
                  map.setBearing(initialGestureBearing - e.rotation);
                }
              });

              // 3D 云台姿态控制中枢 (Bearing 方位横杆 & Pitch 俯仰拉杆)
              let isUserAdjustingGimbal = false;

              function updateBearingDisplay(b) {
                const normB = Math.round(((b % 360) + 360) % 360);
                const slider = document.getElementById('bearing-slider');
                if (slider && document.activeElement !== slider) slider.value = normB;
                const badge = document.getElementById('bearing-val-badge');
                if (badge) {
                  let dirName = '正北';
                  if (normB >= 23 && normB < 68) dirName = '东北';
                  else if (normB >= 68 && normB < 113) dirName = '正东';
                  else if (normB >= 113 && normB < 158) dirName = '东南';
                  else if (normB >= 158 && normB < 203) dirName = '正南';
                  else if (normB >= 203 && normB < 248) dirName = '西南';
                  else if (normB >= 248 && normB < 293) dirName = '正西';
                  else if (normB >= 293 && normB < 338) dirName = '西北';
                  badge.innerText = `${normB}° ${dirName}`;
                }
              }

              function updatePitchDisplay(p) {
                const normP = Math.round(Math.max(0, Math.min(85, p)));
                const slider = document.getElementById('pitch-slider');
                if (slider && document.activeElement !== slider) slider.value = normP;
                const badge = document.getElementById('pitch-val-badge');
                if (badge) {
                  let pitchName = '鸟瞰';
                  if (normP <= 10) pitchName = '顶视';
                  else if (normP >= 65) pitchName = '平视';
                  badge.innerText = `${normP}° ${pitchName}`;
                }
              }

              window.onBearingSliderInput = function(val) {
                try {
                  const b = parseFloat(val);
                  isUserAdjustingGimbal = true;
                  currentSmoothBearing = b;
                  if (map) {
                    map.setBearing(b);
                  }
                  updateBearingDisplay(b);
                } catch (err) {
                  logToSwift('[onBearingSliderInput err]: ' + err);
                } finally {
                  setTimeout(() => { isUserAdjustingGimbal = false; }, 60);
                }
              };

              window.onPitchSliderInput = function(val) {
                try {
                  const p = parseFloat(val);
                  isUserAdjustingGimbal = true;
                  if (map) {
                    map.setPitch(p);
                  }
                  updatePitchDisplay(p);
                } catch (err) {
                  logToSwift('[onPitchSliderInput err]: ' + err);
                } finally {
                  setTimeout(() => { isUserAdjustingGimbal = false; }, 60);
                }
              };

              window.setBearingPreset = function(deg) {
                try {
                  currentSmoothBearing = deg;
                  if (map) {
                    map.easeTo({ bearing: deg, duration: 400 });
                  }
                  updateBearingDisplay(deg);
                } catch (err) {
                  logToSwift('[setBearingPreset err]: ' + err);
                }
              };

              window.setPitchPreset = function(deg) {
                try {
                  if (map) {
                    map.easeTo({ pitch: deg, duration: 400 });
                  }
                  updatePitchDisplay(deg);
                } catch (err) {
                  logToSwift('[setPitchPreset err]: ' + err);
                }
              };

              // 双向事件绑定：当触控板手势、鼠标旋转或倾斜地图时，自动实时同步至右侧控制台
              map.on('rotate', () => {
                if (!isUserAdjustingGimbal) {
                  updateBearingDisplay(map.getBearing());
                }
              });

              map.on('pitch', () => {
                if (!isUserAdjustingGimbal) {
                  updatePitchDisplay(map.getPitch());
                }
              });

              // 初始状态同步
              updateBearingDisplay(map.getBearing());
              updatePitchDisplay(map.getPitch());

              // 剖面图折叠与展开状态控制
              let profileCollapsed = false;

              window.toggleProfile = function() {
                profileCollapsed = !profileCollapsed;
                // 1. 无条件强制复位拖拽锁，杜绝 WebKit 状态挂起
                isDragging = false;
                if (typeof window.forceResetDragState === 'function') {
                  window.forceResetDragState();
                }

                const card = document.getElementById('profile-container');
                const btn = document.getElementById('toggle-profile-btn');
                const tooltip = document.getElementById('profile-tooltip');
                if (tooltip) tooltip.style.display = 'none';

                if (card && btn) {
                  if (profileCollapsed) {
                    card.classList.add('collapsed');
                    btn.innerText = '▴ 展开剖面';
                  } else {
                    card.classList.remove('collapsed');
                    btn.innerText = '▾ 折叠剖面';
                    // 展开时稍微延时让 DOM 布局完成落地后再重绘
                    setTimeout(() => {
                      if (window.redrawProfile) window.redrawProfile();
                    }, 50);
                  }
                  // 折叠/展开时高度发生改变，平滑微调相机避让位置，杜绝遮挡
                  // 放在 requestAnimationFrame 中，确保在下一渲染帧以最新的 DOM 计算安全避让
                  requestAnimationFrame(() => {
                    if (window.reapplyCameraFollow) {
                      try {
                        window.reapplyCameraFollow();
                      } catch (err) {
                        logToSwift('[reapplyCameraFollow err]: ' + err);
                      }
                    }
                  });
                }
              };

              // 视角模式与巡航控制中枢 (对标两步路 & Strava)
              // viewMode: 'north' (正北鸟瞰，镜头不转，最稳最清晰，默认) | 'follow' (平滑追随，沿大山脉走向极缓跟转)
              let viewMode = 'north';
              let followCameraEnabled = true;
              let isCruising = false;
              let cruiseSpeed = 1; // 1x, 2x, 4x
              let currentSmoothBearing = 0;

              function getShortestBearing(currentBearing, targetBearing) {
                let diff = ((targetBearing - currentBearing + 540) % 360) - 180;
                return currentBearing + diff;
              }

              window.toggleViewMode = function() {
                const btn = document.getElementById('view-mode-btn');
                if (viewMode === 'north') {
                  viewMode = 'follow';
                  if (btn) {
                    btn.innerText = '🎬 平滑追随';
                    btn.classList.add('active');
                  }
                } else {
                  viewMode = 'north';
                  if (btn) {
                    btn.innerText = '🧭 正北鸟瞰';
                    btn.classList.add('active');
                  }
                  // 立即稳健回正至正北 0°
                  currentSmoothBearing = 0;
                  if (map) {
                    map.easeTo({ bearing: 0, duration: 400 });
                  }
                }
              };

              window.toggleFollowCamera = function() {
                followCameraEnabled = !followCameraEnabled;
                const btn = document.getElementById('follow-btn');
                if (btn) {
                  if (followCameraEnabled) {
                    btn.classList.add('active');
                    // 开启随行时，立即平滑飞跃推进至人物当前第一机位 (Zoom 15.0)
                    if (window.flyToCurrentPoint) {
                      window.flyToCurrentPoint();
                    } else if (window.reapplyCameraFollow) {
                      window.reapplyCameraFollow();
                    }
                  } else {
                    btn.classList.remove('active');
                  }
                }
              };

              window.cycleCruiseSpeed = function() {
                if (cruiseSpeed === 1) cruiseSpeed = 2;
                else if (cruiseSpeed === 2) cruiseSpeed = 4;
                else cruiseSpeed = 1;
                const btn = document.getElementById('speed-btn');
                if (btn) btn.innerText = cruiseSpeed + 'x';
              };

              window.resetToOverview = function() {
                if (typeof window.stopCruise === 'function') window.stopCruise();
                // 明确退出跟随人物模式，解除按钮激活态，避免全景下状态混淆
                followCameraEnabled = false;
                const fBtn = document.getElementById('follow-btn');
                if (fBtn) fBtn.classList.remove('active');

                currentSmoothBearing = 0;
                if (map) {
                  const pad = getOverviewPadding();
                  map.fitBounds(bounds, {
                    padding: pad,
                    pitch: 55,
                    bearing: 0,
                    duration: 1000
                  });
                }
              };

              // 专业海拔与心率双轴组合图表引擎 (Canvas 60fps 高清渲染)
              function initProfileChart(map, hoverMarker, hoverMarkerEl) {
                const canvas = document.getElementById('profile-canvas');
                const box = document.getElementById('profile-chart-box');
                const tooltip = document.getElementById('profile-tooltip');
                if (!canvas || !box || profileData.length < 2) return;

                const ctx = canvas.getContext('2d');
                let hoverIndex = -1;

                // 统计极值
                let minE = Infinity, maxE = -Infinity;
                let minH = Infinity, maxH = -Infinity;
                let hasHR = false;
                const maxD = profileData[profileData.length - 1].dist || 1.0;

                profileData.forEach(p => {
                  if (typeof p.ele === 'number') {
                    if (p.ele < minE) minE = p.ele;
                    if (p.ele > maxE) maxE = p.ele;
                  }
                  if (typeof p.hr === 'number' && p.hr > 0) {
                    hasHR = true;
                    if (p.hr < minH) minH = p.hr;
                    if (p.hr > maxH) maxH = p.hr;
                  }
                });

                if (minE === Infinity) minE = 0;
                if (maxE === -Infinity) maxE = 100;
                const eleSpan = Math.max(10, maxE - minE);
                const chartMinEle = Math.floor(minE - eleSpan * 0.06);
                const chartMaxEle = Math.ceil(maxE + eleSpan * 0.08);

                if (!hasHR) { minH = 60; maxH = 180; }
                const hrSpan = Math.max(20, maxH - minH);
                const chartMinHR = Math.max(30, Math.floor(minH - hrSpan * 0.1));
                const chartMaxHR = Math.min(220, Math.ceil(maxH + hrSpan * 0.1));

                let lastCanvasW = 0;
                let lastCanvasH = 0;

                function updateCanvasDimensions() {
                  if (profileCollapsed) return false;
                  const rect = box.getBoundingClientRect();
                  const w = rect.width;
                  const h = rect.height;
                  if (w <= 0 || h <= 0) return false;
                  const dpr = window.devicePixelRatio || 1;

                  if (Math.abs(w - lastCanvasW) > 0.5 || Math.abs(h - lastCanvasH) > 0.5) {
                    lastCanvasW = w;
                    lastCanvasH = h;
                    canvas.width = Math.round(w * dpr);
                    canvas.height = Math.round(h * dpr);
                    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
                    return true;
                  }
                  return false;
                }

                function render() {
                  if (profileCollapsed) return; // 折叠态下跳过 Canvas 绘制，避免 0x0 显存分配
                  const rect = box.getBoundingClientRect();
                  const w = rect.width;
                  const h = rect.height;
                  if (w <= 0 || h <= 0) return;

                  // 仅在容器真实 resize 时更新 Canvas 像素缓冲区，日常绘制零显存重分配
                  updateCanvasDimensions();
                  ctx.clearRect(0, 0, w, h);

                  const padLeft = 44;
                  const padRight = hasHR ? 44 : 12;
                  const padTop = 14;
                  const padBottom = 18;
                  const chartW = w - padLeft - padRight;
                  const chartH = h - padTop - padBottom;

                  if (chartW <= 0 || chartH <= 0) return;

                  function getX(dist) {
                    return padLeft + (dist / maxD) * chartW;
                  }
                  function getYEle(ele) {
                    const norm = (ele - chartMinEle) / (chartMaxEle - chartMinEle);
                    return padTop + (1 - norm) * chartH;
                  }
                  function getYHR(hr) {
                    const norm = (hr - chartMinHR) / (chartMaxHR - chartMinHR);
                    return padTop + (1 - norm) * chartH;
                  }

                  // 1. 绘制水平刻度虚线
                  ctx.strokeStyle = 'rgba(255, 255, 255, 0.07)';
                  ctx.lineWidth = 1;
                  ctx.setLineDash([4, 4]);

                  for (let i = 0; i <= 2; i++) {
                    const y = padTop + (chartH / 2) * i;
                    ctx.beginPath();
                    ctx.moveTo(padLeft, y);
                    ctx.lineTo(padLeft + chartW, y);
                    ctx.stroke();

                    // 左刻度 (海拔)
                    const eleVal = Math.round(chartMaxEle - (i / 2) * (chartMaxEle - chartMinEle));
                    ctx.fillStyle = 'rgba(255, 152, 0, 0.85)';
                    ctx.font = '9px SF Mono, monospace';
                    ctx.textAlign = 'right';
                    ctx.fillText(eleVal + 'm', padLeft - 6, y + 3);

                    // 右刻度 (心率)
                    if (hasHR) {
                      const hrVal = Math.round(chartMaxHR - (i / 2) * (chartMaxHR - chartMinHR));
                      ctx.fillStyle = 'rgba(239, 68, 68, 0.8)';
                      ctx.textAlign = 'left';
                      ctx.fillText(hrVal, padLeft + chartW + 6, y + 3);
                    }
                  }
                  ctx.setLineDash([]);

                  // 2. 绘制海拔面积图 (Orange 户外活力亮橙发光填充)
                  ctx.beginPath();
                  ctx.moveTo(getX(profileData[0].dist), padTop + chartH);

                  profileData.forEach((p, idx) => {
                    const x = getX(p.dist);
                    const y = getYEle(typeof p.ele === 'number' ? p.ele : minE);
                    if (idx === 0) ctx.lineTo(x, y);
                    else ctx.lineTo(x, y);
                  });

                  ctx.lineTo(getX(profileData[profileData.length - 1].dist), padTop + chartH);
                  ctx.closePath();

                  const eleGrad = ctx.createLinearGradient(0, padTop, 0, padTop + chartH);
                  eleGrad.addColorStop(0, 'rgba(255, 122, 0, 0.45)');
                  eleGrad.addColorStop(0.8, 'rgba(255, 122, 0, 0.08)');
                  eleGrad.addColorStop(1, 'rgba(255, 122, 0, 0.0)');
                  ctx.fillStyle = eleGrad;
                  ctx.fill();

                  // 顶部高亮边线 (亮橙)
                  ctx.beginPath();
                  profileData.forEach((p, idx) => {
                    const x = getX(p.dist);
                    const y = getYEle(typeof p.ele === 'number' ? p.ele : minE);
                    if (idx === 0) ctx.moveTo(x, y);
                    else ctx.lineTo(x, y);
                  });
                  ctx.strokeStyle = '#ff7a00';
                  ctx.lineWidth = 2.0;
                  ctx.shadowColor = 'rgba(255, 122, 0, 0.85)';
                  ctx.shadowBlur = 6;
                  ctx.stroke();
                  ctx.shadowBlur = 0;

                  // 3. 绘制红色心率曲线 (Red Line Chart)
                  if (hasHR) {
                    ctx.beginPath();
                    let hasStarted = false;
                    profileData.forEach(p => {
                      if (typeof p.hr === 'number' && p.hr > 0) {
                        const x = getX(p.dist);
                        const y = getYHR(p.hr);
                        if (!hasStarted) {
                          ctx.moveTo(x, y);
                          hasStarted = true;
                        } else {
                          ctx.lineTo(x, y);
                        }
                      }
                    });
                    ctx.strokeStyle = '#ef4444';
                    ctx.lineWidth = 1.8;
                    ctx.shadowColor = 'rgba(239, 68, 68, 0.9)';
                    ctx.shadowBlur = 5;
                    ctx.stroke();
                    ctx.shadowBlur = 0;
                  }

                  // 4. 绘制底轴刻度 (公里数)
                  ctx.fillStyle = 'rgba(255, 255, 255, 0.45)';
                  ctx.font = '9px SF Mono, monospace';
                  ctx.textAlign = 'center';
                  for (let i = 0; i <= 4; i++) {
                    const d = (maxD / 4) * i;
                    const x = getX(d);
                    ctx.fillText(d.toFixed(1) + 'km', x, h - 3);
                  }

                  // 5. 悬停十字标尺线与当前点亮点
                  if (hoverIndex >= 0 && hoverIndex < profileData.length) {
                    const curP = profileData[hoverIndex];
                    const hx = getX(curP.dist);

                    ctx.strokeStyle = 'rgba(255, 255, 255, 0.45)';
                    ctx.lineWidth = 1;
                    ctx.setLineDash([3, 3]);
                    ctx.beginPath();
                    ctx.moveTo(hx, padTop);
                    ctx.lineTo(hx, padTop + chartH);
                    ctx.stroke();
                    ctx.setLineDash([]);

                    // 海拔高亮点 (亮橙与纯白复合高光)
                    if (typeof curP.ele === 'number') {
                      const ey = getYEle(curP.ele);
                      ctx.fillStyle = '#ffffff';
                      ctx.beginPath();
                      ctx.arc(hx, ey, 5.0, 0, Math.PI * 2);
                      ctx.fill();
                      ctx.fillStyle = '#ff7a00';
                      ctx.beginPath();
                      ctx.arc(hx, ey, 3.2, 0, Math.PI * 2);
                      ctx.fill();
                    }

                    // 心率高亮点 (Red)
                    if (hasHR && typeof curP.hr === 'number') {
                      const hy = getYHR(curP.hr);
                      ctx.fillStyle = '#ffffff';
                      ctx.beginPath();
                      ctx.arc(hx, hy, 4.5, 0, Math.PI * 2);
                      ctx.fill();
                      ctx.fillStyle = '#ef4444';
                      ctx.beginPath();
                      ctx.arc(hx, hy, 3, 0, Math.PI * 2);
                      ctx.fill();
                    }
                  }
                }

                window.redrawProfile = render;
                window.addEventListener('resize', () => {
                  updateCanvasDimensions();
                  render();
                });
                render();

                // 相机跟随平滑缓动队列 (RAF 驱动，彻底告别瞎转与晃动)
                let pendingCameraTarget = null;
                let cameraRAF = null;

                function applyCameraFollow(pt, isAutoCruise = false) {
                  if (!map || !followCameraEnabled || !pt) return;

                  try {
                    let targetBearing = map.getBearing();
                    let targetPitch = map.getPitch();

                    // 只有在【沿线巡航】(Auto Cruise) 时，才由软件智能推荐航向与仰角；
                    // 其余所有手动拖拽/点按随行，100% 保持摄影师已手动调好的方向角与仰角！
                    if (isAutoCruise) {
                      if (viewMode === 'north') {
                        targetBearing = 0;
                        currentSmoothBearing = 0;
                        targetPitch = 55;
                      } else {
                        const macro = (pt.macroBearing !== undefined) ? pt.macroBearing : currentSmoothBearing;
                        let diff = ((macro - currentSmoothBearing + 540) % 360) - 180;
                        if (Math.abs(diff) < 8.0) {
                          targetBearing = currentSmoothBearing;
                        } else {
                          currentSmoothBearing += diff * 0.04;
                          targetBearing = currentSmoothBearing;
                        }
                        targetPitch = 62;
                      }
                    }

                    const pad = getCameraPadding(32);
                    map.easeTo({
                      center: [pt.lng, pt.lat],
                      bearing: targetBearing,
                      pitch: targetPitch,
                      zoom: Math.max(map.getZoom(), 15.0),
                      padding: pad,
                      duration: 120,
                      easing: (t) => t
                    });
                  } catch (err) {
                    logToSwift('[applyCameraFollow err]: ' + err);
                  }
                }

                window.reapplyCameraFollow = function() {
                  try {
                    if (pendingCameraTarget && followCameraEnabled) {
                      applyCameraFollow(pendingCameraTarget, false);
                    } else if (hoverIndex >= 0 && hoverIndex < profileData.length && followCameraEnabled) {
                      applyCameraFollow(profileData[hoverIndex], false);
                    }
                  } catch (err) {
                    logToSwift('[reapplyCameraFollow err]: ' + err);
                  }
                };

                window.flyToCurrentPoint = function() {
                  const targetIdx = (hoverIndex >= 0 && hoverIndex < profileData.length) ? hoverIndex : 0;
                  const pt = profileData[targetIdx];
                  if (pt && map) {
                    try {
                      const pad = getCameraPadding(32);
                      // 飞跃推近时，100% 严格保持摄影师当前手动选好的方向角与仰角！
                      map.flyTo({
                        center: [pt.lng, pt.lat],
                        bearing: map.getBearing(),
                        pitch: map.getPitch(),
                        zoom: Math.max(map.getZoom(), 15.0),
                        padding: pad,
                        duration: 800
                      });
                    } catch (err) {
                      logToSwift('[flyToCurrentPoint err]: ' + err);
                    }
                  }
                };

                let pendingIsAutoCruise = false;

                function scheduleCameraFollow(pt, isAutoCruise = false) {
                  pendingCameraTarget = pt;
                  pendingIsAutoCruise = isAutoCruise;
                  if (!cameraRAF) {
                    cameraRAF = requestAnimationFrame(() => {
                      cameraRAF = null;
                      if (pendingCameraTarget && followCameraEnabled) {
                        applyCameraFollow(pendingCameraTarget, pendingIsAutoCruise);
                      }
                    });
                  }
                }

                // 流光轨迹 RAF 节流调度队列 (杜绝高频巡航导致的 WebGL 顶点重复三角剖分)
                let pendingTraversedIdx = -1;
                let traversedRAF = null;

                function updateTraversedLine(idx) {
                  pendingTraversedIdx = idx;
                  if (!traversedRAF) {
                    traversedRAF = requestAnimationFrame(() => {
                      traversedRAF = null;
                      if (pendingTraversedIdx < 0) return;
                      const traversedSrc = map.getSource('gpx-track-traversed-source');
                      if (traversedSrc && allTrackCoords && allTrackCoords.length > 0) {
                        const curCoords = allTrackCoords.slice(0, Math.max(1, pendingTraversedIdx + 1));
                        traversedSrc.setData({
                          type: 'Feature',
                          properties: {},
                          geometry: {
                            type: 'LineString',
                            coordinates: curCoords
                          }
                        });
                      }
                    });
                  }
                }

                // 统一点选、剖面标尺、两步路人物 Puck、流光轨迹生长与 3D 相机联动
                function selectPointByIndex(idx, moveCamera, isAutoCruise = false) {
                  if (idx < 0 || idx >= profileData.length) return;
                  hoverIndex = idx;
                  const pt = profileData[idx];

                  render();

                  // 1. 更新底部剖面图 Tooltip (仅展开时显示，折叠时绝对隐藏)
                  if (tooltip) {
                    if (profileCollapsed) {
                      tooltip.style.display = 'none';
                    } else {
                      const rect = canvas.getBoundingClientRect();
                      const padLeft = 44;
                      const padRight = hasHR ? 44 : 12;
                      const chartW = rect.width - padLeft - padRight;
                      if (chartW > 0) {
                        const hx = padLeft + (pt.dist / maxD) * chartW;
                        tooltip.style.display = 'block';
                        tooltip.style.left = Math.max(90, Math.min(rect.width - 90, hx)) + 'px';
                        let text = `🚩 ${pt.dist.toFixed(2)} km  |  🏔️ ${pt.ele ? pt.ele + 'm' : '--'}`;
                        if (hasHR && pt.hr) {
                          text += `  |  ❤️ <span style="color:#f87171;font-weight:bold;">${pt.hr} bpm</span>`;
                        }
                        tooltip.innerHTML = text;
                      }
                    }
                  }

                  // 2. 更新 3D 人物运动主体 Puck 位置、前进航向罗盘箭头与悬浮数据气泡
                  if (hoverMarker) {
                    hoverMarker.setLngLat([pt.lng, pt.lat]);

                    const arrowEl = document.getElementById('puck-arrow');
                    if (arrowEl && pt.heading !== undefined) {
                      const mapBearing = map.getBearing();
                      const relAngle = pt.heading - mapBearing;
                      arrowEl.style.transform = `rotate(${relAngle}deg)`;
                    }

                    const distEl = document.getElementById('puck-dist');
                    const eleEl = document.getElementById('puck-ele');
                    if (distEl) distEl.innerText = `${pt.dist.toFixed(1)}km`;
                    if (eleEl && pt.ele) eleEl.innerText = `${Math.round(pt.ele)}m`;
                  }

                  // 3. 动态生长已走轨迹流光线 (Traversed Trail - RAF 节流合并调度)
                  updateTraversedLine(idx);

                  // 4. 驱动相机跟随
                  if (moveCamera && followCameraEnabled) {
                    scheduleCameraFollow(pt, isAutoCruise);
                  }
                }

                // 沿轨迹自动巡航漫游 (Auto Cruise)
                let cruiseTimer = null;
                let cruiseIndex = 0;

                function startCruise() {
                  if (isCruising) return;
                  isCruising = true;

                  // 巡航自动激活随行相机模式与按钮高亮
                  followCameraEnabled = true;
                  const fBtn = document.getElementById('follow-btn');
                  if (fBtn) fBtn.classList.add('active');

                  const card = document.getElementById('profile-container');
                  if (card) card.classList.add('cruising');
                  const btn = document.getElementById('cruise-btn');
                  if (btn) {
                    btn.innerText = '❚❚ 暂停';
                    btn.classList.add('cruising');
                  }
                  if (hoverIndex < 0 || hoverIndex >= profileData.length - 1) {
                    cruiseIndex = 0;
                  } else {
                    cruiseIndex = hoverIndex;
                  }

                  // 若当前相机仍停留在全景模式 (Zoom < 14)，先平滑推近至巡航起点机位
                  if (map && map.getZoom() < 14.0) {
                    const startPt = profileData[cruiseIndex];
                    if (startPt) {
                      try {
                        const pad = getCameraPadding(32);
                        map.flyTo({
                          center: [startPt.lng, startPt.lat],
                          zoom: 15.0,
                          pitch: (viewMode === 'north') ? 55 : 62,
                          padding: pad,
                          duration: 600
                        });
                      } catch (err) {
                        logToSwift('[startCruise flyTo err]: ' + err);
                      }
                    }
                  }

                  function stepCruise() {
                    if (!isCruising) return;
                    if (cruiseIndex >= profileData.length) {
                      stopCruise();
                      return;
                    }
                    // 巡航步进：开启 isAutoCruise = true
                    selectPointByIndex(cruiseIndex, true, true);
                    const stepSize = Math.max(1, Math.round(cruiseSpeed));
                    cruiseIndex += stepSize;
                    const interval = Math.max(15, Math.round(35 / cruiseSpeed));
                    cruiseTimer = setTimeout(stepCruise, interval);
                  }
                  stepCruise();
                }

                function stopCruise() {
                  isCruising = false;
                  if (cruiseTimer) {
                    clearTimeout(cruiseTimer);
                    cruiseTimer = null;
                  }
                  const card = document.getElementById('profile-container');
                  if (card) card.classList.remove('cruising');
                  const btn = document.getElementById('cruise-btn');
                  if (btn) {
                    btn.innerText = '▶ 沿线巡航';
                    btn.classList.remove('cruising');
                  }
                }

                window.toggleCruise = function() {
                  if (isCruising) {
                    stopCruise();
                  } else {
                    startCruise();
                  }
                };
                window.stopCruise = stopCruise;

                // 鼠标滑动与按住拖拽擦洗 (Scrubbing)
                let isDragging = false;

                function forceResetDragState() {
                  isDragging = false;
                }
                window.forceResetDragState = forceResetDragState;

                // 注册全局全生命周期事件监听，杜绝任何因 DOM 突变丢弃 mouseup 导致的 WebKit 拖拽死锁
                window.addEventListener('mouseup', forceResetDragState);
                window.addEventListener('pointerup', forceResetDragState);
                window.addEventListener('pointercancel', forceResetDragState);
                window.addEventListener('blur', forceResetDragState);

                // 基于物理里程（dist）的高性能二分查找定位函数 (彻底解决点密度不均引起的十字标尺与光标错位 Bug)
                function findClosestIndexByDist(targetDist) {
                  if (!profileData || profileData.length === 0) return 0;
                  const lastIdx = profileData.length - 1;
                  if (targetDist <= (profileData[0].dist || 0)) return 0;
                  if (targetDist >= (profileData[lastIdx].dist || 0)) return lastIdx;

                  let low = 0;
                  let high = lastIdx;
                  while (low <= high) {
                    const mid = (low + high) >> 1;
                    const midDist = profileData[mid].dist || 0;
                    if (midDist === targetDist) {
                      return mid;
                    } else if (midDist < targetDist) {
                      low = mid + 1;
                    } else {
                      high = mid - 1;
                    }
                  }

                  const leftIdx = Math.max(0, high);
                  const rightIdx = Math.min(lastIdx, low);
                  const diffLeft = Math.abs((profileData[leftIdx].dist || 0) - targetDist);
                  const diffRight = Math.abs((profileData[rightIdx].dist || 0) - targetDist);
                  return (diffLeft <= diffRight) ? leftIdx : rightIdx;
                }

                function handlePointerAt(clientX, moveCamera = false) {
                  if (profileCollapsed) return;
                  const rect = canvas.getBoundingClientRect();
                  const x = clientX - rect.left;
                  const padLeft = 44;
                  const padRight = hasHR ? 44 : 12;
                  const chartW = rect.width - padLeft - padRight;
                  if (chartW <= 0) return;

                  const ratio = Math.max(0, Math.min(1, (x - padLeft) / chartW));
                  const targetDist = ratio * maxD;
                  const idx = findClosestIndexByDist(targetDist);
                  // moveCamera 决定是否拉扯相机：悬停为 false，点按拖拽为 true
                  selectPointByIndex(idx, moveCamera, false);
                }

                canvas.addEventListener('mousedown', (e) => {
                  if (isCruising) stopCruise(); // 用户主动按住拖拽时才暂停巡航
                  isDragging = true;
                  // 点按开始：切入随行，平移相机 (moveCamera = true)
                  handlePointerAt(e.clientX, true);
                });

                window.addEventListener('mousemove', (e) => {
                  if (isDragging) {
                    // 按住拖拽滑动：随行移动相机 (moveCamera = true)
                    handlePointerAt(e.clientX, true);
                  }
                });

                canvas.addEventListener('mousemove', (e) => {
                  if (!isDragging) {
                    if (isCruising) return; // 自动巡航中，鼠标无意悬停不抢断巡航
                    // 仅指针悬停移动：纯看数据与指标，绝对不移动相机 (moveCamera = false)！
                    handlePointerAt(e.clientX, false);
                  }
                });

                canvas.addEventListener('mouseleave', () => {
                  if (!isDragging && !isCruising) {
                    if (tooltip) tooltip.style.display = 'none';
                  }
                });

                // 单击平滑飞跃至该山头机位 (Fly to)
                canvas.addEventListener('click', (e) => {
                  if (isCruising) stopCruise(); // 用户显式点击具体点时暂停自动巡航
                  const rect = canvas.getBoundingClientRect();
                  const x = e.clientX - rect.left;
                  const padLeft = 44;
                  const padRight = hasHR ? 44 : 12;
                  const chartW = rect.width - padLeft - padRight;
                  if (chartW <= 0) return;

                  const ratio = Math.max(0, Math.min(1, (x - padLeft) / chartW));
                  const targetDist = ratio * maxD;
                  const idx = findClosestIndexByDist(targetDist);
                  const pt = profileData[idx];
                  if (pt && map) {
                    try {
                      followCameraEnabled = true;
                      const fBtn = document.getElementById('follow-btn');
                      if (fBtn) fBtn.classList.add('active');

                      selectPointByIndex(idx, false);
                      const pad = getCameraPadding(32);
                      // 单重点按机位：100% 保持摄影师已手动设好的方向角与仰角！
                      map.flyTo({
                        center: [pt.lng, pt.lat],
                        bearing: map.getBearing(),
                        pitch: map.getPitch(),
                        zoom: Math.max(map.getZoom(), 15.0),
                        padding: pad,
                        duration: 800
                      });
                    } catch (err) {
                      logToSwift('[canvas click flyTo err]: ' + err);
                    }
                  }
                });

                // 地图旋转时实时校准 3D 罗盘箭头前进航向
                map.on('rotate', () => {
                  if (hoverIndex >= 0 && hoverIndex < profileData.length) {
                    const pt = profileData[hoverIndex];
                    const arrowEl = document.getElementById('puck-arrow');
                    if (arrowEl && pt && pt.heading !== undefined) {
                      const mapBearing = map.getBearing();
                      const relAngle = pt.heading - mapBearing;
                      arrowEl.style.transform = `rotate(${relAngle}deg)`;
                    }
                  }
                });

                // 3D 地图轨迹线鼠标移动拾取与双向反向联动
                map.on('mouseenter', 'gpx-track-base-line', () => {
                  map.getCanvas().style.cursor = 'pointer';
                });

                map.on('mouseleave', 'gpx-track-base-line', () => {
                  map.getCanvas().style.cursor = '';
                });

                let hoverRAF = null;
                let lastFoundIdx = 0;

                function findClosestIndexFast(clickLng, clickLat) {
                  let start = Math.max(0, lastFoundIdx - 150);
                  let end = Math.min(profileData.length, lastFoundIdx + 150);
                  let bestIdx = lastFoundIdx;
                  let minDistanceSq = Infinity;

                  for (let i = start; i < end; i++) {
                    const dLng = profileData[i].lng - clickLng;
                    const dLat = profileData[i].lat - clickLat;
                    const distSq = dLng * dLng + dLat * dLat;
                    if (distSq < minDistanceSq) {
                      minDistanceSq = distSq;
                      bestIdx = i;
                    }
                  }

                  if (minDistanceSq > 0.005) {
                    for (let i = 0; i < profileData.length; i++) {
                      const dLng = profileData[i].lng - clickLng;
                      const dLat = profileData[i].lat - clickLat;
                      const distSq = dLng * dLng + dLat * dLat;
                      if (distSq < minDistanceSq) {
                        minDistanceSq = distSq;
                        bestIdx = i;
                      }
                    }
                  }
                  lastFoundIdx = bestIdx;
                  return bestIdx;
                }

                map.on('click', 'gpx-track-base-line', (e) => {
                  const bestIdx = findClosestIndexFast(e.lngLat.lng, e.lngLat.lat);
                  const pt = profileData[bestIdx];
                  if (pt && map) {
                    try {
                      followCameraEnabled = true;
                      const fBtn = document.getElementById('follow-btn');
                      if (fBtn) fBtn.classList.add('active');

                      selectPointByIndex(bestIdx, false);
                      const pad = getCameraPadding(32);
                      // 地图轨迹线点击机位：100% 保持摄影师已手动设好的方向角与仰角！
                      map.flyTo({
                        center: [pt.lng, pt.lat],
                        bearing: map.getBearing(),
                        pitch: map.getPitch(),
                        zoom: Math.max(map.getZoom(), 15.0),
                        padding: pad,
                        duration: 800
                      });
                    } catch (err) {
                      logToSwift('[track click flyTo err]: ' + err);
                    }
                  }
                });

                map.on('mousemove', 'gpx-track-base-line', (e) => {
                  if (isDragging || isCruising) return;
                  if (!hoverRAF) {
                    const lng = e.lngLat.lng;
                    const lat = e.lngLat.lat;
                    hoverRAF = requestAnimationFrame(() => {
                      hoverRAF = null;
                      const bestIdx = findClosestIndexFast(lng, lat);
                      // 在地图轨迹上移动时，反向高亮剖面图与指标卡片，不拉扯大镜头
                      selectPointByIndex(bestIdx, false);
                    });
                  }
                });

                // 全生命周期显存与实例销毁释放钩子 (由 Swift dismantleNSView 显式调用，彻底释放 WebGL 显存与停止定时器)
                window.destroyMap = function() {
                  try {
                    if (ticker) { clearInterval(ticker); }
                    if (typeof window.stopCruise === 'function') { window.stopCruise(); }
                    if (cameraRAF) { cancelAnimationFrame(cameraRAF); cameraRAF = null; }
                    if (traversedRAF) { cancelAnimationFrame(traversedRAF); traversedRAF = null; }
                    if (hoverRAF) { cancelAnimationFrame(hoverRAF); hoverRAF = null; }
                    if (map) {
                      map.remove();
                      window.mapInstance = null;
                    }
                  } catch (e) {
                    logToSwift('[destroyMap err]: ' + e);
                  }
                };
              }
            }
          </script>
        </body>
        </html>
        """
    }
}
