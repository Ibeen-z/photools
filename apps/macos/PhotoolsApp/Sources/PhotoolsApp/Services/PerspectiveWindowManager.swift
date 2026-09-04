import AppKit
import Foundation
import PhotoolsCore
import SwiftUI

/// 3D 摄影机位视角与地形比对独立辅助窗口中枢 (Perspective Window Manager)
/// 专为专业摄影师设计：将 3D 地图透视控制台以独立子窗口形态呈现，支持自由拖拽缩放与多屏摆放，
/// 彻底消除模态弹窗对原图画面的遮挡，实现高精照片构图与 3D 地形走向的同屏实时比对。
@MainActor
public final class PerspectiveWindowManager: ObservableObject {
    public static let shared = PerspectiveWindowManager()

    @Published public private(set) var isVisible: Bool = false
    @Published public var currentAsset: PhotoAssetGroup?
    @Published public var currentExif: ExifMetadata?

    private var window: NSWindow?
    private var windowController: NSWindowController?

    private init() {}

    /// 打开或置顶 3D 地图对比窗口，并载入指定照片
    public func show(asset: PhotoAssetGroup, exif: ExifMetadata) {
        self.currentAsset = asset
        self.currentExif = exif

        if let existing = window {
            existing.title = windowTitle(for: asset)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "机位视角与 3D 卫星地形"
        newWindow.titlebarAppearsTransparent = false
        newWindow.titleVisibility = .visible
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 860, height: 560)
        newWindow.backgroundColor = NSColor(red: 7/255.0, green: 10/255.0, blue: 18/255.0, alpha: 1.0)

        let rootView = PerspectiveWindowContainerView(manager: self)
        newWindow.contentViewController = NSHostingController(rootView: rootView)
        newWindow.center()

        // 监听窗口关闭事件
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isVisible = false
            }
        }

        self.window = newWindow
        self.windowController = NSWindowController(window: newWindow)

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.isVisible = true
    }

    /// 当主窗口切换选中照片时，若 3D 浮动窗口处于打开状态，平滑同步更新机位
    public func updateIfVisible(asset: PhotoAssetGroup, exif: ExifMetadata) {
        guard isVisible, window != nil else { return }
        self.currentAsset = asset
        self.currentExif = exif
        self.window?.title = windowTitle(for: asset)
    }

    /// 关闭独立窗口
    public func close() {
        window?.close()
        isVisible = false
    }

    private func windowTitle(for asset: PhotoAssetGroup) -> String {
        "3D 卫星机位视角与地形比对 - \(asset.baseName)"
    }
}

/// 宿主容器视图，响应式绑定 manager 的当前资产状态
private struct PerspectiveWindowContainerView: View {
    @ObservedObject var manager: PerspectiveWindowManager

    var body: some View {
        if let asset = manager.currentAsset, let exif = manager.currentExif {
            PhotoPerspectiveSheet(
                asset: asset,
                exif: exif,
                onClose: {
                    manager.close()
                }
            )
            .id(asset.id) // 换图时重建状态
        } else {
            VStack {
                ProgressView("正在载入机位数据...")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
