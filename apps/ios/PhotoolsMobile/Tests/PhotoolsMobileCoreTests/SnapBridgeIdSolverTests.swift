import XCTest
@testable import PhotoolsMobileCore

final class SnapBridgeIdSolverTests: XCTestCase {

    func testNextBytesMatchesVerifiedJavaOutput() {
        // Verified on a JVM: new Random(1785587115763L).nextBytes(8) -> "48ee2fc1f03fcf17"
        let data = SnapBridgeIdSolver.nextBytes(seed: 1785587115763, count: 8)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "48ee2fc1f03fcf17")
    }

    func testSolvedSeedsContainTheRealPairingSeed() {
        // The camera advertises 44 5d 4b 24 (LE uint32 = 0x244B5D44). The seed that
        // actually produced the working DeviceID was the first SnapBridge launch:
        // 2026-04-25 20:37:21 = 1777120641934.
        let seeds = SnapBridgeIdSolver.solveSeeds(targetDevice: 0x244B5D44)
        XCTAssertTrue(seeds.contains(1777120641934))
        XCTAssertTrue(seeds.contains(1782432516591))
    }

    func testCandidatesFilteredByTimeWindow() {
        let candidates = SnapBridgeIdSolver.candidatesFor(
            targetDevice: 0x244B5D44,
            windowStartMs: 1777120641934 - 1000,
            windowEndMs: 1777120641934 + 1000
        )
        XCTAssertEqual(candidates.map { $0.seed }, [1777120641934])
        guard let single = candidates.first else {
            XCTFail("应当匹配到候选")
            return
        }
        XCTAssertEqual(single.fullHex, "445d4b24981064f7")
        XCTAssertEqual(single.deviceID, 0x244B5D44)
        // 后 4 字节 98 10 64 f7 (LE uint32: 0xF7641098)
        XCTAssertEqual(single.nonce, 0xF7641098)
    }
}
