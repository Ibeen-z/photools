import SwiftUI
#if canImport(UIKit)
import UIKit
#if canImport(LinkPresentation)
import LinkPresentation
#endif

/// 针对本地 GPX 轨迹文件的高性能分享数据源 (显式提供 LPLinkMetadata，消除 iOS 16+ Collaboration 协同探测超时与 Code=-10814 报错)
public final class GPXActivityItemSource: NSObject, UIActivityItemSource {
    public let fileURL: URL
    public let title: String

    public init(fileURL: URL, title: String? = nil) {
        self.fileURL = fileURL
        self.title = title ?? fileURL.lastPathComponent
        super.init()
    }

    public func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return fileURL
    }

    public func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return fileURL
    }

    #if canImport(LinkPresentation)
    public func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = fileURL
        if let image = UIImage(systemName: "map.fill") {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
    #endif
}

/// iOS 系统原生分享面板 (UIActivityViewController)
public struct ShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]
    public let applicationActivities: [UIActivity]?

    public init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        // 自动将 URL 包装为 GPXActivityItemSource，提供显式元数据并加速面板弹出
        self.activityItems = activityItems.map { item -> Any in
            if let url = item as? URL {
                return GPXActivityItemSource(fileURL: url)
            }
            return item
        }
        self.applicationActivities = applicationActivities
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
