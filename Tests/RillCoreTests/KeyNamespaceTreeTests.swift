import XCTest
import Darwin
@testable import RillCore

final class KeyNamespaceTreeTests: XCTestCase {
    private func leaves(_ nodes: [KeyNamespaceNode]) -> [Data] {
        nodes.flatMap { $0.isFolder ? leaves($0.children) : [$0.bytes] }
    }
    private func nodes(_ roots: [KeyNamespaceNode]) -> [KeyNamespaceNode] { roots.flatMap { [$0] + nodes($0.children) } }
    func testPrefixKeysEmptySegmentsAndBinaryIdentitiesNeverCollide() {
        let keys = ["a", "a:b", "a:", "a::b", "a*b:x", "中文:键", "0xff", ""].map { Data($0.utf8) } + [Data([255]), Data([255, 58, 0])]
        let tree = KeyNamespaceTree.build(keys + [keys[0]])
        XCTAssertEqual(Set(leaves(tree.roots)), Set(keys)); XCTAssertEqual(leaves(tree.roots).count, keys.count)
        let all = nodes(tree.roots)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.contains { $0.isFolder && $0.bytes == Data("a:".utf8) })
        XCTAssertTrue(all.contains { !$0.isFolder && $0.bytes == Data("a:".utf8) })
        XCTAssertTrue(all.contains { $0.isFolder && $0.label == "（空分段）" })
        XCTAssertTrue(all.contains { $0.bytes == Data([255]) && $0.binaryLabel })
        XCTAssertTrue(all.contains { $0.bytes == Data("0xff".utf8) && !$0.binaryLabel })
        XCTAssertFalse(tree.isLimited)
    }
    func testCustomMultiByteSeparatorAndCapacityFallbackPreserveEveryKey() {
        let keys = ["a::b::c", "a::d", "a", "x::", "x::::y"].map { Data($0.utf8) }
        let full = KeyNamespaceTree.build(keys, separator: Data("::".utf8))
        XCTAssertEqual(Set(leaves(full.roots)), Set(keys)); XCTAssertFalse(full.isLimited)
        for tree in [KeyNamespaceTree.build(keys, separator: Data("::".utf8), maximumFolders: 1),
                     KeyNamespaceTree.build(keys, separator: Data("::".utf8), maximumDepth: 1),
                     KeyNamespaceTree.build(keys, separator: Data("::".utf8), maximumPrefixBytes: 1)] {
            XCTAssertTrue(tree.isLimited); XCTAssertEqual(Set(leaves(tree.roots)), Set(keys))
        }
        let ungrouped = KeyNamespaceTree.build(keys, separator: Data())
        XCTAssertTrue(ungrouped.roots.allSatisfy { !$0.isFolder }); XCTAssertEqual(Set(leaves(ungrouped.roots)), Set(keys))
    }
    func testDeepKeysHaveBoundedHierarchyWithoutDroppingLeaves() {
        let key = Data((String(repeating: "a:", count: 1000) + "leaf").utf8)
        let tree = KeyNamespaceTree.build([key])
        XCTAssertTrue(tree.isLimited); XCTAssertEqual(leaves(tree.roots), [key])
        XCTAssertLessThanOrEqual(nodes(tree.roots).filter(\.isFolder).count, 64)
    }
    func testBoundedKeyPreviewPreservesUnicodeBoundariesAndBinaryPrefixes() {
        XCTAssertEqual(DataPresentation.previewKey(Data("中文".utf8), limit: 4), "中…（6 字节）")
        XCTAssertEqual(DataPresentation.previewKey(Data("a🔑b".utf8), limit: 3), "a…（6 字节）")
        XCTAssertEqual(DataPresentation.previewKey(Data([0xff, 0, 1]), limit: 2), "0xff00…（3 字节）")
    }
    func testHundredThousandKeyTreeConstruction() {
        let keys = (0..<100_000).map { Data("app:\($0 / 100):item:\($0)".utf8) }
        let before = residentBytes(), start = ContinuousClock.now
        let tree = KeyNamespaceTree.build(keys)
        let elapsed = start.duration(to: .now).rillMilliseconds, after = residentBytes()
        XCTAssertEqual(tree.roots.reduce(0) { $0 + $1.keyCount }, 100_000)
        XCTAssertFalse(tree.isLimited)
        print(String(format: "TREE100K debug: %.1f ms; test-process resident change %.1f MiB", elapsed, Double(after) / 1_048_576 - Double(before) / 1_048_576))
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}
