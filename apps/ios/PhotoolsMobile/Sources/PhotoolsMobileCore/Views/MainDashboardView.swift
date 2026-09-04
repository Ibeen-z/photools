import SwiftUI

/// 尼康 GPS 仪表盘主视图
public struct MainDashboardView: View {
    @ObservedObject var coordinator = CameraSyncCoordinator.shared
    @ObservedObject var gpxRecorder = GPXRecorderService.shared
    @State private var showingPairingSheet = false
    @State private var showingTracksSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 0. 系统关键权限与后台守护状态横幅 (核心保障)
                    systemPermissionsBanner

                    // 1. 顶部摄影巡航模式核心控制卡片
                    cruiseModeControlCard

                    // 2. 实时 GPS 卫星与物理坐标卡片
                    locationDashboardCard

                    // 3. 多相机机位状态看板
                    cameraDevicesCard

                    // 4. 实时下发中文日志流
                    liveLogSection
                }
                .padding()
            }
            .navigationTitle("NikonGPS for iOS")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            showingTracksSheet = true
                        } label: {
                            Label("轨迹档案", systemImage: "point.topleft.down.curvedto.point.filled.bottomright.up")
                        }

                        Button {
                            showingPairingSheet = true
                        } label: {
                            Label("配对新相机", systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPairingSheet) {
                PairingGuideView()
            }
            .sheet(isPresented: $showingTracksSheet) {
                GPXTrackHistoryView()
            }
            .onAppear {
                coordinator.checkBackgroundRefreshStatus()
            }
        }
    }

    // MARK: - 系统权限与后台刷新监控横幅
    private var systemPermissionsBanner: some View {
        let isAlways = coordinator.locationAuthStatus == .authorizedAlways
        let isFull = coordinator.isFullAccuracy
        let isBgRefresh = coordinator.isBackgroundRefreshEnabled
        let allGreen = isAlways && isFull && isBgRefresh

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(allGreen ? "后台同步权限完全就绪 🛡️" : "后台长效权限待完善 ⚠️",
                      systemImage: allGreen ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(allGreen ? .green : .orange)
                Spacer()
                if !allGreen {
                    Button("前往设置") {
                        coordinator.openSystemSettings()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }

            // 权限状态三联标
            HStack(spacing: 12) {
                // 1. 始终定位
                HStack(spacing: 4) {
                    Circle()
                        .fill(isAlways ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(isAlways ? "始终定位" : "非始终定位")
                        .font(.caption2)
                        .foregroundColor(isAlways ? .primary : .orange)
                }

                // 2. 精确位置
                HStack(spacing: 4) {
                    Circle()
                        .fill(isFull ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(isFull ? "精确位置" : "近似位置(偏差)")
                        .font(.caption2)
                        .foregroundColor(isFull ? .primary : .red)
                }

                // 3. 后台应用刷新
                HStack(spacing: 4) {
                    Circle()
                        .fill(isBgRefresh ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(isBgRefresh ? "后台刷新" : "后台刷新已关")
                        .font(.caption2)
                        .foregroundColor(isBgRefresh ? .primary : .red)
                }

                // 4. 运动协处理器
                HStack(spacing: 4) {
                    Circle()
                        .fill(coordinator.isMotionAvailable ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(coordinator.isMotionAvailable ? "运动感知" : "GPS位移")
                        .font(.caption2)
                        .foregroundColor(coordinator.isMotionAvailable ? .primary : .secondary)
                }
            }

            if !allGreen {
                Text("提示：锁屏息屏或手机放入口袋时，必须开启「始终允许」定位、「精确位置」及「后台刷新」，否则系统可能暂停 GPS 注入。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding()
        #if os(iOS)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - 巡航控制大卡片
    private var cruiseModeControlCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("摄影巡航模式")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(coordinator.isCruiseModeActive ? "后台长效守护中 · 连机即注入" : "已暂停 · 点按开启自动同步")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    coordinator.toggleCruiseMode()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: coordinator.isCruiseModeActive ? "pause.fill" : "play.fill")
                        Text(coordinator.isCruiseModeActive ? "停止巡航" : "开启巡航")
                    }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(coordinator.isCruiseModeActive ? Color.orange : Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
            }

            // 巡航录制状态横幅
            if coordinator.isCruiseModeActive {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("GPX 轨迹同步录制中")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                    }
                    Spacer()
                    if let stats = coordinator.gpxRecorder.activeRecordingStats {
                        Text("\(stats.pointCount) 点 · \(stats.formattedDistance) · \(stats.formattedDuration)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.primary)
                    } else {
                        Text("等待记录首个有效机位点...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)

                // 运动状态与保鲜策略胶囊
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: coordinator.currentMotionState.icon)
                            .foregroundColor(.blue)
                        Text(coordinator.currentMotionState.rawValue)
                            .font(.caption.bold())
                    }
                    Spacer()
                    let windowDesc = coordinator.currentMotionState == .stationary ? "20m 深度休眠保鲜" : (coordinator.currentMotionState.isMoving ? "5m 动态跟随" : "10m 默认保鲜")
                    Text("机位保鲜策略: \(windowDesc)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .cornerRadius(8)
            }

            Divider()

            HStack {
                Label("\(coordinator.totalInjectedCount) 次下发", systemImage: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
                Spacer()
                Button {
                    showingTracksSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text("轨迹档案 (\(gpxRecorder.recordedSessions.count))")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.blue)
                }
            }
        }
        .padding()
        #if os(iOS)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - GPS 坐标看板
    private var locationDashboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时 GPS 状态 (WGS-84)", systemImage: "location.fill")
                    .font(.headline)
                    .foregroundColor(.blue)
                Spacer()
                if let loc = coordinator.latestLocation {
                    Text("精度 ±\(Int(loc.accuracy))m")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(loc.accuracy <= 15 ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .foregroundColor(loc.accuracy <= 15 ? .green : .orange)
                        .cornerRadius(6)
                }
            }

            if let loc = coordinator.latestLocation {
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("纬度 Latitude")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.6f° %@", abs(loc.latitude), loc.latitude >= 0 ? "N" : "S"))
                                .font(.system(.subheadline, design: .monospaced).bold())
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("经度 Longitude")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.6f° %@", abs(loc.longitude), loc.longitude >= 0 ? "E" : "W"))
                                .font(.system(.subheadline, design: .monospaced).bold())
                        }
                    }

                    HStack {
                        VStack(alignment: .leading) {
                            Text("海拔高度")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(Int(loc.altitude)) m")
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("时区基准")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(TimeZone.current.identifier) (UTC\(TimeZone.current.secondsFromGMT() >= 0 ? "+" : "")\(TimeZone.current.secondsFromGMT() / 3600))")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    Divider()

                    // GPS 信号质量深度说明与解算评级
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                                .foregroundColor(colorForQuality(loc.fixQuality))
                            Text("GNSS 质量: \(loc.fixQuality.summary)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("传感器融合高精解算")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                .padding(.top, 4)
            } else {
                Text("等待定位数据获取中... 请确保开启系统定位权限")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .padding()
        #if os(iOS)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - 相机状态看板
    private var cameraDevicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已配对相机列表 (\(coordinator.savedCameras.count))", systemImage: "camera.fill")
                    .font(.headline)
                Spacer()
                Button("重新扫描") {
                    coordinator.bluetoothManager.startScanning()
                }
                .font(.caption)
            }

            if coordinator.savedCameras.isEmpty {
                VStack(spacing: 10) {
                    if coordinator.discoveredCameras.isEmpty {
                        Text("暂未保存任何尼康相机，正在自动扫描附近设备...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("打开配对向导") {
                            showingPairingSheet = true
                        }
                        .font(.subheadline.bold())
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("发现附近的相机 (可直接点击连接)：")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)

                            ForEach(coordinator.discoveredCameras) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.displayName)
                                                .font(.subheadline.bold())
                                            let bleQ = BLESignalQuality.from(rssi: item.rssi)
                                            HStack(spacing: 2) {
                                                bleSignalBarsView(bars: bleQ.bars, color: colorForBLE(bleQ))
                                                Text("\(item.rssi) dBm")
                                                    .font(.system(size: 10, design: .monospaced).bold())
                                                    .foregroundColor(colorForBLE(bleQ))
                                            }
                                        }
                                        Text(item.isPrePaired ? "已配对过 SnapBridge (可免配对直连)" : "全新配对模式")
                                            .font(.caption2)
                                            .foregroundColor(item.isPrePaired ? .green : .blue)
                                    }
                                    Spacer()
                                    Button(item.isPrePaired ? "免配对直连" : "开始配对") {
                                        coordinator.connectDiscoveredCamera(item)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(item.isPrePaired ? .green : .blue)
                                    .font(.caption.bold())
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(coordinator.savedCameras) { cam in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cam.displayName)
                                .font(.subheadline.bold())
                            Text("设备 ID: 0x\(String(cam.deviceID, radix: 16).uppercased())")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            #if canImport(CoreBluetooth)
                            let statusInfo = coordinator.cameraConnectionStatusDesc(for: cam)
                            let isConnected = statusInfo.isReady
                            #else
                            let statusInfo = (text: "未支持", isReady: false)
                            let isConnected = false
                            #endif
                            Text(statusInfo.text)
                                .font(.caption.bold())
                                .foregroundColor(colorForCameraStatus(statusInfo.text, isReady: statusInfo.isReady))

                            if let rssi = coordinator.rssi(for: cam), let bleQ = coordinator.bleSignalQuality(for: cam) {
                                HStack(spacing: 3) {
                                    // bleSignalBarsView(bars: bleQ.bars, color: isConnected ? colorForBLE(bleQ) : .secondary)
                                    Text("\(rssi) dBm (\(bleQ.title))")
                                        .font(.system(size: 10, design: .monospaced).bold())
                                        .foregroundColor(isConnected ? colorForBLE(bleQ) : .secondary)
                                }
                            }

                            if let last = cam.lastConnectedAt {
                                HStack(spacing: 2) {
                                    Text("最近同步")
                                    Text(last, style: .time)
                                }
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .padding()
        #if os(iOS)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - 实时日志流
    private var liveLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("通信事件日志", systemImage: "terminal.fill")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.logs.prefix(20)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.timestamp, style: .time)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text("[\(item.level.rawValue)]")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(colorForLevel(item.level))

                        Text(item.message)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            #if os(iOS)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            #else
            .background(Color.secondary.opacity(0.05))
            #endif
            .cornerRadius(10)
        }
    }

    private func colorForLevel(_ level: SyncLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - 信号质量与颜色映射辅助
    private func colorForQuality(_ quality: GPSFixQuality) -> Color {
        switch quality {
        case .excellent: return .green
        case .good:      return .teal
        case .moderate:  return .yellow
        case .weak:      return .orange
        case .poor:      return .red
        case .invalid:   return .gray
        }
    }

    private func colorForBLE(_ quality: BLESignalQuality) -> Color {
        switch quality {
        case .excellent: return .green
        case .good:      return .teal
        case .fair:      return .orange
        case .poor:      return .red
        }
    }

    private func colorForCameraStatus(_ text: String, isReady: Bool) -> Color {
        if isReady { return .green }
        if text.contains("待机") { return .orange }
        if text.contains("连通") || text.contains("握手") || text.contains("唤醒") { return .blue }
        if text.contains("异常") { return .red }
        return .secondary
    }

    /// 5 阶 GPS 信号柱状指示器
    @ViewBuilder
    private func gpsSignalBarsView(bars: Int, color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...5, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1)
                    .fill(idx <= bars ? color : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + idx * 2))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }

    /// 4 阶 蓝牙链路 RSSI 信号柱状指示器
    @ViewBuilder
    private func bleSignalBarsView(bars: Int, color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1)
                    .fill(idx <= bars ? color : Color.secondary.opacity(0.25))
                    .frame(width: 2.5, height: CGFloat(3.0 + Double(idx) * 2.5))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}
