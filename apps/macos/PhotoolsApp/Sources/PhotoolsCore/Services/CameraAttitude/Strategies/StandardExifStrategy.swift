import Foundation

/// 标准通用 EXIF 姿态与朝向策略 (Standard EXIF Fallback Strategy)
public struct StandardExifStrategy: CameraAttitudeStrategy, Sendable {
    public let id: String = "standard_exif"
    public let priority: Int = 0 // 最低优先级，作为全局兜底

    public init() {}

    public func canHandle(make: String?, model: String?, dict: [String: Any]) -> Bool {
        // 通用兜底，永远可处理
        return true
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
        )

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
        if fov == nil, let flStr = strVal("focal_length", "EXIF:FocalLength", "FocalLength") {
            let clean = flStr.replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
            if let fl = Double(clean), fl > 1.0 {
                fov = CoordinateConverter.calculateFOV(focalLength: fl)
            }
        }

        let pitch = doubleVal("pitch", "XMP-photools:Pitch", "XMP-Camera:Pitch", "Pitch")
        let roll = doubleVal("roll", "XMP-photools:Roll", "XMP-Camera:Roll", "Roll")
        let yaw = doubleVal("yaw", "XMP-photools:Yaw", "XMP-Camera:Yaw", "Yaw")

        // 视距建议与已保存 3D 视距还原
        let altitude = doubleVal("altitude", "Composite:GPSAltitude", "GPS:GPSAltitude", "GPSAltitude")
        let baseSuggestedDist = CoordinateConverter.suggestedDistance(
            focalLength35mm: focal35mm,
            focusDistanceMeters: nil,
            altitudeMeters: altitude,
            pitchDegrees: pitch
        )
        let savedViewDistance = doubleVal("view_distance", "XMP-photools:ViewDistance", "ViewDistance", "photools:ViewDistance")
        let finalSuggestedDist = savedViewDistance ?? baseSuggestedDist

        let desc: String = {
            if savedViewDistance != nil || pitch != nil {
                return "已保存的 3D 地图校准视角"
            }
            return heading != nil ? "标准 EXIF 电子罗盘" : "未记录罗盘数据"
        }()

        return CameraAttitude(
            heading: heading,
            headingRef: headingRef,
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            fov: fov,
            suggestedDistanceMeters: finalSuggestedDist,
            strategyName: "StandardExif",
            sourceDescription: desc
        )
    }
}
