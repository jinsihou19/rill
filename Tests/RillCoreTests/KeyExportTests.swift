import XCTest
import CryptoKit
@testable import RillCore

final class ExportBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var writes = 0
    var failAfter: Int?
    init(failAfter: Int? = nil) { self.failAfter = failAfter }
    func write(_ data: Data) throws {
        try lock.withLock {
            writes += 1
            if let failAfter, writes > failAfter { throw RedisError.message("Synthetic disk full") }
            chunks.append(data)
        }
    }
    var data: Data { lock.withLock { chunks.reduce(Data(), +) } }
}
func decodeExport(_ data: Data) throws -> [KeyExportLine] {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: 10).map { try decoder.decode(KeyExportLine.self, from: Data($0)) }
}
func exportDigest(_ data: Data) -> String {
    let lines = data.split(separator: 10)
    var digest = SHA256()
    for line in lines.dropLast() { var data = Data(line); data.append(10); digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
final class KeyExportTests: XCTestCase {
    func testSchemaRoundTripPreservesEmptyBinaryFieldsScoresAndRepeatedStreamPairs() throws {
        let entry = KeyExportEntry(offset: 0, field: Data(), value: Data([0, 255]), score: "1.2345678901234567", streamFields: [Data(), Data([255]), Data(), Data()])
        let encoded = try JSONEncoder().encode(KeyExportLine(record: .entry, entry: entry))
        let decoded = try JSONDecoder().decode(KeyExportLine.self, from: encoded)
        XCTAssertEqual(decoded.entry?.field, Data()); XCTAssertEqual(decoded.entry?.value, Data([0, 255]))
        XCTAssertEqual(decoded.entry?.streamFields, entry.streamFields); XCTAssertEqual(decoded.entry?.score, entry.score)
    }
}
