import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

/// 扫描发现的候选相机条目
public struct DiscoveredCameraItem: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let isNikonSmartDevice: Bool
    public let discoveredDeviceID: UInt32?
    #if canImport(CoreBluetooth)
    public let peripheral: CBPeripheral
    #endif

    public var isPrePaired: Bool {
        return discoveredDeviceID != nil
    }

    /// UI 显示用的安全脱敏名称 (序列号遮盖 4 位)
    public var displayName: String {
        CameraDevice.maskName(name)
    }
}

/// 相机蓝牙低功耗广播实时状态快照
public struct CameraAdvertisementState: Equatable, Sendable {
    public let rssi: Int
    public let statusByte: UInt8?
    public let lastSeen: Date

    public init(rssi: Int, statusByte: UInt8? = nil, lastSeen: Date = Date()) {
        self.rssi = rssi
        self.statusByte = statusByte
        self.lastSeen = lastSeen
    }

    /// 相机处于待机深睡心跳广播 (0x1D，Bit 0 == 1)
    public var isStandbySleeping: Bool {
        guard let b = statusByte else { return false }
        return (b & 0x01) != 0
    }

    /// 相机处于开机或快门唤醒就绪广播 (0x1C，Bit 0 == 0)
    public var isAwakeReady: Bool {
        guard let b = statusByte else { return false }
        return (b & 0x01) == 0
    }

    /// 广播信号是否在保鲜时效窗口内 (默认 8.0 秒，尼康待机广播约 1.28s~2.56s 一次，超 8s 未收到判定已关机或离开)
    public func isFresh(timeoutSeconds: TimeInterval = 8.0) -> Bool {
        return Date().timeIntervalSince(lastSeen) < timeoutSeconds
    }
}

/// 统合业务调度中枢 (面向 SwiftUI)
@MainActor
public final class CameraSyncCoordinator: ObservableObject {
    public static let shared = CameraSyncCoordinator()

    #if canImport(CoreBluetooth)
    public let bluetoothManager: NikonBluetoothManager
    #endif
    #if canImport(CoreLocation)
    public let locationProvider: LocationProvider
    #endif
    public let gpxRecorder = GPXRecorderService.shared
    public let motionTracker = MotionActivityTracker.shared

    @Published public var savedCameras: [CameraDevice] = []
    @Published public var discoveredCameras: [DiscoveredCameraItem] = []
    @Published public var activeSessionStates: [UUID: CameraConnectionStatus] = [:]
    @Published public var connectedCameraRSSI: [UUID: Int] = [:]
    @Published public var lastKnownCameraRSSI: [UInt32: Int] = [:]
    /// 记录各相机最近一次被扫描捕获的广播状态与时间戳 (按 DeviceID 索引)
    @Published public private(set) var recentCameraAdvertisements: [UInt32: CameraAdvertisementState] = [:]
    /// 记录各外设 UUID 最近一次被扫描捕获的广播状态与时间戳
    @Published public private(set) var recentUUIDAdvertisements: [UUID: CameraAdvertisementState] = [:]
    @Published public var latestLocation: LocationSnapshot?
    @Published public var logs: [SyncLogItem] = []
    @Published public var isCruiseModeActive: Bool = false
    @Published public var totalInjectedCount: Int = 0
    @Published public var currentMotionState: PhotographerMotionState = .unknown
    @Published public var isMotionAvailable: Bool = false

    // 权限与后台状态监控
    #if canImport(CoreLocation)
    @Published public var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    @Published public var isFullAccuracy: Bool = true
    #endif
    @Published public var isBackgroundRefreshEnabled: Bool = true

    private var cancellables = Set<AnyCancellable>()
    private var freshnessTimer: Timer?

    private let userDefaultsKey = "com.vincentchyu.photools.mobile.savedCameras"
    private let cruiseModeDefaultsKey = "com.vincentchyu.photools.mobile.cruiseModeActive"

    public init() {
        #if canImport(CoreBluetooth)
        self.bluetoothManager = NikonBluetoothManager()
        #endif
        #if canImport(CoreLocation)
        self.locationProvider = LocationProvider()
        #endif

        loadSavedCameras()
        self.isMotionAvailable = motionTracker.isActivityAvailable
        setupBindings()
        startFreshnessTimer()
        checkBackgroundRefreshStatus()
        setupLifecycleObservers()

        // 核心自愈：推迟至首个 RunLoop 周期异步触发，确保 App 毫秒级呈现首帧视图，彻底消除 Launch Metrics 超时与启动 Hang
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let savedCruise = UserDefaults.standard.bool(forKey: self.cruiseModeDefaultsKey)
            if savedCruise && !self.savedCameras.isEmpty {
                self.toggleCruiseMode()
            } else if !self.savedCameras.isEmpty {
                #if canImport(CoreLocation)
                self.locationProvider.setCruiseModeActive(false)
                self.locationProvider.start()
                #endif
                #if canImport(CoreBluetooth)
                // 方案 C 最佳实践：未开启巡航时，前台启动低功耗蓝牙扫描，捕获相机并对齐时钟
                self.bluetoothManager.startScanning()
                #endif
            }
        }
    }

    /// 检查 iOS 系统「后台 App 刷新」开关
    public func checkBackgroundRefreshStatus() {
        #if os(iOS)
        let status = UIApplication.shared.backgroundRefreshStatus
        switch status {
        case .available:
            self.isBackgroundRefreshEnabled = true
        case .denied, .restricted:
            self.isBackgroundRefreshEnabled = false
            appendLog(level: .error, message: "⚠️ iOS 系统「后台 App 刷新」已被关闭，锁屏息屏下后台同步将受到限制！请在系统设置中开启。")
        @unknown default:
            break
        }
        #endif
    }

    /// 一键跳转打开该 App 在 iPhone 上的系统设置页面 (用于开启「始终」定位、精确位置或后台刷新)
    public func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// 强制主动申请「始终允许」定位与「精确位置」
    public func requestFullPermissions() {
        #if canImport(CoreLocation)
        locationProvider.requestPermissions()
        #endif
    }

    private func setupLifecycleObservers() {
        // 核心时区事件驱动：仅在 iOS 系统时区发生真实变动时，向相机下发时区补偿
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleSystemTimeZoneChanged()
            }
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidBecomeActive()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidEnterBackground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleProcessTermination()
        }
        #endif
    }

    /// 当监听到 iOS 系统时区发生真实变更时，由事件驱动向已连接相机下发时区补偿
    public func handleSystemTimeZoneChanged() {
        #if canImport(CoreBluetooth)
        bluetoothManager.handleSystemTimeZoneChanged()
        #endif
    }

    /// 当 App 进入前台活跃状态时的自适应处理 (方案 C 最佳实践)
    public func handleAppDidBecomeActive() {
        #if canImport(CoreLocation)
        if !isCruiseModeActive && !savedCameras.isEmpty {
            // 前台仪表盘显示：仅在前台轻量启动定位，绝不开启后台定位指示
            locationProvider.setCruiseModeActive(false)
            locationProvider.start()
        }
        #endif
        #if canImport(CoreBluetooth)
        if !isCruiseModeActive && !savedCameras.isEmpty {
            // 前台轻感知：未开启巡航时，在前台启动低功耗蓝牙扫描，以便秒级捕获开机相机并对齐时钟
            bluetoothManager.startScanning()
        }
        #endif
    }

    /// 当 App 退入后台时的自适应处理
    public func handleAppDidEnterBackground() {
        flushPersistCameras()
        #if canImport(CoreLocation)
        if !isCruiseModeActive {
            // 核心铁律：未开启巡航模式时，退入后台立即彻底停止持续定位，彻底消除状态栏蓝色定位药丸，实现 0 功耗休眠！
            locationProvider.stop()
        }
        #endif
        #if canImport(CoreBluetooth)
        if !isCruiseModeActive {
            // 未开启巡航模式时，退入后台立即彻底停止蓝牙扫描，达到 0 功耗，绝不打扰相机深睡
            bluetoothManager.stopScanning()
        }
        #endif
    }

    /// 进程被杀死或收到系统终止信号时的安全兜底清理函数
    public func handleProcessTermination() {
        appendLog(level: .info, message: "检测到 App 进程即将终止，执行安全退出兜底清理...")
        flushPersistCameras()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        #if canImport(CoreBluetooth)
        bluetoothManager.resetAllBootSessions()
        bluetoothManager.stopScanning()
        #endif
        #if canImport(CoreLocation)
        locationProvider.stop()
        #endif
        motionTracker.stopTracking()
        if isCruiseModeActive {
            _ = gpxRecorder.stopSession()
        }
    }

    private func setupBindings() {
        // 轨迹档案全链路联动：当轨迹被删除或新增时，自动通知界面刷新档案统计
        gpxRecorder.$recordedSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // 运动状态与协处理器感知接入
        motionTracker.onLog = { [weak self] level, msg in
            Task { @MainActor [weak self] in
                self?.appendLog(level: level, message: msg)
            }
        }

        #if canImport(CoreBluetooth)
        motionTracker.onMotionStateChanged = { [weak self] state, isTransition in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentMotionState = state
                self.bluetoothManager.freshnessArbiter.updateMotionState(state, isTransition: isTransition)
            }
        }
        #endif

        #if canImport(CoreBluetooth) && canImport(CoreLocation)
        bluetoothManager.savedCameras = self.savedCameras

        // 日志接入
        bluetoothManager.onLog = { [weak self] level, msg in
            Task { @MainActor [weak self] in
                self?.appendLog(level: level, message: msg)
            }
        }

        locationProvider.onLog = { [weak self] level, msg in
            Task { @MainActor [weak self] in
                self?.appendLog(level: level, message: msg)
            }
        }

        // 监听定位权限变动
        locationProvider.onAuthorizationChanged = { [weak self] status, isFull in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.locationAuthStatus = status
                self.isFullAccuracy = isFull
                self.checkBackgroundRefreshStatus()
            }
        }

        // 设备发现
        bluetoothManager.onCameraDiscovered = { [weak self] peripheral, rssi, mfg, discoveredDevID in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let name = peripheral.name ?? "尼康相机"
                let isSmart = (mfg != nil)
                var statusByte: UInt8? = nil
                if let mfg = mfg, mfg.count >= 7 {
                    statusByte = mfg[6]
                }

                self.recordAdvertisement(
                    cameraDeviceID: discoveredDevID,
                    peripheralID: peripheral.identifier,
                    rssi: rssi,
                    statusByte: statusByte
                )

                let newItem = DiscoveredCameraItem(
                    id: peripheral.identifier,
                    name: name,
                    rssi: rssi,
                    isNikonSmartDevice: isSmart,
                    discoveredDeviceID: discoveredDevID,
                    peripheral: peripheral
                )

                // 关联已配对相机，并自动回填补齐预置相机的 bleIdentifier
                if let matchedIdx = self.savedCameras.firstIndex(where: {
                    $0.matches(
                        discoveredDeviceID: discoveredDevID,
                        peripheralUUID: peripheral.identifier,
                        peripheralName: name
                    )
                }) {
                    let devID = self.savedCameras[matchedIdx].deviceID
                    self.recordAdvertisement(
                        cameraDeviceID: devID,
                        peripheralID: peripheral.identifier,
                        rssi: rssi,
                        statusByte: statusByte
                    )
                    if self.savedCameras[matchedIdx].bleIdentifier == nil {
                        self.savedCameras[matchedIdx].bleIdentifier = peripheral.identifier.uuidString
                        self.persistCameras()
                    }
                }

                let matchIdx = self.discoveredCameras.firstIndex { item in
                    if item.id == peripheral.identifier { return true }
                    if let newDev = discoveredDevID, let oldDev = item.discoveredDeviceID, newDev == oldDev { return true }
                    if !name.isEmpty && name != "尼康相机" && item.name == name { return true }
                    return false
                }

                if let idx = matchIdx {
                    self.discoveredCameras[idx] = newItem
                } else {
                    self.discoveredCameras.append(newItem)
                    self.appendLog(level: .success, message: "发现相机广播: [\(name)] (RSSI: \(rssi) dBm) 📡")
                }
            }
        }

        // 配对信息持久化回调 (仅首次配对触发)
        bluetoothManager.onCameraPairingSaved = { [weak self] newCam in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.saveCamera(newCam)
                self.appendLog(level: .success, message: "已成功配对并保存相机: \(newCam.displayName) 📷")
                // 配对成功后自动激活摄影巡航模式，启动后台高精定位
                if !self.isCruiseModeActive {
                    self.toggleCruiseMode()
                }
            }
        }

        // 外设 UUID 句柄动态更新回调 (静默持久化，不误弹配对成功)
        bluetoothManager.onCameraHandleUpdated = { [weak self] updatedCam in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.saveCamera(updatedCam)
            }
        }

        // 会话状态实时变动感知 (连接/断开/就绪)
        bluetoothManager.onSessionStateChanged = { [weak self] pID, status in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.activeSessionStates[pID] = status
                if status == .disconnected {
                    // 相机关机或物理链路断开时，立即移除已连接实时 RSSI 与残余广播状态，彻底杜绝虚假信号残留
                    self.connectedCameraRSSI.removeValue(forKey: pID)
                    self.recentUUIDAdvertisements.removeValue(forKey: pID)
                    let matchedDevID = self.bluetoothManager.activeSessions[pID]?.stateMachine.savedDeviceID ??
                                       self.savedCameras.first(where: { $0.bleIdentifier == pID.uuidString })?.deviceID
                    if let devID = matchedDevID {
                        self.lastKnownCameraRSSI.removeValue(forKey: devID)
                        self.recentCameraAdvertisements.removeValue(forKey: devID)
                    }
                    self.objectWillChange.send()
                }
            }
        }

        // 蓝牙无线链路信号质量 (RSSI) 实时监听
        bluetoothManager.onCameraRSSIUpdated = { [weak self] pID, rssi in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connectedCameraRSSI[pID] = rssi
                if let sess = self.bluetoothManager.activeSessions[pID],
                   let devID = sess.stateMachine.savedDeviceID {
                    self.lastKnownCameraRSSI[devID] = rssi
                }
            }
        }

        // 相机会话秒级就绪：待机恢复时主动即刻补发最新有效 GPS 坐标
        bluetoothManager.onSessionReady = { [weak self] camUUID in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.activeSessionStates[camUUID] = .ready

                // 核心时效性校验：如果当前已有新鲜坐标 (60s 内)，立即极速注入
                if self.locationProvider.isLocationFresh(maxAge: 60.0),
                   let loc = self.locationProvider.latestValidLocation {
                    let geo = GeoPayload(location: loc)
                    self.bluetoothManager.broadcastLocation(geo: geo)
                    self.bluetoothManager.freshnessArbiter.recordInjection(cameraID: camUUID, location: loc)
                    self.totalInjectedCount += 1
                    self.recordSuccessfulSync()
                    self.appendLog(level: .success, message: "即时注入：最新 GPS 坐标已同步至相机 EXIF 📍")
                } else {
                    // 若未开启巡航模式或当前坐标已陈旧：发起单次高精度定位补位，绝不将几个小时前的陈旧时间戳盲目注入相机导致 ATT 0x80 拒写
                    self.appendLog(level: .info, message: "相机待机连通：正在请求当前新鲜 GPS 坐标以同步机位 🛰️")
                    self.locationProvider.requestSingleFreshLocation { [weak self] freshLoc in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if let loc = freshLoc, self.locationProvider.isLocationFresh(maxAge: 60.0) {
                                let geo = GeoPayload(location: loc)
                                self.bluetoothManager.broadcastLocation(geo: geo)
                                self.bluetoothManager.freshnessArbiter.recordInjection(cameraID: camUUID, location: loc)
                                self.totalInjectedCount += 1
                                self.recordSuccessfulSync()
                                self.appendLog(level: .success, message: "即时注入：当前新鲜 GPS 坐标已同步至相机 EXIF 📍")
                            } else {
                                self.appendLog(level: .info, message: "提示：当前未开启巡航模式，点按下方「开启巡航」即可开启持续后台 GPS 注入 🧭")
                            }
                        }
                    }
                }
            }
        }

        // 手机端实时定位更新 (每秒硬件更新即时触发，驱动 UI 绝对不用老缓存)
        locationProvider.onRealtimeLocationUpdated = { [weak self] clLocation in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snapshot = LocationSnapshot(
                    latitude: clLocation.coordinate.latitude,
                    longitude: clLocation.coordinate.longitude,
                    altitude: clLocation.altitude,
                    accuracy: clLocation.horizontalAccuracy,
                    timestamp: clLocation.timestamp
                )
                self.latestLocation = snapshot
                self.bluetoothManager.freshnessArbiter.updateCurrentLocation(clLocation)
                // 同步记录高精点位以生成合法 GPX 轨迹
                self.gpxRecorder.recordLocation(clLocation)
            }
        }

        // 蓝牙下发节电防抖注入 (位移 > 5m 或 静止 > 25s 触发向相机下发)
        locationProvider.onLocationReadyForSync = { [weak self] clLocation in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let geoPayload = GeoPayload(location: clLocation)
                self.bluetoothManager.broadcastLocation(geo: geoPayload)
                for (camUUID, session) in self.bluetoothManager.activeSessions where session.status == .ready {
                    self.bluetoothManager.freshnessArbiter.recordInjection(cameraID: camUUID, location: clLocation)
                }
                self.totalInjectedCount += 1
                self.recordSuccessfulSync()
            }
        }

        // GPS 丢失通知 (仅记录日志，不向相机下发引发 ATT 0x80 错误的空坐标报文)
        locationProvider.onLocationLost = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.appendLog(level: .warning, message: "GPS 信号暂时丢失，等待重新获取高精卫星 Fix ⚠️")
            }
        }
        #endif
    }

    /// 切换摄影巡航模式 (开启后台长效守护、自动连接与 GPX 轨迹录制)
    public func toggleCruiseMode() {
        isCruiseModeActive.toggle()
        UserDefaults.standard.set(isCruiseModeActive, forKey: cruiseModeDefaultsKey)
        #if canImport(CoreBluetooth) && canImport(CoreLocation)
        bluetoothManager.isCruiseModeActive = isCruiseModeActive
        if isCruiseModeActive {
            locationProvider.setCruiseModeActive(true)
            gpxRecorder.startSession()
            appendLog(level: .info, message: "一键巡航模式已激活：开启高精定位、相机待机秒连与 GPX 轨迹录制 🔴")
            locationProvider.start()
            motionTracker.startTracking()
            bluetoothManager.startScanning()
        } else {
            let session = gpxRecorder.stopSession()
            if let session = session {
                appendLog(level: .success, message: "巡航轨迹已归档保存：\(session.formattedPointCount)，里程 \(session.formattedDistance)，文件 \(session.gpxFileName) 📁")
            } else {
                appendLog(level: .info, message: "摄影巡航模式已暂停：关闭持续定位以省电")
            }
            locationProvider.setCruiseModeActive(false)
            #if canImport(UIKit)
            if UIApplication.shared.applicationState == .background {
                locationProvider.stop()
            }
            #endif
            motionTracker.stopTracking()
            bluetoothManager.stopScanning()
        }
        #endif
    }

    #if canImport(CoreBluetooth)
    public func connectDiscoveredCamera(_ item: DiscoveredCameraItem) {
        let matchedSaved = savedCameras.first(where: {
            $0.matches(
                discoveredDeviceID: item.discoveredDeviceID,
                peripheralUUID: item.id,
                peripheralName: item.name
            )
        })
        let modeDesc = (matchedSaved != nil || item.isPrePaired) ? "免配对直连模式" : "配对模式"
        appendLog(level: .info, message: "正在发起连接相机: \(item.name) (\(modeDesc))...")
        bluetoothManager.connect(to: item.peripheral, savedCamera: matchedSaved, discoveredDeviceID: item.discoveredDeviceID)
    }

    /// 查询指定相机是否处于已连接就绪状态 (多维匹配 UUID / 名称 / Device ID，彻底解决 UI 状态脱节)
    public func isCameraConnected(_ cam: CameraDevice) -> Bool {
        return cameraConnectionStatusDesc(for: cam).isReady
    }

    /// 获取指定已配对相机的精准连接状态描述
    public func cameraConnectionStatusDesc(for cam: CameraDevice) -> (text: String, isReady: Bool) {
        // 1. 优先检查活跃 GATT 会话 (正在连接 / 握手 / 就绪)
        for (uuid, session) in bluetoothManager.activeSessions {
            let isMatch = cam.matches(
                discoveredDeviceID: session.stateMachine.savedDeviceID,
                peripheralUUID: uuid,
                peripheralName: session.peripheral.name
            )
            if isMatch {
                let status = activeSessionStates[uuid] ?? session.status
                switch status {
                case .ready:
                    return ("同步就绪 🟢", true)
                case .connecting:
                    return ("物理连通中 ⚡️", false)
                case .handshaking:
                    return ("握手认证中 🔄", false)
                case .error:
                    return ("通信异常 ⚠️", false)
                case .disconnected, .scanning:
                    break
                }
            }
        }

        // 2. 检查最近是否有新鲜的低功耗广播 (8 秒时效内)
        var recentAdv: CameraAdvertisementState?
        if let adv = recentCameraAdvertisements[cam.deviceID], adv.isFresh() {
            recentAdv = adv
        } else if let bleId = cam.bleIdentifier, let uuid = UUID(uuidString: bleId),
                  let adv = recentUUIDAdvertisements[uuid], adv.isFresh() {
            recentAdv = adv
        }

        if let adv = recentAdv {
            if adv.isStandbySleeping {
                return ("待机休眠 💤", false)
            } else if adv.isAwakeReady {
                return ("唤醒待连 ⚡️", false)
            } else {
                return ("待机休眠 💤", false)
            }
        }

        // 3. 超过 8 秒未收到广播，或物理连接已断开且无广播：明确判定为已关机 / 未连接
        return ("已断开 ⚪️", false)
    }
    #endif

    // MARK: - 持久化管理

    private var persistWorkItem: DispatchWorkItem?

    /// 记录成功同步的时间与累计次数 (内存即时更新，落盘采用 15 秒防抖合并，避免移动过程中每秒序列化)
    public func recordSuccessfulSync() {
        let now = Date()
        var hasChanges = false
        #if canImport(CoreBluetooth)
        for (pID, session) in bluetoothManager.activeSessions where session.status == .ready {
            let pName = session.peripheral.name ?? ""
            if let idx = savedCameras.firstIndex(where: {
                $0.bleIdentifier == pID.uuidString || (!pName.isEmpty && $0.name == pName)
            }) {
                savedCameras[idx].lastConnectedAt = now
                savedCameras[idx].totalSyncCount += 1
                hasChanges = true
            }
        }
        #endif
        if hasChanges {
            scheduleDebouncedPersist()
        }
    }

    /// 调度 15 秒防抖写入，合并高频同步产生的落盘请求
    public func scheduleDebouncedPersist(delay: TimeInterval = 15.0) {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistCameras()
        }
        self.persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 强制即刻将内存中的相机列表落盘 (在退入后台、进程退出或显式增删相机时调用)
    public func flushPersistCameras() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        persistCameras()
    }

    public func saveCamera(_ camera: CameraDevice) {
        if let idx = savedCameras.firstIndex(where: { $0.deviceID == camera.deviceID }) {
            savedCameras[idx] = camera
        } else {
            savedCameras.append(camera)
        }
        flushPersistCameras()
        #if canImport(CoreBluetooth)
        bluetoothManager.savedCameras = savedCameras
        #endif
    }

    public func removeCamera(id: UUID) {
        savedCameras.removeAll(where: { $0.id == id })
        flushPersistCameras()
        #if canImport(CoreBluetooth)
        bluetoothManager.savedCameras = savedCameras
        #endif
    }

    private func persistCameras() {
        if let data = try? JSONEncoder().encode(savedCameras) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadSavedCameras() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let cams = try? JSONDecoder().decode([CameraDevice].self, from: data) {
            self.savedCameras = cams
        }

        // 从软件外部配置文件装载预置相机 (由 extract_pklg_credentials.py 从真机抓包生成)
        let preconfigured = CameraConfigLoader.shared.loadPreconfiguredCameras()
        var hasChanges = false
        for cam in preconfigured {
            if !savedCameras.contains(where: { $0.deviceID == cam.deviceID }) {
                savedCameras.append(cam)
                hasChanges = true
                appendLog(level: .info, message: "已从配置文件加载预置相机: [\(cam.name)] (ID=0x\(String(cam.deviceID, radix: 16).uppercased())) 📄")
            }
        }
        if hasChanges {
            persistCameras()
        }
    }

    public func appendLog(level: SyncLogLevel, message: String, cameraName: String? = nil) {
        let maskedMsg = CameraDevice.maskText(message)
        let maskedCam = cameraName != nil ? CameraDevice.maskName(cameraName) : nil
        AppLogger.log(level: level, message: maskedMsg, cameraName: maskedCam, category: "Sync")
        let item = SyncLogItem(level: level, message: maskedMsg, cameraName: maskedCam)
        logs.insert(item, at: 0)
        if logs.count > 150 {
            logs.removeLast()
        }
    }

    /// 获取指定已配对相机的当前或最近探测到的蓝牙信号强度 (dBm)
    public func rssi(for camera: CameraDevice) -> Int? {
        #if canImport(CoreBluetooth)
        let status = cameraConnectionStatusDesc(for: camera)
        // 铁律：若相机已断开 / 关机，信号强度必须为 nil，严禁显示历史残留虚假信号
        guard status.text != "已断开 ⚪️" && status.text != "未支持" else {
            return nil
        }

        // 1. 若处于 GATT 连通状态，获取已连接链路实时 RSSI
        for (uuid, session) in bluetoothManager.activeSessions where session.status == .ready || activeSessionStates[uuid] == .ready {
            let isMatch = camera.matches(
                discoveredDeviceID: session.stateMachine.savedDeviceID,
                peripheralUUID: uuid,
                peripheralName: session.peripheral.name
            )
            if isMatch {
                if let r = session.lastRSSI ?? connectedCameraRSSI[uuid] {
                    return r
                }
            }
        }

        // 2. 若处于待机休眠或唤醒广播中，获取新鲜广播包的 RSSI (必须具备时效性)
        if let adv = recentCameraAdvertisements[camera.deviceID], adv.isFresh() {
            return adv.rssi
        }
        if let bleId = camera.bleIdentifier, let uuid = UUID(uuidString: bleId),
           let adv = recentUUIDAdvertisements[uuid], adv.isFresh() {
            return adv.rssi
        }

        return nil
        #else
        return nil
        #endif
    }

    /// 获取指定已配对相机的蓝牙无线链路质量评级
    public func bleSignalQuality(for camera: CameraDevice) -> BLESignalQuality? {
        guard let val = rssi(for: camera) else { return nil }
        return BLESignalQuality.from(rssi: val)
    }

    // MARK: - 广播活跃保鲜时效管理

    /// 记录相机的低功耗广播状态快照 (供蓝牙扫描回调与单元测试直接调用)
    public func recordAdvertisement(cameraDeviceID: UInt32?, peripheralID: UUID, rssi: Int, statusByte: UInt8?, timestamp: Date = Date()) {
        // 关键性能优化：若已有状态且状态字节与信号强度波动极小 (<= 2dBm) 且时间间隔极短 (< 0.8s)，跳过重复 @Published 触发以保护 UI 帧率
        if let existing = recentUUIDAdvertisements[peripheralID],
           existing.statusByte == statusByte,
           abs(existing.rssi - rssi) <= 2,
           abs(timestamp.timeIntervalSince(existing.lastSeen)) < 0.8 {
            return
        }

        let advState = CameraAdvertisementState(
            rssi: rssi,
            statusByte: statusByte,
            lastSeen: timestamp
        )
        recentUUIDAdvertisements[peripheralID] = advState
        if let devID = cameraDeviceID {
            recentCameraAdvertisements[devID] = advState
            lastKnownCameraRSSI[devID] = rssi
        }
        connectedCameraRSSI[peripheralID] = rssi
    }

    private func startFreshnessTimer() {
        freshnessTimer?.invalidate()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeStaleAdvertisements()
            }
        }
    }

    /// 清理已超时的陈旧广播状态 (超过 8 秒未收到广播包视为相机关机或离开)
    public func purgeStaleAdvertisements(timeout: TimeInterval = 8.0) {
        let now = Date()
        var changed = false

        let staleDevIDs = recentCameraAdvertisements.filter { now.timeIntervalSince($0.value.lastSeen) >= timeout }.keys
        for devID in staleDevIDs {
            recentCameraAdvertisements.removeValue(forKey: devID)
            lastKnownCameraRSSI.removeValue(forKey: devID)
            changed = true
        }

        let staleUUIDs = recentUUIDAdvertisements.filter { now.timeIntervalSince($0.value.lastSeen) >= timeout }.keys
        for uuid in staleUUIDs {
            recentUUIDAdvertisements.removeValue(forKey: uuid)
            connectedCameraRSSI.removeValue(forKey: uuid)
            changed = true
        }

        // 同样清理 discoveredCameras 中超过 15 秒未更新的陈旧外设
        let originalCount = discoveredCameras.count
        discoveredCameras.removeAll { item in
            if let adv = recentUUIDAdvertisements[item.id] {
                return !adv.isFresh(timeoutSeconds: 15.0)
            }
            return false
        }
        if discoveredCameras.count != originalCount {
            changed = true
        }

        if changed {
            objectWillChange.send()
        }
    }
}
