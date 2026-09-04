import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

/// 单个相机的连接与特征会话
public final class CameraPeripheralSession: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    public let peripheral: CBPeripheral
    public let stateMachine: CameraStateMachine
    public var isReconnectingMode: Bool {
        return stateMachine.savedDeviceID != nil
    }
    public var pairCharacteristic: CBCharacteristic?
    public var not1Characteristic: CBCharacteristic?
    public var idCharacteristic: CBCharacteristic?
    public var timeCharacteristic: CBCharacteristic?
    public var geoCharacteristic: CBCharacteristic?

    public var status: CameraConnectionStatus = .disconnected
    public var lastSyncTime: Date?
    public var lastTimeSyncDate: Date?
    public var syncCount: Int = 0
    public private(set) var lastRSSI: Int?

    /// 记录当前相机在本次 App 进程或物理开机会话中是否已完成首轮时钟与时区校准
    public internal(set) var hasCompletedBootSync: Bool = false

    public var onStatusChanged: ((CameraPeripheralSession, CameraConnectionStatus) -> Void)?
    public var onHandshakeCompleted: ((CameraPeripheralSession, UInt32, UInt32) -> Void)?
    public var onSessionReady: ((CameraPeripheralSession) -> Void)?
    public var onRSSIUpdated: ((CameraPeripheralSession, Int) -> Void)?
    public var onLog: ((SyncLogLevel, String) -> Void)?

    public init(
        peripheral: CBPeripheral,
        savedDeviceID: UInt32? = nil,
        savedNonce: UInt32? = nil,
        discoveredDeviceID: UInt32? = nil,
        controllerName: String = "iPhone_NikonGPS"
    ) {
        self.peripheral = peripheral
        let effectiveDeviceID = savedDeviceID ?? discoveredDeviceID
        self.stateMachine = CameraStateMachine(
            savedDeviceID: effectiveDeviceID,
            savedNonce: savedNonce,
            controllerName: controllerName
        )
        super.init()
        self.peripheral.delegate = self
    }

    /// 热更新或注入配对凭据，使会话瞬间具备重连免配对能力
    public func updateCredentials(savedDeviceID: UInt32?, savedNonce: UInt32?) {
        stateMachine.updateCredentials(savedDeviceID: savedDeviceID, savedNonce: savedNonce)
    }

    /// 标记会话进入连接中状态
    public func markConnecting() {
        if status != .connecting {
            status = .connecting
            onStatusChanged?(self, status)
        }
    }

    /// 重置物理开机会话标志位 (在进程终止、相机长时间断开或显式重新初始化时调用)
    public func resetBootSession() {
        hasCompletedBootSync = false
    }

    /// 开始服务发现与监听激活流水线
    public func startDiscovery() {
        status = .connecting
        onStatusChanged?(self, status)
        stateMachine.reset()

        // 物理链路重建，必须重置句柄并重新发现，确保 CCCD 订阅通知不被 iOS 视为 no-op 吞掉
        self.pairCharacteristic = nil
        self.not1Characteristic = nil
        self.idCharacteristic = nil
        self.timeCharacteristic = nil
        self.geoCharacteristic = nil

        peripheral.discoverServices([NikonUUIDs.service])
    }

    /// 发射 Stage 1 认证挑战包
    public func sendStage1() {
        guard let pairChar = self.pairCharacteristic else { return }
        status = .handshaking
        onStatusChanged?(self, status)
        let stage1Data = stateMachine.startHandshake()
        let hexDump = stage1Data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let modeDesc = isReconnectingMode ? "凭据重连" : "全新配对"
        onLog?(.info, "[\(peripheral.name ?? "相机")] PAIR 通道已就绪，发起 Stage 1 认证挑战 (\(modeDesc), ID=0x\(String(stateMachine.activeDeviceID, radix: 16).uppercased()), Nonce=0x\(String(stateMachine.activeNonce, radix: 16).uppercased())): \(hexDump)")
        let writeType: CBCharacteristicWriteType = pairChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(stage1Data, for: pairChar, type: writeType)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            status = .error
            onStatusChanged?(self, status)
            onLog?(.error, "[\(peripheral.name ?? "相机")] 服务发现失败: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services,
              let nikonService = services.first(where: { $0.uuid == NikonUUIDs.service }) else {
            status = .error
            onStatusChanged?(self, status)
            onLog?(.warning, "[\(peripheral.name ?? "相机")] 未找到尼康智能服务")
            return
        }

        onLog?(.info, "[\(peripheral.name ?? "相机")] 发现服务，正在检索特征...")
        peripheral.discoverCharacteristics([
            NikonUUIDs.pair,
            NikonUUIDs.not1,
            NikonUUIDs.deviceName,
            NikonUUIDs.time,
            NikonUUIDs.geo
        ], for: nikonService)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            status = .error
            onStatusChanged?(self, status)
            onLog?(.error, "[\(peripheral.name ?? "相机")] 特征发现失败: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            switch char.uuid {
            case NikonUUIDs.pair:
                self.pairCharacteristic = char
                // 开启 PAIR 读通知以接收 Stage 2 与 Stage 4
                peripheral.setNotifyValue(true, for: char)
            case NikonUUIDs.not1:
                self.not1Characteristic = char
                if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: char)
                }
            case NikonUUIDs.deviceName:
                self.idCharacteristic = char
            case NikonUUIDs.time:
                self.timeCharacteristic = char
            case NikonUUIDs.geo:
                self.geoCharacteristic = char
            default:
                break
            }
        }

        guard self.pairCharacteristic != nil else {
            onLog?(.error, "[\(peripheral.name ?? "相机")] 缺失 PAIR 握手特征")
            return
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            onLog?(.error, "[\(peripheral.name ?? "相机")] 开启 \(characteristic.uuid.uuidString) 通知失败: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == NikonUUIDs.pair, characteristic.isNotifying else { return }
        if status == .connecting || status == .disconnected {
            sendStage1()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            onLog?(.error, "[\(peripheral.name ?? "相机")] 读取特征失败: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == NikonUUIDs.not1, let data = characteristic.value {
            if data.count >= 2 && data[0] == 0x01 && data[1] == 0x00 {
                onLog?(.info, "[\(peripheral.name ?? "相机")] 收到相机 NOT1 确认指令 (01 00)")
            }
            return
        }

        guard characteristic.uuid == NikonUUIDs.pair, let data = characteristic.value else { return }

        let hexDump = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let stageNum = data.first.map { String(format: "0x%02X", $0) } ?? "??"
        onLog?(.info, "[\(peripheral.name ?? "相机")] 收到 PAIR 报文 (Stage \(stageNum), \(data.count)B): \(hexDump)")

        let action = stateMachine.handlePairDataReceived(data)
        switch action {
        case .sendStage3(let stage3Data):
            if !isReconnectingMode {
                onLog?(.info, "[\(peripheral.name ?? "相机")] 收到 Stage 2 挑战，Salt 验证成功！发送 Stage 3 回应...")
            }
            peripheral.writeValue(stage3Data, for: characteristic, type: .withResponse)

        case .sendDeviceName(let nameData):
            // 写入设备名称 (优先采用无需应答模式写入)
            if let idChar = self.idCharacteristic {
                let writeType: CBCharacteristicWriteType = idChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(nameData, for: idChar, type: writeType)
            }

            let dev = stateMachine.activeDeviceID
            let nonce = stateMachine.activeNonce

            stateMachine.markReady()
            status = .ready
            onStatusChanged?(self, status)

            if isReconnectingMode {
                // 免配对凭据重连模式
                if !hasCompletedBootSync {
                    // 本次 App 进程或物理开机会话的首轮连通：强制校准时钟与时区
                    ensureTimeSynchronized(force: true)
                    hasCompletedBootSync = true
                    onLog?(.success, "[\(peripheral.name ?? "相机")] ⏱️ 首轮连接时钟与时区已校准完成，GPS 会话已就绪！")
                } else {
                    // 待机休眠后的快门唤醒或保鲜心跳：严格跳过时间写入，仅极速秒级恢复会话
                    onLog?(.success, "[\(peripheral.name ?? "相机")] ⚡️ 快门待机唤醒连通 (已跳过重复校时)，GPS 会话已就绪！")
                }
                onSessionReady?(self)
            } else {
                // 初次配对模式：派发配对持久化并校准时钟
                onHandshakeCompleted?(self, dev, nonce)
                onLog?(.success, "[\(peripheral.name ?? "相机")] 🎉 纯 BLE 首次配对成功！(ID=0x\(String(dev, radix: 16).uppercased())) 🟢")
                ensureTimeSynchronized(force: true)
                hasCompletedBootSync = true
                onSessionReady?(self)
            }

        case .ready:
            status = .ready
            onStatusChanged?(self, status)
            onSessionReady?(self)
            onLog?(.success, "[\(peripheral.name ?? "相机")] 认证全链路就绪，已连接！")

        case .error(let reason):
            status = .error
            onStatusChanged?(self, status)
            onLog?(.error, "[\(peripheral.name ?? "相机")] 握手阶段失败: \(reason)")
        }
    }

    /// 保证时钟同步 (仅在首轮开机会话未同步、或显式强制 force == true 时执行；坚决杜绝基于固定时间的无脑轮询校时)
    public func ensureTimeSynchronized(payload: TimePayload = TimePayload(), force: Bool = false) {
        if force || !hasCompletedBootSync {
            writeTime(payload)
            hasCompletedBootSync = true
        }
    }

    /// 向相机注入时间与时区 (自适应优先无需应答模式，避免阻塞蓝牙信道)
    public func writeTime(_ payload: TimePayload) {
        guard status == .ready, let char = timeCharacteristic else { return }
        let data = payload.encode()
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
        lastTimeSyncDate = Date()
        if writeType == .withoutResponse {
            onLog?(.info, "[\(peripheral.name ?? "相机")] 相机时钟与时区已完成同步 ⏱️")
        }
    }

    /// 向相机注入地理位置 (WGS-84，优先无需应答模式极速下发，彻底杜绝 ATT 缓冲区冲突)
    public func writeGeo(_ payload: GeoPayload) {
        guard status == .ready, let char = geoCharacteristic else { return }
        let data = payload.encode()
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
        lastSyncTime = Date()
        syncCount += 1
        if writeType == .withoutResponse {
            if syncCount == 1 || syncCount % 10 == 0 {
                onLog?(.success, "[\(peripheral.name ?? "相机")] GPS 坐标持续注入中 (累计 \(syncCount) 次) 📍")
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            onLog?(.warning, "[\(peripheral.name ?? "相机")] 特征写入异常 (\(characteristic.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == NikonUUIDs.deviceName {
            onLog?(.success, "[\(peripheral.name ?? "相机")] 智能设备名称已成功注册至相机！")
        } else if characteristic.uuid == NikonUUIDs.time {
            onLog?(.info, "[\(peripheral.name ?? "相机")] 相机时钟与时区已完成同步 ⏱️")
        } else if characteristic.uuid == NikonUUIDs.geo {
            if syncCount == 1 || syncCount % 10 == 0 {
                onLog?(.success, "[\(peripheral.name ?? "相机")] GPS 坐标已成功写入相机 EXIF 📍 (累计 \(syncCount) 次)")
            }
            if syncCount % 3 == 0 {
                // 常态巡航中，每 3 次注入主动采样一次蓝牙链路信号强度
                readRSSI()
            }
        }
    }

    /// 主动发起外设无线链路信号质量 (RSSI) 读取
    public func readRSSI() {
        guard peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let val = RSSI.intValue
        self.lastRSSI = val
        self.onRSSIUpdated?(self, val)
    }
}

/// 尼康 CoreBluetooth 调度器 (支持后台恢复与多相机并发管理)
public final class NikonBluetoothManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public static let restoreIdentifier = "com.vincentchyu.photools.mobile.ble"

    private var centralManager: CBCentralManager!
    private let dispatchQueue = DispatchQueue(label: "com.vincentchyu.photools.mobile.bleQueue", qos: .userInitiated)
    private let stateLock = NSRecursiveLock()

    private var _lastDisconnectTimes: [UUID: Date] = [:]
    /// 记录各相机最近一次发起连接请求的时间戳，用于高频广播防抖 (3秒)，防止握手期间重复发起与刷屏
    private var _lastConnectAttemptTimes: [UUID: Date] = [:]
    /// 记录各相机连续握手未完成即断开的次数，用于断开熔断保护
    private var _consecutiveHandshakeFailures: [UUID: Int] = [:]
    private struct PendingConnectionRequest {
        let peripheral: CBPeripheral
        let savedCamera: CameraDevice?
        let discoveredDeviceID: UInt32?
    }
    private var _pendingConnections: [UUID: PendingConnectionRequest] = [:]
    private var _activeSessions: [UUID: CameraPeripheralSession] = [:]
    private var _savedCameras: [CameraDevice] = []
    private var _isCruiseModeActive: Bool = false

    public var isCruiseModeActive: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCruiseModeActive
        }
        set {
            stateLock.lock()
            _isCruiseModeActive = newValue
            stateLock.unlock()
        }
    }

    /// 对外提供活跃会话的安全快照 (写时复制 Copy-on-Write，遍历绝对安全)
    public var activeSessions: [UUID: CameraPeripheralSession] {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _activeSessions
        }
    }

    /// 对外提供已配对相机的安全快照
    public var savedCameras: [CameraDevice] {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _savedCameras
        }
        set {
            stateLock.lock()
            _savedCameras = newValue
            stateLock.unlock()
            syncCredentialsToActiveSessions()
        }
    }

    // MARK: - 内部并发安全辅助方法

    private func getSession(for uuid: UUID) -> CameraPeripheralSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeSessions[uuid]
    }

    private func setSession(_ session: CameraPeripheralSession, for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _activeSessions[uuid] = session
    }

    @discardableResult
    private func removeSession(for uuid: UUID) -> CameraPeripheralSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeSessions.removeValue(forKey: uuid)
    }

    private func getLastDisconnectTime(for uuid: UUID) -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastDisconnectTimes[uuid]
    }

    private func setLastDisconnectTime(_ date: Date, for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _lastDisconnectTimes[uuid] = date
    }

    private func getLastConnectAttemptTime(for uuid: UUID) -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastConnectAttemptTimes[uuid]
    }

    private func setLastConnectAttemptTime(_ date: Date, for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _lastConnectAttemptTimes[uuid] = date
    }

    private func removeLastConnectAttemptTime(for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _lastConnectAttemptTimes.removeValue(forKey: uuid)
    }

    private func getConsecutiveFailures(for uuid: UUID) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _consecutiveHandshakeFailures[uuid] ?? 0
    }

    private func incrementConsecutiveFailures(for uuid: UUID) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let count = (_consecutiveHandshakeFailures[uuid] ?? 0) + 1
        _consecutiveHandshakeFailures[uuid] = count
        return count
    }

    private func resetConsecutiveFailures(for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _consecutiveHandshakeFailures[uuid] = 0
    }

    private func setPendingConnection(_ req: PendingConnectionRequest, for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _pendingConnections[uuid] = req
    }

    private func removePendingConnection(for uuid: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _pendingConnections.removeValue(forKey: uuid)
    }

    private func drainPendingConnections() -> [PendingConnectionRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let queued = Array(_pendingConnections.values)
        _pendingConnections.removeAll()
        return queued
    }

    /// 安全判断相机名称是否匹配 (统一调用 CameraDevice 规范化型号比对)
    public static func isCameraNameMatched(savedName: String?, peripheralName: String?) -> Bool {
        let cSaved = CameraDevice.canonicalName(savedName)
        let cPeriph = CameraDevice.canonicalName(peripheralName)
        guard !cSaved.isEmpty && !cPeriph.isEmpty else { return false }
        return cSaved == cPeriph
    }

    /// 自动将最新加载或配对的凭据热注入至活跃会话，防止极端时序竞态
    private func syncCredentialsToActiveSessions() {
        stateLock.lock()
        let sessions = _activeSessions
        let cameras = _savedCameras
        stateLock.unlock()

        guard !sessions.isEmpty && !cameras.isEmpty else { return }
        for (uuid, session) in sessions {
            if let matched = cameras.first(where: {
                $0.matches(
                    discoveredDeviceID: session.stateMachine.savedDeviceID,
                    peripheralUUID: uuid,
                    peripheralName: session.peripheral.name
                )
            }) {
                session.updateCredentials(savedDeviceID: matched.deviceID, savedNonce: matched.nonce)
            }
        }
    }

    public var onLog: ((SyncLogLevel, String) -> Void)?
    public var onCameraDiscovered: ((CBPeripheral, Int, Data?, UInt32?) -> Void)?
    public var onSessionStateChanged: ((UUID, CameraConnectionStatus) -> Void)?
    public var onCameraPairingSaved: ((CameraDevice) -> Void)?
    public var onCameraHandleUpdated: ((CameraDevice) -> Void)?
    public var onSessionReady: ((UUID) -> Void)?
    public var onCameraRSSIUpdated: ((UUID, Int) -> Void)?
    public let freshnessArbiter = StandbyFreshnessArbiter()

    public override init() {
        super.init()

        var options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true
        ]

        // 防御性校验：仅当 App 显式配置了 bluetooth-central 后台模式时才启用系统状态恢复，防止崩溃
        let bgModes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []
        if bgModes.contains("bluetooth-central") {
            options[CBCentralManagerOptionRestoreIdentifierKey] = Self.restoreIdentifier
        }

        self.centralManager = CBCentralManager(
            delegate: self,
            queue: dispatchQueue,
            options: options
        )
    }

    /// 开始扫描附近的尼康相机广播与已连接外设
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            onLog?(.warning, "蓝牙未开启，无法启动扫描")
            return
        }
        onLog?(.info, "正在扫描附近的尼康相机广播...")

        // 1. 优先检索当前已被 iOS 系统建立连接的尼康相机，并主动无缝接管 GATT 会话
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [NikonUUIDs.service])
        for p in connected {
            let name = p.name ?? "Nikon Camera"
            let matchedSaved = savedCameras.first(where: {
                $0.matches(peripheralUUID: p.identifier, peripheralName: p.name)
            })
            // 核心防重：若该相机在当前会话中已经处于同步就绪态 (.ready) 或正在握手连接中，直接跳过，坚决不重复打断握手！
            if let existing = getSession(for: p.identifier),
               (existing.status == .ready || existing.status == .handshaking || existing.status == .connecting) {
                continue
            }
            onLog?(.success, "检测到系统已预连相机: \(name) 📷，正在无缝激活同步链路...")
            onCameraDiscovered?(p, -40, nil, matchedSaved?.deviceID)
            // 关键：仅对已保存配对的相机显式发起 connect 激活 App 级 GATT 会话与握手
            if let saved = matchedSaved {
                connect(to: p, savedCamera: saved)
            }
        }

        // 2. 硬件级精准扫描 (基于尼康 SnapBridge 专有服务 0000de00-...)
        centralManager.scanForPeripherals(
            withServices: [NikonUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// 停止扫描
    public func stopScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        onLog?(.info, "已停止扫描")
    }

    /// 获取或创建相机会话单例并配置回调
    @discardableResult
    private func getOrCreateSession(
        for peripheral: CBPeripheral,
        savedCamera: CameraDevice? = nil,
        discoveredDeviceID: UInt32? = nil
    ) -> CameraPeripheralSession {
        let matchedSaved = savedCamera ?? savedCameras.first(where: {
            $0.matches(discoveredDeviceID: discoveredDeviceID, peripheralUUID: peripheral.identifier, peripheralName: peripheral.name)
        })
        var resolvedNonce = matchedSaved?.nonce
        let effectiveDevID = matchedSaved?.deviceID ?? discoveredDeviceID

        // 智能自愈：若匹配到了有效 DeviceID 但缺少 Nonce（例如首次嗅探到广播或仅有 DeviceID），使用 SnapBridgeIdSolver 动态逆向求解真实 Nonce
        if (resolvedNonce == nil || resolvedNonce == 0), let devID = effectiveDevID, devID != 0 {
            let candidates = SnapBridgeIdSolver.candidatesFor(targetDevice: devID)
            if let best = candidates.first {
                resolvedNonce = best.nonce
                onLog?(.info, "[\(peripheral.name ?? "相机")] 🎯 SnapBridgeIdSolver 成功反解相机凭据: DeviceID=0x\(String(devID, radix: 16).uppercased()), Nonce=0x\(String(best.nonce, radix: 16).uppercased())")
            }
        }

        let session: CameraPeripheralSession
        stateLock.lock()
        if let existing = _activeSessions[peripheral.identifier] {
            session = existing
            stateLock.unlock()
            session.updateCredentials(savedDeviceID: effectiveDevID, savedNonce: resolvedNonce)
        } else {
            session = CameraPeripheralSession(
                peripheral: peripheral,
                savedDeviceID: effectiveDevID,
                savedNonce: resolvedNonce,
                discoveredDeviceID: discoveredDeviceID
            )

            session.onLog = { [weak self] level, msg in
                self?.onLog?(level, msg)
            }

            session.onStatusChanged = { [weak self] sess, status in
                self?.onSessionStateChanged?(sess.peripheral.identifier, status)
            }

            session.onHandshakeCompleted = { [weak self] sess, devID, nonce in
                guard let self = self else { return }
                let name = sess.peripheral.name ?? "Nikon Camera"
                let cam = CameraDevice(
                    name: name,
                    bleIdentifier: sess.peripheral.identifier.uuidString,
                    deviceID: devID,
                    nonce: nonce,
                    lastConnectedAt: Date()
                )
                self.onCameraPairingSaved?(cam)
            }

            session.onSessionReady = { [weak self] sess in
                self?.resetConsecutiveFailures(for: sess.peripheral.identifier)
                sess.readRSSI()
                self?.onSessionReady?(sess.peripheral.identifier)
            }

            session.onRSSIUpdated = { [weak self] sess, rssi in
                self?.onCameraRSSIUpdated?(sess.peripheral.identifier, rssi)
            }

            _activeSessions[peripheral.identifier] = session
            stateLock.unlock()
        }
        return session
    }

    /// 连接指定相机 (支持已保存凭据或广播中嗅探到的 DeviceID 免配对直连，优先复用 Session 与 GATT 缓存)
    public func connect(to peripheral: CBPeripheral, savedCamera: CameraDevice? = nil, discoveredDeviceID: UInt32? = nil) {
        // 核心守卫：若当前会话已处于同步就绪态，坚决不重复连入以防打断已有连接
        if let existing = getSession(for: peripheral.identifier), existing.status == .ready {
            return
        }

        setLastConnectAttemptTime(Date(), for: peripheral.identifier)

        let matchedSaved = savedCamera ?? savedCameras.first(where: {
            $0.matches(
                discoveredDeviceID: discoveredDeviceID,
                peripheralUUID: peripheral.identifier,
                peripheralName: peripheral.name
            )
        })

        let session = getOrCreateSession(
            for: peripheral,
            savedCamera: matchedSaved,
            discoveredDeviceID: discoveredDeviceID
        )
        session.markConnecting()

        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.centralManager.state == .poweredOn else {
                self.setPendingConnection(
                    PendingConnectionRequest(
                        peripheral: peripheral,
                        savedCamera: matchedSaved,
                        discoveredDeviceID: discoveredDeviceID
                    ),
                    for: peripheral.identifier
                )
                self.onLog?(.warning, "[\(peripheral.name ?? "相机")] 蓝牙未就绪，连接指令已排队，待蓝牙开启后自动连接 ⏳")
                return
            }

            self.removePendingConnection(for: peripheral.identifier)
            self.centralManager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }

    /// 断开指定相机 (仅在用户主动取消同步或退出巡航时调用)
    public func disconnect(peripheralID: UUID) {
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.removePendingConnection(for: peripheralID)
            guard let session = self.getSession(for: peripheralID) else { return }
            if self.centralManager.state == .poweredOn && session.peripheral.state != .disconnected {
                self.centralManager.cancelPeripheralConnection(session.peripheral)
            } else {
                self.removeSession(for: peripheralID)
            }
        }
    }

    /// 向所有已就绪的相机并发写入 GPS 坐标 (仅在必要时才补偿时钟，杜绝微秒级并发冲突)
    public func broadcastLocation(geo: GeoPayload) {
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            let readySessions: [CameraPeripheralSession]
            self.stateLock.lock()
            readySessions = self._activeSessions.values.filter { $0.status == .ready }
            self.stateLock.unlock()

            for session in readySessions {
                session.writeGeo(geo)
            }
        }
    }

    /// 向所有已就绪的相机并发写入时间与 GPS 坐标 (向后兼容)
    public func broadcastLocation(time: TimePayload, geo: GeoPayload) {
        broadcastLocation(geo: geo)
    }

    /// 响应 iOS 系统时区发生变动 (NSSystemTimeZoneDidChange)：
    /// 仅在系统时区真实变更时，向所有当前已就绪的相机即时补偿写入新时区，并标记待机相机下一次快门唤醒时重新校准
    public func handleSystemTimeZoneChanged() {
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.onLog?(.info, "检测到 iOS 系统时区发生变更 (当前时区: \(TimeZone.current.identifier))，正在向相机下发时区补偿 🌐⏱️")
            let payload = TimePayload()
            let sessions: [CameraPeripheralSession]
            self.stateLock.lock()
            sessions = Array(self._activeSessions.values)
            self.stateLock.unlock()

            for session in sessions {
                if session.status == .ready {
                    session.writeTime(payload)
                } else {
                    // 当前处于待机或断开状态的相机，重置开机会话标志位，确保下次快门唤醒连通的第一时间对齐新时区
                    session.resetBootSession()
                }
            }
        }
    }

    /// 重置所有已激活相机的开机会话标志位 (用于进程退出清理或重置全新会话)
    public func resetAllBootSessions() {
        stateLock.lock()
        let sessions = Array(_activeSessions.values)
        stateLock.unlock()
        for session in sessions {
            session.resetBootSession()
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onLog?(.info, "蓝牙引擎已就绪")
            // 1. 处理恢复的外设中已连通项的服务发现
            stateLock.lock()
            let connectedSessions = _activeSessions.values.filter { $0.peripheral.state == .connected }
            stateLock.unlock()
            for session in connectedSessions {
                session.startDiscovery()
            }
            // 2. 消费所有排队的连接请求
            let queued = drainPendingConnections()
            for req in queued {
                connect(
                    to: req.peripheral,
                    savedCamera: req.savedCamera,
                    discoveredDeviceID: req.discoveredDeviceID
                )
            }
            // 3. 自动恢复扫描
            if isCruiseModeActive || savedCameras.isEmpty {
                startScanning()
            }
        case .poweredOff:
            onLog?(.warning, "蓝牙已关闭")
        case .unauthorized:
            onLog?(.error, "无蓝牙访问权限")
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        onLog?(.info, "系统后台恢复状态中...")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in peripherals {
                let pName = p.name ?? ""
                onLog?(.info, "已恢复相机外设句柄: \(pName.isEmpty ? p.identifier.uuidString : pName) 📷")
                let matchedSaved = savedCameras.first(where: {
                    $0.bleIdentifier == p.identifier.uuidString || (!pName.isEmpty && $0.name == pName)
                })

                // 核心修复：仅重建会话并绑定代理，绝对不在 willRestoreState 阶段调用 centralManager.connect
                let session = getOrCreateSession(for: p, savedCamera: matchedSaved)
                p.delegate = session

                if p.state != .connected {
                    // 若处于未连接状态，记录到待连接队列，待 poweredOn 时安全发起连接
                    setPendingConnection(
                        PendingConnectionRequest(
                            peripheral: p,
                            savedCamera: matchedSaved,
                            discoveredDeviceID: nil
                        ),
                        for: p.identifier
                    )
                }
            }
        }
        if let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            onLog?(.info, "已恢复系统后台扫描服务 (\(services.count) 项)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []

        var isNikon = serviceUUIDs.contains(NikonUUIDs.service)
        var discoveredDevID: UInt32? = nil
        var cameraStatusByte: UInt8? = nil

        if let mfg = mfgData, mfg.count >= 2 {
            let prefix = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
            if prefix == NikonUUIDs.nikonCompanyID {
                isNikon = true
                if mfg.count >= 6 {
                    discoveredDevID = mfg.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) }
                }
                if mfg.count >= 7 {
                    cameraStatusByte = mfg[6]
                }
            }
        }

        let upperName = name.uppercased()
        if upperName.hasPrefix("Z") || upperName.contains("NIKON") || upperName.hasPrefix("COOLPIX") || upperName.hasPrefix("D") {
            isNikon = true
        }

        guard isNikon else { return }

        onCameraDiscovered?(peripheral, RSSI.intValue, mfgData, discoveredDevID)

        // 1. 多维精准匹配已保存相机列表（硬件 DeviceID > 本地 UUID > 规范化名称绝对相等）
        let matchedCamera = savedCameras.first { cam in
            cam.matches(
                discoveredDeviceID: discoveredDevID,
                peripheralUUID: peripheral.identifier,
                peripheralName: name
            )
        }

        guard let matchedSaved = matchedCamera else { return }

        // 若首次抓取到外设 UUID 句柄或发生变动，动态反哺更新持久化，加速后续秒连 (在锁保护下修改)
        if matchedSaved.bleIdentifier == nil || matchedSaved.bleIdentifier != peripheral.identifier.uuidString {
            var updatedCam: CameraDevice?
            stateLock.lock()
            if let idx = _savedCameras.firstIndex(where: { $0.deviceID == matchedSaved.deviceID }) {
                _savedCameras[idx].bleIdentifier = peripheral.identifier.uuidString
                updatedCam = _savedCameras[idx]
            }
            stateLock.unlock()
            if let cam = updatedCam {
                onCameraHandleUpdated?(cam)
            }
        }

        // 关键防重检查：
        // 1. 若系统底层外设已处于连接中 (.connecting) 或已连通 (.connected)，严禁重复发起连接
        if peripheral.state == .connecting || peripheral.state == .connected {
            return
        }

        let session = getSession(for: peripheral.identifier)
        // 2. 若当前会话已在连接中、握手中或已就绪，严禁重复发起连接
        if let s = session, (s.status == .connecting || s.status == .handshaking || s.status == .ready) {
            return
        }
        let isDisconnected = (session == nil || session?.status == .disconnected || session?.status == .error)
        guard isDisconnected else { return }

        // 3. 检查刚断开时的防抖冷静期 (5秒)，防止断开瞬态的残余广播引起震荡
        if let lastDis = getLastDisconnectTime(for: peripheral.identifier) {
            let elapsed = Date().timeIntervalSince(lastDis)
            if elapsed < freshnessArbiter.config.cooldownSeconds {
                // 处于防抖冷静期内，静默跳过残余包
                return
            }
        }

        // 4. 发起连接的短时防抖 (3秒)，防止在链路握手完成前连续收到高频广播重复触发 connect 与打印日志
        if let lastAttempt = getLastConnectAttemptTime(for: peripheral.identifier) {
            let elapsed = Date().timeIntervalSince(lastAttempt)
            if elapsed < 3.0 {
                return
            }
        }

        // 3. 基于尼康相机硬件广播状态字节 (Status Byte) 精准识别休眠 vs 唤醒
        // - 0x1D (Bit 0 == 1): 相机处于待机深睡心跳广播，用户未碰相机
        // - 0x1C (Bit 0 == 0): 相机处于开机/快门唤醒就绪广播，准备接受连接
        let isStandbySleeping = (cameraStatusByte.map { ($0 & 0x01) != 0 } ?? false)
        let isAwakeReady = (cameraStatusByte.map { ($0 & 0x01) == 0 } ?? false)

        if isStandbySleeping {
            // 💤 相机待机深睡中 (广播码 0x1D)：
            // 核心铁律：
            // 1. 未开启巡航模式时 (isCruiseModeActive == false)：摄影师处于非巡航普通待机，100% 保持静默监听，
            //    坚决不主动发起连接打扰相机深睡，彻底消除未巡航时的 7.4 秒超时警告 (原因码 6)；
            // 2. 仅在开启巡航模式时 (isCruiseModeActive == true)：为保证随时抓拍不偏离机位，由四维待机保鲜仲裁引擎评估
            //    (位移 >= 30m、新机位停步瞬态或 10~20m 周期保鲜)。
            guard isCruiseModeActive else { return }

            let decision = freshnessArbiter.shouldAllowStandbyReconnect(cameraID: peripheral.identifier)
            switch decision {
            case .allow(let reason):
                onLog?(.info, "[\(matchedSaved.name)] 触发保鲜连接: \(reason)")
                connect(to: peripheral, savedCamera: matchedSaved)
            case .suppress:
                // 处于原地静止或冷静期内，保持静默待命，绝不骚扰休眠中的相机
                break
            }
        } else if isAwakeReady {
            // ⚡️ 相机开机/快门唤醒就绪中 (广播码 0x1C)！
            let hexStr = String(format: "0x%02X", cameraStatusByte ?? 0x1C)
            if isCruiseModeActive {
                onLog?(.success, "[\(matchedSaved.name)] 📷 捕获到快门唤醒广播 (\(hexStr) 就绪)，正在极速秒连...")
                connect(to: peripheral, savedCamera: matchedSaved)
            } else {
                onLog?(.info, "[\(matchedSaved.name)] 捕获到相机唤醒广播 (\(hexStr))，正在恢复连接...")
                connect(to: peripheral, savedCamera: matchedSaved)
            }
        } else {
            // 针对未携带 Manufacturer Data 的广播包 (例如短广播或扫描响应)：
            // 仅在开启巡航且明确触发保鲜仲裁时才连接，杜绝误唤醒
            guard isCruiseModeActive else { return }
            let decision = freshnessArbiter.shouldAllowStandbyReconnect(cameraID: peripheral.identifier)
            if case .allow(let reason) = decision {
                onLog?(.info, "[\(matchedSaved.name)] 触发保鲜连接: \(reason)")
                connect(to: peripheral, savedCamera: matchedSaved)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = getSession(for: peripheral.identifier) else { return }
        // 核心守卫：若会话已处于 .ready 同步就绪态，说明物理链路保持连通，切勿重复重新发起服务发现和重置握手
        if session.status == .ready {
            return
        }

        if session.isReconnectingMode {
            onLog?(.info, "[\(peripheral.name ?? "相机")] 物理链路瞬间连通，正在激活会话通道 ⚡️")
        } else {
            onLog?(.info, "[\(peripheral.name ?? "相机")] 蓝牙物理链路已建立，开始服务握手...")
        }

        // 关键时序优化（Gentle Delay）：在专有 BLE 队列延迟 350ms 发起服务发现
        // 尼康相机固件在连接建立后约 70~120ms 会主动向 iOS 发起 ATT Exchange MTU Request (515)
        // 若 iOS 过于激进（< 200ms）调用 discoverServices，iOS 底层会抢先发出 MTU 185 Request，
        // 导致相机固件状态机死锁（不应答导致 7.5 秒 Connection Timeout，抓包证实此现象）。
        // 在专属 BLE 队列稳健延迟 350ms 礼让相机充分完成 MTU 协商与状态平复后再开始服务检索，彻底杜绝超时断开。
        let pID = peripheral.identifier
        self.dispatchQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self,
                  let active = self.getSession(for: pID),
                  active.peripheral.state == .connected else { return }
            active.startDiscovery()
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        removeLastConnectAttemptTime(for: peripheral.identifier)
        onLog?(.error, "[\(peripheral.name ?? "相机")] 连接建立失败: \(error?.localizedDescription ?? "未知")")
        _ = incrementConsecutiveFailures(for: peripheral.identifier)
        removeSession(for: peripheral.identifier)
        onSessionStateChanged?(peripheral.identifier, .error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let now = Date()
        let pID = peripheral.identifier
        removeLastConnectAttemptTime(for: pID)
        let session = getSession(for: pID)
        let wasReady = (session?.status == .ready)

        // 统一记录断开时间，标准 5 秒防抖冷静期过滤断开瞬态残包
        setLastDisconnectTime(now, for: pID)
        freshnessArbiter.recordDisconnection(cameraID: pID, at: now)

        if let session = session {
            session.status = .disconnected
            session.stateMachine.reset()
            onSessionStateChanged?(pID, .disconnected)
        }

        // 熔断与异常检测：判断是正常进入就绪后的待机断开，还是握手未完成被相机踢出
        if wasReady {
            resetConsecutiveFailures(for: pID)
        } else {
            let failures = incrementConsecutiveFailures(for: pID)
            if failures >= 3 {
                onLog?(.warning, "[\(peripheral.name ?? "相机")] ⚠️ 连续 \(failures) 次握手未完成即断开，触发 15 秒安全熔断冷却保护 ⏳")
                // 惩罚性延长冷却期，防止残余广播狂刷死循环
                setLastDisconnectTime(now.addingTimeInterval(10.0), for: pID)
                // 若该会话没有有效已配对凭据，坚决清理残余会话，避免脏数据永久滞留
                if session?.isReconnectingMode != true {
                    removeSession(for: pID)
                }
            }
        }

        // 顺应相机原生休眠：若无错误或为对端主动断开 (CBError 7: peripheralDisconnected / 0x13 Remote User Terminated)，
        // 判定为相机待机超时自然进入深睡待命，优雅呈现日志
        let nsErr = error as? NSError
        let isCameraNaturalSleep = error == nil || nsErr?.code == 7
        if isCameraNaturalSleep {
            onLog?(.info, "[\(peripheral.name ?? "相机")] 相机完成同步并自然转入休眠 💤 (多维保鲜仲裁守护中)")
        } else {
            let errDesc = nsErr.map { " (原因码 \($0.code): \($0.localizedDescription))" } ?? ""
            onLog?(.warning, "[\(peripheral.name ?? "相机")] 蓝牙物理链路断开\(errDesc)")
        }

        // 仅在非巡航且非重连模式下释放 Session 实例
        // 关键改动：绝不在此处盲目调用 centralManager.connect 挂起连接，以彻底杜绝相机低功耗心跳广播被 iOS 无脑秒连唤醒
        if !isCruiseModeActive && session?.isReconnectingMode != true {
            removeSession(for: pID)
        }
    }
}
#endif
