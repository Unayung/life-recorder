import XCTest
import SwiftUI
@testable import LifeRecorderMac

/// Highlighting a name in a day offers to fix it, right where it was read.
final class ReadingTextTests: XCTestCase {
    @MainActor
    func testAHighlightedNameLeadsTheContextMenu() throws {
        var fixed: [String] = []
        let line = "明天有企業參訪（Alice、陳偉（?）接待學生）"
        let view = BlockView(block: Block(id: 0, kind: .bullet(line)))
            .environment(\.fixName, NameFixAction { fixed.append($0) })
            .frame(width: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let text = try XCTUnwrap(Self.textView(in: host))
        XCTAssertEqual(text.string, line)
        // Highlight "陳偉（?）", the way a reader drags across it.
        let range = (line as NSString).range(of: "陳偉（?）")
        text.setSelectedRange(range)
        let layout = try XCTUnwrap(text.layoutManager)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: try XCTUnwrap(text.textContainer))
        let point = text.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))

        let menu = try XCTUnwrap(text.menu(for: click))
        let item = menu.items[0]
        XCTAssertEqual(item.title, "Fix “陳偉” in Names and Terms…")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertEqual(fixed, ["陳偉"])
    }

    @MainActor
    func testASentenceIsNotOfferedAsAName() throws {
        let line = String(repeating: "這是一整段話，不是名字。", count: 5)
        let host = NSHostingView(rootView: BlockView(block: Block(id: 0, kind: .paragraph(line)))
            .environment(\.fixName, NameFixAction { _ in XCTFail("A sentence is not a name") })
            .frame(width: 500))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(Self.textView(in: host))
        text.setSelectedRange(NSRange(location: 0, length: (line as NSString).length))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: text.convert(NSPoint(x: 5, y: 5), to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(text.menu(for: click)?.items.first?.title.hasPrefix("Fix") ?? false)
    }

    private static func textView(in view: NSView) -> ReadingTextView? {
        if let text = view as? ReadingTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
