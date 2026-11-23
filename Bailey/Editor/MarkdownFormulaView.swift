import SwiftUI
import SwiftUIMath

private struct MarkdownSourceLocationKey: EnvironmentKey {
    static let defaultValue: ((Int) -> Void)? = nil
}

extension EnvironmentValues {
    var markdownSourceLocation: ((Int) -> Void)? {
        get { self[MarkdownSourceLocationKey.self] }
        set { self[MarkdownSourceLocationKey.self] = newValue }
    }
}

struct MarkdownEmbeddedSourceHit: Equatable {
    let source: NSRange
    let viewportFrame: CGRect
    let documentFrame: CGRect
}

struct MarkdownEmbeddedSourceHitPreference: PreferenceKey {
    static var defaultValue: [MarkdownEmbeddedSourceHit] { [] }

    static func reduce(value: inout [MarkdownEmbeddedSourceHit], nextValue: () -> [MarkdownEmbeddedSourceHit]) {
        value.append(contentsOf: nextValue())
    }
}

struct MarkdownEmbeddedSourceMapping: ViewModifier {
    let source: NSRange?

    func body(content: Content) -> some View {
        content.background {
            if let source {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MarkdownEmbeddedSourceHitPreference.self,
                        value: [MarkdownEmbeddedSourceHit(
                            source: source,
                            viewportFrame: geometry.frame(in: .named("bailey.markdown.reader")),
                            documentFrame: geometry.frame(in: .named("bailey.markdown.content"))
                        )]
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// Public SwiftUI Canvas-based math typesetting; no WebKit, JS, or SPI.
struct MarkdownFormulaView: View {
    let latex: String
    let display: Bool
    var fontSize: CGFloat? = nil
    var source: NSRange? = nil
    @Environment(\.markdownSourceLocation) private var locateSource
    @State private var cannotTypeset = false

    var body: some View {
        Group {
            if cannotTypeset {
                MarkdownNativeText.make([.text(display ? "$$\n\(latex)\n$$" : "$\(latex)$", source: source)])
                    .font(.system(size: fontSize ?? (display ? 18 : 16), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .pointerStyle(.horizontalText)
            } else {
                SwiftUIMath.Math(latex)
                    .mathFont(SwiftUIMath.Math.Font(name: .latinModern,
                                                   size: fontSize ?? (display ? 22 : 16)))
                    .mathTypesettingStyle(display ? .display : .text)
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width <= 0 || proxy.size.height <= 0
                    } action: { hasNoLayout in
                        // SwiftUIMath reports zero intrinsic size if parsing fails.
                        // Swap the entire view; merely not placing a sibling still draws it.
                        if hasNoLayout { cannotTypeset = true }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math: \(latex)")
        .modifier(MarkdownEmbeddedSourceMapping(source: source))
        .onTapGesture(count: 2) {
            if let source { locateSource?(source.location) }
        }
        .onChange(of: latex) { _, _ in cannotTypeset = false }
    }
}
