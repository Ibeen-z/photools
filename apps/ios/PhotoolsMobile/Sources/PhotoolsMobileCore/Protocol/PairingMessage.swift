import Foundation

/// 尼康 SnapBridge BLE 17 字节配对/重连报文
/// Offset 0  (1B): stage (0x01, 0x02, 0x03, 0x04)
/// Offset 1  (8B): timestamp (小端序)
/// Offset 9  (4B): device id (小端序)
/// Offset 13 (4B): nonce (小端序)
public struct PairingMessage: Equatable, Sendable {
    public static let size = 17

    public let stage: UInt8
    public let timestamp: UInt64
    public let device: UInt32
    public let nonce: UInt32

    public init(stage: UInt8, timestamp: UInt64, device: UInt32, nonce: UInt32) {
        self.stage = stage
        self.timestamp = timestamp
        self.device = device
        self.nonce = nonce
    }

    /// 从 17 字节二进制数据反序列化 (零堆内存分配优化)
    public init?(data: Data) {
        guard data.count >= Self.size else { return nil }
        self.stage = data[data.startIndex]

        let (ts, dev, non) = data.withUnsafeBytes { ptr -> (UInt64, UInt32, UInt32) in
            let ts = ptr.loadUnaligned(fromByteOffset: 1, as: UInt64.self)
            let dev = ptr.loadUnaligned(fromByteOffset: 9, as: UInt32.self)
            let non = ptr.loadUnaligned(fromByteOffset: 13, as: UInt32.self)
            return (ts, dev, non)
        }
        self.timestamp = ts
        self.device = dev
        self.nonce = non
    }

    /// 序列化为 17 字节小端序报文
    public func encode() -> Data {
        var data = Data(capacity: Self.size)
        data.append(stage)

        var tsLE = timestamp.littleEndian
        data.append(Data(bytes: &tsLE, count: 8))

        var devLE = device.littleEndian
        data.append(Data(bytes: &devLE, count: 4))

        var nonceLE = nonce.littleEndian
        data.append(Data(bytes: &nonceLE, count: 4))

        return data
    }

    /// 生成阶段 1 初始配对报文
    /// - Parameters:
    ///   - deviceID: 已配对设备的 deviceID 或新建配对时的随机 ID（配对时 LSB 必须为 0x01）
    ///   - nonce: 随机或保存的 nonce
    public static func createStage1(deviceID: UInt32? = nil, nonce: UInt32? = nil) -> PairingMessage {
        var dev = deviceID ?? UInt32.random(in: 0...UInt32.max)
        if deviceID == nil {
            // 新配对时确保 Least Significant Byte 最低有效位为 0x01
            dev = (dev & 0xFFFFFF00) | 0x01
        }
        let n = nonce ?? UInt32.random(in: 0...UInt32.max)
        let ts = UInt64.random(in: 0...UInt64.max)

        return PairingMessage(stage: 0x01, timestamp: ts, device: dev, nonce: n)
    }
}
