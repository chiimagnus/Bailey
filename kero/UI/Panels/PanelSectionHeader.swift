import SwiftUI

struct PanelSectionHeader: View {
    struct MenuAction: Identifiable {
        var id: String { title }
        let title: String
        var disabled = false
        let perform: () -> Void
    }
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        let isLoading: Bool
        let perform: () -> Void

        init(
            systemImage: String,
            help: String,
            isLoading: Bool = false,
            perform: @escaping () -> Void
        ) {
            self.systemImage = systemImage
            self.help = help
            self.isLoading = isLoading
            self.perform = perform
        }
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]
    var actionsDisabled = false
    /// When set, a small "?" after the title opens this in a popover.
    var helpText: String?
    var menuActions: [MenuAction] = []

    @State private var isHovering = false
    @State private var isShowingHelp = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .panelFont(size: 7, weight: .semibold)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .panelFont(size: 9.5, weight: .medium)
                }
                .foregroundStyle(Color.secondary.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if let helpText {
                Button {
                    isShowingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .panelFont(size: 9)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "About \(title)", table: "Sidebar"))
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                    Text(helpText)
                        .panelFont(size: 11)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(12)
                }
            }

            ForEach(actions) { action in
                Button(action: action.perform) {
                    Group {
                        if action.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: action.systemImage)
                                .panelFont(size: 9, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .disabled(actionsDisabled)
                .opacity(action.isLoading ? 1 : (actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55)))
                .help(action.help)
                .accessibilityLabel(
                    action.isLoading
                        ? String(localized: "\(action.help), in progress", table: "Sidebar")
                        : action.help
                )
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text(String(localized: "\(count)", table: "Sidebar"))
                    .panelFont(size: 9, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.help, action: action.perform)
                    .disabled(actionsDisabled)
            }
            if !actions.isEmpty, !menuActions.isEmpty { Divider() }
            ForEach(menuActions) { action in
                Button(action.title, action: action.perform)
                    .disabled(actionsDisabled || action.disabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(title), \(count) items", table: "Sidebar"))
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}
