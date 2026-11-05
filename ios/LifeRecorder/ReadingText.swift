import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

/// What a day's page does with a name highlighted in it.
struct NameFixAction {
    let perform: (String) -> Void
    func callAsFunction(_ name: String) { perform(name) }
}

private struct NameFixKey: EnvironmentKey {
    static let defaultValue: NameFixAction? = nil
}

extension EnvironmentValues {
    /// Set by a day's page; text inside it then offers to fix a highlighted name.
    var fixName: NameFixAction? {
        get { self[NameFixKey.self] }
        set { self[NameFixKey.self] = newValue }
    }
}

/// A run of a day's text drawn by the system's own text view, so part of it can be highlighted
/// and sent to Names and terms. SwiftUI's Text can be selected, but never says what was selected.
struct ReadingText: View {
    let markdown: String
    let style: Font.TextStyle
    var lineSpacing: CGFloat = 5
    @Environment(\.textScale) private var scale
    @Environment(\.fixName) private var fixName
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        let text = PreparedText.make(markdown, font: font, lineSpacing: lineSpacing * scale)
        SelectableTextView(text: text, fixName: fixName)
            // A bullet or a time beside the text lines up with its first line, as it did with Text.
            .alignmentGuide(.firstTextBaseline) { d in text.measure(width: d.width).baseline }
    }

    private var font: PlatformFont {
        #if os(macOS)
        NSFont.reading(style, scale: scale)
        #else
        UIFont.preferredFont(forTextStyle: UIFont.TextStyle(style),
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
        #endif
    }
}

/// Text styled once, with its height remembered for each width it has been laid out at.
final class PreparedText {
    struct Measure {
        let width: CGFloat
        let height: CGFloat
        let baseline: CGFloat  // Of the first line, from the top.
    }

    let attributed: NSAttributedString
    private var measured: [CGFloat: Measure] = [:]
    private static let cache = NSCache<NSString, PreparedText>()

    private init(attributed: NSAttributedString) {
        self.attributed = attributed
    }

    static func make(_ markdown: String, font: PlatformFont, lineSpacing: CGFloat) -> PreparedText {
        let key = "\(font.fontName)|\(font.pointSize)|\(lineSpacing)|\(markdown)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let prepared = PreparedText(attributed: styled(markdown, font: font, lineSpacing: lineSpacing))
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    /// Laid out with TextKit 1, as the text views are, so the height is the one they draw.
    func measure(width: CGFloat) -> Measure {
        let width = width.isFinite && width > 0 ? width : 100_000
        if let known = measured[width] { return known }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var baseline = used.height
        if layout.numberOfGlyphs > 0 {
            baseline = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + layout.location(forGlyphAt: 0).y
        }
        let result = Measure(width: ceil(used.width), height: ceil(used.height), baseline: baseline)
        if measured.count > 8 { measured.removeAll() }  // A window being resized passes through many widths.
        measured[width] = result
        return result
    }

    /// The inline Markdown a summary uses (bold, italics, code, links) as attributes the text views draw.
    private static func styled(_ markdown: String, font: PlatformFont, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let parsed = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: variant(of: font, bold: intent.contains(.stronglyEmphasized),
                               italic: intent.contains(.emphasized), code: intent.contains(.code)),
                .foregroundColor: labelColor,
                .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static var labelColor: Any {
        #if os(macOS)
        NSColor.labelColor
        #else
        UIColor.label
        #endif
    }

    private static func variant(of font: PlatformFont, bold: Bool, italic: Bool, code: Bool) -> PlatformFont {
        if code { return .monospacedSystemFont(ofSize: font.pointSize * 0.95, weight: bold ? .bold : .regular) }
        guard bold || italic else { return font }
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

#if os(macOS)
private struct SelectableTextView: NSViewRepresentable {
    let text: PreparedText
    let fixName: NameFixAction?

    func makeNSView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(usingTextLayoutManager: false)  // TextKit 1, as PreparedText measures.
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ReadingTextView, context: Context) {
        if view.shown !== text {
            view.textStorage?.setAttributedString(text.attributed)
            view.shown = text
        }
        view.fixName = fixName
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingTextView, context: Context) -> CGSize? {
        size(of: text, for: proposal)
    }
}

final class ReadingTextView: NSTextView {
    var shown: PreparedText?
    var fixName: NameFixAction?

    /// The highlighted text, when it is short enough to be a name.
    private var highlightedName: String? {
        let range = selectedRange()
        let whole = string as NSString
        guard range.length > 0, NSMaxRange(range) <= whole.length else { return nil }
        let name = NameFix.clean(whole.substring(with: range))
        return name.isEmpty || name.count > NameFix.longest ? nil : name
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Asked first: a right-click outside the highlight selects the word under it.
        let menu = super.menu(for: event)
        guard let menu, fixName != nil, let name = highlightedName else { return menu }
        let item = NSMenuItem(title: "Fix “\(name)” in Names and Terms…", action: #selector(fixHighlightedName),
                              keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func fixHighlightedName() {
        if let name = highlightedName { fixName?(name) }
    }

    /// One highlight on the page at a time, as in a single document.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }
}
#else
private struct SelectableTextView: UIViewRepresentable {
    let text: PreparedText
    let fixName: NameFixAction?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)  // TextKit 1, as PreparedText measures.
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if context.coordinator.shown !== text {
            view.attributedText = text.attributed
            context.coordinator.shown = text
        }
        context.coordinator.fixName = fixName
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        size(of: text, for: proposal)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var shown: PreparedText?
        var fixName: NameFixAction?

        /// "Fix Name" leads the menu that appears over highlighted text.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let whole = textView.text as NSString
            guard let fixName, range.length > 0, NSMaxRange(range) <= whole.length else { return nil }
            let name = NameFix.clean(whole.substring(with: range))
            guard !name.isEmpty, name.count <= NameFix.longest else { return nil }
            let fix = UIAction(title: "Fix Name", image: UIImage(systemName: "character.book.closed")) { _ in
                fixName(name)
            }
            return UIMenu(children: [fix] + suggestedActions)
        }
    }
}

extension UIFont.TextStyle {
    init(_ style: Font.TextStyle) {
        self = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif

/// The text's own width when nothing is proposed, otherwise the width it was given.
private func size(of text: PreparedText, for proposal: ProposedViewSize) -> CGSize {
    let measure = text.measure(width: proposal.width ?? .infinity)
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? measure.width
    return CGSize(width: width, height: measure.height)
}
