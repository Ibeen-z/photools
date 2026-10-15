import Foundation

/// 从用户主动选择的 PacketLogger 文件中提取已经完成四阶段认证的身份。
/// 仅处理 HCI ACL 的 ATT 固定信道；不猜测 Nonce，不上传抓包。
public enum NikonCaptureCredentials {
    private struct Session {
        let attribute: UInt16
        let stage1: PairingMessage
        var expectedStage3: Data?
        var responseMatched = false
    }

    public static func extract(from data: Data, cameraName: String, deviceID: UInt32) throws -> CameraCredentialConfig {
        guard data.count <= 64 * 1024 * 1024 else {
            throw CredentialImportError.invalid("抓包超过 64 MB，请导入仅包含一次 SnapBridge 重连的蓝牙抓包")
        }
        let bytes = [UInt8](data)
        var offset = 0
        var sessions: [UInt16: Session] = [:]
        var buffers: [String: [UInt8]] = [:]
        var readAttributes: [UInt16: UInt16] = [:]

        func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
            UInt16(b[i]) | UInt16(b[i + 1]) << 8
        }

        while offset + 13 <= bytes.count {
            // pklg: record length BE32, seconds BE32, microseconds BE32, type U8.
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            guard length >= 9, length <= bytes.count - offset - 4 else {
                throw CredentialImportError.invalid("PacketLogger 文件不完整或格式不受支持")
            }
            let type = bytes[offset + 12]
            let packet = Array(bytes[(offset + 13)..<(offset + 4 + length)])
            offset += 4 + length
            if type == 1, packet.count >= 6, packet[0] == 0x05 {
                let disconnected = le16(packet, 3) & 0x0FFF
                sessions.removeValue(forKey: disconnected)
                readAttributes.removeValue(forKey: disconnected)
                buffers.removeValue(forKey: "2:\(disconnected)")
                buffers.removeValue(forKey: "3:\(disconnected)")
                continue
            }
            guard type == 2 || type == 3, packet.count >= 4 else { continue }
            let header = le16(packet, 0)
            let connection = header & 0x0FFF
            let aclLength = Int(le16(packet, 2))
            guard aclLength == packet.count - 4 else { continue }
            let key = "\(type):\(connection)"
            let payload = Array(packet.dropFirst(4))
            if header & 0x3000 == 0x1000 {
                guard buffers[key] != nil else { continue }
                buffers[key]?.append(contentsOf: payload)
            } else {
                buffers[key] = payload
            }
            guard let buffer = buffers[key], buffer.count >= 4 else { continue }
            let l2Length = Int(le16(buffer, 0))
            guard buffer.count >= l2Length + 4 else { continue }
            buffers.removeValue(forKey: key)
            guard le16(buffer, 2) == 4 else { continue }
            let att = Array(buffer[4..<(l2Length + 4)])
            guard let opcode = att.first else { continue }

            if type == 2, opcode == 0x0A, att.count == 3 {
                readAttributes[connection] = le16(att, 1)
                continue
            }

            if type == 2, (opcode == 0x12 || opcode == 0x52), att.count == 20 {
                let attribute = le16(att, 1)
                let value = Data(att.dropFirst(3))
                guard let message = PairingMessage(data: value) else { continue }
                if message.stage == 1 {
                    sessions.removeValue(forKey: connection)
                    readAttributes.removeValue(forKey: connection)
                    if message.device == deviceID {
                        sessions[connection] = Session(attribute: attribute, stage1: message)
                    }
                } else if message.stage == 3, var session = sessions[connection], session.attribute == attribute {
                    session.responseMatched = session.expectedStage3 == value
                    sessions[connection] = session
                }
                continue
            }

            guard type == 3, var session = sessions[connection] else { continue }
            let attribute: UInt16?
            let value: Data
            if (opcode == 0x1B || opcode == 0x1D), att.count == 20 {
                attribute = le16(att, 1)
                value = Data(att.dropFirst(3))
            } else if opcode == 0x0B, att.count == 18 {
                attribute = readAttributes.removeValue(forKey: connection)
                value = Data(att.dropFirst())
            } else {
                continue
            }
            guard attribute == session.attribute, let message = PairingMessage(data: value) else { continue }
            if message.stage == 2 {
                let expected = NikonSecurityEngine.shared.verifyStage2AndBuildStage3(
                    stage1: session.stage1, stage2: message
                )?.encode()
                if expected != session.expectedStage3 { session.responseMatched = false }
                session.expectedStage3 = expected
                sessions[connection] = session
            } else if message.stage == 4, session.responseMatched {
                return CameraCredentialConfig(
                    name: cameraName,
                    deviceID: String(format: "0x%08X", session.stage1.device),
                    nonce: String(format: "0x%08X", session.stage1.nonce),
                    isDefault: true,
                    comment: "本机从完整四阶段抓包提取，Stage 2/3 加密校验通过；仍需重新连接确认"
                )
            }
        }
        throw CredentialImportError.invalid("未找到此相机完整且校验通过的四阶段握手。请用官方 SnapBridge 成功重连后重新抓包；不能使用本 App 的失败日志")
    }
}
