import SwiftUI

/// Where this app keeps its files. iOS gives every app its own Application Support; a Mac app
/// shares the user's, so there it takes a folder named after itself.
enum AppFiles {
    static let support: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let url = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.unayung.liferecorder.mac",
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        return support
        #endif
    }()
}

/// What to call the two ends of a sync: the same stores run on the phone and on a Mac.
enum Wording {
    #if os(macOS)
    static let here = "this Mac"
    static let receiver = "the receiver"
    #else
    static let here = "this phone"
    static let receiver = "your Mac"
    #endif
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// How much larger than standard a day's text is drawn. The phone leaves this at 1 and
    /// follows the system's text size; a Mac has no such setting, so the app keeps its own.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension Font {
    /// A text style at the reader's scale.
    static func reading(_ style: TextStyle, scale: CGFloat) -> Font {
        #if os(macOS)
        // Text styles have one fixed size each on a Mac, so the larger size is asked for outright.
        let appKit: NSFont.TextStyle = switch style {
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        default: .body
        }
        return .system(size: NSFont.preferredFont(forTextStyle: appKit).pointSize * scale,
                       weight: style == .headline ? .bold : .regular)
        #else
        return .system(style)
        #endif
    }
}

extension View {
    /// A pushed page's title, kept small. Only iOS has a large one to avoid.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// A sheet on a Mac has no size of its own; on the phone it fills the screen.
    func sheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}
