import PhotoolsCore
import SwiftUI

public struct DetailView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var lang = LanguageManager.shared

    public init(store: WorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.selectedSection {
            case .pipeline:
                PipelineExecutionConsole(store: store)

            case .inbox:
                if let asset = store.selectedAsset {
                    PhotoExifInspectorView(store: store, asset: asset)
                } else {
                    EmptyDetailStateView(
                        title: lang.text(.noPhotoSelectedTitle),
                        subtitle: lang.text(.noPhotoSelectedSubtitle)
                    )
                }

            case .processed:
                if let asset = store.selectedAsset {
                    PhotoExifInspectorView(store: store, asset: asset, isArchivedFrozen: true)
                } else {
                    processedInspectorView
                }

            case .geodata:
                GeodataTestDetailView(store: store)

            case .gpx:
                gpxInspectorView

            case .testRestore:
                testRestoreHelpDetail

            case .guide:
                GuideDocDetailView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var processedInspectorView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(lang.text(.processedArchiveInfo), systemImage: "archivebox.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(lang.text(.processedArchiveCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.summary?.processedAssetGroupCount ?? 0)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.indigo)
                    Text("组照片 (\(store.summary?.processedFileCount ?? 0) 个物理文件)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let path = store.summary?.processedDirectory {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 10))

            Button {
                if let path = store.summary?.processedDirectory {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } label: {
                Label(lang.text(.openInFinder), systemImage: "folder")
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var gpxInspectorView: some View {
        GPXTrackDetailInspectorView(store: store, selectedPath: store.selectedGPXPath)
    }

    private var testRestoreHelpDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(lang.text(.testRestoreMechTitle), systemImage: "arrow.counterclockwise.circle.fill")
                .font(.headline)

            Text(lang.text(.testRestoreMechDesc))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct EmptyDetailStateView: View {
    let title: String
    let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GPXTrackDetailInspectorView: View {
    @ObservedObject var store: WorkspaceStore
    let selectedPath: String?
    @ObservedObject private var lang = LanguageManager.shared

    @State private var trackSummary: GPXTrackSummary?
    @State private var isLoading: Bool = false
    @State private var loadingProgress: Double = 0.0
    @State private var loadingStage: String = "正在解析轨迹高程与空间数据..."

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let path = selectedPath {
                    if isLoading {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .stroke(Color.cyan.opacity(0.25), lineWidth: 2.5)
                                    .frame(width: 44, height: 44)

                                Image(systemName: "figure.hiking")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.cyan)
                            }

                            VStack(spacing: 8) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 5)

                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.cyan, Color.blue],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(0, min(geo.size.width * CGFloat(loadingProgress), geo.size.width)), height: 5)
                                            .animation(.easeOut(duration: 0.25), value: loadingProgress)
                                    }
                                }
                                .frame(height: 5)

                                HStack {
                                    Text(loadingStage)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text("\(Int(loadingProgress * 100))%")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.cyan)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    } else if let summary = trackSummary, summary.filePath == path {
                        // 标题区
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "figure.hiking")
                                    .font(.title2)
                                    .foregroundStyle(.cyan)
                                Text(summary.name)
                                    .font(.title3.bold())
                                    .lineLimit(2)
                            }

                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        // 一键 3D 漫游大按钮
                        Button {
                            GPXTrackWindowManager.shared.show(summary: summary)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mountain.2.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("在 3D 真实地形中漫游轨迹")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .shadow(color: Color.cyan.opacity(0.35), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)

                        // 核心数据指标卡片
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                statCard(title: "总里程", value: summary.formattedDistance, icon: "arrow.triangle.swap", color: .cyan)
                                statCard(title: "累计爬升", value: summary.elevationGain.map { String(format: "+%.0fm", $0) } ?? "--", icon: "arrow.up.right", color: .green)
                            }
                            HStack(spacing: 12) {
                                statCard(title: "最高海拔", value: summary.maxElevation.map { "\(Int($0))m" } ?? "--", icon: "mountain.2", color: .orange)
                                statCard(title: "记录耗时", value: summary.formattedDuration, icon: "clock", color: .purple)
                            }
                            if summary.hasHeartRateData {
                                HStack(spacing: 12) {
                                    statCard(title: "平均心率", value: summary.avgHeartRate.map { "\(Int($0)) bpm" } ?? "--", icon: "heart.fill", color: .red)
                                    statCard(title: "最高心率", value: summary.maxHeartRate.map { "\($0) bpm" } ?? "--", icon: "bolt.heart.fill", color: .pink)
                                }
                            }
                        }

                        // 轨迹起止与采样元数据
                        VStack(alignment: .leading, spacing: 8) {
                            Text("轨迹空间档案")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            if let start = summary.startTime {
                                metaRow(label: "记录开始", value: Self.dateFormatter.string(from: start))
                            }
                            if let end = summary.endTime {
                                metaRow(label: "记录结束", value: Self.dateFormatter.string(from: end))
                            }
                            metaRow(label: "原始采样点", value: "\(summary.rawPointCount) 个点")
                            metaRow(label: "3D 高清点", value: "\(summary.renderedPoints.count) 个点")
                            if let minE = summary.minElevation, let maxE = summary.maxElevation {
                                metaRow(label: "海拔跨度", value: "\(Int(minE))m ~ \(Int(maxE))m")
                            }
                            if summary.hasHeartRateData, let minHr = summary.minHeartRate, let maxHr = summary.maxHeartRate {
                                metaRow(label: "心率区间", value: "\(minHr) ~ \(maxHr) bpm")
                            }
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

                        // 操作按钮
                        HStack(spacing: 12) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                Label(lang.text(.showInFinder), systemImage: "folder")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            } label: {
                                Label(lang.text(.openFile), systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    overviewCard
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: selectedPath) {
            guard let path = selectedPath else {
                trackSummary = nil
                isLoading = false
                return
            }
            trackSummary = nil
            isLoading = true
            loadingProgress = 0.15
            loadingStage = "正在读取本地 GPX 轨迹数据..."
            let summary = await GPXTrackParser.shared.parse(filePath: path) { progress, stage in
                Task { @MainActor in
                    loadingProgress = progress
                    loadingStage = stage
                }
            }
            if !Task.isCancelled && selectedPath == path {
                trackSummary = summary
            }
            isLoading = false
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(lang.text(.gpxMatchOverview), systemImage: "map.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(lang.text(.gpxFilesCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(store.summary?.gpxFiles.count ?? 0)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 10))

            Text("在中间列表中选择一条 GPX 轨迹，即可在此查看海拔与爬升空间档案，并在 3D 真实高程地形中全屏漫游。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(lang.text(.gpxPipelineDesc))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
        }
    }
}

