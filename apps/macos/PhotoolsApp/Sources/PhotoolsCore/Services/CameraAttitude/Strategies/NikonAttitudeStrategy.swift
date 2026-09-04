import Foundation

/// 尼康 (Nikon) 专业单反/微单专属姿态与朝向策略 (Nikon Attitude Strategy)
/// 支持提取尼康机身内部五轴防抖传感器与电子水平仪姿态 (PitchAngle / RollAngle / YawAngle)
public struct NikonAttitudeStrategy: CameraAttitudeStrategy, Sendable {
    public let id: String = "nikon_attitude"
    public let priority: Int = 40

    public init() {}

    public func canHandle(make: String?, model: String?, dict: [String: Any]) -> Bool {
        if let m = make?.lowercased(), m.contains("nikon") {
            return true
        }
        if dict["MakerNotes:PitchAngle"] != nil || dict["MakerNotes:YawAngle"] != nil {
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
        )

        // 尼康机内五轴防抖与电子水平仪倾角 (MakerNotes 或 XMP-photools/XMP-Camera 闭环数据)
        let pitch = doubleVal(
            "pitch_angle", "MakerNotes:PitchAngle", "PitchAngle",
            "XMP-photools:Pitch", "XMP-Camera:Pitch", "Pitch"
        )
        let roll = doubleVal(
            "roll_angle", "MakerNotes:RollAngle", "RollAngle",
            "XMP-photools:Roll", "XMP-Camera:Roll", "Roll"
        )
        let yaw = doubleVal(
            "yaw_angle", "MakerNotes:YawAngle", "YawAngle",
            "XMP-Camera:Yaw", "Yaw"
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

        // 提取物理对焦距离（如 "17.4 m" -> 17.4）
        let focusDistStr = strVal("focus_distance", "MakerNotes:FocusDistance", "FocusDistance")
        let focusDistMeters: Double? = {
            guard let s = focusDistStr else { return nil }
            let clean = s.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            if let d = Double(clean), d > 0.1 {
                return d
            }
            return nil
        }()

        // 机位海拔
        let altitude = doubleVal("altitude", "Composite:GPSAltitude", "GPS:GPSAltitude", "GPSAltitude", "XMP:GPSAltitude")

        // 智能视距（结合物理对焦距离、海拔与俯仰角高空远眺模型）
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
            if heading != nil && pitch != nil {
                return "尼康外置 GPS 罗盘 + 机内水平仪仰角"
            } else if heading != nil {
                return "尼康 GPS 罗盘朝向"
            } else if pitch != nil {
                return "尼康机内五轴防抖水平仪 (仰角已校正)"
            }
            return "尼康光学拍摄数据 (无罗盘)"
        }()

        return CameraAttitude(
            heading: heading,
            headingRef: headingRef,
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            fov: fov,
            focusDistanceMeters: focusDistMeters,
            suggestedDistanceMeters: finalSuggestedDist,
            strategyName: "NikonAttitude",
            sourceDescription: desc
        )
    }
}
