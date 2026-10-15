import Foundation

/// 配置文件中的相机凭据模型
public struct CameraCredentialConfig: Codable, Equatable, Sendable {
    public let name: String
    public let deviceID: String           // 支持十六进制 "0x12345678" 或十进制字符串
    public let nonce: String              // 支持十六进制 "0x87654321" 或十进制字符串
    public let controllerName: String?    // 配对时注册的控制器名称 (如 "iPhone_NikonGPS")
    public let isDefault: Bool?
    public let comment: String?

    public init(
        name: String,
        deviceID: String,
        nonce: String,
        controllerName: String? = nil,
        isDefault: Bool? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.deviceID = deviceID
        self.nonce = nonce
        self.controllerName = controllerName
        self.isDefault = isDefault
        self.comment = comment
    }

    /// 解析 4 字节无符号整数 DeviceID
    public var parsedDeviceID: UInt32? {
        if deviceID.lowercased().hasPrefix("0x") {
            let hex = String(deviceID.dropFirst(2))
            return UInt32(hex, radix: 16)
        }
        return UInt32(deviceID)
    }

    /// 解析 4 字节无符号整数 Nonce
    public var parsedNonce: UInt32? {
        if nonce.lowercased().hasPrefix("0x") {
            let hex = String(nonce.dropFirst(2))
            return UInt32(hex, radix: 16)
        }
        return UInt32(nonce)
    }

    /// 转换为系统标准 CameraDevice 实体
    public func toCameraDevice() -> CameraDevice? {
        guard let dev = parsedDeviceID, let n = parsedNonce else { return nil }
        return CameraDevice(
            name: name,
            bleIdentifier: nil,
            deviceID: dev,
            nonce: n,
            controllerName: controllerName,
            isDefault: isDefault ?? false,
            lastConnectedAt: Date()
        )
    }
}

/// 凭据配置文件根容器
public struct CameraCredentialsContainer: Codable, Equatable, Sendable {
    public let cameras: [CameraCredentialConfig]

    public init(cameras: [CameraCredentialConfig]) {
        self.cameras = cameras
    }
}

public enum CredentialImportError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 相机配置加载器：负责从外部 JSON 资源中安全解析预置的相机凭据
public final class CameraConfigLoader: Sendable {
    public static let shared = CameraConfigLoader()

    public init() {}

    /// 解析指定的 JSON 配置文件
    public func load(from data: Data) throws -> [CameraDevice] {
        let container = try JSONDecoder().decode(CameraCredentialsContainer.self, from: data)
        return container.cameras.compactMap { $0.toCameraDevice() }
    }

    /// 手动导入时整份校验，拒绝部分成功及示例凭据。
    public func loadForImport(from data: Data) throws -> [CameraDevice] {
        let container = try JSONDecoder().decode(CameraCredentialsContainer.self, from: data)
        guard !container.cameras.isEmpty else {
            throw CredentialImportError.invalid("文件中没有相机凭据")
        }
        var devices: [CameraDevice] = []
        var ids = Set<UInt32>()
        for item in container.cameras {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let device = item.toCameraDevice(), device.deviceID != 0 else {
                throw CredentialImportError.invalid("相机名称、DeviceID 或 Nonce 格式无效")
            }
            guard !Self.isExampleCamera(device) else {
                throw CredentialImportError.invalid("这是示例凭据，请导入从本人 SnapBridge 通信中提取的真实凭据")
            }
            guard ids.insert(device.deviceID).inserted else {
                throw CredentialImportError.invalid("文件包含重复的相机 DeviceID")
            }
            devices.append(device)
        }
        return devices
    }

    public static func isExampleCamera(_ camera: CameraDevice) -> Bool {
        let name = camera.name.lowercased()
        return camera.deviceID == 0x12345678 &&
            (name.contains("example") || name.contains("demo"))
    }

    /// 解析指定 URL 路径的 JSON 文件
    public func load(from fileURL: URL) throws -> [CameraDevice] {
        let data = try Data(contentsOf: fileURL)
        return try load(from: data)
    }

    /// 定位并装载系统预置的 camera_credentials.json 配置文件
    /// 支持 SPM Bundle.module、主应用 Bundle.main、源码树直接定位以及编译期内嵌凭据四重容错兜底机制
    public func loadPreconfiguredCameras() -> [CameraDevice] {
        if let url = locateConfigFile() {
            if let devices = try? load(from: url), !devices.isEmpty {
                return devices
            }
        }
        // 内嵌最终兜底保障：即使移动工程缺失外部 JSON 资源，也提供合法的演示相机实体，避免私有设备信息硬编码泄漏
        return [
            CameraDevice(
                name: "Nikon Z_Demo",
                bleIdentifier: nil,
                deviceID: 0x12345678,
                nonce: 0x87654321,
                isDefault: true,
                lastConnectedAt: Date()
            )
        ]
    }

    /// 获取默认相机的凭据元组 (供配对工具或首次连接使用)
    public func defaultCredentials() -> (deviceID: UInt32, nonce: UInt32, controllerName: String)? {
        if let url = locateConfigFile(),
           let data = try? Data(contentsOf: url),
           let container = try? JSONDecoder().decode(CameraCredentialsContainer.self, from: data) {
            let target = container.cameras.first(where: { $0.isDefault == true }) ?? container.cameras.first
            if let item = target,
               let dev = item.parsedDeviceID,
               let n = item.parsedNonce {
                let ctrlName = item.controllerName ?? "iPhone_NikonGPS"
                return (deviceID: dev, nonce: n, controllerName: ctrlName)
            }
        }
        return (deviceID: 0x12345678, nonce: 0x87654321, controllerName: "iPhone_NikonGPS")
    }

    /// 定位配置文件路径 (优先读取正式私有配置 camera_credentials.json，缺失时回退探测开源示例模板)
    public func locateConfigFile() -> URL? {
        let fileNames = [
            ("camera_credentials", "json"),
            ("camera_credentials.example", "json"),
            ("camera_credentials", "example.json"),
            ("camera_credentials", "json.example"),
            ("camera_credentials", "json.exp")
        ]

        #if SWIFT_PACKAGE
        // 1. SPM 资源包优先
        for (name, ext) in fileNames {
            if let moduleURL = Bundle.module.url(forResource: name, withExtension: ext) {
                return moduleURL
            }
        }
        #endif

        // 2. iOS App 运行时的 Bundle.main 资源
        for (name, ext) in fileNames {
            if let mainURL = Bundle.main.url(forResource: name, withExtension: ext) {
                return mainURL
            }
            if let mainSubURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
                return mainSubURL
            }
        }

        // 3. 开发环境与命令行测试探测本地工程源码树
        let candidateBases = [
            "Sources/PhotoolsMobileCore/Resources",
            "apps/ios/PhotoolsMobile/Sources/PhotoolsMobileCore/Resources",
            "../Sources/PhotoolsMobileCore/Resources",
            "Resources"
        ]

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath

        for base in candidateBases {
            for (name, ext) in fileNames {
                let filename = ext.isEmpty ? name : "\(name).\(ext)"
                let fullPath = URL(fileURLWithPath: currentDir)
                    .appendingPathComponent(base)
                    .appendingPathComponent(filename).path
                if fileManager.fileExists(atPath: fullPath) {
                    return URL(fileURLWithPath: fullPath)
                }
            }
        }

        return nil
    }
}
