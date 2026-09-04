import XCTest
@testable import PhotoolsMobileCore

final class PairingMessageTests: XCTestCase {
    func testPairingMessageSerializationAndDeserialization() {
        let msg = PairingMessage(
            stage: 0x01,
            timestamp: 0x1122334455667788,
            device: 0x12345678,
            nonce: 0x87654321
        )

        let encoded = msg.encode()
        XCTAssertEqual(encoded.count, 17)
        XCTAssertEqual(encoded[0], 0x01)

        guard let decoded = PairingMessage(data: encoded) else {
            XCTFail("无法反序列化 PairingMessage")
            return
        }

        XCTAssertEqual(decoded, msg)
    }

    func testCreateStage1EnsuresLSBIsOneForNewPairing() {
        for _ in 0..<100 {
            let stage1 = PairingMessage.createStage1()
            XCTAssertEqual(stage1.stage, 0x01)
            XCTAssertEqual(stage1.device & 0xFF, 0x01, "新配对的 deviceID 最低有效位必须恒为 0x01")
        }
    }

    func testCreateStage1WithExistingDeviceID() {
        let savedID: UInt32 = 0x88776655
        let savedNonce: UInt32 = 0x44332211
        let stage1 = PairingMessage.createStage1(deviceID: savedID, nonce: savedNonce)

        XCTAssertEqual(stage1.stage, 0x01)
        XCTAssertEqual(stage1.device, savedID)
        XCTAssertEqual(stage1.nonce, savedNonce)
    }

    func testTruncatedDataReturnsNil() {
        let shortData = Data([0x01, 0x02, 0x03])
        XCTAssertNil(PairingMessage(data: shortData))
    }

    /// 验证尼康广播 Manufacturer Data 状态字节 (第 7 字节) 位判断逻辑:
    /// - 0x1D (最低位 Bit 0 == 1): 相机处于待机休眠深睡心跳态
    /// - 0x1C (最低位 Bit 0 == 0): 相机处于开机/快门唤醒就绪态
    func testNikonAdvertisementStatusByteDiscrimination() {
        let standbyByte: UInt8 = 0x1D // 0b00011101
        let awakeByte: UInt8 = 0x1C   // 0b00011100

        XCTAssertTrue((standbyByte & 0x01) != 0, "0x1D 最低位必须为 1，判定为待机深睡广播")
        XCTAssertFalse((standbyByte & 0x01) == 0, "0x1D 严禁误判为唤醒就绪")

        XCTAssertTrue((awakeByte & 0x01) == 0, "0x1C 最低位必须为 0，判定为开机/快门唤醒就绪广播")
        XCTAssertFalse((awakeByte & 0x01) != 0, "0x1C 严禁误判为休眠")
    }
}
