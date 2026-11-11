import AppKit
import SwiftUI

/// A compact remote picker; the connection and path state live in its model.
@MainActor
struct SSHFolderPickerView: View {
    @State private var model: SSHFolderPickerModel
    @FocusState private var inputFocused: Bool
    @FocusState private var hostChoicesFocused: Bool
    @State private var highlightedHost = 0

    let onCancel: () -> Void
    let onChoose: @MainActor @Sendable (String, String) -> Void

    private let themeChanges = Theme.changes

    init(
        hosts: [String],
        onCancel: @escaping () -> Void,
        onChoose: @escaping @MainActor @Sendable (String, String) -> Void
    ) {
        _model = State(initialValue: SSHFolderPickerModel(hosts: hosts))
        self.onCancel = onCancel
        self.onChoose = onChoose
    }

    var body: some View {
        let _ = themeChanges.revision
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityRepresentation {
                    Button(String(localized: "Close SSH Folder Picker", table: "Terminal"),
                           action: onCancel)
                        .accessibilityIdentifier("bailey.sshFolderPicker.dismiss")
                }

            panel
                .padding(.horizontal, 12)
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .task { if model.host == nil { hostChoicesFocused = true } }
        .onExitCommand(perform: onCancel)
        .onChange(of: model.host) { _, host in
            if host != nil { DispatchQueue.main.async { inputFocused = true } }
        }
        .onDisappear { model.invalidate() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.host == nil {
                    Image(systemName: "network")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Choose SSH Host", table: "Terminal"))
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    TextField(
                        String(localized: "Remote folder path…", table: "Terminal"),
                        text: Binding(
                            get: { model.input },
                            set: { model.editInput($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($inputFocused)
                    .onSubmit(acceptInput)
                    .onKeyPress(.upArrow) {
                        guard !model.isLoading else { return .ignored }
                        model.moveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !model.isLoading else { return .ignored }
                        model.moveSelection(1)
                        return .handled
                    }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    .accessibilityIdentifier("bailey.sshFolderPicker.path")

                    Menu {
                        ForEach(model.hosts, id: \.self) { alias in
                            Button {
                                Task { await model.selectHost(alias) }
                            } label: {
                                if model.host == alias {
                                    Label(alias, systemImage: "checkmark")
                                } else {
                                    Text(alias)
                                }
                            }
                        }
                        Divider()
                        Toggle(
                            String(localized: "Show Hidden Folders", table: "Terminal"),
                            isOn: Binding(
                                get: { model.showHidden },
                                set: { model.showHidden = $0 }
                            )
                        )
                    } label: {
                        Label(
                            model.host ?? String(localized: "SSH host", table: "Terminal"),
                            systemImage: "network"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(String(
                        localized: "SSH hosts are configured in ~/.ssh/config.",
                        table: "Terminal"
                    ))
                    .accessibilityIdentifier("bailey.sshFolderPicker.host")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.5)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("bailey.sshFolderPicker.error")
            }

            if model.host == nil, !model.hosts.isEmpty {
                hostChoices
            } else if model.isLoading {
                ProgressView(
                    String(localized: "Loading remote folders…", table: "Terminal")
                )
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else if model.rows.isEmpty, model.errorMessage == nil {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 27)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.rows, id: \.self) { folder in
                                folderRow(folder)
                                    .id(folder)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 310)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.selectedName) { _, name in
                        if let name { proxy.scrollTo(name) }
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", table: "Terminal"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if model.host != nil {
                    Button(String(localized: "Add", table: "Terminal")) {
                        Task { await model.confirm(onChoose: onChoose) }
                    }
                    .disabled(model.addPath == nil)
                    .accessibilityIdentifier("bailey.sshFolderPicker.add")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: Theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
    }

    private var hostChoices: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.hosts.enumerated()), id: \.offset) { index, host in
                        Button {
                            highlightedHost = index
                            Task { await model.selectHost(host) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(verbatim: host)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlightedHost = index } }
                        .modifier(RowHighlightStyle(
                            isSelected: index == highlightedHost,
                            listActive: hostChoicesFocused,
                            cornerRadius: 6
                        ))
                        .accessibilityIdentifier("bailey.sshFolderPicker.hostChoice")
                        .accessibilityValue(host)
                        .id(index)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 310)
            .fixedSize(horizontal: false, vertical: true)
            .focusable()
            .focused($hostChoicesFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                highlightedHost = max(0, highlightedHost - 1)
                proxy.scrollTo(highlightedHost)
                return .handled
            }
            .onKeyPress(.downArrow) {
                highlightedHost = min(model.hosts.count - 1, highlightedHost + 1)
                proxy.scrollTo(highlightedHost)
                return .handled
            }
            .onKeyPress(.return) {
                guard model.hosts.indices.contains(highlightedHost) else { return .ignored }
                Task { await model.selectHost(model.hosts[highlightedHost]) }
                return .handled
            }
        }
    }

    private var emptyMessage: String {
        if model.host == nil {
            return String(localized: "Configure SSH hosts in ~/.ssh/config.", table: "Terminal")
        }
        if model.directory == nil || model.enterPath != nil {
            return String(localized: "Press Return to open the entered path.", table: "Terminal")
        }
        if SSHFolderPickerModel.remotePath(model.input) == nil {
            return String(localized: "Enter an absolute remote folder path.", table: "Terminal")
        }
        return String(localized: "No subfolders", table: "Terminal")
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: folder == ".." ? "arrow.up" :
                model.showingDrives ? "internaldrive" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(
                    folder == ".." ? Color.secondary : Color(nsColor: Theme.accent)
                )
                .frame(width: 16)
            Text(verbatim: model.showingDrives ? folder.uppercased() + ":" : folder)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if folder != ".." {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(
            TapGesture(count: 2).onEnded {
                if let path = model.path(for: folder) {
                    Task { await model.navigate(to: path) }
                }
            }
            .exclusively(before: TapGesture(count: 1).onEnded {
                model.selectedName = folder
                inputFocused = true
            })
        )
        .modifier(RowHighlightStyle(
            isSelected: model.selectedName == folder,
            listActive: inputFocused,
            cornerRadius: 6
        ))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.selectedName = folder
            inputFocused = true
        }
        .accessibilityIdentifier("bailey.sshFolderPicker.folder")
        .accessibilityValue(folder)
    }

    private func acceptInput() {
        guard let path = model.enterPath else { return }
        Task { await model.navigate(to: path) }
    }
}
