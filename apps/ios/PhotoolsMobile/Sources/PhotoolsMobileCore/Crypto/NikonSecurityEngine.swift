import Foundation

/// 尼康握手安全引擎：负责 Blowfish 密钥调度、8 组 Salt 验证与 Stage 3 挑战回应计算
public final class NikonSecurityEngine: Sendable {
    public static let shared = NikonSecurityEngine()

    private let blowfish: Blowfish

    /// 尼康固定的 Blowfish 密钥: FF FF AA 55 11 22 33 00
    public static let key: [UInt8] = [
        0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00
    ]

    /// 尼康预设的 8 组 Salt
    public static let salts: [[UInt32]] = [
        [0x704066e4, 0x0433d552],
        [0xed4b8fac, 0x15f7e47b],
        [0x24471f11, 0x8b5ea1fc],
        [0x05960c31, 0x2b8c7f41],
        [0xfda588c1, 0xeba8b1f3],
        [0x99166056, 0x1bd3d550],
        [0xcd32687f, 0xa9e28a30],
        [0x2a8fe834, 0xdec7ebf4]
    ]

    public init(key: [UInt8] = key) {
        self.blowfish = Blowfish(key: key)
    }

    /// 尼康自定义 Hash 计算过程
    /// left 初始值: 0x01020304
    /// right 初始值: 0x05060708
    public func hash(blocks: [UInt32]) -> (left: UInt32, right: UInt32)? {
        guard blocks.count % 2 == 0 else { return nil }

        var left: UInt32 = 0x01020304
        var right: UInt32 = 0x05060708

        for i in stride(from: 0, to: blocks.count, by: 2) {
            let inL = blocks[i] ^ left
            let inR = blocks[i + 1] ^ right

            let encrypted = blowfish.encryptBlock(left: inL, right: inR)
            left = encrypted.left
            right = encrypted.right
        }

        return (left, right)
    }

    /// 将 64 位小端时间戳拆解为两个大端序 32 位整数 (lo, hi)
    private func splitTimestampToBigEndian(_ ts: UInt64) -> (lo: UInt32, hi: UInt32) {
        var le = ts.littleEndian
        let bytes = withUnsafeBytes(of: &le) { Array($0) }
        let lo = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let hi = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        return (lo, hi)
    }

    /// 校验 Stage 2 相机下发的挑战，匹配 Salt，并构建 Stage 3 回应报文
    public func verifyStage2AndBuildStage3(stage1: PairingMessage, stage2: PairingMessage) -> PairingMessage? {
        let (ourTsLo, ourTsHi) = splitTimestampToBigEndian(stage1.timestamp)
        let (camTsLo, camTsHi) = splitTimestampToBigEndian(stage2.timestamp)

        // 相机在 Stage 2 下发的 challenge (device 与 nonce)，转换成对应的大端数值
        let camDeviceExpected = stage2.device.byteSwapped
        let camNonceExpected = stage2.nonce.byteSwapped

        var matchedSaltIndex: Int?

        for (index, salt) in Self.salts.enumerated() {
            let challengeInput: [UInt32] = [
                salt[0], salt[1],
                camTsLo, camTsHi,
                ourTsLo, ourTsHi
            ]

            guard let res = hash(blocks: challengeInput) else { continue }
            if res.left == camDeviceExpected && res.right == camNonceExpected {
                matchedSaltIndex = index
                break
            }
        }

        guard let matchedIndex = matchedSaltIndex else {
            return nil // 无法匹配任何一组 Salt，挑战校验失败
        }

        // 使用匹配的 Salt 计算 Stage 3 回应数据
        let matchedSalt = Self.salts[matchedIndex]
        let responseInput: [UInt32] = [
            matchedSalt[0], matchedSalt[1],
            ourTsLo, ourTsHi,
            camTsLo, camTsHi
        ]

        guard let resp = hash(blocks: responseInput) else { return nil }

        // 将 hash 结果转换回小端序填入 device 和 nonce
        let stage3Device = resp.left.byteSwapped
        let stage3Nonce = resp.right.byteSwapped

        return PairingMessage(
            stage: 0x03,
            timestamp: stage1.timestamp,
            device: stage3Device,
            nonce: stage3Nonce
        )
    }
}
