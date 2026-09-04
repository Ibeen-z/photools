import Foundation

/// GPX 1.1 规范合法轨迹序列化引擎 (支持全量与流式分块极速导出)
public enum GPXExporter {

    /// 将会话与轨迹点序列化为标准 GPX 1.1 XML 文本 (内部采用 FastTimeFormatter 加速)
    public static func export(
        session: GPXTrackSession,
        points: [GPXRecordedPoint],
        creator: String = "NikonGPS for iOS"
    ) -> String {
        let estimatedCapacity = 512 + points.count * 220
        var xml = String()
        xml.reserveCapacity(estimatedCapacity)

        xml += """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escapeXML(creator))"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(session.sessionName))</name>
            <desc>NikonGPS for iOS 摄影巡航轨迹记录</desc>
            <time>\(FastTimeFormatter.formatUTCISO8601(date: session.startTime))</time>
          </metadata>
          <trk>
            <name>\(escapeXML(session.sessionName))</name>
            <trkseg>

        """

        for pt in points {
            xml += "      <trkpt lat=\"\(String(format: "%.6f", pt.latitude))\" lon=\"\(String(format: "%.6f", pt.longitude))\">\n"
            if let ele = pt.elevation {
                xml += "        <ele>\(String(format: "%.2f", ele))</ele>\n"
            }
            xml += "        <time>\(FastTimeFormatter.formatUTCISO8601(date: pt.timestamp))</time>\n"
            if let spd = pt.speed, spd >= 0 {
                xml += "        <speed>\(String(format: "%.2f", spd))</speed>\n"
            }
            if let course = pt.course, course >= 0 {
                xml += "        <course>\(String(format: "%.1f", course))</course>\n"
            }
            if pt.horizontalAccuracy > 0 {
                xml += "        <hdop>\(String(format: "%.1f", pt.horizontalAccuracy))</hdop>\n"
            }
            xml += "      </trkpt>\n"
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>
        """

        return xml
    }

    /// 超长距离流式分块写入目标文件 (内存恒定在 64KB 以内，杜绝数万点产生的数十 MB 内存震荡与主线程挂起)
    public static func exportStream(
        session: GPXTrackSession,
        points: [GPXRecordedPoint],
        to destinationURL: URL,
        creator: String = "NikonGPS for iOS"
    ) throws {
        // 若目标文件已存在先移除
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        guard let outputStream = OutputStream(url: destinationURL, append: false) else {
            throw NSError(domain: "com.vincentchyu.photools.mobile.gpx", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法打开输出流"])
        }

        outputStream.open()
        defer { outputStream.close() }

        func flushBuffer(_ data: inout Data) throws {
            guard !data.isEmpty else { return }
            let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return outputStream.write(baseAddress, maxLength: data.count)
            }
            if bytesWritten < data.count {
                throw NSError(domain: "com.vincentchyu.photools.mobile.gpx", code: -2, userInfo: [NSLocalizedDescriptionKey: "写入输出流失败"])
            }
            data.removeAll(keepingCapacity: true)
        }

        var buffer = Data()
        buffer.reserveCapacity(65536) // 64KB 缓冲区

        // 1. XML 头部
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escapeXML(creator))"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(session.sessionName))</name>
            <desc>NikonGPS for iOS 摄影巡航轨迹记录</desc>
            <time>\(FastTimeFormatter.formatUTCISO8601(date: session.startTime))</time>
          </metadata>
          <trk>
            <name>\(escapeXML(session.sessionName))</name>
            <trkseg>

        """
        if let headerData = header.data(using: .utf8) {
            buffer.append(headerData)
        }

        // 2. 逐点写入分块缓冲区
        for pt in points {
            var ptStr = "      <trkpt lat=\"\(String(format: "%.6f", pt.latitude))\" lon=\"\(String(format: "%.6f", pt.longitude))\">\n"
            if let ele = pt.elevation {
                ptStr += "        <ele>\(String(format: "%.2f", ele))</ele>\n"
            }
            ptStr += "        <time>\(FastTimeFormatter.formatUTCISO8601(date: pt.timestamp))</time>\n"
            if let spd = pt.speed, spd >= 0 {
                ptStr += "        <speed>\(String(format: "%.2f", spd))</speed>\n"
            }
            if let course = pt.course, course >= 0 {
                ptStr += "        <course>\(String(format: "%.1f", course))</course>\n"
            }
            if pt.horizontalAccuracy > 0 {
                ptStr += "        <hdop>\(String(format: "%.1f", pt.horizontalAccuracy))</hdop>\n"
            }
            ptStr += "      </trkpt>\n"

            if let ptData = ptStr.data(using: .utf8) {
                buffer.append(ptData)
            }

            // 缓冲区超过 64KB 时刷新至磁盘
            if buffer.count >= 65536 {
                try flushBuffer(&buffer)
            }
        }

        // 3. XML 尾部
        let footer = """
            </trkseg>
          </trk>
        </gpx>
        """
        if let footerData = footer.data(using: .utf8) {
            buffer.append(footerData)
        }

        // 最终刷盘
        try flushBuffer(&buffer)
    }

    /// XML 实体字符安全转义
    public static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
