import AppKit
import CoreLocation
import PhotoolsCore
import SwiftUI
import WebKit

/// 3D 真实地形 GPX 轨迹漫游专业控制台 (包含 3D 地形画布、浮动数据看板与多图源切换)
public struct GPXTrackPerspectiveSheet: View {
    public let summary: GPXTrackSummary
    public var onClose: () -> Void = {}

    @State private var selectedTileProvider: MapTileProvider = .googleSatellite
    @State private var isHeaderCollapsed: Bool = false
    @ObservedObject private var lang = LanguageManager.shared

    public init(summary: GPXTrackSummary, onClose: @escaping () -> Void = {}) {
        self.summary = summary
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 3D 真实高程地形与发光轨迹画布
            GPXTrack3DMapView(
                summary: summary,
                tileProvider: selectedTileProvider
            )
            .id(summary.filePath)
            .ignoresSafeArea()

            // 顶部浮动控制中枢：统一使用顶层 HStack，左侧悬浮 HUD 看板，右侧图源与控制工具，物理隔绝彻底杜绝重叠
            HStack(alignment: .top, spacing: 16) {
                // 左上角：专业浮动轨迹 HUD 看板 (展开态最大宽度 380，折叠态极简微胶囊)
                trackHUDCard
                    .frame(maxWidth: 380, alignment: .leading)

                Spacer(minLength: 20)

                // 右上角：图源选择器与视角复位工具栏
                topTrailingControls
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(red: 7/255.0, green: 10/255.0, blue: 18/255.0))
    }

    private var topTrailingControls: some View {
        HStack(spacing: 8) {
            // 图源切换胶囊
            tileProviderMenu

            // 复位视角按钮：通过定向通知直接触达当前地图实例，杜绝全局跨窗口搜索
            Button {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ResetGPXCamera"),
                    object: summary.filePath
                )
            } label: {
                Label("全景俯瞰", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var trackHUDCard: some View {
        if isHeaderCollapsed {
            // 折叠态：极简单行微胶囊 (极低视觉遮挡)
            HStack(spacing: 8) {
                Image(systemName: "figure.hiking")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.cyan)

                Text(summary.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("·")
                    .foregroundStyle(.white.opacity(0.35))

                Text(summary.formattedDistance)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)

                if let gain = summary.elevationGain {
                    Text(String(format: "+%.0fm", gain))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHeaderCollapsed = false
                }
            }
        } else {
            // 展开态：四要素完整数据卡片，带右上角折叠按钮
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.hiking")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.cyan)

                    Text(summary.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHeaderCollapsed = true
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("折叠")
                                .font(.system(size: 10))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                // 四要素网格
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        statItem(label: "总里程", value: summary.formattedDistance, icon: "arrow.triangle.swap")
                        statItem(label: "累计爬升", value: summary.elevationGain.map { String(format: "+%.0fm", $0) } ?? "--", icon: "arrow.up.right")
                    }
                    GridRow {
                        statItem(label: "海拔跨度", value: summary.formattedElevationSummary, icon: "mountain.2")
                        statItem(label: "记录耗时", value: summary.formattedDuration, icon: "clock")
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("原始记录 \(summary.rawPointCount) 点 · 3D 高清渲染 \(summary.renderedPoints.count) 点")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 2)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
    }

    private func statItem(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.cyan.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
    }

    private var tileProviderMenu: some View {
        Menu {
            ForEach(MapTileProvider.allCases) { provider in
                Button {
                    selectedTileProvider = provider
                } label: {
                    HStack {
                        Text(provider.displayName)
                        if selectedTileProvider == provider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.cyan)
                Text(selectedTileProvider.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
