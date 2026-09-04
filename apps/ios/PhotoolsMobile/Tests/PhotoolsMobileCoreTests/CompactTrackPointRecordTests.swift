import XCTest
@testable import PhotoolsMobileCore

final class CompactTrackPointRecordTests: XCTestCase {

    func testExact32BytesRecordSize() {
        XCTAssertEqual(CompactTrackPointRecord.recordSize, 32)
        let pt = GPXRecordedPoint(
            latitude: 31.2304123,
            longitude: 121.4737456,
            elevation: 18.5,
            timestamp: Date(timeIntervalSince1970: 1776000000),
            horizontalAccuracy: 4.8,
            speed: 1.25,
            course: 185.5
        )
        let record = CompactTrackPointRecord(point: pt)
        let data = record.serialize()
        XCTAssertEqual(data.count, 32, "序列化后的单点数据必须严格等于 32 字节")
    }

    func testLosslessRoundtripConversion() {
        let originalTime = Date(timeIntervalSince1970: 1776000123.456)
        let original = GPXRecordedPoint(
            latitude: 43.1234567,
            longitude: 82.6543219,
            elevation: 2150.75,
            timestamp: originalTime,
            horizontalAccuracy: 3.25,
            speed: 2.45,
            course: 270.3
        )

        let record = CompactTrackPointRecord(point: original)
        let serialized = record.serialize()
        guard let deserialized = CompactTrackPointRecord.deserialize(from: serialized) else {
            XCTFail("反序列化失败")
            return
        }

        let recovered = deserialized.toRecordedPoint()

        // 经纬度保留 7 位小数（厘米级），误差 < 1e-6
        XCTAssertEqual(recovered.latitude, original.latitude, accuracy: 0.0000002)
        XCTAssertEqual(recovered.longitude, original.longitude, accuracy: 0.0000002)
        // 海拔保留厘米，误差 < 0.01m
        XCTAssertEqual(recovered.elevation!, original.elevation!, accuracy: 0.01)
        // 时间戳毫秒对齐，误差 < 0.002s
        XCTAssertEqual(recovered.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 0.002)
        // 精度、速度、航向
        XCTAssertEqual(recovered.horizontalAccuracy, original.horizontalAccuracy, accuracy: 0.01)
        XCTAssertEqual(recovered.speed!, original.speed!, accuracy: 0.01)
        XCTAssertEqual(recovered.course!, original.course!, accuracy: 0.1)
    }

    func testNegativeCoordinatesAndNilOptionals() {
        let original = GPXRecordedPoint(
            latitude: -45.1234567,
            longitude: -75.9876543,
            elevation: nil,
            timestamp: Date(timeIntervalSince1970: 1776000000),
            horizontalAccuracy: 12.0,
            speed: nil,
            course: nil
        )

        let record = CompactTrackPointRecord(point: original)
        let data = record.serialize()
        let recovered = CompactTrackPointRecord.deserialize(from: data)!.toRecordedPoint()

        XCTAssertEqual(recovered.latitude, original.latitude, accuracy: 0.0000002)
        XCTAssertEqual(recovered.longitude, original.longitude, accuracy: 0.0000002)
        XCTAssertNil(recovered.elevation, "未设置海拔时恢复必须为 nil")
        XCTAssertNil(recovered.speed, "未设置速度时恢复必须为 nil")
        XCTAssertNil(recovered.course, "未设置航向时恢复必须为 nil")
        XCTAssertEqual(recovered.horizontalAccuracy, 12.0, accuracy: 0.01)
    }

    func testBatchDeserializeAll() {
        var points: [GPXRecordedPoint] = []
        var buffer = Data()
        let now = Date()

        for i in 0..<100 {
            let pt = GPXRecordedPoint(
                latitude: 30.0 + Double(i) * 0.001,
                longitude: 120.0 + Double(i) * 0.001,
                elevation: 100.0 + Double(i),
                timestamp: now.addingTimeInterval(Double(i)),
                horizontalAccuracy: 5.0
            )
            points.append(pt)
            let rec = CompactTrackPointRecord(point: pt)
            buffer.append(rec.serialize())
        }

        XCTAssertEqual(buffer.count, 100 * 32)
        let recoveredList = CompactTrackPointRecord.deserializeAll(from: buffer)
        XCTAssertEqual(recoveredList.count, 100)

        for (orig, rec) in zip(points, recoveredList) {
            XCTAssertEqual(rec.latitude, orig.latitude, accuracy: 0.0000002)
            XCTAssertEqual(rec.longitude, orig.longitude, accuracy: 0.0000002)
        }
    }
}
