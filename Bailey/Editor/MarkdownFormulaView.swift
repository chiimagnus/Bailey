import SwiftUI
import SwiftUIMath

/// Public SwiftUI Canvas-based math typesetting; no WebKit, JS, or SPI.
struct MarkdownFormulaView: View {
    let latex: String
    let display: Bool
    var fontSize: CGFloat? = nil

    var body: some View {
        SwiftUIMath.Math(latex)
            .mathFont(SwiftUIMath.Math.Font(name: .latinModern,
                                           size: fontSize ?? (display ? 22 : 16)))
            .mathTypesettingStyle(display ? .display : .text)
            .accessibilityLabel("Math: \(latex)")
    }
}
