import PhotoolsCore
import SwiftUI
import QuickLook

public struct PhotoThumbnailView: View {
    let asset: PhotoAssetGroup
    var targetSize: CGSize
    var quality: ThumbnailQuality
    var contentMode: ContentMode
    var cornerRadius: CGFloat
    var fixedSize: CGSize?

    @State private var thumbnail: NSImage?
    @State private var isLoading: Bool = true

    public init(
        asset: PhotoAssetGroup,
        targetSize: CGSize = CGSize(width: 80, height: 80),
        quality: ThumbnailQuality = .auto,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 8,
        fixedSize: CGSize? = nil
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.quality = quality
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.fixedSize = fixedSize
    }

    public var body: some View {
        ZStack {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(0.6)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
        }
        .frame(
            width: fixedSize?.width,
            height: fixedSize?.height
        )
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(asset.id)::\(quality.rawValue)::\(Int(targetSize.width))x\(Int(targetSize.height))::\(asset.fileModificationDate?.timeIntervalSince1970 ?? 0)") {
            isLoading = true
            thumbnail = await PhotoThumbnailLoader.shared.loadThumbnail(for: asset, targetSize: targetSize, quality: quality)
            isLoading = false
        }
    }
}
