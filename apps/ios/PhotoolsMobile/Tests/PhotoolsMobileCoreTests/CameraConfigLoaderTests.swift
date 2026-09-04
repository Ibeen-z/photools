import XCTest
@testable import PhotoolsMobileCore

final class CameraConfigLoaderTests: XCTestCase {

    func testHexAndDecimalStringParsing() {
        let entryHex = CameraCredentialConfig(
            name: "Test Z6 III",
            deviceID: "0x12345678",
            nonce: "0x87654321",
            controllerName: "iPhone_NikonGPS",
            isDefault: true
        )

        XCTAssertEqual(entryHex.parsedDeviceID, 0x12345678)
        XCTAssertEqual(entryHex.parsedNonce, 0x87654321)

        let device = entryHex.toCameraDevice()
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.name, "Test Z6 III")
        XCTAssertEqual(device?.deviceID, 0x12345678)
        XCTAssertEqual(device?.nonce, 0x87654321)
        XCTAssertEqual(device?.isDefault, true)

        let entryDec = CameraCredentialConfig(
            name: "Test Decimal",
            deviceID: "305419896",
            nonce: "2271560481"
        )
        XCTAssertEqual(entryDec.parsedDeviceID, 0x12345678)
        XCTAssertEqual(entryDec.parsedNonce, 0x87654321)
    }

    func testLoadFromJSONData() throws {
        let json = """
        {
          "cameras": [
            {
              "name": "Nikon Z6 III (1234567)",
              "deviceID": "0x12345678",
              "nonce": "0x87654321",
              "controllerName": "iPhone_NikonGPS",
              "isDefault": true,
              "comment": "由抓包自动化提取"
            }
          ]
        }
        """

        let data = Data(json.utf8)
        let loader = CameraConfigLoader()
        let cameras = try loader.load(from: data)

        XCTAssertEqual(cameras.count, 1)
        XCTAssertEqual(cameras[0].name, "Nikon Z6 III (1234567)")
        XCTAssertEqual(cameras[0].deviceID, 0x12345678)
        XCTAssertEqual(cameras[0].nonce, 0x87654321)
        XCTAssertEqual(cameras[0].isDefault, true)
    }

    func testPreconfiguredFileLoading() {
        let loader = CameraConfigLoader.shared
        let cameras = loader.loadPreconfiguredCameras()

        XCTAssertFalse(cameras.isEmpty, "必须能够成功探测并加载 camera_credentials.json 或其示例模板")
        guard let firstCam = cameras.first else {
            XCTFail("无法解析出有效相机实体")
            return
        }
        XCTAssertFalse(firstCam.name.isEmpty, "相机名称不可为空")
        XCTAssertGreaterThan(firstCam.deviceID, 0, "DeviceID 必须为有效的 4 字节正整数")
        XCTAssertGreaterThan(firstCam.nonce, 0, "Nonce 必须为有效的 4 字节正整数")

        let defCreds = loader.defaultCredentials()
        XCTAssertNotNil(defCreds, "默认凭据元组必须有效")
        if let creds = defCreds {
            XCTAssertGreaterThan(creds.deviceID, 0)
            XCTAssertGreaterThan(creds.nonce, 0)
            XCTAssertFalse(creds.controllerName.isEmpty)
        }
    }
}
