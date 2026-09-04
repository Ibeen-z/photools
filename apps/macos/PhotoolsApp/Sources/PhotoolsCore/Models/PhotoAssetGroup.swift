import Foundation

public enum PrimaryAssetType: String, Codable, Equatable, Sendable {
    case rawPair        // RAW + JPG 双格式配套
    case rawOnly        // 独立单 RAW
    case jpgOnly        // 独立单 JPG
    case companionOnly  // 仅伴随文件 (XMP/WAV 等，缺少主文件)

    @MainActor
    public var title: String {
        switch self {
        case .rawPair:
            return LanguageManager.shared.text(.typeRawPairTitle)
        case .rawOnly:
            return LanguageManager.shared.text(.typeRawOnlyTitle)
        case .jpgOnly:
            return LanguageManager.shared.text(.typeJpgOnlyTitle)
        case .companionOnly:
            return LanguageManager.shared.text(.typeCompanionOnlyTitle)
        }
    }
}

public enum PhotoAssetStatus: String, Codable, Equatable, Sendable {
    case ready          // 可作为主决策源处理 (RAW+JPG, 单RAW, 单JPG)
    case companionOnly  // 缺少主文件，暂不处理

    @MainActor
    public var title: String {
        switch self {
        case .ready:
            return LanguageManager.shared.text(.statusReadyTitle)
        case .companionOnly:
            return LanguageManager.shared.text(.statusCompanionOnlyTitle)
        }
    }

    @MainActor
    public var suggestion: String {
        switch self {
        case .ready:
            return LanguageManager.shared.text(.statusReadySuggestion)
        case .companionOnly:
            return LanguageManager.shared.text(.statusCompanionOnlySuggestion)
        }
    }
}

public struct PhotoAssetGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let baseName: String
    public let directory: String
    public let rawPath: String?
    public let jpgPath: String?
    public let xmpPath: String?
    public let companionPaths: [String]
    public let fileModificationDate: Date?
    public var captureDate: Date?

    public init(
        id: String,
        baseName: String,
        directory: String,
        rawPath: String?,
        jpgPath: String?,
        xmpPath: String?,
        companionPaths: [String],
        fileModificationDate: Date? = nil,
        captureDate: Date? = nil
    ) {
        self.id = id
        self.baseName = baseName
        self.directory = directory
        self.rawPath = rawPath
        self.jpgPath = jpgPath
        self.xmpPath = xmpPath
        self.companionPaths = companionPaths
        self.fileModificationDate = fileModificationDate
        self.captureDate = captureDate
    }

    /// 提供便捷方法返回注入拍摄时间的资产组副本
    public func withCaptureDate(_ date: Date?) -> PhotoAssetGroup {
        PhotoAssetGroup(
            id: id,
            baseName: baseName,
            directory: directory,
            rawPath: rawPath,
            jpgPath: jpgPath,
            xmpPath: xmpPath,
            companionPaths: companionPaths,
            fileModificationDate: fileModificationDate,
            captureDate: date
        )
    }

    /// 有效时间：优先真实相机曝光拍摄时间，无拍摄时间时平滑回退至文件物理修改时间
    public var effectiveDate: Date? {
        captureDate ?? fileModificationDate
    }

    public var primaryType: PrimaryAssetType {
        if rawPath != nil && jpgPath != nil {
            return .rawPair
        }
        if rawPath != nil {
            return .rawOnly
        }
        if jpgPath != nil {
            return .jpgOnly
        }
        return .companionOnly
    }

    public var primaryPath: String? {
        if let rawPath {
            return rawPath
        }
        if let jpgPath {
            return jpgPath
        }
        return nil
    }

    public var hasRaw: Bool { rawPath != nil }
    public var hasJpg: Bool { jpgPath != nil }
    public var hasXmp: Bool { xmpPath != nil }

    public var status: PhotoAssetStatus {
        if primaryPath != nil {
            return .ready
        }
        return .companionOnly
    }

    public var allFiles: [String] {
        var files: [String] = []
        if let rawPath {
            files.append(rawPath)
        }
        if let jpgPath {
            files.append(jpgPath)
        }
        files.append(contentsOf: companionPaths)
        return files
    }
}

public enum PhotoSortField: String, CaseIterable, Identifiable, Sendable {
    case captureDate
    case fileModificationDate
    case baseName

    public var id: String { rawValue }

    @MainActor
    public var title: String {
        switch self {
        case .captureDate:
            return LanguageManager.shared.text(.sortCaptureDate)
        case .fileModificationDate:
            return LanguageManager.shared.text(.sortModificationDate)
        case .baseName:
            return LanguageManager.shared.text(.sortFileName)
        }
    }

    public var iconName: String {
        switch self {
        case .captureDate:
            return "camera.fill"
        case .fileModificationDate:
            return "clock.fill"
        case .baseName:
            return "textformat"
        }
    }
}

public enum PhotoSortOrder: String, CaseIterable, Identifiable, Sendable {
    case descending
    case ascending

    public var id: String { rawValue }

    @MainActor
    public var title: String {
        switch self {
        case .descending:
            return LanguageManager.shared.text(.sortDescending)
        case .ascending:
            return LanguageManager.shared.text(.sortAscending)
        }
    }

    public var iconName: String {
        switch self {
        case .descending:
            return "arrow.down"
        case .ascending:
            return "arrow.up"
        }
    }
}
