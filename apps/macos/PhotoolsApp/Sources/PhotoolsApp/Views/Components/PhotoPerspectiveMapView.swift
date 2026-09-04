import AppKit
import CoreLocation
import MapKit
import PhotoolsCore
import SwiftUI

/// 3D 摄影机观察模式
public enum PerspectiveCameraMode: String, CaseIterable, Identifiable, Sendable {
    /// 上帝俯瞰模式：观察视锥几何中心，机位与扇形视锥完整展现于屏幕中央
    case overview = "overview"
    /// 取景器第一人称模式 (POV)：站在机位沿镜头朝向平视/仰望前方 3D 卫星地形
    case pov = "pov"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: return "俯瞰全貌"
        case .pov: return "摄影重现"
        }
    }
}

/// 基于 MapKit 呈现 3D 卫星地形视差与半透明扇形视锥的地图视图
public struct PhotoPerspectiveMapView: NSViewRepresentable {
    public let coordinate: CLLocationCoordinate2D
    public let heading: Double
    public let fov: Double
    public let pitch: Double
    public let distance: Double
    public let mapType: MKMapType
    public let cameraMode: PerspectiveCameraMode
    public let lockNorthUp: Bool
    public let assetTitle: String

    public init(
        coordinate: CLLocationCoordinate2D,
        heading: Double,
        fov: Double,
        pitch: Double,
        distance: Double,
        mapType: MKMapType = .hybridFlyover,
        cameraMode: PerspectiveCameraMode = .overview,
        lockNorthUp: Bool = false,
        assetTitle: String
    ) {
        self.coordinate = coordinate
        self.heading = heading
        self.fov = fov
        self.pitch = pitch
        self.distance = distance
        self.mapType = mapType
        self.cameraMode = cameraMode
        self.lockNorthUp = lockNorthUp
        self.assetTitle = assetTitle
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        // 隐藏原生比例尺与罗盘，彻底避免左上角被经纬度角标遮挡、右下角被底栏 HUD 遮挡截断
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.mapType = mapType

        let mapCenter = coordinate.toAppleMapsCoordinate()
        let targetLookAt = computeLookAtTarget(
            center: mapCenter,
            heading: heading,
            distance: distance,
            mode: cameraMode,
            lockNorthUp: lockNorthUp
        )
        let actualPitch = computeActualPitch(requestedPitch: pitch, mode: cameraMode, lockNorthUp: lockNorthUp)
        let cameraHeading = lockNorthUp ? 0.0 : heading
        // 上帝俯瞰模式下保证足够的舒适高程，避免超近焦距 (如 35m) 导致镜头贴地变成平面贴图而看不出 3D 视差
        let minComfortDistance: Double = (cameraMode == .overview) ? 260.0 : 60.0
        let cameraDistance = max(distance, minComfortDistance)

        let camera = MKMapCamera(
            lookingAtCenter: targetLookAt,
            fromDistance: cameraDistance,
            pitch: CGFloat(actualPitch),
            heading: cameraHeading
        )
        mapView.camera = camera

        // 缓存初始状态
        let coordinator = context.coordinator
        coordinator.lastHeading = cameraHeading
        coordinator.lastFov = fov
        coordinator.lastPitch = actualPitch
        coordinator.lastDistance = distance
        coordinator.lastCenter = mapCenter
        coordinator.lastMapType = mapType
        coordinator.lastCameraMode = cameraMode
        coordinator.lastLockNorthUp = lockNorthUp

        // 添加机位大头针
        let pin = CameraPinAnnotation(
            coordinate: mapCenter,
            title: assetTitle,
            subtitle: ""
        )
        mapView.addAnnotation(pin)

        // 添加半透明扇形视锥 (按实际视距绘制)
        let coneCoords = CoordinateConverter.generateViewConeCoordinates(
            center: mapCenter,
            heading: heading,
            fov: fov,
            distanceMeters: max(distance * 0.9, 15.0),
            steps: 24
        )
        let polygon = ViewConePolygon(coordinates: coneCoords, count: coneCoords.count)
        mapView.addOverlay(polygon, level: .aboveRoads)

        return mapView
    }

    public func updateNSView(_ nsView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let mapCenter = coordinate.toAppleMapsCoordinate()

        // 1. 底图类型切换
        if nsView.mapType != mapType {
            nsView.mapType = mapType
            coordinator.lastMapType = mapType
        }

        // 2. 检查相机是否需要更新
        let targetLookAt = computeLookAtTarget(
            center: mapCenter,
            heading: heading,
            distance: distance,
            mode: cameraMode,
            lockNorthUp: lockNorthUp
        )
        let actualPitch = computeActualPitch(requestedPitch: pitch, mode: cameraMode, lockNorthUp: lockNorthUp)
        let cameraHeading = lockNorthUp ? 0.0 : heading
        let minComfortDistance: Double = (cameraMode == .overview) ? 260.0 : 60.0
        let cameraDistance = max(distance, minComfortDistance)

        let headingChanged = coordinator.lastHeading.map { abs($0 - cameraHeading) > 0.2 } ?? true
        let pitchChanged = coordinator.lastPitch.map { abs($0 - actualPitch) > 0.5 } ?? true
        let distChanged = coordinator.lastDistance.map { abs($0 - distance) > 2.0 } ?? true
        let centerChanged = coordinator.lastCenter.map {
            abs($0.latitude - mapCenter.latitude) > 0.00001 || abs($0.longitude - mapCenter.longitude) > 0.00001
        } ?? true
        let modeChanged = coordinator.lastCameraMode != cameraMode
        let northLockChanged = coordinator.lastLockNorthUp != lockNorthUp

        if headingChanged || pitchChanged || distChanged || centerChanged || modeChanged || northLockChanged {
            let isFirstLoad = (coordinator.lastHeading == nil)
            coordinator.lastHeading = cameraHeading
            coordinator.lastPitch = actualPitch
            coordinator.lastDistance = distance
            coordinator.lastCenter = mapCenter
            coordinator.lastCameraMode = cameraMode
            coordinator.lastLockNorthUp = lockNorthUp

            let camera = MKMapCamera(
                lookingAtCenter: targetLookAt,
                fromDistance: cameraDistance,
                pitch: CGFloat(actualPitch),
                heading: cameraHeading
            )
            // 模式切换、正北锁定或首次加载使用平滑动画；滑块高频连续微调 (pitch/heading/distance) 采用零延迟直通更新，彻底避免 MapKit 动画堆叠丢帧导致“看似不动”
            let needAnimation = isFirstLoad || modeChanged || northLockChanged
            nsView.setCamera(camera, animated: needAnimation)
        }

        // 3. 检查视锥 Overlay 是否需要更新
        let fovChanged = coordinator.lastFov.map { abs($0 - fov) > 0.2 } ?? true
        if headingChanged || fovChanged || distChanged || centerChanged || northLockChanged || pitchChanged {
            coordinator.lastFov = fov

            let coneCoords = CoordinateConverter.generateViewConeCoordinates(
                center: mapCenter,
                heading: heading,
                fov: fov,
                distanceMeters: max(distance * 0.9, 15.0),
                steps: 24
            )

            let newPolygon = ViewConePolygon(coordinates: coneCoords, count: coneCoords.count)
            let oldOverlays = nsView.overlays
            nsView.addOverlay(newPolygon, level: .aboveRoads)
            nsView.removeOverlays(oldOverlays)
        }

        // 4. 更新机位标注
        if centerChanged || nsView.annotations.isEmpty {
            let currentAnnotations = nsView.annotations.compactMap { $0 as? CameraPinAnnotation }
            if let existing = currentAnnotations.first {
                existing.coordinate = mapCenter
                existing.title = assetTitle
            } else {
                let pin = CameraPinAnnotation(
                    coordinate: mapCenter,
                    title: assetTitle,
                    subtitle: ""
                )
                nsView.addAnnotation(pin)
            }
        }
    }

    // MARK: - 几何与相机辅助计算

    private func computeLookAtTarget(
        center: CLLocationCoordinate2D,
        heading: Double,
        distance: Double,
        mode: PerspectiveCameraMode,
        lockNorthUp: Bool
    ) -> CLLocationCoordinate2D {
        if lockNorthUp {
            // 正北锁定模式：直接对准机位中心稍偏视锥方向
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: min(distance * 0.3, 100.0)
            )
        }

        switch mode {
        case .overview:
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: distance * 0.40
            )
        case .pov:
            return CoordinateConverter.projectTargetCoordinate(
                from: center,
                heading: heading,
                distanceMeters: max(distance * 0.95, 45.0)
            )
        }
    }

    private func computeActualPitch(requestedPitch: Double, mode: PerspectiveCameraMode, lockNorthUp: Bool) -> Double {
        let clamped = max(0.0, min(requestedPitch, 75.0))
        if lockNorthUp {
            return min(clamped, 60.0)
        }
        return clamped
    }

    // MARK: - Coordinator & Delegate

    public final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoPerspectiveMapView
        var lastHeading: Double?
        var lastFov: Double?
        var lastPitch: Double?
        var lastDistance: Double?
        var lastCenter: CLLocationCoordinate2D?
        var lastMapType: MKMapType?
        var lastCameraMode: PerspectiveCameraMode?
        var lastLockNorthUp: Bool?

        init(_ parent: PhotoPerspectiveMapView) {
            self.parent = parent
        }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? ViewConePolygon {
                let renderer = MKPolygonRenderer(polygon: poly)
                // 极地青蓝半透明渐变雷达视锥
                renderer.fillColor = NSColor.systemTeal.withAlphaComponent(0.28)
                renderer.strokeColor = NSColor.systemCyan
                renderer.lineWidth = 1.5
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? CameraPinAnnotation else { return nil }
            let identifier = "CameraPin"
            let annotationView: MKMarkerAnnotationView
            if let dequeued = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView {
                annotationView = dequeued
                annotationView.annotation = pin
            } else {
                annotationView = MKMarkerAnnotationView(annotation: pin, reuseIdentifier: identifier)
                annotationView.canShowCallout = true
            }

            annotationView.markerTintColor = NSColor.systemTeal
            annotationView.glyphImage = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "机位")
            annotationView.displayPriority = .required
            return annotationView
        }
    }
}

// MARK: - 自定义 Annotation 与 Overlay 模型

final class CameraPinAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

final class ViewConePolygon: MKPolygon {}
