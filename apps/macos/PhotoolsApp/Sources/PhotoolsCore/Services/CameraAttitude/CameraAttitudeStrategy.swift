import Foundation

/// 统一的相机空间姿态与光学数据模型 (Camera Attitude & Optical State)
public struct CameraAttitude: Sendable, Equatable {
    /// 镜头绝对地理罗盘朝向（度数 0~360°，0 为正北）
    public let heading: Double?
    /// 罗盘朝向参考系（"T" 为真北 True North，"M" 为磁北 Magnetic North）
    public let headingRef: String?
    /// 镜头俯仰角（Pitch，单位：度。正值为仰视，负值为俯视）
    public let pitch: Double?
    /// 机身水平横滚角（Roll，单位：度。左倾或右倾）
    public let roll: Double?
    /// 机身航向偏航角（Yaw，相对参考或无磁力计相对量）
    public let yaw: Double?
    /// 水平视场角（FOV，单位：度）
    public let fov: Double?
    /// 物理镜头对焦距离（米）
    public let focusDistanceMeters: Double?
    /// 建议观察视距（米）
    public let suggestedDistanceMeters: Double?
    /// 生效的策略名称
    public let strategyName: String
    /// 姿态来源描述（如："Apple 3轴重力加速度解算"、"Nikon 机身五轴水平仪"、"标准 EXIF 电子罗盘"）
    public let sourceDescription: String

    public init(
        heading: Double? = nil,
        headingRef: String? = nil,
        pitch: Double? = nil,
        roll: Double? = nil,
        yaw: Double? = nil,
        fov: Double? = nil,
        focusDistanceMeters: Double? = nil,
        suggestedDistanceMeters: Double? = nil,
        strategyName: String = "Standard",
        sourceDescription: String = "标准 EXIF"
    ) {
        self.heading = heading
        self.headingRef = headingRef
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
        self.fov = fov
        self.focusDistanceMeters = focusDistanceMeters
        self.suggestedDistanceMeters = suggestedDistanceMeters
        self.strategyName = strategyName
        self.sourceDescription = sourceDescription
    }
}

/// 相机姿态与朝向分析策略协议 (Camera Attitude Strategy Protocol)
public protocol CameraAttitudeStrategy: Sendable {
    /// 策略唯一标识
    var id: String { get }
    /// 策略优先级 (数值越高越优先匹配，如专有相机厂商策略 > 通用标准策略)
    var priority: Int { get }

    /// 判断当前策略是否匹配该元数据字典
    func canHandle(make: String?, model: String?, dict: [String: Any]) -> Bool

    /// 执行姿态与朝向提取
    func extractAttitude(from dict: [String: Any], make: String?, model: String?) -> CameraAttitude
}

/// 相机姿态分析策略注册中心 (Camera Attitude Registry)
public final class CameraAttitudeRegistry: @unchecked Sendable {
    public static let shared = CameraAttitudeRegistry()

    private let lock = NSLock()
    private var strategies: [CameraAttitudeStrategy] = []

    public init() {
        registerDefaultStrategies()
    }

    /// 注册策略
    public func register(_ strategy: CameraAttitudeStrategy) {
        lock.lock()
        defer { lock.unlock() }
        strategies.removeAll { $0.id == strategy.id }
        strategies.append(strategy)
        strategies.sort { $0.priority > $1.priority }
    }

    /// 根据元数据字典与机型自动匹配最优策略并解算相机姿态
    public func resolve(from dict: [String: Any], make: String?, model: String?) -> CameraAttitude {
        lock.lock()
        let currentStrategies = strategies
        lock.unlock()

        for strategy in currentStrategies {
            if strategy.canHandle(make: make, model: model, dict: dict) {
                return strategy.extractAttitude(from: dict, make: make, model: model)
            }
        }

        // 兜底返回默认姿态
        return CameraAttitude(strategyName: "DefaultFallback", sourceDescription: "无匹配策略")
    }

    private func registerDefaultStrategies() {
        register(AppleAttitudeStrategy())
        register(NikonAttitudeStrategy())
        register(StandardExifStrategy())
    }
}
