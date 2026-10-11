//
//  PanelTypography.swift
//  kero
//

import SwiftUI

private struct PanelFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var panelFontScale: CGFloat {
        get { self[PanelFontScaleKey.self] }
        set { self[PanelFontScaleKey.self] = newValue }
    }
}

/// Scales a panel font from its designed size while preserving the relative
/// hierarchy between section labels, content, metadata, and controls.
private struct PanelFontModifier: ViewModifier {
    @Environment(\.panelFontScale) private var scale

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func panelFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(PanelFontModifier(size: size, weight: weight, design: design))
    }
}
