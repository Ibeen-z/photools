import Foundation

/// 相机连接状态枚举
public enum CameraConnectionStatus: String, Codable, Sendable {
    case disconnected        = "未连接"
    case scanning            = "正在搜索"
    case connecting          = "正在连接"
    case handshaking         = "认证握手中"
    case ready               = "同步就绪"
    case error               = "异常错误"
}

/// 已保存的尼康相机模型
public struct CameraDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID                   // 本地唯一标识符
    public var name: String               // 相机名称 (例如 "NIKON Z 8", "NIKON Z 50_2")
    public var bleIdentifier: String?     // CoreBluetooth peripheral identifier UUID 字符串
    public var deviceID: UInt32           // 协议中的 4 字节 deviceID
    public var controllerName: String?
    public var nonce: UInt32              // 协议中的 4 字节 nonce
    public var isDefault: Bool            // 是否为启动自动连接的默认相机
    public var lastConnectedAt: Date?     // 上次连接时间
    public var totalSyncCount: Int        // 累计位置下发次数

    public init(
        id: UUID = UUID(),
        name: String,
        bleIdentifier: String? = nil,
        deviceID: UInt32 = 0,
        nonce: UInt32 = 0,
        controllerName: String? = nil,
        isDefault: Bool = false,
        lastConnectedAt: Date? = nil,
        totalSyncCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.bleIdentifier = bleIdentifier
        self.deviceID = deviceID
        self.nonce = nonce
        self.controllerName = controllerName
        self.isDefault = isDefault
        self.lastConnectedAt = lastConnectedAt
        self.totalSyncCount = totalSyncCount
    }

    /// UI 显示用的安全脱敏名称 (序列号遮盖 4 位，例如 "Z6_3_80****9")
    public var displayName: String {
        Self.maskName(name)
    }
}

extension CameraDevice {
    /// 提取规范化相机型号标识 (统一剥离大小写、"Nikon " / "Nikon_" 品牌前缀与内部空格，便于跨平台纯净比对)
    public static func canonicalName(_ raw: String?) -> String {
        guard let r = raw else { return "" }
        var clean = r.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasPrefix("nikon ") {
            clean = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("nikon_") {
            clean = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 消除内部空格差异 (例如 "z 6_3_1234567" 与 "z6_3_1234567" 归一化)
        clean = clean.replacingOccurrences(of: " ", with: "")
        return clean
    }

    /// 三阶严格匹配算法：
    /// 1. 硬件 DeviceID 绝对优先 (防伪造、防漂移)
    /// 2. 本地固化外设 UUID 匹配 (秒级命中)
    /// 3. 规范化型号严格相等 == (彻底杜绝 contains 模糊快速枚举导致的 NSTaggedPointerString 崩溃)
    public func matches(
        discoveredDeviceID: UInt32? = nil,
        peripheralUUID: UUID? = nil,
        peripheralName: String? = nil
    ) -> Bool {
        // 第一阶：硬件 DeviceID 绝对优先
        if let devID = discoveredDeviceID, devID != 0 && self.deviceID == devID {
            return true
        }

        // 第二阶：本地固化外设 UUID 匹配
        if let pUUID = peripheralUUID, let savedUUID = self.bleIdentifier, !savedUUID.isEmpty {
            if savedUUID.caseInsensitiveCompare(pUUID.uuidString) == .orderedSame {
                return true
            }
        }

        // 第三阶：未绑定 UUID 时的规范化型号严格比对 (防御通用占位符)
        let cSaved = Self.canonicalName(self.name)
        let cPeriph = Self.canonicalName(peripheralName)
        if !cSaved.isEmpty && !cPeriph.isEmpty && cSaved != "尼康相机" && cPeriph != "尼康相机" && cSaved == cPeriph {
            return true
        }

        return false
    }

    // MARK: - 序列号安全脱敏 (保护摄影师隐私)

    /// 对纯数字序列号进行 4 位脱敏
    public static func maskSerialNumber(_ serial: String) -> String {
        let count = serial.count
        guard count >= 4 else {
            return String(repeating: "*", count: count)
        }
        if count == 4 {
            return "****"
        }
        if count == 5 {
            let prefix = serial.prefix(1)
            return "\(prefix)****"
        }
        // 6位及以上：遮盖中间4位，保留首尾
        // count == 6: 前1, 遮4, 后1  => 1****6
        // count == 7 (尼康主流7位): 前2, 遮4, 后1 => 80****9
        // count == 8: 前2, 遮4, 后2  => 12****78
        // count >= 9: 前(count - 4 - 2), 遮4, 后2
        let suffixLen = count >= 8 ? 2 : 1
        let prefixLen = count - 4 - suffixLen
        let prefix = serial.prefix(prefixLen)
        let suffix = serial.suffix(suffixLen)
        return "\(prefix)****\(suffix)"
    }

    /// 对相机名称进行脱敏（将末尾或内含的机身序列号脱敏 4 位）
    public static func maskName(_ raw: String?) -> String {
        guard let name = raw, !name.isEmpty else { return "" }

        // 1. 如果整个名字就是纯数字序列号
        if let _ = name.range(of: #"^\d{4,10}$"#, options: .regularExpression) {
            return maskSerialNumber(name)
        }

        // 2. 如果包含分隔符并以 4~10 位数字结尾 (如 "Z6_3_1234567", "NIKON Z 8_1234567", "Z 50_2 2001234")
        if let regex = try? NSRegularExpression(pattern: #"^(.*?[-_\s])(\d{4,10})$"#) {
            let nsStr = name as NSString
            let matches = regex.matches(in: name, range: NSRange(location: 0, length: nsStr.length))
            if let match = matches.first, match.numberOfRanges == 3 {
                let prefix = nsStr.substring(with: match.range(at: 1))
                let serial = nsStr.substring(with: match.range(at: 2))
                return prefix + maskSerialNumber(serial)
            }
        }

        // 3. 如果紧跟在字母后面没有分隔符但以 4~10 位数字结尾 (如 "Z631234567")
        if let regex = try? NSRegularExpression(pattern: #"^(.*?[A-Za-z])(\d{5,10})$"#) {
            let nsStr = name as NSString
            let matches = regex.matches(in: name, range: NSRange(location: 0, length: nsStr.length))
            if let match = matches.first, match.numberOfRanges == 3 {
                let prefix = nsStr.substring(with: match.range(at: 1))
                let serial = nsStr.substring(with: match.range(at: 2))
                return prefix + maskSerialNumber(serial)
            }
        }

        return name
    }

    /// 对任意日志文本中的相机名称/序列号进行脱敏过滤
    public static func maskText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // 匹配跟在相机型号分隔符后面的 5~9 位序列号 (如 Z6_3_1234567 中的 1234567)
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[A-Za-z0-9][_\s-])(\d{5,9})(?=[^\d]|$)"#) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // 从后往前替换，避免字符偏移量被破坏
        for match in matches.reversed() {
            let serialRange = match.range(at: 1)
            let serial = nsText.substring(with: serialRange)
            let masked = maskSerialNumber(serial)
            if let swiftRange = Range(serialRange, in: result) {
                result.replaceSubrange(swiftRange, with: masked)
            }
        }
        return result
    }
}
