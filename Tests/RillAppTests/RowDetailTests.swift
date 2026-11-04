import XCTest
import SwiftUI
@testable import RillCore
@testable import RillApp

final class RowDetailTests: XCTestCase {
    @MainActor
    func testDetailDisplaysFullContentInSelectableReadOnlyScrollView() async throws {
        _ = NSApplication.shared
        let content = String(repeating: "完整内容🔑\n", count: 1_000) + "末尾标记"
        let row = ValueRow(field: Data("123-0".utf8), value: Data(content.utf8))
        let host = NSHostingView(rootView: RowDetailView(row: row, key: RedisKey(bytes: Data("events".utf8), kind: .stream)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let valueView = try XCTUnwrap(textViews(in: host).first { $0.string == content })
        XCTAssertFalse(valueView.isEditable)
        XCTAssertTrue(valueView.isSelectable)
        let scroll = try XCTUnwrap(valueView.enclosingScrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        valueView.scrollRangeToVisible(NSRange(location: content.utf16.count - 4, length: 4))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
    }

    func testStreamPreviewShowsValuesWithoutJSONScaffoldingAndKeepsDuplicateFields() {
        let fields = ["event", "completed", "event", "waiting", "message", "第一行\n第二行"].map { Data($0.utf8) }
        let row = ValueRow(field: Data("123-0".utf8), value: Data("[]".utf8), streamFields: fields)
        XCTAssertEqual(row.collectionPreview, "event: completed\nevent: waiting\nmessage: 第一行\\n第二行")
    }

    func testBoundedPreviewDoesNotTruncateFullValue() {
        let content = String(repeating: "完整内容🔑\n", count: 1_000) + "末尾标记"
        let value = Data(content.utf8)
        let row = ValueRow(field: Data("123-0".utf8), value: value, streamFields: [Data("payload".utf8), value])
        XCTAssertTrue(row.collectionPreview.hasPrefix("payload: "))
        XCTAssertLessThan(row.collectionPreview.count, 250)
        XCTAssertFalse(row.collectionPreview.contains("末尾标记"))
        XCTAssertEqual(row.valueText, content)
        XCTAssertEqual(row.streamFields?.last, value)
    }

    func testStreamPreviewLimitsFieldsAndHandlesBinaryValues() {
        let fields = [Data("binary".utf8), Data([0, 255]), Data(), Data(), Data("event".utf8), Data("completed".utf8), Data("last".utf8), Data("value".utf8)]
        let row = ValueRow(field: Data(), value: Data(), streamFields: fields)
        XCTAssertTrue(row.collectionPreview.contains("binary: 0x00ff"))
        XCTAssertTrue(row.collectionPreview.contains("共 4 个字段"))
        XCTAssertFalse(row.collectionPreview.contains("last: value"))
        XCTAssertEqual(row.streamFields, fields)
    }

    func testNonStreamPreviewStaysBoundedAndBinaryDetailKeepsEveryByte() {
        let text = String(repeating: "long value ", count: 1_000)
        let row = ValueRow(field: Data("field".utf8), value: Data(text.utf8))
        XCTAssertLessThan(row.collectionPreview.count, 550)
        XCTAssertEqual(row.valueText, text)
        let binary = ValueRow(field: Data(), value: Data([0, 255, 10, 128]))
        XCTAssertEqual(binary.valueText, "0x00ff0a80")
    }
}
