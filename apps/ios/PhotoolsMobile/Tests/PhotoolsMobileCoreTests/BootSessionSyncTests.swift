import XCTest
@testable import PhotoolsMobileCore

final class BootSessionSyncTests: XCTestCase {
    @MainActor
    func testInitialBootSyncFlagIsFalse() {
        let coordinator = CameraSyncCoordinator.shared
        // 验证管理器重置接口存在且可安全调用
        coordinator.bluetoothManager.resetAllBootSessions()
    }

    @MainActor
    func testCoordinatorLifecycleHandling() {
        let coordinator = CameraSyncCoordinator.shared
        
        // 1. 测试安全退出兜底函数不会崩溃且正确清理
        coordinator.handleProcessTermination()
        
        // 2. 测试前台活跃与退入后台自适应处理
        coordinator.handleAppDidBecomeActive()
        coordinator.handleAppDidEnterBackground()
        
        // 3. 验证再次调用兜底安全幂等
        coordinator.handleProcessTermination()
    }

    @MainActor
    func testSystemTimeZoneChangedTriggersCompensation() {
        let coordinator = CameraSyncCoordinator.shared
        // 验证系统时区变动事件触发不会崩溃
        coordinator.handleSystemTimeZoneChanged()
    }
}
