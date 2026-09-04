import Foundation

/// 握手状态流转
public enum HandshakeState: Equatable, Sendable {
    case idle
    case stage1Sent(stage1: PairingMessage)
    case stage2Received(stage2: PairingMessage)
    case stage3Sent(stage3: PairingMessage)
    case stage4Verified
    case nameConfigured
    case ready
    case failed(reason: String)
}

/// 单个相机会话的状态机驱动器
public final class CameraStateMachine: @unchecked Sendable {
    public private(set) var state: HandshakeState = .idle
    private let securityEngine: NikonSecurityEngine
    public private(set) var savedDeviceID: UInt32?
    public private(set) var savedNonce: UInt32?
    public var controllerName: String
    public private(set) var activeDeviceID: UInt32 = 0
    public private(set) var activeNonce: UInt32 = 0

    public init(
        securityEngine: NikonSecurityEngine = .shared,
        savedDeviceID: UInt32? = nil,
        savedNonce: UInt32? = nil,
        controllerName: String = "iPhone_NikonGPS"
    ) {
        self.securityEngine = securityEngine
        self.savedDeviceID = savedDeviceID
        self.savedNonce = savedNonce
        self.controllerName = controllerName
        if let dev = savedDeviceID { self.activeDeviceID = dev }
        if let non = savedNonce { self.activeNonce = non }
    }

    /// 动态热更新或注入配对凭据 (避免会话复用时凭据缺失被相机秒踢)
    public func updateCredentials(savedDeviceID: UInt32?, savedNonce: UInt32?) {
        if let dev = savedDeviceID {
            self.savedDeviceID = dev
            self.activeDeviceID = dev
        }
        if let non = savedNonce {
            self.savedNonce = non
            self.activeNonce = non
        }
    }

    /// 重置状态机
    public func reset() {
        state = .idle
    }

    /// 开始握手：生成 Stage 1 载荷
    public func startHandshake() -> Data {
        let stage1 = PairingMessage.createStage1(deviceID: savedDeviceID, nonce: savedNonce)
        self.activeDeviceID = stage1.device
        self.activeNonce = stage1.nonce
        state = .stage1Sent(stage1: stage1)
        return stage1.encode()
    }

    /// 收到 PAIR 特征数据更新 (相机返回的 Stage 2 或 Stage 4)
    public func handlePairDataReceived(_ data: Data) -> HandshakeNextStep {
        guard let message = PairingMessage(data: data) else {
            state = .failed(reason: "解析 PAIR 报文失败，长度不足或格式损坏")
            return .error("报文格式损坏")
        }

        switch (state, message.stage) {
        case (.stage1Sent(let stage1), 0x02):
            // 收到 Stage 2 挑战，验证 Salt 并计算 Stage 3
            guard let stage3 = securityEngine.verifyStage2AndBuildStage3(stage1: stage1, stage2: message) else {
                let diag = "Stage 2 挑战校验失败 (相机下发 Dev=0x\(String(message.device, radix: 16).uppercased()), Nonce=0x\(String(message.nonce, radix: 16).uppercased()), 我方 Stage1 Dev=0x\(String(stage1.device, radix: 16).uppercased()), Nonce=0x\(String(stage1.nonce, radix: 16).uppercased()))"
                state = .failed(reason: diag)
                return .error(diag)
            }
            state = .stage3Sent(stage3: stage3)
            return .sendStage3(stage3.encode())

        case (.stage3Sent, 0x04):
            // 收到 Stage 4 确认，握手认证成功！接下来向 ID 写入设备名称
            state = .stage4Verified
            let nameData = formatControllerName(controllerName)
            state = .nameConfigured
            return .sendDeviceName(nameData)

        default:
            state = .failed(reason: "当前状态 \(state) 与收到的 Stage \(message.stage) 不匹配")
            return .error("状态机不匹配")
        }
    }

    /// 格式化智能设备控制器名称 (固定 32 字节 ASCII，以 0x00 结尾)
    public func formatControllerName(_ name: String) -> Data {
        var data = Data(count: 32)
        let asciiBytes = Array(name.utf8.prefix(31))
        for (i, b) in asciiBytes.enumerated() {
            data[i] = b
        }
        data[31] = 0x00
        return data
    }

    /// 标记完成名称设置，进入同步就绪
    public func markReady() {
        state = .ready
    }
}

/// 状态机下一步动作指令
public enum HandshakeNextStep: Equatable, Sendable {
    case sendStage3(Data)
    case sendDeviceName(Data)
    case ready
    case error(String)
}
