import XCTest
@testable import PhotoolsMobileCore

final class NikonCaptureCredentialsTests: XCTestCase {
    private let device: UInt32 = 0x11223344
    private let nonce: UInt32 = 0xAABBCCDD

    private func record(_ type: UInt8, _ payload: [UInt8]) -> Data {
        let length = UInt32(payload.count + 9)
        var bytes: [UInt8] = [UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]
        bytes += Array(repeating: 0, count: 8)
        bytes += [type] + payload
        return Data(bytes)
    }

    private func att(_ type: UInt8, _ value: [UInt8], fragmented: Bool = false) -> Data {
        let length = value.count
        let l2: [UInt8] = [UInt8(length & 255), UInt8(length >> 8), 4, 0] + value
        func acl(_ header: UInt8, _ body: [UInt8]) -> Data {
            record(type, [1, header, UInt8(body.count & 255), UInt8(body.count >> 8)] + body)
        }
        if fragmented {
            return acl(0x20, Array(l2.prefix(10))) + acl(0x10, Array(l2.dropFirst(10)))
        }
        return acl(0x20, l2)
    }

    private func capture(corrupt: Bool = false, final: Bool = true, read: Bool = false, fragment: Bool = false) -> Data {
        let first = PairingMessage(stage: 1, timestamp: 0x1122334455667788, device: device, nonce: nonce)
        // Construct a valid peer challenge using the public Nikon protocol salts.
        let response = NikonSecurityEngine.shared.hash(blocks: [
            NikonSecurityEngine.salts[0][0], NikonSecurityEngine.salts[0][1],
            0x01020304, 0x05060708, 0x88776655, 0x44332211
        ])!
        let second = PairingMessage(stage: 2, timestamp: 0x0807060504030201,
                                   device: response.left.byteSwapped, nonce: response.right.byteSwapped)
        var third = NikonSecurityEngine.shared.verifyStage2AndBuildStage3(stage1: first, stage2: second)!.encode()
        if corrupt { third[third.count - 1] ^= 1 }
        let fourth = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0)
        var result = att(2, [0x12, 0x10, 0] + Array(first.encode()))
        if read {
            result += att(2, [0x0A, 0x10, 0])
            result += att(3, [0x0B] + Array(second.encode()), fragmented: fragment)
        } else {
            result += att(3, [0x1D, 0x10, 0] + Array(second.encode()), fragmented: fragment)
        }
        result += att(2, [0x12, 0x10, 0] + Array(third))
        if final {
            if read {
                result += att(2, [0x0A, 0x10, 0])
                result += att(3, [0x0B] + Array(fourth.encode()))
            } else {
                result += att(3, [0x1D, 0x10, 0] + Array(fourth.encode()))
            }
        }
        return result
    }

    func testVerifiedNotificationCaptureExtractsCredentials() throws {
        let found = try NikonCaptureCredentials.extract(from: capture(), cameraName: "Nikon Test", deviceID: device)
        XCTAssertEqual(found.parsedDeviceID, device)
        XCTAssertEqual(found.parsedNonce, nonce)
    }

    func testReadResponsesAndFragmentedACLCanBeExtracted() throws {
        let found = try NikonCaptureCredentials.extract(from: capture(read: true, fragment: true), cameraName: "Nikon Test", deviceID: device)
        XCTAssertEqual(found.parsedNonce, nonce)
    }

    func testCorruptedStage3AndMissingStage4AreRejected() {
        for data in [capture(corrupt: true), capture(final: false)] {
            XCTAssertThrowsError(try NikonCaptureCredentials.extract(from: data, cameraName: "Nikon Test", deviceID: device))
        }
    }

    func testWrongCameraAndTruncatedCaptureAreRejected() {
        XCTAssertThrowsError(try NikonCaptureCredentials.extract(from: capture(), cameraName: "Other Camera", deviceID: 0x55667788))
        XCTAssertThrowsError(try NikonCaptureCredentials.extract(from: Data(capture().dropLast(8)), cameraName: "Nikon Test", deviceID: device))
    }
    func testNewIdentityCannotCompleteAnOldPartialHandshake() {
        let other = PairingMessage(stage: 1, timestamp: 0, device: 0x55667788, nonce: 0)
        let fourth = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0)
        let combined = capture(final: false)
            + att(2, [0x12, 0x10, 0] + Array(other.encode()))
            + att(3, [0x1D, 0x10, 0] + Array(fourth.encode()))
        XCTAssertThrowsError(try NikonCaptureCredentials.extract(from: combined, cameraName: "Nikon Test", deviceID: device))
    }

    func testDisconnectedHandleCannotCompleteAnOldPartialHandshake() {
        let fourth = PairingMessage(stage: 4, timestamp: 0, device: 0, nonce: 0)
        let combined = capture(final: false)
            + record(1, [0x05, 0x04, 0, 1, 0, 0x13])
            + att(3, [0x1D, 0x10, 0] + Array(fourth.encode()))
        XCTAssertThrowsError(try NikonCaptureCredentials.extract(from: combined, cameraName: "Nikon Test", deviceID: device))
    }

}
