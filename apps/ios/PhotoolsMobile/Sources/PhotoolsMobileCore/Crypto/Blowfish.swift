import Foundation
import CommonCrypto

/// 基于 Apple CommonCrypto 的高性能标准 Blowfish 加密器（ECB 模式无填充）
public struct Blowfish: Sendable {
    private let keyData: Data

    public init(key: [UInt8]) {
        self.keyData = Data(key)
    }

    /// 加密单个 64 位块 (大端序 32 位 left 与 right)
    public func encryptBlock(left: UInt32, right: UInt32) -> (left: UInt32, right: UInt32) {
        var inBytes = [UInt8](repeating: 0, count: 8)
        var bigL = left.bigEndian
        var bigR = right.bigEndian

        withUnsafeBytes(of: &bigL) { inBytes.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: &bigR) { inBytes.replaceSubrange(4..<8, with: $0) }

        var outBytes = [UInt8](repeating: 0, count: 8)
        var numBytesEncrypted: size_t = 0

        let status = keyData.withUnsafeBytes { keyBuffer in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmBlowfish),
                CCOptions(kCCOptionECBMode),
                keyBuffer.baseAddress,
                keyData.count,
                nil,
                inBytes,
                8,
                &outBytes,
                8,
                &numBytesEncrypted
            )
        }

        guard status == kCCSuccess else {
            return (0, 0)
        }

        let outL = outBytes[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let outR = outBytes[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return (outL, outR)
    }

    /// 加密 8 字节数据
    public func encrypt(data: Data) -> Data {
        precondition(data.count == 8, "Blowfish block size must be 8 bytes")
        var outBytes = [UInt8](repeating: 0, count: 8)
        var numBytesEncrypted: size_t = 0

        let status = keyData.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { inBuffer in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmBlowfish),
                    CCOptions(kCCOptionECBMode),
                    keyBuffer.baseAddress,
                    keyData.count,
                    nil,
                    inBuffer.baseAddress,
                    8,
                    &outBytes,
                    8,
                    &numBytesEncrypted
                )
            }
        }

        guard status == kCCSuccess else {
            return Data()
        }
        return Data(outBytes)
    }
}
