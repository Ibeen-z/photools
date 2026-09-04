import XCTest
@testable import PhotoolsMobileCore

final class BlowfishTests: XCTestCase {
    func testBlowfishInitializationAndEncryption() {
        let key = NikonSecurityEngine.key
        let bf = Blowfish(key: key)

        // 测试对称块加密
        let (outL, outR) = bf.encryptBlock(left: 0x01020304, right: 0x05060708)
        XCTAssertNotEqual(outL, 0x01020304)
        XCTAssertNotEqual(outR, 0x05060708)

        // 验证确定性：相同输入必须产出完全相同输出
        let (outL2, outR2) = bf.encryptBlock(left: 0x01020304, right: 0x05060708)
        XCTAssertEqual(outL, outL2)
        XCTAssertEqual(outR, outR2)
    }

    func testBlowfish8ByteDataEncryption() {
        let key = NikonSecurityEngine.key
        let bf = Blowfish(key: key)

        let input = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let encrypted = bf.encrypt(data: input)
        XCTAssertEqual(encrypted.count, 8)
        XCTAssertNotEqual(encrypted, input)
    }
}
