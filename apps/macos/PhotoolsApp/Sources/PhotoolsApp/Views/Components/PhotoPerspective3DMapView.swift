import AppKit
import CoreLocation
import PhotoolsCore
import SwiftUI
import WebKit

/// 基于 MapLibre GL 3D Terrain (数字高程模型) 呈现真实立体山川、山体阴影与 3D 贴地视锥的渲染视图
public struct PhotoPerspective3DMapView: NSViewRepresentable {
    public let coordinate: CLLocationCoordinate2D
    public let heading: Double
    public let fov: Double
    public let pitch: Double
    public let distance: Double
    public let cameraMode: PerspectiveCameraMode
    public let lockNorthUp: Bool
    public let assetTitle: String
    public let tileProvider: MapTileProvider
    public var onCameraChanged: ((Double, Double) -> Void)? = nil
    public var onZoomChanged: ((Double) -> Void)? = nil
    public var onFallbackToNative: (() -> Void)? = nil

    public init(
        coordinate: CLLocationCoordinate2D,
        heading: Double,
        fov: Double,
        pitch: Double,
        distance: Double,
        cameraMode: PerspectiveCameraMode = .overview,
        lockNorthUp: Bool = false,
        assetTitle: String,
        tileProvider: MapTileProvider = .googleSatellite,
        onCameraChanged: ((Double, Double) -> Void)? = nil,
        onZoomChanged: ((Double) -> Void)? = nil,
        onFallbackToNative: (() -> Void)? = nil
    ) {
        self.coordinate = coordinate
        self.heading = heading
        self.fov = fov
        self.pitch = pitch
        self.distance = distance
        self.cameraMode = cameraMode
        self.lockNorthUp = lockNorthUp
        self.assetTitle = assetTitle
        self.tileProvider = tileProvider
        self.onCameraChanged = onCameraChanged
        self.onZoomChanged = onZoomChanged
        self.onFallbackToNative = onFallbackToNative
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "mapPerspectiveChanged")
        contentController.add(context.coordinator, name: "mapZoomChanged")
        contentController.add(context.coordinator, name: "mapReady")
        contentController.add(context.coordinator, name: "fallbackToNative")
        contentController.add(context.coordinator, name: "mapConsoleLog")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 设定合理默认初始物理尺寸，杜绝 frame 为 .zero 导致 WebGL 容器视口计算为 0x0 并黑屏
        let initialRect = NSRect(x: 0, y: 0, width: 980, height: 680)
        let webView = WKWebView(frame: initialRect, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(true, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor(red: 7/255.0, green: 10/255.0, blue: 18/255.0, alpha: 1.0).cgColor

        context.coordinator.webView = webView

        let html = generateHTMLTemplate()
        // 使用安全本地资源域，杜绝虚拟 https 域名引起的跨域或网络阻断
        let localBaseURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        webView.loadHTMLString(html, baseURL: localBaseURL)

        return webView
    }

    /// 转换为适配当前底图瓦片投影的渲染坐标
    /// - 若为 Google 纯卫星/Google 混合/ESRI 遥感：切片源本身为纯正 WGS-84，直接采用原始物理 GPS 坐标，零偏移绝对精准贴合；
    /// - 若为高德卫星：中国境内必须将原始 WGS-84 转换为 GCJ-02 才能贴合加密切片；境外自动保持纯正 WGS-84
    private var renderCoordinate: CLLocationCoordinate2D {
        tileProvider.renderCoordinate(for: coordinate)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // 仅在容器物理尺寸真实改变时，才通知 JS 端自适应触发 resize，避免父级求值时无意义的跨进程 IPC
        let currentSize = nsView.bounds.size
        if currentSize != coordinator.lastBoundsSize && currentSize.width > 0 && currentSize.height > 0 {
            coordinator.lastBoundsSize = currentSize
            nsView.evaluateJavaScript("if (window.resizeMap) { window.resizeMap(); }")
        }
        applyPerspective(to: nsView, coordinator: coordinator)
    }

    public func applyPerspective(to nsView: WKWebView, coordinator: Coordinator) {
        guard coordinator.isMapReady else { return }

        let renderCoord = renderCoordinate
        let targetLookAt = computeLookAtTarget(
            center: renderCoord,
            heading: heading,
            distance: distance,
            mode: cameraMode,
            lockNorthUp: lockNorthUp
        )
        let actualPitch = computeActualPitch(requestedPitch: pitch, mode: cameraMode, lockNorthUp: lockNorthUp)
        let cameraHeading = lockNorthUp ? 0.0 : heading
        
        let zoom: Double
        if cameraMode == .pov {
            // 视角轴线摄影重现模式：根据镜头视场角 (FOV) 智能模拟焦距变焦，广角展现全景，长焦将远山拉近
            let fovFactor = log2(max(40.0 / max(fov, 12.0), 0.35)) * 0.75
            let baseZoom = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: max(distance * 0.70, 40.0))
            zoom = min(max(baseZoom + fovFactor, 4.0), 19.5)
        } else {
            zoom = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: distance)
        }

        let isFirstRun = (coordinator.lastDistance == nil)
        let headingChanged = coordinator.lastHeading.map { abs($0 - cameraHeading) > 0.2 } ?? true
        let pitchChanged = coordinator.lastPitch.map { abs($0 - actualPitch) > 0.5 } ?? true
        let distChanged = coordinator.lastDistance.map { abs($0 - distance) > 2.0 } ?? true
        let centerChanged = coordinator.lastCenter.map {
            abs($0.latitude - renderCoord.latitude) > 0.00001 || abs($0.longitude - renderCoord.longitude) > 0.00001
        } ?? true
        let fovChanged = coordinator.lastFov.map { abs($0 - fov) > 0.2 } ?? true
        let modeChanged = coordinator.lastCameraMode != cameraMode
        let northLockChanged = coordinator.lastLockNorthUp != lockNorthUp
        let tileProviderChanged = coordinator.lastTileProvider != tileProvider

        if headingChanged || pitchChanged || distChanged || centerChanged || fovChanged || modeChanged || northLockChanged || tileProviderChanged {
            // 核心交互铁律：仅在全局模式切换(摄影重现/俯瞰全貌)、切换图源、或者初次进入时，才允许强行运镜重置相机的视口中心 (center) 和缩放级别 (zoom)
            // 用户在面板微调朝向、俯仰、视距时，相机的当前缩放大小与焦点绝对不跳变、不位移
            let resetViewport = modeChanged || tileProviderChanged || isFirstRun
            let syncCenter = resetViewport || (cameraMode == .pov && headingChanged)
            let syncZoom = resetViewport
            let syncPitch = resetViewport || pitchChanged
            let syncBearing = resetViewport || (cameraMode == .pov && headingChanged) || northLockChanged

            coordinator.lastHeading = cameraHeading
            coordinator.lastPitch = actualPitch
            coordinator.lastDistance = distance
            coordinator.lastCenter = renderCoord
            coordinator.lastFov = fov
            coordinator.lastCameraMode = cameraMode
            coordinator.lastLockNorthUp = lockNorthUp
            coordinator.lastTileProvider = tileProvider

            let conePoints = CoordinateConverter.generateViewConeCoordinates(
                center: renderCoord,
                heading: heading,
                fov: fov,
                distanceMeters: max(distance * 0.9, 15.0),
                steps: 24
            )

            let coneCoordsArray = conePoints.map { [$0.longitude, $0.latitude] }

            let centerAim = CoordinateConverter.projectTargetCoordinate(
                from: renderCoord,
                heading: heading,
                distanceMeters: max(distance * 0.9, 15.0)
            )

            let updatePayload: [String: Any] = [
                "center": [targetLookAt.longitude, targetLookAt.latitude],
                "pinCoord": [renderCoord.longitude, renderCoord.latitude],
                "bearing": cameraHeading,
                "syncCenter": syncCenter,
                "syncZoom": syncZoom,
                "syncPitch": syncPitch,
                "syncBearing": syncBearing,
                "isModeSwitch": modeChanged,
                "pitch": actualPitch,
                "zoom": zoom,
                "coneCoordinates": coneCoordsArray,
                "aimCoord": [centerAim.longitude, centerAim.latitude],
                "title": assetTitle
            ]

            if tileProviderChanged {
                let switchPayload: [String: Any] = [
                    "tiles": tileProvider.tileURLs,
                    "maxzoom": tileProvider.maxZoom,
                    "perspective": updatePayload
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: switchPayload),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    nsView.evaluateJavaScript("if (window.switchTileProvider) { window.switchTileProvider(\(jsonStr)); }")
                }
            } else {
                if let jsonData = try? JSONSerialization.data(withJSONObject: updatePayload),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    nsView.evaluateJavaScript("if (window.updatePerspective) { window.updatePerspective(\(jsonStr)); }")
                }
            }
        }
    }

    // MARK: - 几何与相机计算辅助

    private func computeLookAtTarget(
        center: CLLocationCoordinate2D,
        heading: Double,
        distance: Double,
        mode: PerspectiveCameraMode,
        lockNorthUp: Bool
    ) -> CLLocationCoordinate2D {
        if lockNorthUp {
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: min(distance * 0.35, 100.0)
            )
        }

        switch mode {
        case .overview:
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: distance * 0.45
            )
        case .pov:
            // 视角轴线摄影重现：焦点笔直对齐镜头朝向，延伸至主体山脉，轴线垂直贯穿屏幕中央
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: max(distance * 0.95, 45.0)
            )
        }
    }

    private func computeActualPitch(requestedPitch: Double, mode: PerspectiveCameraMode, lockNorthUp: Bool) -> Double {
        // 3D 地形防穿透安全包络 (Terrain Collision Envelope):
        // MapLibre 在开启 3D DEM 真实地形时，相机的飞行高度随 pitch 增大而急剧贴近地表。
        // 当 pitch 超过 60° 时，在天山等高原山区 (海拔 2650m) 会导致相机直接切入后方山体地层内部，
        // 触发 WebGL 硬件背面剔除 (Back-face Culling) 导致全屏被 background-color 纯黑吞没。
        // 因此传给 MapLibre 相机渲染的最大俯仰角安全夹紧至 60° (保证高空清晰俯瞰雪山全貌与视锥)，
        // 而 UI 底栏与左上角角标依然 100% 完整显示原始真实的物理仰角 (如 75.0°)！
        return max(0.0, min(requestedPitch, 60.0))
    }

    // MARK: - Coordinator & WebKit 桥接

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PhotoPerspective3DMapView
        weak var webView: WKWebView?
        var isMapReady = false

        var lastHeading: Double?
        var lastFov: Double?
        var lastPitch: Double?
        var lastDistance: Double?
        var lastCenter: CLLocationCoordinate2D?
        var lastCameraMode: PerspectiveCameraMode?
        var lastLockNorthUp: Bool?
        var lastTileProvider: MapTileProvider?
        var lastBoundsSize: CGSize = .zero

        init(_ parent: PhotoPerspective3DMapView) {
            self.parent = parent
            self.lastTileProvider = parent.tileProvider
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "mapReady":
                isMapReady = true
                self.lastTileProvider = parent.tileProvider
                if let wv = webView {
                    parent.applyPerspective(to: wv, coordinator: self)
                }
            case "mapPerspectiveChanged":
                guard let dict = message.body as? [String: Any] else { return }
                if let b = dict["bearing"] as? Double, let p = dict["pitch"] as? Double {
                    let normalizedBearing = (b.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
                    parent.onCameraChanged?(normalizedBearing, p)
                }
            case "mapZoomChanged":
                guard let dict = message.body as? [String: Any],
                      let newZoom = dict["zoom"] as? Double else { return }
                let newDist = CoordinateConverter.mapZoomToDistanceMeters(zoom: newZoom)
                self.lastDistance = newDist
                DispatchQueue.main.async {
                    self.parent.onZoomChanged?(newZoom)
                }
            case "fallbackToNative":
                DispatchQueue.main.async {
                    self.parent.onFallbackToNative?()
                }
            case "mapConsoleLog":
                #if DEBUG
                if let logText = message.body as? String {
                    print("[3D MapView Console]", logText)
                }
                #endif
            default:
                break
            }
        }
    }

    // MARK: - MapLibre 3D Terrain WebGL 静态资源内存单例缓存 (杜绝主线程重复读盘卡顿)

    private static func findAssetURL(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "maplibre") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // 尝试从应用运行路径向上递归探查源码目录 Resources/maplibre
        let cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cur.appendingPathComponent("apps/macos/PhotoolsApp/Resources/maplibre/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static let cachedCSS: String? = {
        guard let url = findAssetURL(name: "maplibre-gl", ext: "css") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private static let cachedJS: String? = {
        guard let url = findAssetURL(name: "maplibre-gl", ext: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func generateHTMLTemplate() -> String {
        let localCSS = Self.cachedCSS
        let localJS = Self.cachedJS
        let hasLocalAssets = (localCSS != nil && localJS != nil)

        let renderCoord = renderCoordinate
        let targetLookAt = computeLookAtTarget(
            center: renderCoord,
            heading: heading,
            distance: distance,
            mode: cameraMode,
            lockNorthUp: lockNorthUp
        )
        let actualPitch = computeActualPitch(requestedPitch: pitch, mode: cameraMode, lockNorthUp: lockNorthUp)
        let cameraHeading = lockNorthUp ? 0.0 : heading
        let zoom = CoordinateConverter.distanceMetersToMapZoom(distanceMeters: distance)

        let conePoints = CoordinateConverter.generateViewConeCoordinates(
            center: renderCoord,
            heading: heading,
            fov: fov,
            distanceMeters: max(distance * 0.9, 15.0),
            steps: 24
        )
        let coneCoordsArray = conePoints.map { "[\($0.longitude), \($0.latitude)]" }.joined(separator: ", ")

        let centerAim = CoordinateConverter.projectTargetCoordinate(
            from: renderCoord,
            heading: heading,
            distanceMeters: max(distance * 0.9, 15.0)
        )

        let tilesJson = try? JSONSerialization.data(withJSONObject: tileProvider.tileURLs)
        let tilesJsonString = tilesJson.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let tileMaxZoom = tileProvider.maxZoom

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <title>Photools 3D Terrain</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no" />
          \(hasLocalAssets ? "<style>\(localCSS!)</style>" : "<link rel=\"stylesheet\" href=\"https://registry.npmmirror.com/maplibre-gl/4.7.1/files/dist/maplibre-gl.css\" />")
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; overflow: hidden; background: #070a12; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
            #map { width: 100%; height: 100%; position: absolute; top: 0; left: 0; }

            /* 机位发光脉冲光标 */
            .camera-marker {
              width: 22px;
              height: 22px;
              border-radius: 50%;
              background: rgba(6, 182, 212, 0.95);
              border: 2px solid #ffffff;
              box-shadow: 0 0 14px rgba(6, 182, 212, 0.9), 0 0 28px rgba(6, 182, 212, 0.5);
              position: relative;
              cursor: pointer;
            }
            .camera-marker::after {
              content: '';
              position: absolute;
              top: -5px; left: -5px; right: -5px; bottom: -5px;
              border-radius: 50%;
              border: 2px solid rgba(6, 182, 212, 0.75);
              animation: cameraPulse 2.4s infinite cubic-bezier(0.215, 0.61, 0.355, 1);
            }
            @keyframes cameraPulse {
              0% { transform: scale(0.8); opacity: 1; }
              100% { transform: scale(2.3); opacity: 0; }
            }

            /* 加载中与容错遮罩 */
            /* 3D 真实高程 HUD 加载与容错遮罩 */
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
              padding: 24px;
              text-align: center;
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
            .fallback-card {
              display: none;
              flex-direction: column;
              align-items: center;
              animation: fadeIn 0.3s ease-out forwards;
              padding: 16px;
            }
            .fallback-title {
              color: #f59e0b;
              font-size: 13px;
              font-weight: 600;
              margin-bottom: 8px;
            }
            .fallback-desc {
              color: rgba(255, 255, 255, 0.65);
              font-size: 11px;
              line-height: 1.5;
              max-width: 320px;
              margin-bottom: 14px;
            }
            .fallback-btn {
              background: #0d9488;
              border: none;
              color: white;
              padding: 7px 16px;
              border-radius: 6px;
              font-size: 12px;
              font-weight: 600;
              cursor: pointer;
              box-shadow: 0 2px 8px rgba(13, 148, 136, 0.4);
              transition: transform 0.15s ease, background 0.15s ease;
            }
            .fallback-btn:hover { background: #0f766e; transform: scale(1.02); }
            @keyframes radarSpin { 100% { transform: rotate(360deg); } }
            @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
          </style>
        </head>
        <body>
          <div id="loading-overlay">
            <div id="spinner-box" class="hud-box">
              <div class="radar-scan">
                <div class="radar-circle"></div>
                <div class="radar-beam"></div>
                <div class="radar-core">
                  <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#06b6d4" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <circle cx="12" cy="12" r="10"></circle>
                    <polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"></polygon>
                  </svg>
                </div>
              </div>
              <div class="hud-title">3D 真实高程地形与视锥引擎</div>
              <div class="hud-progress-wrap">
                <div class="hud-progress-track">
                  <div id="hud-bar" class="hud-progress-fill"></div>
                </div>
                <div class="hud-meta">
                  <span id="hud-stage">正在启动 3D WebGL 渲染引擎...</span>
                  <span class="hud-pct-text"><strong id="hud-pct">15</strong>%</span>
                </div>
              </div>
            </div>
            <div id="fallback-box" class="fallback-card">
              <div class="fallback-title">3D 地形切片网络连接超时</div>
              <div class="fallback-desc">提示：若使用 Clash 建议开启 TUN 虚拟网卡接管系统网络；也可直接切换至免代理的系统原生 Apple 地图。</div>
              <button class="fallback-btn" onclick="triggerFallback()">切换至系统原生 Apple 卫星图</button>
            </div>
          </div>
          <div id="map"></div>

          \(hasLocalAssets ? "<script>\(localJS!)</script>" : "")

          <script>
            function logToSwift(msg) {
              if (window.webkit && window.webkit.messageHandlers.mapConsoleLog) {
                window.webkit.messageHandlers.mapConsoleLog.postMessage(String(msg));
              }
            }

            function triggerFallback() {
              if (window.webkit && window.webkit.messageHandlers.fallbackToNative) {
                window.webkit.messageHandlers.fallbackToNative.postMessage({});
              }
            }

            // 动态安全加载资源脚本 (多 CDN 双重容错：npmmirror 阿里云直连首选 + jsDelivr 备用)
            function loadResource(src, fallbackSrc, isCSS, cb) {
              const el = isCSS ? document.createElement('link') : document.createElement('script');
              if (isCSS) {
                el.rel = 'stylesheet';
                el.href = src;
              } else {
                el.src = src;
              }
              el.onload = () => cb(true);
              el.onerror = () => {
                logToSwift('Primary CDN load failed for: ' + src + ', trying fallback: ' + fallbackSrc);
                const fb = isCSS ? document.createElement('link') : document.createElement('script');
                if (isCSS) {
                  fb.rel = 'stylesheet';
                  fb.href = fallbackSrc;
                } else {
                  fb.src = fallbackSrc;
                }
                fb.onload = () => cb(true);
                fb.onerror = () => {
                  logToSwift('Fallback CDN also failed: ' + fallbackSrc);
                  cb(false);
                };
                document.head.appendChild(fb);
              };
              document.head.appendChild(el);
            }

            const npmmirrorJS = 'https://registry.npmmirror.com/maplibre-gl/4.7.1/files/dist/maplibre-gl.js';
            const jsdelivrJS = 'https://cdn.jsdelivr.net/npm/maplibre-gl@4.7.1/dist/maplibre-gl.js';
            const npmmirrorCSS = 'https://registry.npmmirror.com/maplibre-gl/4.7.1/files/dist/maplibre-gl.css';
            const jsdelivrCSS = 'https://cdn.jsdelivr.net/npm/maplibre-gl@4.7.1/dist/maplibre-gl.css';

            // 6秒超时未初始化时呈现降级卡片，绝不让用户死等
            const timeoutTimer = setTimeout(() => {
              const spinner = document.getElementById('spinner-box');
              const fallback = document.getElementById('fallback-box');
              if (spinner && fallback) {
                spinner.style.display = 'none';
                fallback.style.display = 'flex';
              }
            }, 6000);

            // 检查 MapLibre 运行时 (优先本地内联，备选动态 CDN 双通道)
            function checkAndStart() {
              const glLib = window.maplibregl || window.maplibre_gl;
              if (typeof glLib !== 'undefined') {
                logToSwift('MapLibre GL ready (instant local / preloaded)');
                initMap(glLib);
                return;
              }

              // 启动 CDN 加载流程
              loadResource(npmmirrorCSS, jsdelivrCSS, true, () => {});
              loadResource(npmmirrorJS, jsdelivrJS, false, (success) => {
                const lib = window.maplibregl || window.maplibre_gl;
                if (!success || typeof lib === 'undefined') {
                  logToSwift('MapLibre GL library failed to initialize via CDN');
                  const spinner = document.getElementById('spinner-box');
                  const fallback = document.getElementById('fallback-box');
                  if (spinner && fallback) {
                    spinner.style.display = 'none';
                    fallback.style.display = 'flex';
                  }
                  return;
                }
                initMap(lib);
              });
            }

            checkAndStart();

            function initMap(glLib) {
              const lib = glLib || window.maplibregl || window.maplibre_gl;
              if (!lib) {
                logToSwift('Fatal: MapLibre library not found in initMap');
                return;
              }

              const initialLng = \(renderCoord.longitude);
              const initialLat = \(renderCoord.latitude);
              const targetLng = \(targetLookAt.longitude);
              const targetLat = \(targetLookAt.latitude);
              const initialBearing = \(cameraHeading);
              const initialPitch = \(actualPitch);
              const initialZoom = \(zoom);

              let isUpdatingFromSwift = false;

              // 高清卫星底图瓦片：动态配置当前图源 (\(tileProvider.displayName))
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
                      tiles: [
                        'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'
                      ],
                      tileSize: 256,
                      encoding: 'terrarium',
                      maxzoom: 15
                    }
                  },
                  layers: [
                    {
                      id: 'background-layer',
                      type: 'background',
                      paint: {
                        'background-color': '#070a12'
                      }
                    },
                    {
                      id: 'satellite-layer',
                      type: 'raster',
                      source: 'satellite-source'
                    },
                    {
                      id: 'hillshade-layer',
                      type: 'hillshade',
                      source: 'terrain-source',
                      paint: {
                        'hillshade-shadow-color': '#060a12',
                        'hillshade-highlight-color': '#f8fafc',
                        'hillshade-accent-color': '#1e293b',
                        'hillshade-exaggeration': 0.60
                      }
                    }
                  ]
                },
                center: [targetLng, targetLat],
                zoom: initialZoom,
                bearing: initialBearing,
                pitch: initialPitch,
                maxPitch: 62,
                dragRotate: true,
                pitchWithRotate: true,
                touchZoomRotate: true,
                attributionControl: false
              });

              // 视口自适应机制：监听容器物理尺寸，杜绝窗口初次展开时 0x0 视口黑屏
              window.resizeMap = function() {
                if (map) {
                  map.resize();
                }
              };

              const mapEl = document.getElementById('map');
              if (window.ResizeObserver && mapEl) {
                const ro = new ResizeObserver(() => {
                  if (map) {
                    map.resize();
                  }
                });
                ro.observe(mapEl);
              }

              // 初始化阶段自适应触发多帧脉冲 resize，确保 macOS 窗口从展开动画到最终落定全程自适应校准视口
              requestAnimationFrame(() => { if (map) map.resize(); });
              setTimeout(() => { if (map) map.resize(); }, 60);
              setTimeout(() => { if (map) map.resize(); }, 180);
              setTimeout(() => { if (map) map.resize(); }, 350);
              setTimeout(() => { if (map) map.resize(); }, 700);
              setTimeout(() => { if (map) map.resize(); }, 1200);

              document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible' && map) {
                  map.resize();
                }
              });

              // 机位发光 Marker
              const markerEl = document.createElement('div');
              markerEl.className = 'camera-marker';
              markerEl.title = "\(assetTitle)";
              const marker = new lib.Marker({ element: markerEl })
                .setLngLat([initialLng, initialLat])
                .addTo(map);

              let currentPct = 25.0;
              let hasDismissed = false;
              let isSatelliteLoaded = false;
              let isTerrainLoaded = false;
              let hasSetupLayers = false;

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
                if (hasDismissed) return;
                hasDismissed = true;
                updateProgressUI(100, '3D 真实高程地形与视锥就绪！');
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
                // 视锥与地形就绪，且卫星瓦片已加载或视口瓦片已加载完毕
                const tilesReady = (map.areTilesLoaded && map.areTilesLoaded()) || isSatelliteLoaded;
                if (hasSetupLayers && tilesReady) {
                  finishLoading();
                }
              }

              // 监听切片流式加载事件
              map.on('sourcedata', (e) => {
                if (e.sourceId === 'satellite-source') {
                  if (e.isSourceLoaded) {
                    isSatelliteLoaded = true;
                    updateProgressUI(95, '卫星影像切片加载就绪...');
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

              // 地图空闲事件
              map.on('idle', () => {
                if (map) map.resize();
                if (isSatelliteLoaded || (map.areTilesLoaded && map.areTilesLoaded())) {
                  checkReadyToDismiss();
                }
              });

              // 兜底超时：3.5 秒强制就绪淡出，杜绝任何弱网或瓦片丢包导致的卡屏
              setTimeout(() => {
                if (!hasDismissed) {
                  finishLoading();
                }
              }, 3500);

              function setupLayersAndSources() {
                if (hasSetupLayers) return;
                hasSetupLayers = true;

                updateProgressUI(60, '正在构建立体视锥与山体阴影...');
                // 启用 3D 真实地形 (自然高程 1.15x，真实展现山体且杜绝近距离穿刺)
                try {
                  map.setTerrain({
                    source: 'terrain-source',
                    exaggeration: 1.15
                  });
                } catch (e) {
                  logToSwift('setTerrain error: ' + e);
                }

                // 大气雾效
                if (map.setFog) {
                  map.setFog({
                    range: [-0.5, 12],
                    color: '#070a12',
                    'high-color': '#0284c7',
                    'space-color': '#030712',
                    'horizon-blend': 0.12
                  });
                }

                // 贴地扇形视锥
                if (!map.getSource('view-cone-source')) {
                  map.addSource('view-cone-source', {
                    type: 'geojson',
                    data: {
                      type: 'Feature',
                      properties: {},
                      geometry: {
                        type: 'Polygon',
                        coordinates: [ [ \(coneCoordsArray) ] ]
                      }
                    }
                  });

                  map.addLayer({
                    id: 'view-cone-fill',
                    type: 'fill',
                    source: 'view-cone-source',
                    paint: {
                      'fill-color': '#06b6d4',
                      'fill-opacity': 0.30
                    }
                  });

                  map.addLayer({
                    id: 'view-cone-stroke',
                    type: 'line',
                    source: 'view-cone-source',
                    paint: {
                      'line-color': '#22d3ee',
                      'line-width': 2.0,
                      'line-opacity': 0.95
                    }
                  });
                }

                // 中心瞄准虚线
                if (!map.getSource('aim-line-source')) {
                  map.addSource('aim-line-source', {
                    type: 'geojson',
                    data: {
                      type: 'Feature',
                      properties: {},
                      geometry: {
                        type: 'LineString',
                        coordinates: [
                          [initialLng, initialLat],
                          [\(centerAim.longitude), \(centerAim.latitude)]
                        ]
                      }
                    }
                  });

                  map.addLayer({
                    id: 'aim-line-layer',
                    type: 'line',
                    source: 'aim-line-source',
                    paint: {
                      'line-color': '#ffffff',
                      'line-width': 1.5,
                      'line-dasharray': [2, 2],
                      'line-opacity': 0.85
                    }
                  });
                }

                // 通知 Swift 就绪
                if (window.webkit && window.webkit.messageHandlers.mapReady) {
                  window.webkit.messageHandlers.mapReady.postMessage({});
                }
                checkReadyToDismiss();
              }

              // 双重保障：只要样式元数据就绪 (style.load) 或全量就绪 (load)，立即添加视锥与瞄准线，绝不因外部切片延迟被挂起阻塞
              map.on('style.load', setupLayersAndSources);
              map.on('load', setupLayersAndSources);

              // 忽略个别瓦片 404，不阻断主图
              map.on('error', (e) => {
                logToSwift('MapLibre error: ' + (e && e.error ? e.error.message : e));
              });

              // 用户在三维地球自由旋转视角时同步回传 Swift
              function notifyPerspectiveChanged() {
                if (isUpdatingFromSwift) return;
                if (window.webkit && window.webkit.messageHandlers.mapPerspectiveChanged) {
                  window.webkit.messageHandlers.mapPerspectiveChanged.postMessage({
                    bearing: map.getBearing(),
                    pitch: map.getPitch(),
                    zoom: map.getZoom()
                  });
                }
              }

              map.on('rotate', notifyPerspectiveChanged);
              map.on('pitch', notifyPerspectiveChanged);

              // 用户在地图上手势缩放 (滚轮或捏合) 结束后，回传最新缩放等级给 Swift
              map.on('zoomend', function() {
                if (isUpdatingFromSwift) return;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mapZoomChanged) {
                  window.webkit.messageHandlers.mapZoomChanged.postMessage({
                    zoom: map.getZoom()
                  });
                }
              });

              // 监听 Mac 触控板原生双指旋转手势 (Rotate Gesture)，自由旋转地图东南西北
              let gestureStartBearing = 0;
              let isGestureRotating = false;

              window.addEventListener('gesturestart', function(e) {
                e.preventDefault();
                isGestureRotating = true;
                gestureStartBearing = map.getBearing();
              }, { passive: false });

              window.addEventListener('gesturechange', function(e) {
                e.preventDefault();
                if (!isGestureRotating || typeof e.rotation !== 'number') return;
                // e.rotation: 顺时针旋转手势 (度)
                // 顺时针旋转手指，地图向顺时针观察方位转动
                const targetBearing = (gestureStartBearing - e.rotation + 720) % 360;
                map.setBearing(targetBearing);
              }, { passive: false });

              window.addEventListener('gestureend', function(e) {
                e.preventDefault();
                isGestureRotating = false;
              }, { passive: false });

              // 动态更新接口
              window.updatePerspective = function(data) {
                isUpdatingFromSwift = true;

                if (data.pinCoord && data.pinCoord.length === 2) {
                  marker.setLngLat(data.pinCoord);
                }

                if (data.coneCoordinates && map.getSource('view-cone-source')) {
                  map.getSource('view-cone-source').setData({
                    type: 'Feature',
                    properties: {},
                    geometry: {
                      type: 'Polygon',
                      coordinates: [ data.coneCoordinates ]
                    }
                  });
                }

                if (data.pinCoord && data.aimCoord && map.getSource('aim-line-source')) {
                  map.getSource('aim-line-source').setData({
                    type: 'Feature',
                    properties: {},
                    geometry: {
                      type: 'LineString',
                      coordinates: [ data.pinCoord, data.aimCoord ]
                    }
                  });
                }

                // ── 3D 地形防穿透安全包络（防相机沉入地层全黑）──────────────────────────
                // 当 pitch 超过 60° 时，相机视点极易钻入山体地层内部触发 WebGL 背面剔除全黑。
                // 因此将实际渲染 pitch 安全收敛至最高 60°
                const rawPitch = (typeof data.pitch === 'number') ? data.pitch : map.getPitch();
                const safePitch = Math.min(rawPitch, 60);   // JS 端二次安全夹紧，最高 60°
                const safeExaggeration = rawPitch > 55
                  ? Math.max(0.20, 1.15 - (rawPitch - 55) * 0.05)
                  : 1.15;
                try {
                  map.setTerrain({ source: 'terrain-source', exaggeration: safeExaggeration });
                } catch(e) {}
                // ────────────────────────────────────────────────────────────────────────

                // isUpdatingFromSwift 兜底复位：350ms 强制解锁，彻底消灭按钮卡死感
                const unlockSwiftUpdate = () => { isUpdatingFromSwift = false; };
                const fallbackTimer = setTimeout(unlockSwiftUpdate, 350);

                if (data.isModeSwitch) {
                  // 视角模式切换或对齐视角轴线时：使用电影级飞跃运镜 (850ms 丝滑平滑过渡)
                  const flyOptions = {
                    center: data.center,
                    pitch: safePitch,
                    bearing: data.bearing,
                    zoom: data.zoom,
                    duration: 850,
                    essential: true
                  };
                  map.once('moveend', () => { clearTimeout(fallbackTimer); unlockSwiftUpdate(); });
                  map.flyTo(flyOptions);
                  setTimeout(() => { clearTimeout(fallbackTimer); unlockSwiftUpdate(); }, 880);
                } else {
                  // 交互微调时：仅对明确需要更新的相机属性执行平滑过渡，未指定的属性绝对保持现状不变
                  const easeOptions = {
                    duration: 220,
                    easing: (t) => t
                  };
                  let needsCameraEase = false;

                  if (data.syncCenter && data.center && data.center.length === 2) {
                    easeOptions.center = data.center;
                    needsCameraEase = true;
                  }
                  if (data.syncZoom && typeof data.zoom === 'number') {
                    easeOptions.zoom = data.zoom;
                    needsCameraEase = true;
                  }
                  if (data.syncPitch && typeof data.pitch === 'number') {
                    easeOptions.pitch = safePitch;
                    needsCameraEase = true;
                  }
                  if (data.syncBearing && typeof data.bearing === 'number') {
                    easeOptions.bearing = data.bearing;
                    needsCameraEase = true;
                  }

                  if (needsCameraEase) {
                    map.once('moveend', () => { clearTimeout(fallbackTimer); unlockSwiftUpdate(); });
                    map.easeTo(easeOptions);
                    setTimeout(() => { clearTimeout(fallbackTimer); unlockSwiftUpdate(); }, 240);
                  } else {
                    clearTimeout(fallbackTimer);
                    unlockSwiftUpdate();
                  }
                }
              };

              // 动态切换卫星底图切片源 (支持 Google 纯卫星/Google 混合地球/高德卫星/ESRI 遥感)
              window.switchTileProvider = function(data) {
                if (!map) return;
                try {
                  isSatelliteLoaded = false;
                  const tiles = data.tiles;
                  const maxzoom = data.maxzoom || 20;

                  if (map.getLayer('satellite-layer')) {
                    map.removeLayer('satellite-layer');
                  }
                  if (map.getSource('satellite-source')) {
                    map.removeSource('satellite-source');
                  }

                  map.addSource('satellite-source', {
                    type: 'raster',
                    tiles: tiles,
                    tileSize: 256,
                    maxzoom: maxzoom
                  });

                  const beforeId = map.getLayer('hillshade-layer') ? 'hillshade-layer' : (map.getLayer('view-cone-fill') ? 'view-cone-fill' : undefined);
                  map.addLayer({
                    id: 'satellite-layer',
                    type: 'raster',
                    source: 'satellite-source'
                  }, beforeId);

                  if (data.perspective && window.updatePerspective) {
                    window.updatePerspective(data.perspective);
                  }
                } catch (e) {
                  logToSwift('switchTileProvider error: ' + e);
                }
              };
            }
          </script>
        </body>
        </html>
        """
    }
}
