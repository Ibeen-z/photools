import CoreLocation
import Foundation

/// 3D 摄影地形底图切片提供商
public enum MapTileProvider: String, CaseIterable, Identifiable, Sendable {
    /// Google 纯卫星影像 (全球高清无偏移，免 Key，国际标准 WGS-84)
    case googleSatellite = "google_satellite"
    /// Google 混合地球 (卫星影像 + 道路地名注记，免 Key，国际标准 WGS-84)
    case googleHybrid = "google_hybrid"
    /// 高德遥感卫星 (国内直连秒开，自适应 GCJ-02 测绘纠偏)
    case autoNaviSatellite = "autonavi"
    /// ESRI ArcGIS 全球遥感 (全球覆盖，免 Key，WGS-84 原生，国内免梯直连)
    case esriSatellite = "esri_satellite"

    public var id: String { rawValue }

    /// 图源完整显示名称
    public var displayName: String {
        switch self {
        case .googleSatellite:
            return "Google 卫星"
        case .googleHybrid:
            return "Google 混合"
        case .autoNaviSatellite:
            return "高德卫星"
        case .esriSatellite:
            return "ESRI 遥感"
        }
    }

    /// 紧凑简短名称 (用于工具栏窄宽按钮)
    public var shortName: String {
        switch self {
        case .googleSatellite:
            return "Google 卫星"
        case .googleHybrid:
            return "Google 混合"
        case .autoNaviSatellite:
            return "高德卫星"
        case .esriSatellite:
            return "ESRI 遥感"
        }
    }

    /// 详细特性副标题
    public var subtitle: String {
        switch self {
        case .googleSatellite:
            return "WGS-84 物理对齐 · 纯净影像 (免Key)"
        case .googleHybrid:
            return "WGS-84 物理对齐 · 附带路网 (免Key)"
        case .autoNaviSatellite:
            return "国内免翻秒开 · GCJ-02 自动纠偏"
        case .esriSatellite:
            return "WGS-84 物理对齐 · 国内直连免梯 (免Key)"
        }
    }

    /// 该图源切片所使用的物理或加密坐标体系
    public var coordinateSystem: CoordinateSystem {
        switch self {
        case .googleSatellite, .googleHybrid, .esriSatellite:
            return .wgs84
        case .autoNaviSatellite:
            return .gcj02
        }
    }

    public enum CoordinateSystem: Sendable {
        /// 国际标准真实物理坐标 (相机的 GPS / GPX 原始标准)
        case wgs84
        /// 中国国测局非线性几何模糊加密坐标 (高德/腾讯等国内底图标准)
        case gcj02
    }

    /// 该切片源在中国大陆网络环境下是否通常需要代理访问
    public var requiresProxyInMainland: Bool {
        switch self {
        case .googleSatellite, .googleHybrid:
            return true
        case .autoNaviSatellite, .esriSatellite:
            return false
        }
    }

    /// 标准 XYZ 栅格瓦片 URL 列表 (支持多子域并发加速)
    public var tileURLs: [String] {
        switch self {
        case .googleSatellite:
            return [
                "https://mt0.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
                "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
                "https://mt2.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
                "https://mt3.google.com/vt/lyrs=s&x={x}&y={y}&z={z}"
            ]
        case .googleHybrid:
            return [
                "https://mt0.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
                "https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
                "https://mt2.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
                "https://mt3.google.com/vt/lyrs=y&x={x}&y={y}&z={z}"
            ]
        case .autoNaviSatellite:
            return [
                "https://webst01.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}",
                "https://webst02.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}",
                "https://webst03.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}",
                "https://webst04.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}"
            ]
        case .esriSatellite:
            return [
                "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
            ]
        }
    }

    /// 最大缩放等级
    public var maxZoom: Int {
        switch self {
        case .googleSatellite, .googleHybrid:
            return 20
        case .autoNaviSatellite, .esriSatellite:
            return 19
        }
    }

    /// 将照片的原始 WGS-84 物理坐标自适应映射至当前图源切片所匹配的渲染坐标
    /// - 若为 Google 或 ESRI 图源，切片本身为 WGS-84，直接返回原坐标，物理级零偏移；
    /// - 若为高德图源，国内自动执行 GCJ-02 纠偏转换以贴合加密切片，境外保持原值。
    public func renderCoordinate(for originalCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        switch coordinateSystem {
        case .wgs84:
            return originalCoord
        case .gcj02:
            return originalCoord.toGCJ02()
        }
    }
}
