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
                Text(verbatim: display ? "$$\n\(latex)\n$$" : "$\(latex)$")
                    .font(.system(size: fontSize ?? (display ? 18 : 16), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
        .onTapGesture(count: 2) {
            if let source { locateSource?(source.location) }
        }
        .onChange(of: latex) { _, _ in cannotTypeset = false }
    }
}
