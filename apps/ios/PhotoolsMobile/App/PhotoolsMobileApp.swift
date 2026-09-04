import SwiftUI
import PhotoolsMobileCore

@main
struct PhotoolsMobileApp: App {
    init() {
        // 核心：在 App 进程被 iOS 系统后台唤醒启动的首毫秒内，立即实例化协调器与蓝牙单例
        // 确保向系统提交相同的 CBCentralManagerOptionRestoreIdentifierKey，完成 State Restoration
        _ = CameraSyncCoordinator.shared
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NikonGPSMainAppView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                CameraSyncCoordinator.shared.handleAppDidBecomeActive()
            case .background:
                CameraSyncCoordinator.shared.handleAppDidEnterBackground()
            default:
                break
            }
        }
    }
}
