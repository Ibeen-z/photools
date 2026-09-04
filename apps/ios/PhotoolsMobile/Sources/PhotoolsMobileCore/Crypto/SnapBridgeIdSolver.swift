import Foundation

/// 针对尼康相机中已配对的 SnapBridge 设备标识 (DeviceID / Nonce) 的数学逆向反解器
///
/// 原理 (基于 HowenXu/snapbridge-id-extractor 与 gkoh/furble 逆向工程):
/// 官方 SnapBridge 首次安装配对时，通过以下逻辑生成 8 字节的控制器凭据:
/// ```
/// byte[] id = new byte[8];
/// new Random(new Date().getTime()).nextBytes(id); // 种子为 Unix 毫秒时间戳
/// ```
/// 相机在 BLE 广播的厂商数据 (0x0399 后) 暴露了前 4 字节 (小端序 uint32)。
/// 利用 Java Random (48-bit LCG) 的模反元素，我们可以在 1 毫秒内反推出种子，
/// 并精确重构出当年的后 4 字节 Nonce，使 iPhone App 能以完全相同的凭据秒级接管相机，
/// 无需进入相机菜单重新配对，亦无需经典蓝牙参与。
public enum SnapBridgeIdSolver {
    public struct Candidate: Equatable, Sendable {
        public let seed: Int64
        public let deviceID: UInt32
        public let nonce: UInt32
        public let fullHex: String

        public init(seed: Int64, deviceID: UInt32, nonce: UInt32, fullHex: String) {
            self.seed = seed
            self.deviceID = deviceID
            self.nonce = nonce
            self.fullHex = fullHex
        }
    }

    private static let mask48: UInt64 = (1 << 48) - 1
    private static let multiplier: UInt64 = 0x5DEECE66D
    private static let addend: UInt64 = 0xB

    /// multiplier 在模 2^48 下的乘法逆元 (通过扩展欧几里得计算，精确固定)
    /// pow(0x5DEECE66D, -1, 1 << 48) = 0xdfe05bcb1365
    private static let invMultiplier: UInt64 = 0xdfe05bcb1365

    /// 反解所有使得第一个 nextInt() 等于 targetDevice 的 48 位种子候选
    /// - Parameter targetDevice: 相机广播暴露的 4 字节小端序整数
    public static func solveSeeds(targetDevice: UInt32) -> [Int64] {
        let target = UInt64(targetDevice)
        var seeds: [Int64] = []
        seeds.reserveCapacity(1 << 16)

        for low16 in 0..<UInt64(1 << 16) {
            // state = (target << 16) | low16
            let state = (target << 16) | low16
            // x = (((state - ADDEND) & MASK48) * inv) & MASK48
            let diff = (state &- addend) & mask48
            let x = (diff &* invMultiplier) & mask48
            let seed = Int64(bitPattern: x ^ multiplier)
            seeds.append(seed)
        }
        return seeds
    }

    /// 模拟 Java Random.nextBytes(n)
    public static func nextBytes(seed: Int64, count: Int) -> Data {
        var state = (UInt64(bitPattern: seed) ^ multiplier) & mask48
        var out = Data(count: count)
        var i = 0

        while i < count {
            state = (state &* multiplier &+ addend) & mask48
            let rnd = (state >> 16) & 0xFFFFFFFF
            let step = min(4, count - i)
            for j in 0..<step {
                out[i] = UInt8((rnd >> (8 * j)) & 0xFF)
                i += 1
            }
        }
        return out
    }

    /// 在指定时间窗口内搜索候选凭据 (默认从 SnapBridge 发布的 2016 年至今)
    public static func candidatesFor(
        targetDevice: UInt32,
        windowStartMs: Int64 = 1451606400000, // 2016-01-01
        windowEndMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) + 86400000
    ) -> [Candidate] {
        let allSeeds = solveSeeds(targetDevice: targetDevice)
        var candidates: [Candidate] = []

        for seed in allSeeds where seed >= windowStartMs && seed <= windowEndMs {
            let bytes = nextBytes(seed: seed, count: 8)
            let dev = bytes.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let non = bytes.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            candidates.append(Candidate(seed: seed, deviceID: dev, nonce: non, fullHex: hex))
        }

        return candidates.sorted(by: { $0.seed < $1.seed })
    }
}
