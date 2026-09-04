import SwiftUI
import Combine

/// 轨迹历史数据专用轻量 ViewModel (精准订阅，隔离高频实时 GPS 录制重绘风暴)
@MainActor
public final class GPXTrackHistoryViewModel: ObservableObject {
    @Published public private(set) var sessions: [GPXTrackSession] = []
    private var cancellables = Set<AnyCancellable>()
    private let recorder: GPXRecorderService

    public convenience init() {
        self.init(recorder: GPXRecorderService.shared)
    }

    public init(recorder: GPXRecorderService) {
        self.recorder = recorder
        self.sessions = recorder.recordedSessions

        // 仅在低频归档历史数据产生变化时更新，后台录制每秒打点完全不会触发本列表 Diff
        recorder.$recordedSessions
            .sink { [weak self] newSessions in
                guard let self = self else { return }
                if self.sessions != newSessions {
                    self.sessions = newSessions
                }
            }
            .store(in: &cancellables)
    }

    public func fileURL(for session: GPXTrackSession) -> URL {
        recorder.gpxFileURL(for: session)
    }

    public func deleteSession(_ session: GPXTrackSession) {
        recorder.deleteSession(session)
    }

    public func deleteSessions(at offsets: IndexSet) {
        recorder.deleteSessions(at: offsets)
    }
}

/// 导出分享载荷包装器
private struct ExportFilePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 摄影巡航 GPX 历史轨迹管理与导出视图
public struct GPXTrackHistoryView: View {
    @StateObject private var viewModel = GPXTrackHistoryViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var sessionToDelete: GPXTrackSession?
    @State private var showDeleteConfirm: Bool = false
    @State private var exportPayload: ExportFilePayload?

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.sessions.isEmpty {
                    emptyStateView
                } else {
                    trackListView
                }
            }
            .navigationTitle("巡航轨迹档案")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "确认删除此轨迹？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: sessionToDelete
            ) { session in
                Button("删除该记录及 GPX 文件", role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.deleteSession(session)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { session in
                Text("删除后无法恢复（文件：\(session.gpxFileName)）")
            }
            #if canImport(UIKit)
            .sheet(item: $exportPayload) { payload in
                ShareSheet(activityItems: [payload.url])
            }
            #endif
        }
    }

    // MARK: - 列表视图
    private var trackListView: some View {
        List {
            Section {
                ForEach(viewModel.sessions) { session in
                    trackSessionRow(session)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                sessionToDelete = session
                                showDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                exportPayload = ExportFilePayload(url: viewModel.fileURL(for: session))
                            } label: {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                }
                .onDelete { indexSet in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.deleteSessions(at: indexSet)
                    }
                }
            } header: {
                Text("已归档 \(viewModel.sessions.count) 段摄影轨迹")
            } footer: {
                Text("提示：连接 Mac 电脑后，在访达 (Finder) -> 文件 中亦可直接拷贝出所有 GPX 文件；向左滑动轨迹卡片可快速分享或删除。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - 单条轨迹卡片
    private func trackSessionRow(_ session: GPXTrackSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(session.gpxFileName)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    exportPayload = ExportFilePayload(url: viewModel.fileURL(for: session))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出 GPX")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 16) {
                // 点数
                HStack(spacing: 4) {
                    Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Text(session.formattedPointCount)
                        .font(.caption.bold())
                }

                // 里程
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(session.formattedDistance)
                        .font(.caption.bold())
                }

                // 爬升
                if session.elevationGain > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(session.formattedElevationGain)
                            .font(.caption.bold())
                    }
                }

                // 耗时
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(session.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.topleft.down.curvedto.point.filled.bottomright.up")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.6))
            Text("暂无巡航轨迹记录")
                .font(.headline)
                .foregroundColor(.primary)
            Text("在首页开启「摄影巡航模式」后，系统将在持续向相机注入经纬度的同时，自动记录高精轨迹点位。\n巡航停止后将在此自动生成合法的 GPX 1.1 文件。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
