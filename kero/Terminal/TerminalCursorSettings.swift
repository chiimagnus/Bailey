//
//  TerminalCursorSettings.swift
//  kero
//

import Foundation
import GhosttyTerminal

enum TerminalCursorShape: String, CaseIterable, Sendable {
    case block
    case bar
    case underline

    var title: String {
        switch self {
        case .block: String(localized: "Block", table: "Terminal")
        case .bar:
            String(
                localized: "Bar", table: "Terminal",
                comment: "Thin vertical terminal cursor shape."
            )
        case .underline: String(localized: "Underline", table: "Terminal")
        }
    }

    var ghosttyValue: TerminalCursorStyle {
        switch self {
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        }
    }
}
