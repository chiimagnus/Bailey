import SwiftUI

struct ImageAnnotationToolbar: View {
    let document: ImageAnnotationDocument
    let focusCanvas: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { tools; actions }
                VStack(spacing: 6) { tools; actions }
                VStack(spacing: 6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: 3)], spacing: 3) {
                        toolButtons
                    }
                    ViewThatFits(in: .horizontal) {
                        actions
                        ScrollView(.horizontal) { actions }
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let edit = document.textEdit {
                HStack {
                    TextField(String(localized: "Annotation Text", table: "Editor"), text: Binding(
                        get: { document.textEdit?.text ?? edit.text },
                        set: { document.textEdit?.text = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .onAppear { textFocused = true }
                    .onSubmit { commitText() }
                    Button(String(localized: "Add Text", table: "Editor"), action: commitText)
                    Button(String(localized: "Cancel", table: "Editor")) {
                        document.cancelText()
                        focusCanvas()
                    }
                }
                .frame(maxWidth: 360)
                if let error = document.textError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .disabled(!document.canMutate)
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    private func commitText() {
        document.commitText()
        if document.textEdit == nil { focusCanvas() }
    }

    private var tools: some View {
        HStack(spacing: 3) { toolButtons }
    }

    private var toolButtons: some View {
        ForEach(ImageAnnotationTool.allCases, id: \.self) { tool in
            Button {
                document.tool = tool
                focusCanvas()
            } label: {
                Image(systemName: tool.symbol)
                    .frame(width: 24, height: 24)
                    .background(document.tool == tool ? Color.accentColor.opacity(0.18) : .clear,
                                in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
            }
            .help(Text(verbatim: tool.hint))
            .accessibilityLabel(tool.title)
            .accessibilityAddTraits(document.tool == tool ? .isSelected : [])
            .accessibilityIdentifier("bailey.annotation.tool." + tool.rawValue)
            .disabled(document.textEdit != nil)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(ImageAnnotationColor.allCases, id: \.self) { color in
                    Button {
                        document.color = color
                    } label: {
                        Label(color.title, systemImage: document.color == color ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Circle().fill(Color(cgColor: document.color.cgColor))
                    .overlay { Circle().strokeBorder(.secondary, lineWidth: 1) }
                    .frame(width: 16, height: 16)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "Annotation Color", table: "Editor"))
            Button {
                document.undoManager.undo()
            } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!document.undoManager.canUndo)
                .help(String(localized: "Undo", table: "Editor"))
            Button {
                document.undoManager.redo()
            } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!document.undoManager.canRedo)
                .help(String(localized: "Redo", table: "Editor"))
            Button {
                document.removeSelection()
            } label: { Image(systemName: "trash") }
                .disabled(document.selection.isEmpty)
                .help(String(localized: "Delete Selection", table: "Editor"))
            if document.state.crop != nil {
                Button {
                    document.resetCrop()
                } label: { Image(systemName: "crop.rotate") }
                    .help(String(localized: "Reset Crop", table: "Editor"))
            }
            Button(String(localized: "Cancel", table: "Editor")) { document.cancel() }
            Button(String(localized: "Done", table: "Editor")) { document.finish() }
                .disabled(document.textEdit != nil)
        }
    }
}

extension ImageAnnotationTool {
    var shortcut: String {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "e"
        case .text: "t"
        case .number: "n"
        case .blur: "b"
        case .pixelate: "m"
        case .crop: "c"
        }
    }

    fileprivate var hint: String { "\(title) (\(shortcut.uppercased()))" }

    fileprivate var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .number: "1.circle"
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        case .crop: "crop"
        }
    }

    fileprivate var title: String {
        switch self {
        case .pen: String(localized: "Pen", table: "Editor")
        case .select: String(localized: "Select Annotation", table: "Editor")
        case .arrow: String(localized: "Arrow", table: "Editor")
        case .rectangle: String(localized: "Rectangle", table: "Editor")
        case .ellipse: String(localized: "Ellipse", table: "Editor")
        case .text: String(localized: "Text", table: "Editor")
        case .number: String(localized: "Number", table: "Editor")
        case .blur: String(localized: "Blur", table: "Editor")
        case .pixelate: String(localized: "Pixelate", table: "Editor")
        case .crop: String(localized: "Crop", table: "Editor")
        }
    }
}

private extension ImageAnnotationColor {
    var title: String {
        switch self {
        case .red: String(localized: "Red", table: "Editor")
        case .orange: String(localized: "Orange", table: "Editor")
        case .blue: String(localized: "Blue", table: "Editor")
        case .white: String(localized: "White", table: "Editor")
        case .black: String(localized: "Black", table: "Editor")
        }
    }
}
