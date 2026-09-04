import Foundation

/// Apple / iPhone 系列相机专属姿态与朝向策略 (Apple Attitude Strategy)
/// 支持通过 AccelerationVector 3轴加速度解算真实拍摄仰俯角 (Pitch) 与水平横滚角 (Roll)
public struct AppleAttitudeStrategy: CameraAttitudeStrategy, Sendable {
    public let id: String = "apple_attitude"
    public let priority: Int = 50

    public init() {}

    public func canHandle(make: String?, model: String?, dict: [String: Any]) -> Bool {
        if let m = make?.lowercased(), m.contains("apple") {
            return true
        }
        if dict["MakerNotes:AccelerationVector"] != nil || dict["AccelerationVector"] != nil {
            return true
        }
        return false
    }

    public func extractAttitude(from dict: [String: Any], make: String?, model: String?) -> CameraAttitude {
        func doubleVal(_ keys: String...) -> Double? {
            for k in keys {
                if let val = dict[k] {
                    if let d = val as? Double { return d }
                    if let s = val as? String, let d = Double(s) { return d }
                    if let num = val as? NSNumber { return num.doubleValue }
                }
            }
            return nil
        }

        func strVal(_ keys: String...) -> String? {
            for k in keys {
                if let val = dict[k] {
                    let s = "\(val)".trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty && s != "<nil>" && s != "0" && s != "undef" && s != "-" {
                        return s
                    }
                }
            }
            return nil
        }

        let heading = doubleVal(
            "gps_img_direction",
            "Composite:GPSImgDirection",
            "GPS:GPSImgDirection",
            "GPSImgDirection",
            "XMP:GPSImgDirection",
            "gps_dest_bearing",
            "Composite:GPSDestBearing",
            "GPS:GPSDestBearing",
            "GPSDestBearing",
            "XMP:GPSDestBearing"
        )
        let headingRef = strVal(
            "gps_img_direction_ref",
            "GPS:GPSImgDirectionRef",
            "GPSImgDirectionRef",
            "XMP:GPSImgDirectionRef",
            "gps_dest_bearing_ref",
            "GPS:GPSDestBearingRef",
            "GPSDestBearingRef",
            "XMP:GPSDestBearingRef"
        ) ?? "T"

        // 解析 iPhone 3轴重力加速度向量 (形如 "-0.9796136019 0.01809608005 0.1817096768")
        var pitch: Double? = nil
        var roll: Double? = nil

        let accelStr = strVal("MakerNotes:AccelerationVector", "AccelerationVector", "MakerNotes:Acceleration")
        if let s = accelStr {
            let parts = s.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .compactMap { Double($0) }
            if parts.count >= 3 {
                let ax = parts[0]
                let ay = parts[1]
                let az = parts[2]

                // iPhone 坐标系：Z 轴垂直于机身屏幕向外，镜头在机身背面（-Z 方向）
                // 仰俯角 (Pitch)：重力加速度沿 Z 轴的投影 (旋转不变性)
                let horizontalG = sqrt(ax * ax + ay * ay)
                if horizontalG > 0.0001 || abs(az) > 0.0001 {
                    let pitchRad = atan2(az, horizontalG)
                    pitch = pitchRad * 180.0 / Double.pi
                }

                // 横滚角 (Roll)：结合拍摄持握方向 (Orientation) 判定重力基准轴
                let orientStr = strVal("orientation", "EXIF:Orientation", "Orientation")?.lowercased() ?? ""
                let isLandscape = orientStr.contains("horizontal") || orientStr.contains("180")
                if abs(ax) > 0.0001 || abs(ay) > 0.0001 {
                    if isLandscape {
                        // 横屏握持：主重力轴在 X 轴，Y 轴反映机身水平微倾
                        let rollRad = atan2(ay, abs(ax))
                        roll = rollRad * 180.0 / Double.pi
                    } else {
                        // 竖屏握持：主重力轴在 Y 轴，X 轴反映机身左右微倾
                        let rollRad = atan2(ax, abs(ay))
                        roll = rollRad * 180.0 / Double.pi
                    }
                }
            }
        }

        // 优先采纳已由摄影师或 3D 地图保存的精确仰俯与横滚角 (XMP-photools / XMP-Camera)
        if let savedPitch = doubleVal("pitch", "XMP-photools:Pitch", "XMP-Camera:Pitch", "Pitch") {
            pitch = savedPitch
        }
        if let savedRoll = doubleVal("roll", "XMP-photools:Roll", "XMP-Camera:Roll", "Roll") {
            roll = savedRoll
        }

        // 视场角与焦距
        let focal35mm = doubleVal(
            "focal_length_in_35mm_format",
            "EXIF:FocalLengthIn35mmFormat",
            "Composite:FocalLength35efl",
            "FocalLengthIn35mmFormat"
        )
        let fovStr = strVal("fov", "Composite:FOV", "FOV")
        let rawFOV: Double? = {
            guard let s = fovStr else { return nil }
            let clean = s.replacingOccurrences(of: "deg", with: " ")
            let parts = clean.split(separator: " ")
            if let first = parts.first, let d = Double(first) {
                return d
            }
            return nil
        }()

        var fov: Double? = rawFOV
        if fov == nil, let fl = focal35mm, fl > 1.0 {
            fov = CoordinateConverter.calculateFOV(focalLength: fl)
        }

        // 提取物理对焦距或测距深度 (AFMeasuredDepth 单位通常为 mm，FocusDistanceRange 如 "0.95 - 1.20 m")
        var focusDistMeters: Double? = nil
        if let depthMm = doubleVal("AFMeasuredDepth", "MakerNotes:AFMeasuredDepth"), depthMm > 10.0 && depthMm < 15000.0 {
            focusDistMeters = depthMm / 1000.0
        } else if let rangeStr = strVal("FocusDistanceRange", "MakerNotes:FocusDistanceRange") {
            let parts = rangeStr.components(separatedBy: "-")
            if let last = parts.last {
                let clean = last.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
                if let d = Double(clean), d > 0.1 && d < 1000.0 {
                    focusDistMeters = d
                }
            }
        }

        // 机位海拔
        let altitude = doubleVal("altitude", "Composite:GPSAltitude", "GPS:GPSAltitude", "GPSAltitude", "XMP:GPSAltitude")

        // 智能视距（结合物理对焦距离、海拔与俯仰角启发式模型）
        let baseSuggestedDist = CoordinateConverter.suggestedDistance(
            focalLength35mm: focal35mm,
            focusDistanceMeters: focusDistMeters,
            altitudeMeters: altitude,
            pitchDegrees: pitch
        )

        // 优先采纳已保存的 3D 视角视距
        let savedViewDistance = doubleVal(
            "view_distance",
            "XMP-photools:ViewDistance",
            "ViewDistance",
            "photools:ViewDistance"
        )
        let finalSuggestedDist = savedViewDistance ?? baseSuggestedDist

        let desc: String = {
            if pitch != nil && heading != nil {
                return "iPhone 磁力计罗盘 + 加速度计仰角解算"
            } else if heading != nil {
                return "iPhone 磁力计电子罗盘"
            } else if pitch != nil {
                return "iPhone 加速度计重力仰角解算"
            }
            return "Apple 标准图像元数据"
        }()

        return CameraAttitude(
            heading: heading,
            headingRef: headingRef,
            pitch: pitch,
            roll: roll,
            yaw: nil,
            fov: fov,
            focusDistanceMeters: focusDistMeters,
            suggestedDistanceMeters: finalSuggestedDist,
            strategyName: "AppleAttitude",
            sourceDescription: desc
        )
    }
}
