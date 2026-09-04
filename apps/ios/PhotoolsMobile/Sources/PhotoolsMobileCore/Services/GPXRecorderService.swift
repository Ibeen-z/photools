import Foundation
import Combine
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 巡航轨迹持续录制与持久化管理中枢 (面向超长巡航紧凑二进制存储与流式异步导出)
@MainActor
public final class GPXRecorderService: ObservableObject {
    public static let shared = GPXRecorderService()

    /// 历史轨迹归档列表 (按开始时间降序排列)
    @Published public private(set) var recordedSessions: [GPXTrackSession] = []
    /// 当前正在录制的实时统计数据 (用于 UI 高频刷新)
    @Published public private(set) var activeRecordingStats: GPXRecordingStats?
    /// 当前是否处于轨迹录制状态
    @Published public private(set) var isRecording: Bool = false

    /// 当前活跃会话元数据
    public private(set) var currentSession: GPXTrackSession?
    /// 当前活跃会话点位集合
    public private(set) var currentPoints: [GPXRecordedPoint] = []

    /// 采样配置参数
    public var maxAllowedAccuracyMeters: Double = 50.0  // 最大允许误差（米）
    public var minMovementDistanceMeters: Double = 3.0   // 最小位移门限（米）
    public var heartbeatIntervalSeconds: TimeInterval = 15.0 // 静止时最长心跳采样间隔（秒）

    private var lastRecordedPoint: GPXRecordedPoint?
    private var lastFlushPointCount: Int = 0

    private let fileManager = FileManager.default
    private let indexFileName = "tracks_index.json"
    private let activeSnapshotFileName = "active_session_snapshot.json"
    private let activeMetaFileName = "active_session_meta.json"
    private let activeBinaryWALFileName = "active_points.bin"
    private let activeWALFileName = "active_points.wal"
    private let ioQueue = DispatchQueue(label: "com.vincentchyu.photools.mobile.gpxIO", qos: .utility)

    /// GPX 文件主存储目录 (沙盒 Documents/Tracks)
    public let tracksDirectoryURL: URL

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tracks", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.tracksDirectoryURL = dir
        loadIndex()
        recoverInterruptedSessionIfNeeded()
    }

    // MARK: - 录制生命周期

    /// 开启一次新的轨迹录制会话
    public func startSession() {
        guard !isRecording else { return }

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let sessionName = "\(formatter.string(from: now)) 摄影巡航"

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let gpxFileName = "Track_\(fileFormatter.string(from: now)).gpx"

        let session = GPXTrackSession(
            sessionName: sessionName,
            startTime: now,
            gpxFileName: gpxFileName,
            isCompleted: false
        )

        self.currentSession = session
        self.currentPoints = []
        self.lastRecordedPoint = nil
        self.lastFlushPointCount = 0
        self.isRecording = true
        self.activeRecordingStats = GPXRecordingStats(
            sessionID: session.id,
            pointCount: 0,
            distanceMeters: 0,
            elevationGain: 0,
            durationSeconds: 0,
            latestAccuracy: 0
        )

        saveActiveSessionMeta()
    }

    #if canImport(CoreLocation)
    /// 收到系统 CoreLocation 定位更新时记录
    public func recordLocation(_ location: CLLocation) {
        guard isRecording, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxAllowedAccuracyMeters else {
            return
        }
        let pt = GPXRecordedPoint(location: location)
        recordPoint(pt)
    }
    #endif

    /// 核心采样逻辑与点位入库
    public func recordPoint(_ point: GPXRecordedPoint) {
        guard isRecording, var session = currentSession else { return }

        // 水平精度过滤
        if point.horizontalAccuracy > maxAllowedAccuracyMeters {
            return
        }

        // 自适应防漂移与心跳过滤
        if let last = lastRecordedPoint {
            let dist = point.distance(to: last)
            let elapsed = point.timestamp.timeIntervalSince(last.timestamp)

            // 若位移小于最小门限且未达到心跳保活间隔，判定为静止微动，跳过记录
            if dist < minMovementDistanceMeters && elapsed < heartbeatIntervalSeconds {
                return
            }

            // 累计里程
            session.totalDistanceMeters += dist

            // 累计爬升
            if let newEle = point.elevation, let oldEle = last.elevation, newEle > oldEle {
                session.elevationGain += (newEle - oldEle)
            }
        }

        currentPoints.append(point)
        lastRecordedPoint = point
        session.pointCount = currentPoints.count
        self.currentSession = session

        let duration = max(0, point.timestamp.timeIntervalSince(session.startTime))
        self.activeRecordingStats = GPXRecordingStats(
            sessionID: session.id,
            pointCount: session.pointCount,
            distanceMeters: session.totalDistanceMeters,
            elevationGain: session.elevationGain,
            durationSeconds: duration,
            latestAccuracy: point.horizontalAccuracy
        )

        // 增量容灾写入：每累积 10 个点仅追加 320 字节二进制紧凑数据 (零 JSON 序列化开销，零 GC 压力)
        if currentPoints.count - lastFlushPointCount >= 10 {
            let slice = Array(currentPoints[lastFlushPointCount..<currentPoints.count])
            appendIncrementalPoints(slice)
            lastFlushPointCount = currentPoints.count
        }
    }

    /// 停止录制并生成合法的 GPX 1.1 文件 (默认后台流式分块无锁落盘，可指定 flushSync: true 同步等待)
    @discardableResult
    public func stopSession(flushSync: Bool = false) -> GPXTrackSession? {
        guard isRecording, var session = currentSession else { return nil }

        let now = Date()
        session.endTime = now
        session.isCompleted = true
        session.pointCount = currentPoints.count

        // 1. 主线程瞬时就绪：立即插入归档首位并重置录制态，UI 零挂起
        recordedSessions.insert(session, at: 0)
        let pointsToExport = self.currentPoints
        let finalSession = session
        let fileURL = tracksDirectoryURL.appendingPathComponent(session.gpxFileName)

        self.currentSession = nil
        self.currentPoints = []
        self.lastRecordedPoint = nil
        self.isRecording = false
        self.activeRecordingStats = nil

        let writeTask = { [weak self] in
            guard let self = self else { return }

            #if os(iOS)
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "GPXExportTask") {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            #endif

            defer {
                #if os(iOS)
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
                #endif
            }

            if !pointsToExport.isEmpty {
                // 流式分块写入，内存恒定在 64KB 以内，杜绝数万点内存震荡
                try? GPXExporter.exportStream(session: finalSession, points: pointsToExport, to: fileURL)
            }

            self.saveIndex()
            self.clearActiveWAL()
        }

        if flushSync {
            ioQueue.sync(execute: writeTask)
        } else {
            ioQueue.async(execute: writeTask)
        }

        return finalSession
    }

    /// 同步排空当前所有的后台 I/O 任务 (用于单测与退出时保证磁盘数据落盘一致性)
    public func flushPendingWritesSync() {
        ioQueue.sync {}
    }

    /// 删除单次轨迹记录 (同步删除文件和索引条目)
    public func deleteSession(_ session: GPXTrackSession) {
        let fileURL = tracksDirectoryURL.appendingPathComponent(session.gpxFileName)
        try? fileManager.removeItem(at: fileURL)

        recordedSessions.removeAll(where: { $0.id == session.id })
        saveIndex()
    }

    /// 批量删除指定索引位置的轨迹记录
    public func deleteSessions(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { recordedSessions[$0] }
        recordedSessions.remove(atOffsets: offsets)
        for session in sessionsToDelete {
            let fileURL = tracksDirectoryURL.appendingPathComponent(session.gpxFileName)
            try? fileManager.removeItem(at: fileURL)
        }
        saveIndex()
    }

    /// 获取会话对应的实际 GPX 文件 URL
    public func gpxFileURL(for session: GPXTrackSession) -> URL {
        return tracksDirectoryURL.appendingPathComponent(session.gpxFileName)
    }

    // MARK: - 持久化与断电容灾自愈

    private func saveIndex() {
        let sessions = self.recordedSessions
        let fileURL = tracksDirectoryURL.appendingPathComponent(indexFileName)
        ioQueue.async {
            if let data = try? JSONEncoder().encode(sessions) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func loadIndex() {
        let fileURL = tracksDirectoryURL.appendingPathComponent(indexFileName)
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([GPXTrackSession].self, from: data) {
            self.recordedSessions = list
        }
    }

    private struct ActiveSnapshot: Codable {
        let session: GPXTrackSession
        let points: [GPXRecordedPoint]
    }

    /// 仅在会话开启时保存轻量元数据 (数字节)
    private func saveActiveSessionMeta() {
        guard let session = currentSession else { return }
        let fileURL = tracksDirectoryURL.appendingPathComponent(activeMetaFileName)
        ioQueue.async {
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 仅将新增的点位以 32 字节紧凑定长二进制追加至 WAL 物理文件末尾 (O(1) 增量 I/O，体积缩减 75%)
    private func appendIncrementalPoints(_ points: [GPXRecordedPoint]) {
        guard !points.isEmpty else { return }
        let binURL = tracksDirectoryURL.appendingPathComponent(activeBinaryWALFileName)
        ioQueue.async {
            var buffer = Data(capacity: points.count * CompactTrackPointRecord.recordSize)
            for pt in points {
                let compact = CompactTrackPointRecord(point: pt)
                buffer.append(compact.serialize())
            }
            guard !buffer.isEmpty else { return }
            if FileManager.default.fileExists(atPath: binURL.path) {
                if let handle = try? FileHandle(forWritingTo: binURL) {
                    handle.seekToEndOfFile()
                    handle.write(buffer)
                    try? handle.close()
                }
            } else {
                try? buffer.write(to: binURL, options: .atomic)
            }
        }
    }

    private func clearActiveWAL() {
        let metaURL = tracksDirectoryURL.appendingPathComponent(activeMetaFileName)
        let binURL = tracksDirectoryURL.appendingPathComponent(activeBinaryWALFileName)
        let walURL = tracksDirectoryURL.appendingPathComponent(activeWALFileName)
        let legacyURL = tracksDirectoryURL.appendingPathComponent(activeSnapshotFileName)
        ioQueue.async {
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: binURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    /// 检查并自愈恢复上次未正常结束的会话 (三模自愈：首选 32B 二进制 WAL，次选 JSON Lines WAL，兼容旧版全量快照)
    public func recoverInterruptedSessionIfNeeded() {
        let legacyURL = tracksDirectoryURL.appendingPathComponent(activeSnapshotFileName)
        let metaURL = tracksDirectoryURL.appendingPathComponent(activeMetaFileName)
        let binURL = tracksDirectoryURL.appendingPathComponent(activeBinaryWALFileName)
        let walURL = tracksDirectoryURL.appendingPathComponent(activeWALFileName)

        // 1. 兼容模式：处理可能存在的极旧版本全量快照
        if fileManager.fileExists(atPath: legacyURL.path) {
            if let data = try? Data(contentsOf: legacyURL),
               let snapshot = try? JSONDecoder().decode(ActiveSnapshot.self, from: data) {
                var session = snapshot.session
                let points = snapshot.points
                if !points.isEmpty {
                    session.endTime = points.last?.timestamp ?? Date()
                    session.isCompleted = true
                    session.pointCount = points.count
                    let gpxURL = tracksDirectoryURL.appendingPathComponent(session.gpxFileName)
                    try? GPXExporter.exportStream(session: session, points: points, to: gpxURL)
                    recordedSessions.insert(session, at: 0)
                    saveIndex()
                }
            }
            try? fileManager.removeItem(at: legacyURL)
        }

        // 2. 读取中断会话元数据
        guard fileManager.fileExists(atPath: metaURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              var session = try? JSONDecoder().decode(GPXTrackSession.self, from: metaData) else {
            return
        }

        var recoveredPoints: [GPXRecordedPoint] = []

        // 2.1 首选：32 字节紧凑定长二进制 WAL (极速反序列化)
        if fileManager.fileExists(atPath: binURL.path),
           let binData = try? Data(contentsOf: binURL) {
            recoveredPoints = CompactTrackPointRecord.deserializeAll(from: binData)
        }

        // 2.2 次选：旧版 JSON Lines WAL (向前兼容)
        if recoveredPoints.isEmpty, fileManager.fileExists(atPath: walURL.path),
           let walData = try? Data(contentsOf: walURL) {
            let decoder = JSONDecoder()
            let lines = walData.split(separator: 0x0A)
            for line in lines where !line.isEmpty {
                if let pt = try? decoder.decode(GPXRecordedPoint.self, from: Data(line)) {
                    recoveredPoints.append(pt)
                }
            }
        }

        // 2.3 生成合法 GPX 1.1 文件并入库
        if !recoveredPoints.isEmpty {
            session.endTime = recoveredPoints.last?.timestamp ?? Date()
            session.isCompleted = true
            session.pointCount = recoveredPoints.count
            let gpxURL = tracksDirectoryURL.appendingPathComponent(session.gpxFileName)
            try? GPXExporter.exportStream(session: session, points: recoveredPoints, to: gpxURL)
            recordedSessions.insert(session, at: 0)
            saveIndex()
        }

        clearActiveWAL()
    }
}
