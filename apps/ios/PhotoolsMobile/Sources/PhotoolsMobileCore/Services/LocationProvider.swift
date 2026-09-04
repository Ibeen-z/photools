import Foundation
#if canImport(CoreLocation)
import CoreLocation

/// GPS 高精定位与后台保活调度引擎
public final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let locationManager = CLLocationManager()

    /// 实时定位刷新回调 (每次硬件更新即时触发，用于驱动 UI 显示，绝不用陈旧缓存)
    public var onRealtimeLocationUpdated: ((CLLocation) -> Void)?
    /// 节电防抖下发回调 (位移 > 5m 或 静止 > 25s 时触发，供向相机蓝牙写入)
    public var onLocationReadyForSync: ((CLLocation) -> Void)?
    public var onLocationUpdated: ((CLLocation) -> Void)? // 向后兼容

    public var onLocationLost: (() -> Void)?
    public var onAuthorizationChanged: ((CLAuthorizationStatus, Bool) -> Void)?
    public var onLog: ((SyncLogLevel, String) -> Void)?

    /// 最近一次获取到的高精有效 GPS 位置 (用于相机唤醒瞬间 0 延迟即刻注入)
    public private(set) var latestValidLocation: CLLocation?

    private var lastEmittedLocation: CLLocation?
    private var lastEmittedTime: Date?
    private var hasSentInvalidFix: Bool = false

    /// 最小位移触发距离 (米)
    public var distanceFilterMeters: Double = 5.0
    /// 最大静止保活间隔 (秒)
    public var maxKeepAliveIntervalSeconds: TimeInterval = 25.0

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone // 手机端持续无阻碍接收真实卫星高频更新，永不停歇
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .fitness // 摄影巡航/户外活动，防止系统误判静止挂起

        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        // 核心铁律：默认关闭后台药丸指示器，仅在摄影师显式开启「巡航模式」时才激活
        locationManager.showsBackgroundLocationIndicator = false
        #endif
    }

    /// 动态配置摄影巡航模式对后台定位与系统状态栏药丸的影响
    public func setCruiseModeActive(_ active: Bool) {
        #if os(iOS)
        // 核心铁律：仅在巡航模式下常驻状态栏蓝色定位药丸；未巡航时彻底关闭指示，规避用户电量焦虑与权限困扰
        locationManager.showsBackgroundLocationIndicator = active
        #endif
        if active {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.activityType = .fitness
        } else {
            // 未开启巡航时，前台使用自适应精度，允许系统适度节电优化
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 3.0
            locationManager.pausesLocationUpdatesAutomatically = true
        }
    }

    /// 当前是否拥有始终定位权限
    public var isAlwaysAuthorized: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    /// 当前是否开启了精确位置
    public var isFullAccuracy: Bool {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            return locationManager.accuracyAuthorization == .fullAccuracy
        }
        #endif
        return true
    }

    /// 核心权限自检与逐步请求
    public func requestPermissions() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            onLog?(.info, "申请始终定位权限...")
            locationManager.requestAlwaysAuthorization()
        #if os(iOS)
        case .authorizedWhenInUse:
            // 已经是使用期间权限，升级为始终定位
            onLog?(.warning, "当前仅为「使用 App 期间」，请求升级为「始终允许」以支持息屏锁屏后台同步...")
            locationManager.requestAlwaysAuthorization()
        #endif
        case .denied, .restricted:
            onLog?(.error, "定位权限被系统禁用，请在 iPhone 设置中开启")
        case .authorizedAlways:
            onLog?(.success, "已拥有「始终允许」定位权限 🟢")
        @unknown default:
            break
        }

        // 校验精确位置权限 (iOS 14+)
        #if os(iOS)
        if #available(iOS 14.0, *) {
            if locationManager.accuracyAuthorization == .reducedAccuracy {
                onLog?(.warning, "检测到当前为「近似位置」，正在申请「精确位置」以保证坐标真实有效...")
                locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "NikonHighAccuracyGPS") { [weak self] error in
                    if let error = error {
                        self?.onLog?(.error, "申请精确位置失败: \(error.localizedDescription)")
                    } else {
                        self?.onLog?(.success, "已获得高精度坐标授权 🟢")
                    }
                }
            }
        }
        #endif
    }

    /// 请求权限并开启定位
    public func start() {
        requestPermissions()
        locationManager.startUpdatingLocation()
        onLog?(.info, "GPS 定位引擎已启动 (后台保活中枢已就绪)")
    }

    /// 停止定位
    public func stop() {
        locationManager.stopUpdatingLocation()
        lastEmittedLocation = nil
        lastEmittedTime = nil
        hasSentInvalidFix = false
        onLog?(.info, "GPS 定位引擎已休眠")
    }

    /// 判断当前保存的定位是否新鲜 (默认 60s 内)
    public func isLocationFresh(maxAge: TimeInterval = 60.0) -> Bool {
        guard let loc = latestValidLocation else { return false }
        return abs(Date().timeIntervalSince(loc.timestamp)) <= maxAge
    }

    private var singleLocationCallbacks: [(CLLocation?) -> Void] = []
    private var isRequestingSingleLocation = false

    /// 在未开启持续巡航模式时，按需单次请求最新鲜高精度定位 (防止向相机注入陈旧历史时间戳导致 ATT 0x80 错误)
    public func requestSingleFreshLocation(timeout: TimeInterval = 5.0, completion: @escaping (CLLocation?) -> Void) {
        if isLocationFresh(maxAge: 30.0), let loc = latestValidLocation {
            completion(loc)
            return
        }

        singleLocationCallbacks.append(completion)
        if !isRequestingSingleLocation {
            isRequestingSingleLocation = true
            requestPermissions()
            locationManager.requestLocation()

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, self.isRequestingSingleLocation else { return }
                self.isRequestingSingleLocation = false
                let callbacks = self.singleLocationCallbacks
                self.singleLocationCallbacks.removeAll()
                let loc = self.isLocationFresh(maxAge: 60.0) ? self.latestValidLocation : nil
                for cb in callbacks {
                    cb(loc)
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let isFull = isFullAccuracy
        onAuthorizationChanged?(manager.authorizationStatus, isFull)

        #if os(iOS)
        if #available(iOS 14.0, *) {
            if manager.accuracyAuthorization == .reducedAccuracy {
                onLog?(.warning, "警告：当前处于近似位置模式，尼康相机无法获得精准拍摄机位！")
            }
        }
        #endif

        if manager.authorizationStatus == .authorizedAlways {
            onLog?(.success, "定位权限处于最高等级：始终允许 (锁屏息屏下持续同步)")
        }
        #if os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse {
            onLog?(.warning, "提示：当前为「使用期间」，锁屏后可能被系统暂停定位，建议在系统设置中改为「始终」")
        }
        #endif
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // 检查定位有效性 (若开启了精准位置，精度通常在 5m~20m 左右)
        let isValid = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 65.0

        if !isValid {
            if !hasSentInvalidFix {
                hasSentInvalidFix = true
                onLog?(.warning, "GPS 信号弱 (精度 \(Int(location.horizontalAccuracy))m)，向相机发送单次无效标记")
                onLocationLost?()
            }
            return
        }

        hasSentInvalidFix = false
        self.latestValidLocation = location
        onRealtimeLocationUpdated?(location) // 实时刷新手机端 UI 坐标与精度，永不停歇

        if isRequestingSingleLocation {
            isRequestingSingleLocation = false
            let callbacks = self.singleLocationCallbacks
            self.singleLocationCallbacks.removeAll()
            for cb in callbacks {
                cb(location)
            }
        }

        let now = Date()

        // 仅对向相机的蓝牙下发做防抖控制 (位移 > 5m 或 静止 > 25s)
        if let lastLoc = lastEmittedLocation, let lastTime = lastEmittedTime {
            let distance = location.distance(from: lastLoc)
            let elapsed = now.timeIntervalSince(lastTime)

            if distance < distanceFilterMeters && elapsed < maxKeepAliveIntervalSeconds {
                return // 静止防抖，跳过向相机的蓝牙下发
            }
        }

        lastEmittedLocation = location
        lastEmittedTime = now
        onLocationReadyForSync?(location)
        onLocationUpdated?(location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isRequestingSingleLocation {
            isRequestingSingleLocation = false
            let callbacks = self.singleLocationCallbacks
            self.singleLocationCallbacks.removeAll()
            let loc = self.isLocationFresh(maxAge: 60.0) ? self.latestValidLocation : nil
            for cb in callbacks {
                cb(loc)
            }
        }
        onLog?(.error, "定位服务异常: \(error.localizedDescription)")
    }
}
#endif
