import XCTest
@testable import PhotoolsMobileCore

final class HandshakeTests: XCTestCase {
    /// 使用尼康 Z50_2 实机抓包数据，验证 Salt 匹配与 Stage 3 回应生成
    func testCapturedStage2FindsSaltSixAndBuildsExpectedStage3() {
        let stage1 = PairingMessage(
            stage: 0x01,
            timestamp: 0x677da144ec13e1db,
            device: 0x3c3ae501,
            nonce: 0x3fdaa451
        )

        let stage2 = PairingMessage(
            stage: 0x02,
            timestamp: 0xb9943d5e8026fa29,
            device: 0xa8b3f2e4,
            nonce: 0x16d56a13
        )

        let engine = NikonSecurityEngine.shared
        guard let stage3 = engine.verifyStage2AndBuildStage3(stage1: stage1, stage2: stage2) else {
            XCTFail("未能匹配任何 Salt，握手失败")
            return
        }

        XCTAssertEqual(stage3.stage, 0x03)
        XCTAssertEqual(stage3.timestamp, stage1.timestamp)
        XCTAssertEqual(stage3.device, 0x79f1ad53)
        XCTAssertEqual(stage3.nonce, 0x23838a35)

        let encoded = stage3.encode()
        let expectedBytes: [UInt8] = [
            0x03,
            0xdb, 0xe1, 0x13, 0xec,
            0x44, 0xa1, 0x7d, 0x67,
            0x53, 0xad, 0xf1, 0x79,
            0x35, 0x8a, 0x83, 0x23
        ]

        XCTAssertEqual(encoded, Data(expectedBytes), "编码生成的 Stage 3 报文必须与真机捕获的 17 字节完全一致")
    }

    func testInvalidStage2RejectsGracefully() {
        let stage1 = PairingMessage(
            stage: 0x01,
            timestamp: 0x1122334455667788,
            device: 0x12345601,
            nonce: 0x87654321
        )

        // 构造一个不可能匹配的伪造 challenge
        let corruptedStage2 = PairingMessage(
            stage: 0x02,
            timestamp: 0x9988776655443322,
            device: 0xFFFFFFFF,
            nonce: 0x00000000
        )

        let engine = NikonSecurityEngine.shared
        let result = engine.verifyStage2AndBuildStage3(stage1: stage1, stage2: corruptedStage2)
        XCTAssertNil(result, "无法匹配 Salt 的非法挑战必须返回 nil")
    }

    /// 使用已验证的真机抓包样本报文进行 Blowfish 100% 字节级断言
    func testCapturedStage2FindsSaltAndBuildsExpectedStage3Vector2() {
        let stage1Bytes: [UInt8] = [
            0x01,
            0x74, 0x68, 0x66, 0xce, 0x72, 0x35, 0x9a, 0x16,
            0xc7, 0x95, 0xe7, 0x12,
            0x5b, 0x2e, 0x78, 0xc7
        ]
        let stage2Bytes: [UInt8] = [
            0x02,
            0x5d, 0xde, 0x36, 0x9c, 0x04, 0xe8, 0xf8, 0xa5,
            0xae, 0xce, 0x14, 0x92,
            0x25, 0x63, 0x8f, 0xa4
        ]
        let expectedStage3Bytes: [UInt8] = [
            0x03,
            0x74, 0x68, 0x66, 0xce, 0x72, 0x35, 0x9a, 0x16,
            0xc6, 0x2f, 0xb0, 0x36,
            0x80, 0x51, 0x83, 0xf3
        ]

        guard let stage1 = PairingMessage(data: Data(stage1Bytes)),
              let stage2 = PairingMessage(data: Data(stage2Bytes)) else {
            XCTFail("解析报文失败")
            return
        }

        let stage3 = NikonSecurityEngine.shared.verifyStage2AndBuildStage3(stage1: stage1, stage2: stage2)
        XCTAssertNotNil(stage3)
        XCTAssertEqual(stage3?.encode(), Data(expectedStage3Bytes), "Blowfish 算法计算结果必须与真机抓包字节完全一致！")
    }

    /// 验证状态机凭据热更新机制：防止会话复用时凭据缺失被相机秒踢
    func testStateMachineCredentialHotReloadingPreventsRandomDeviceID() {
        // 1. 模拟初始无凭据建立的状态机 (比如刚恢复或广播未匹配时)
        let sm = CameraStateMachine(savedDeviceID: nil, savedNonce: nil)
        XCTAssertNil(sm.savedDeviceID)
        XCTAssertNil(sm.savedNonce)

        let initialData = sm.startHandshake()
        guard let initialMsg = PairingMessage(data: initialData) else {
            XCTFail("无法解析初始 Stage 1 报文")
            return
        }
        // 无凭据时必须生成以 0x01 结尾的新配对随机 ID
        XCTAssertEqual(initialMsg.device & 0x000000FF, 0x01)

        // 2. 模拟随后通过 UserDefaults 恢复或外设重新发现匹配到真实凭据
        let knownDeviceID: UInt32 = 0x12345678
        let knownNonce: UInt32 = 0x87654321
        sm.updateCredentials(savedDeviceID: knownDeviceID, savedNonce: knownNonce)

        XCTAssertEqual(sm.savedDeviceID, knownDeviceID)
        XCTAssertEqual(sm.savedNonce, knownNonce)

        // 3. 重置并再次开始握手，断言必须使用已注入的真实凭据
        sm.reset()
        let updatedData = sm.startHandshake()
        guard let updatedMsg = PairingMessage(data: updatedData) else {
            XCTFail("无法解析更新后的 Stage 1 报文")
            return
        }
        XCTAssertEqual(updatedMsg.device, knownDeviceID, "热更新后 Stage 1 必须使用真实配对 Device ID，绝不能再随机生成！")
        XCTAssertEqual(updatedMsg.nonce, knownNonce, "热更新后 Stage 1 必须使用保存的 Nonce")
    }
    func testExpectedPeerStageTracksPendingAuthentication() {
        let machine = CameraStateMachine(savedDeviceID: 0x3c3ae501, savedNonce: 0x3fdaa451)
        // Use deterministic recorded input via the ordinary start handshake path's peer stage.
        XCTAssertNil(machine.expectedPeerStage)
        _ = machine.startHandshake()
        XCTAssertEqual(machine.expectedPeerStage, 2)
        machine.reset()
        XCTAssertNil(machine.expectedPeerStage)
    }

    func testStage4BeforeStage2DoesNotAuthenticate() {
        let machine = CameraStateMachine(savedDeviceID: 0x11223344, savedNonce: 0xAABBCCDD)
        _ = machine.startHandshake()
        let premature = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0)
        guard case .error = machine.handlePairDataReceived(premature.encode()) else {
            return XCTFail("Out-of-order Stage 4 must be rejected")
        }
        XCTAssertNotEqual(machine.state, .ready)
    }

    func testDuplicatePeerReplyIsIdempotent() {
        let machine = CameraStateMachine(savedDeviceID: 0x11223344, savedNonce: 0xAABBCCDD)
        let initial = machine.startHandshake()
        let timestamp = Array(initial[1..<9])
        func word(_ start: Int) -> UInt32 {
            timestamp[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let challenge = NikonSecurityEngine.shared.hash(blocks: [
            NikonSecurityEngine.salts[0][0], NikonSecurityEngine.salts[0][1],
            0x01020304, 0x05060708, word(0), word(4)
        ])!
        let second = PairingMessage(stage: 2, timestamp: 0x0807060504030201,
                                   device: challenge.left.byteSwapped, nonce: challenge.right.byteSwapped).encode()
        guard case .sendStage3 = machine.handlePairDataReceived(second) else {
            return XCTFail("Valid Stage 2 should produce Stage 3")
        }
        XCTAssertEqual(machine.expectedPeerStage, 4)
        XCTAssertEqual(machine.handlePairDataReceived(second), .wait)
        XCTAssertEqual(machine.expectedPeerStage, 4)
        let fourth = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0).encode()
        guard case .sendDeviceName = machine.handlePairDataReceived(fourth) else {
            return XCTFail("Stage 4 should advance to name configuration")
        }
        XCTAssertEqual(machine.handlePairDataReceived(fourth), .wait)
        XCTAssertNotEqual(machine.state, .ready)
    }

    func testFailedHandshakeRejectsLateStage4AndCanRestart() {
        let machine = CameraStateMachine(savedDeviceID: 0x11223344, savedNonce: 0xAABBCCDD)
        _ = machine.startHandshake()
        machine.fail(reason: "timeout")
        XCTAssertNil(machine.expectedPeerStage)
        let late = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0).encode()
        guard case .error = machine.handlePairDataReceived(late) else {
            return XCTFail("Late Stage 4 must not revive failed authentication")
        }
        machine.reset()
        _ = machine.startHandshake()
        XCTAssertEqual(machine.expectedPeerStage, 2)
    }

}
