import AppKit
import CoreLocation
import MapKit
import PhotoolsCore
import SwiftUI

/// 3D 摄影地图引擎与底图风格
public enum PerspectiveMapStyle: String, CaseIterable, Identifiable, Sendable {
    /// 3D 真实地形 (MapLibre 3D DEM + 高清遥感 + 贴地视锥，真实山川立体起伏，默认首选)
    case terrain3D = "terrain3d"
    /// Apple 混合卫星 (系统 MapKit)
    case appleHybrid = "apple_hybrid"
    /// Apple 纯卫星图 (系统 MapKit)
    case appleSatellite = "apple_satellite"
    /// Apple 标准地图 (系统 MapKit)
    case appleStandard = "apple_standard"

    public var id: String { rawValue }

    public var mkMapType: MKMapType {
        switch self {
        case .terrain3D, .appleHybrid:
            return .hybridFlyover
        case .appleSatellite:
            return .satelliteFlyover
        case .appleStandard:
            return .standard
        }
    }
}

/// 拍摄机位视角与 3D 卫星地形定向控制视图 (Photo Perspective & 3D Terrain View)
/// 支持在独立浮动辅助窗口或模态抽屉中运行
public struct PhotoPerspectiveSheet: View {
    public let asset: PhotoAssetGroup
    public let exif: ExifMetadata
    public var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared

    // 可交互调节的 3D 摄像机状态
    @State private var heading: Double
    @State private var fov: Double
    @State private var pitch: Double
    @State private var distance: Double
    @State private var cameraMode: PerspectiveCameraMode = .overview
    @State private var lockNorthUp: Bool = false
    @State private var mapStyle: PerspectiveMapStyle = .terrain3D
    @AppStorage("perspective3DTileProvider") private var selectedTileProvider: MapTileProvider = .autoNaviSatellite
    @State private var mapBearing: Double = 0.0
    @State private var isCustomPerspective: Bool = false

    // 3D 摄影视角写回 EXIF 状态
    @State private var isSavingPerspective: Bool = false
    @State private var savePerspectiveSuccess: Bool = false
    @State private var saveErrorMessage: String? = nil

    private var distanceProgressBinding: Binding<Double> {
        Binding<Double>(
            get: {
                CoordinateConverter.distanceToLogProgress(distance)
            },
            set: { newProg in
                distance = CoordinateConverter.logProgressToDistance(newProg)
                isCustomPerspective = true
            }
        )
    }

    public init(asset: PhotoAssetGroup, exif: ExifMetadata, onClose: (() -> Void)? = nil) {
        self.asset = asset
        self.exif = exif
        self.onClose = onClose

        // 优先使用 CameraAttitudeRegistry 策略解算出的真实姿态
        let attitude = exif.cameraAttitude
        let initialHeading = attitude?.heading ?? exif.gpsImgDirection ?? 0.0
        let initialFOV = attitude?.fov ?? exif.fieldOfView ?? 50.0
        let initialPitch = attitude?.pitch ?? exif.pitchAngle ?? 55.0

        // 视距优先使用已保存的 3D 视距 (viewDistance) 闭环还原
        // 其次使用物理对焦距离 (FocusDistance) 智能锚定，最后使用策略建议视距 (含海拔启发式)
        let initialDistance: Double = {
            if let savedDist = exif.viewDistance, savedDist >= 10.0 {
                return savedDist
            }
            if let focusM = attitude?.focusDistanceMeters ?? exif.focusDistanceMeters {
                return max(focusM * 2.0, 35.0)
            }
            return attitude?.suggestedDistanceMeters ?? 3000.0
        }()

        _heading = State(initialValue: initialHeading)
        _fov = State(initialValue: initialFOV)
        _pitch = State(initialValue: initialPitch)
        _distance = State(initialValue: initialDistance)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            ZStack(alignment: .bottom) {
                // 3D 卫星地图主体
                if let lat = exif.latitude, let lon = exif.longitude {
                    Group {
                        if mapStyle == .terrain3D {
                            PhotoPerspective3DMapView(
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                heading: heading,
                                fov: fov,
                                pitch: pitch,
                                distance: distance,
                                cameraMode: cameraMode,
                                lockNorthUp: lockNorthUp,
                                assetTitle: asset.baseName,
                                tileProvider: selectedTileProvider,
                                onCameraChanged: { newHeading, newPitch in
                                    // 触控板双指旋转地图仅改变地图摄像机观察朝向，照片拍摄朝向 heading 纹丝不动
                                    self.mapBearing = newHeading
                                },
                                onFallbackToNative: {
                                    self.mapStyle = .appleHybrid
                                }
                            )
                        } else {
                            PhotoPerspectiveMapView(
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                heading: heading,
                                fov: fov,
                                pitch: pitch,
                                distance: distance,
                                mapType: mapStyle.mkMapType,
                                cameraMode: cameraMode,
                                lockNorthUp: lockNorthUp,
                                assetTitle: asset.baseName
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 左上角悬浮机位与拍摄参数角标
                    VStack(alignment: .leading, spacing: 6) {
                        locationBadge(lat: lat, lon: lon)
                        cameraAttitudeBadge
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    // 底部一体化专业摄影控制坞 (居中平稳悬浮，彻底告别布局散架)
                    HStack {
                        Spacer(minLength: 0)
                        unifiedBottomControlDock
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else {
                    noGPSPlaceholder
                }
            }
            .clipped()
        }
        .frame(minWidth: 800, minHeight: 560)
        .onAppear {
            syncAttitudeFromExif()
        }
        .onExitCommand {
            if let customClose = onClose {
                customClose()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - 顶部工具栏 (左侧器材与文件名数据 + 右侧视角模式，窗口标题居中显示在系统标题栏)

    private var headerBar: some View {
        HStack(spacing: 8) {
            // 左对齐：照片文件名 + 相机机型 · 镜头型号 · 等效焦距 + 姿态策略徽章
            HStack(spacing: 6) {
                Text(asset.baseName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
                    .fixedSize()

                if let camera = exif.cameraModel {
                    Text(camera)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                if let lens = exif.lensModel {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(lens)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                if let focal = compactFocalLengthText {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(focal)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.blue)
                        .lineLimit(1)
                        .fixedSize()
                }

                if let attitude = exif.cameraAttitude {
                    Text(attitude.strategyName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                        .fixedSize()
                        .help(attitude.sourceDescription)
                }
            }

            Spacer(minLength: 20)

            // 右对齐：正北朝上锁定 + 俯瞰/主观视角切换
            HStack(spacing: 8) {
                Toggle(isOn: $lockNorthUp) {
                    Label("正北朝上", systemImage: lockNorthUp ? "location.north.line.fill" : "location.north.line")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(lockNorthUp ? "当前保持地图上北下南不旋转" : "点击切换为地图正北朝上锁定")

                Picker("", selection: $cameraMode) {
                    ForEach(PerspectiveCameraMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 160)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 悬浮状态角标

    private func locationBadge(lat: Double, lon: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.caption2)
                .foregroundStyle(.teal)
            Text(String(format: "%.6f°, %.6f°", lat, lon))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            if let alt = exif.altitude {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0fm", alt))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if mapStyle == .terrain3D {
                Text("DEM 真实高程")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.cyan.opacity(0.18), in: Capsule())

                Text(selectedTileProvider.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15), in: Capsule())

                let isWGS = selectedTileProvider.coordinateSystem == .wgs84 || CoordinateConverter.isOutOfChina(latitude: lat, longitude: lon)
                Text(isWGS ? "WGS-84 物理对齐" : "高德 GCJ-02 纠偏")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            } else {
                Text(CoordinateConverter.isOutOfChina(latitude: lat, longitude: lon) ? "WGS-84 原始机位" : "高德卫星纠偏")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .black).opacity(0.72))
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .colorScheme(.dark)
    }

    private var cameraAttitudeBadge: some View {
        let hasPitch = (exif.pitchAngle ?? exif.cameraAttitude?.pitch) != nil
        let hasRoll = (exif.rollAngle ?? exif.cameraAttitude?.roll) != nil
        let hasFD = exif.focusDistance != nil && !exif.focusDistance!.isEmpty

        if !hasPitch && !hasRoll && !hasFD {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "camera.metering.matrix")
                    .font(.caption2)
                    .foregroundStyle(Color.cyan)

                if let pitch = exif.pitchAngle ?? exif.cameraAttitude?.pitch {
                    Text("物理仰角: \(String(format: "%.1f°", pitch))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white)
                }

                if let roll = exif.rollAngle ?? exif.cameraAttitude?.roll {
                    Text("· 水平仪: \(String(format: "%.1f°", roll))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(abs(roll) < 1.0 ? Color.green : Color.orange)
                }

                if let fd = exif.focusDistance, !fd.isEmpty {
                    Text("· 对焦距: \(fd)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .black).opacity(0.72))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .colorScheme(.dark)
        )
    }

    // MARK: - 底部一体化专业摄影控制坞 (左侧机位视锥控制 + 竖直分隔线 + 右侧底图图源与外链)

    private var unifiedBottomControlDock: some View {
        HStack(alignment: .center, spacing: 16) {
            // 左半区：相机姿态与视角控制
            VStack(alignment: .leading, spacing: 8) {
                // 第 1 行：镜头朝向 (读数 + 130px长操作杆 + ±5°微调 + 纯文字4向预设)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.cyan)
                        Text(headingText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                            .lineLimit(1)
                    }
                    .frame(width: 86, alignment: .leading)

                    Slider(value: $heading, in: 0...360, step: 1.0)
                        .frame(width: 130)
                        .onChange(of: heading) { _ in
                            isCustomPerspective = true
                        }
                        .help("朝向操作杆 (平滑拖拽 0°~360°)")

                    // 常用 ±5° 快速微调 (位于方向预设之前)
                    HStack(spacing: 2) {
                        Button {
                            adjustHeading(by: -5.0)
                        } label: {
                            Text("-5°")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("逆时针微调 5°")

                        Button {
                            adjustHeading(by: 5.0)
                        } label: {
                            Text("+5°")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("顺时针微调 5°")
                    }

                    // 正四向预设 (只保留纯文字，无数字组合)
                    HStack(spacing: 3) {
                        presetButton("北", angle: 0.0)
                        presetButton("东", angle: 90.0)
                        presetButton("南", angle: 180.0)
                        presetButton("西", angle: 270.0)
                    }
                }

                // 第 2 行：视距与视场 (视距读数 + 130px长操作杆 + 视距微调 + 主体对焦 + 视角读数)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.yellow)
                        Text(distanceFormattedText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.yellow)
                            .lineLimit(1)
                    }
                    .frame(width: 86, alignment: .leading)

                    Slider(value: distanceProgressBinding, in: 0.0...1.0)
                        .frame(width: 130)
                        .help("对数视距操作杆 (平滑拉近或推远 15m~150km)")

                    // 视距微调 (自适应步长)
                    HStack(spacing: 2) {
                        Button {
                            adjustDistance(by: -fineDistanceStep)
                        } label: {
                            Text("-" + fineDistanceStepText)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .frame(minWidth: 34)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("拉近视距 \(fineDistanceStepHelpText)")

                        Button {
                            adjustDistance(by: fineDistanceStep)
                        } label: {
                            Text("+" + fineDistanceStepText)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .frame(minWidth: 34)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("推远视距 \(fineDistanceStepHelpText)")
                    }

                    // 主体对焦快捷按钮
                    if let focusM = exif.cameraAttitude?.focusDistanceMeters ?? exif.focusDistanceMeters {
                        Button {
                            distance = max(focusM * 2.0, 30.0)
                            isCustomPerspective = true
                        } label: {
                            Text("主体\(String(format: "%.0fm", focusM))")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.green)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("视锥快速对准镜头对焦主体 (\(String(format: "%.1fm", focusM)))")
                    }

                    // 视场角展示
                    HStack(spacing: 2) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cyan)
                        Text("视角:\(String(format: "%.1f°", fov))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                    }

                    // 核心新功能：快速切换到视角轴线区模拟摄影的角度重现
                    axisPerspectiveToggleButton
                }

                // 第 3 行：俯仰倾角 (俯仰读数 + 130px长操作杆 + 微调步进 + 保存与复位)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "angle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.cyan)
                        Text(String(format: "俯仰 %.0f°", pitch))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                    }
                    .frame(width: 86, alignment: .leading)

                    Slider(value: $pitch, in: 0...82, step: 1.0)
                        .frame(width: 130)
                        .onChange(of: pitch) { _ in
                            isCustomPerspective = true
                        }
                        .help("3D 地图观察倾角 (0° 垂直正俯视 ~ 82° 贴地平视远峰)")

                    // 俯仰角微调
                    HStack(spacing: 2) {
                        Button {
                            adjustPitch(by: -5.0)
                        } label: {
                            Text("-5°")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("视线向下俯瞰 5° (偏向垂直俯视)")

                        Button {
                            adjustPitch(by: -1.0)
                        } label: {
                            Text("-1°")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("视线向下俯瞰 1° (偏向俯瞰)")

                        Button {
                            adjustPitch(by: 1.0)
                        } label: {
                            Text("+1°")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("视线向上抬升 1° (偏向平视)")

                        Button {
                            adjustPitch(by: 5.0)
                        } label: {
                            Text("+5°")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .frame(minWidth: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("视线向上抬升 5° (偏向平视)")
                    }

                    Spacer(minLength: 4)

                    // 视角调整后保存与复位按钮
                    if isCustomPerspective {
                        HStack(spacing: 4) {
                            Button {
                                savePerspectiveToAsset()
                            } label: {
                                HStack(spacing: 3) {
                                    if isSavingPerspective {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "square.and.arrow.down")
                                    }
                                    Text(savePerspectiveSuccess ? "已写入" : "保存视角")
                                        .lineLimit(1)
                                }
                                .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(savePerspectiveSuccess ? .green : .indigo)
                            .controlSize(.small)
                            .disabled(isSavingPerspective)

                            Button {
                                resetToOriginalPerspective()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                            .help("复位至原始 3D 视角")
                        }
                    }
                }

                if let errMsg = saveErrorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                        Text(errMsg)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }

            // 垂直分割线
            Divider()
                .frame(height: 72)
                .overlay(Color.white.opacity(0.20))

            // 右半区：图源区与地图跳转
            VStack(alignment: .leading, spacing: 8) {
                // 第 1 行：3D 瓦片提供商菜单 + 快速跳转系统地图
                HStack(spacing: 8) {
                    if mapStyle == .terrain3D {
                        Menu {
                            ForEach(MapTileProvider.allCases) { provider in
                                Button {
                                    selectedTileProvider = provider
                                } label: {
                                    HStack {
                                        Text(provider.displayName)
                                        Text("· \(provider.subtitle)")
                                        if selectedTileProvider == provider {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "globe.asia.australia.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(selectedTileProvider.coordinateSystem == .wgs84 ? Color.blue : Color.cyan)
                                Text(selectedTileProvider.displayName)
                                    .font(.system(size: 10, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .menuStyle(.borderlessButton)
                        .help("切换 3D 地形底图切片源 (支持免Key的 Google 纯卫星 / Google 混合地球 / 高德遥感 / ESRI 遥感)")
                    }

                    Spacer(minLength: 4)

                    if let lat = exif.latitude, let lon = exif.longitude {
                        Button {
                            CoordinateConverter.openInAppleMaps(latitude: lat, longitude: lon, label: asset.baseName)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right.square.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("地图中打开")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .controlSize(.small)
                        .help(lang.text(.perspectiveOpenInMaps))
                    }
                }

                // 第 2 行：底图模式 Tab 选择
                Picker("", selection: $mapStyle) {
                    Text("3D地形").tag(PerspectiveMapStyle.terrain3D)
                    Text("混合").tag(PerspectiveMapStyle.appleHybrid)
                    Text("卫星").tag(PerspectiveMapStyle.appleSatellite)
                    Text("标准").tag(PerspectiveMapStyle.appleStandard)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 200)
            }
            .frame(width: 205)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .black).opacity(0.80))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)
        .colorScheme(.dark)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var noGPSPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(lang.text(.noGpsNotice))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 辅助组件与算法

    /// 视角轴线摄影重现与全局俯瞰快速切换按钮
    private var axisPerspectiveToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if cameraMode == .overview {
                    cameraMode = .pov
                    // 切入摄影重现模式时，若当前处于垂直俯视或低角度，自动推荐至 75° 贴地平视角度
                    if pitch < 50.0 {
                        pitch = 75.0
                    }
                } else {
                    cameraMode = .overview
                    // 切回全局俯瞰模式时，推荐至 55° 经典高空立体俯瞰角度
                    if pitch > 70.0 {
                        pitch = 55.0
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: cameraMode == .pov ? "viewfinder.circle.fill" : "viewfinder.circle")
                    .font(.system(size: 10, weight: .bold))
                Text(cameraMode == .pov ? "摄影重现" : "轴线重现")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                cameraMode == .pov
                    ? Color.cyan.opacity(0.28)
                    : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(cameraMode == .pov ? Color.cyan.opacity(0.85) : Color.white.opacity(0.18), lineWidth: 1)
            )
            .foregroundStyle(cameraMode == .pov ? Color.cyan : Color.white.opacity(0.92))
        }
        .buttonStyle(.plain)
        .help(cameraMode == .pov ? "当前处于视角轴线摄影重现模式 (POV)，点击切回全局俯瞰模式" : "点击快速对齐至视角轴线，模拟相机取景器的真实透视重现 (POV)")
    }

    private func presetButton(_ title: String, angle: Double) -> some View {
        Button {
            heading = angle
            isCustomPerspective = true
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .frame(minWidth: 20)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .buttonStyle(.plain)
        .help("快速转至正\(title)方向 (\(String(format: "%.0f°", angle)))")
    }

    private func adjustHeading(by delta: Double) {
        let newAngle = (heading + delta).truncatingRemainder(dividingBy: 360.0)
        heading = (newAngle + 360.0).truncatingRemainder(dividingBy: 360.0)
        isCustomPerspective = true
    }

    /// 根据当前视距自适应的微调步长 (米)
    private var fineDistanceStep: Double {
        if distance < 100 { return 10.0 }
        if distance < 500 { return 25.0 }
        if distance < 2000 { return 100.0 }
        if distance < 10000 { return 250.0 }
        if distance < 30000 { return 1000.0 }
        return 5000.0
    }

    private var fineDistanceStepText: String {
        if fineDistanceStep < 1000.0 {
            return String(format: "%.0fm", fineDistanceStep)
        } else {
            return String(format: "%.0fkm", fineDistanceStep / 1000.0)
        }
    }

    private var fineDistanceStepHelpText: String {
        if fineDistanceStep < 1000.0 {
            return String(format: "%.0f 米", fineDistanceStep)
        } else {
            return String(format: "%.0f 公里", fineDistanceStep / 1000.0)
        }
    }

    private func adjustDistance(by delta: Double) {
        distance = max(CoordinateConverter.minViewDistance, min(distance + delta, CoordinateConverter.maxViewDistance))
        isCustomPerspective = true
    }

    private func adjustPitch(by delta: Double) {
        pitch = max(0.0, min(pitch + delta, 82.0))
        isCustomPerspective = true
    }

    private var headingText: String {
        let deg = heading
        let compassDir = compassDirection(for: deg)
        return String(format: "%.1f° %@", deg, compassDir)
    }

    private func compassDirection(for degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int((normalized + 22.5) / 45.0) % 8
        return directions[index]
    }

    private func resetToOriginalPerspective() {
        heading = exif.cameraAttitude?.heading ?? exif.gpsImgDirection ?? 0.0
        pitch = exif.cameraAttitude?.pitch ?? exif.pitchAngle ?? 55.0
        if let savedDist = exif.viewDistance, savedDist >= 10.0 {
            distance = savedDist
        } else if let focusM = exif.cameraAttitude?.focusDistanceMeters ?? exif.focusDistanceMeters {
            distance = max(focusM * 2.0, 35.0)
        } else if let dist = exif.cameraAttitude?.suggestedDistanceMeters {
            distance = dist
        }
        isCustomPerspective = false
    }

    private var compactFocalLengthText: String? {
        guard let fl = exif.focalLength else { return nil }
        let parts = fl.components(separatedBy: " ")
        if let first = parts.first, let num = Double(first) {
            return String(format: "%.0fmm", num)
        }
        return fl
    }

    private var distanceFormattedText: String {
        if distance < 1000.0 {
            return String(format: "%.0fm", distance)
        } else {
            return String(format: "%.1fkm", distance / 1000.0)
        }
    }

    private func syncAttitudeFromExif() {
        let attitude = exif.cameraAttitude
        if let dir = attitude?.heading ?? exif.gpsImgDirection {
            self.heading = dir
        }
        if let fovVal = attitude?.fov ?? exif.fieldOfView {
            self.fov = fovVal
        }
        if let p = attitude?.pitch ?? exif.pitchAngle {
            self.pitch = p
        }
        if let savedDist = exif.viewDistance, savedDist >= 10.0 {
            self.distance = savedDist
        } else if let focusM = attitude?.focusDistanceMeters ?? exif.focusDistanceMeters {
            self.distance = max(focusM * 2.0, 35.0)
        } else if let dist = attitude?.suggestedDistanceMeters {
            self.distance = dist
        }
    }

    /// 严格遵循 SidecarPolicy 调度中枢并执行二次回读校验的 3D 摄影视角保存函数
    private func savePerspectiveToAsset() {
        guard let primary = asset.primaryPath else { return }
        isSavingPerspective = true
        saveErrorMessage = nil
        let targetHeading = heading
        let targetPitch = pitch
        let targetRoll = exif.rollAngle ?? exif.cameraAttitude?.roll ?? 0.0
        let targetDistance = distance

        Task.detached(priority: .userInitiated) {
            // 读取全局 SidecarPolicy 配置
            let policy = PhotoolsEngine.shared.getGlobalConfigJSON()
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .flatMap { $0["sidecar_policy"] as? String } ?? "smart"

            // 全链路统一步调调用 Go 端 WriteCameraPerspective 权威调度器
            let ok = PhotoolsEngine.shared.writeCameraPerspective(
                primaryPath: primary,
                heading: targetHeading,
                pitch: targetPitch,
                roll: targetRoll,
                viewDistance: targetDistance,
                sidecarPolicy: policy
            )

            let errMsg = ok ? nil : PhotoolsEngine.shared.getLastErrorMessage()

            await MainActor.run {
                isSavingPerspective = false
                if ok {
                    savePerspectiveSuccess = true
                    isCustomPerspective = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        savePerspectiveSuccess = false
                    }
                } else {
                    saveErrorMessage = errMsg ?? "写入 3D 视角失败，请检查文件写入权限"
                }
            }
        }
    }
}
