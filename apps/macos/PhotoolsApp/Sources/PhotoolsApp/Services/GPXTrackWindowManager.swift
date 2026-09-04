import AppKit
import Foundation
import PhotoolsCore
import SwiftUI

/// 3D 真实地形 GPX 轨迹漫游独立辅助窗口中枢
@MainActor
public final class GPXTrackWindowManager: ObservableObject {
    public static let shared = GPXTrackWindowManager()

    @Published public private(set) var isVisible: Bool = false
    @Published public var currentSummary: GPXTrackSummary?
    @Published public var isParsingTrack: Bool = false
    @Published public var parsingProgress: Double = 0.0
    @Published public var parsingStage: String = "正在启动 3D 轨迹空间引擎..."
    @Published public var parsingFileName: String = ""

    private var window: NSWindow?
    private var windowController: NSWindowController?

    private init() {}

    /// 确保窗口已创建并置顶激活
    private func ensureWindow(title: String) {
        if let existing = window {
            existing.title = title
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = title
        newWindow.titlebarAppearsTransparent = false
        newWindow.titleVisibility = .visible
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 860, height: 560)
        newWindow.backgroundColor = NSColor(red: 7/255.0, green: 10/255.0, blue: 18/255.0, alpha: 1.0)

        let rootView = GPXTrackWindowContainerView(manager: self)
        newWindow.contentViewController = NSHostingController(rootView: rootView)
        newWindow.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.currentParseTask?.cancel()
                self?.currentParseTask = nil
                self?.currentParsingFilePath = nil
                self?.currentSummary = nil
                self?.isVisible = false
                self?.window = nil
                self?.windowController = nil
                self?.isParsingTrack = false
                self?.parsingFileName = ""
            }
        }

        self.window = newWindow
        self.windowController = NSWindowController(window: newWindow)

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.isVisible = true
    }

    private var currentParseTask: Task<Void, Never>?
    private var currentParsingFilePath: String?

    /// 打开或更新 3D 地图轨迹窗口 (已有解析好的 Summary)
    public func show(summary: GPXTrackSummary) {
        currentParseTask?.cancel()
        currentParseTask = nil
        currentParsingFilePath = summary.filePath
        self.isParsingTrack = false
        self.currentSummary = summary
        self.ensureWindow(title: "3D 真实地形轨迹漫游 - \(summary.name)")
    }

    /// 便捷方法：传入 GPX 文件绝对路径，立即弹出窗口并展示解析进度条
    public func show(filePath: String) {
        // 取消正在进行的任何旧解析任务，杜绝异步乱序竞态覆盖
        currentParseTask?.cancel()
        currentParseTask = nil

        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        self.currentParsingFilePath = filePath
        self.parsingFileName = fileName
        self.currentSummary = nil
        self.isParsingTrack = true
        self.parsingProgress = 0.1
        self.parsingStage = "正在读取本地 GPX 轨迹数据..."

        // 立即弹出独立窗口，杜绝用户在列表前傻等
        self.ensureWindow(title: "3D 真实地形轨迹漫游 - \(fileName)")

        currentParseTask = Task { [weak self] in
            let summary = await GPXTrackParser.shared.parse(filePath: filePath) { [weak self] progress, stage in
                Task { @MainActor [weak self] in
                    guard let self = self, !Task.isCancelled, self.currentParsingFilePath == filePath else { return }
                    self.parsingProgress = progress
                    self.parsingStage = stage
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled, self.currentParsingFilePath == filePath else { return }
                self.isParsingTrack = false
                if let summary = summary {
                    self.show(summary: summary)
                } else {
                    self.parsingStage = "轨迹解析失败，请检查 GPX 文件格式"
                }
            }
        }
    }

    public func close() {
        currentParseTask?.cancel()
        currentParseTask = nil
        currentParsingFilePath = nil
        currentSummary = nil
        isParsingTrack = false
        parsingFileName = ""
        window?.close()
        window = nil
        windowController = nil
        isVisible = false
    }
}

private struct GPXTrackWindowContainerView: View {
    @ObservedObject var manager: GPXTrackWindowManager

    var body: some View {
        ZStack {
            Color(red: 7/255.0, green: 10/255.0, blue: 18/255.0).ignoresSafeArea()

            if let summary = manager.currentSummary {
                GPXTrackPerspectiveSheet(
                    summary: summary,
                    onClose: {
                        manager.close()
                    }
                )
                .id("\(summary.filePath)_\(summary.rawPointCount)_\(summary.totalDistanceMeters)")
            } else {
                GPXTrackLoadingHUDView(
                    fileName: manager.parsingFileName,
                    progress: manager.parsingProgress,
                    stage: manager.parsingStage,
                    onCancel: {
                        manager.close()
                    }
                )
            }
        }
    }
}

/// 轨迹解析加载科技感 HUD 面板
private struct GPXTrackLoadingHUDView: View {
    let fileName: String
    let progress: Double
    let stage: String
    var onCancel: () -> Void = {}

    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 24) {
            // 中心科技动效与脉冲光环
            ZStack {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.6), Color.blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 88, height: 88)
                    .scaleEffect(isPulsing ? 1.15 : 0.95)
                    .opacity(isPulsing ? 0.3 : 0.8)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)

                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: "figure.hiking")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .shadow(color: .cyan.opacity(0.7), radius: 8)
            }
            .onAppear {
                isPulsing = true
            }

            // 文件名与标题
            VStack(spacing: 6) {
                Text(fileName.isEmpty ? "GPX 轨迹空间档案" : fileName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("正在构建 3D 真实地形空间点云模型")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // 进度条与百分比
            VStack(spacing: 8) {
                // 进度条轨道
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, min(geo.size.width * CGFloat(progress), geo.size.width)), height: 6)
                            .shadow(color: Color.cyan.opacity(0.6), radius: 6, x: 0, y: 0)
                            .animation(.easeOut(duration: 0.25), value: progress)
                    }
                }
                .frame(width: 280, height: 6)

                // 阶段文案与百分比
                HStack {
                    Text(stage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.cyan.opacity(0.9))
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .frame(width: 280)
            }

            // 取消按钮
            Button {
                onCancel()
            } label: {
                Text("取消加载")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 12/255.0, green: 16/255.0, blue: 28/255.0).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
        )
    }
}
