import XCTest
@testable import PhotoolsCore

final class PhotoAssetGroupTests: XCTestCase {
    func testRawAndJpgPairIsReady() {
        let group = PhotoAssetGroup(
            id: "/inbox::a001",
            baseName: "A001",
            directory: "/inbox",
            rawPath: "/inbox/A001.NEF",
            jpgPath: "/inbox/A001.JPG",
            xmpPath: "/inbox/A001.xmp",
            companionPaths: ["/inbox/A001.wav", "/inbox/A001.xmp"]
        )

        XCTAssertEqual(group.status, .ready)
        XCTAssertEqual(group.primaryType, .rawPair)
        XCTAssertEqual(group.primaryPath, "/inbox/A001.NEF")
        XCTAssertEqual(group.allFiles, ["/inbox/A001.NEF", "/inbox/A001.JPG", "/inbox/A001.wav", "/inbox/A001.xmp"])
    }

    func testRawOnlyIsReady() {
        let group = PhotoAssetGroup(
            id: "/inbox::b001",
            baseName: "B001",
            directory: "/inbox",
            rawPath: "/inbox/B001.NEF",
            jpgPath: nil,
            xmpPath: nil,
            companionPaths: []
        )

        XCTAssertEqual(group.status, .ready)
        XCTAssertEqual(group.primaryType, .rawOnly)
        XCTAssertEqual(group.primaryPath, "/inbox/B001.NEF")
    }

    func testJpgOnlyIsReady() {
        let group = PhotoAssetGroup(
            id: "/inbox::c001",
            baseName: "C001",
            directory: "/inbox",
            rawPath: nil,
            jpgPath: "/inbox/C001.JPG",
            xmpPath: nil,
            companionPaths: []
        )

        XCTAssertEqual(group.status, .ready)
        XCTAssertEqual(group.primaryType, .jpgOnly)
        XCTAssertEqual(group.primaryPath, "/inbox/C001.JPG")
    }

    func testCompanionOnlyIsNotReady() {
        let group = PhotoAssetGroup(
            id: "/inbox::d001",
            baseName: "D001",
            directory: "/inbox",
            rawPath: nil,
            jpgPath: nil,
            xmpPath: "/inbox/D001.xmp",
            companionPaths: ["/inbox/D001.xmp"]
        )

        XCTAssertEqual(group.status, .companionOnly)
        XCTAssertEqual(group.primaryType, .companionOnly)
        XCTAssertNil(group.primaryPath)
    }

    func testCaptureDateAndEffectiveDate() {
        let modDate = Date(timeIntervalSince1970: 1000)
        let capDate = Date(timeIntervalSince1970: 2000)

        var group = PhotoAssetGroup(
            id: "/inbox::e001",
            baseName: "E001",
            directory: "/inbox",
            rawPath: "/inbox/E001.NEF",
            jpgPath: nil,
            xmpPath: nil,
            companionPaths: [],
            fileModificationDate: modDate
        )

        XCTAssertNil(group.captureDate)
        XCTAssertEqual(group.effectiveDate, modDate)

        let updated = group.withCaptureDate(capDate)
        XCTAssertEqual(updated.captureDate, capDate)
        XCTAssertEqual(updated.effectiveDate, capDate)
    }

    func testSortFieldAndOrderProperties() {
        XCTAssertEqual(PhotoSortField.allCases.count, 3)
        XCTAssertEqual(PhotoSortOrder.allCases.count, 2)
        XCTAssertFalse(PhotoSortField.captureDate.iconName.isEmpty)
        XCTAssertFalse(PhotoSortOrder.descending.iconName.isEmpty)
    }
}
