import SwiftUI

@MainActor
@Observable
final class ImageAnnotationExportSettings {
    var width: String
    var height: String
    var format: ImageAnnotationDrawing.Format = .png
    var colorSpace: ImageAnnotationDrawing.ColorSpace = .sRGB
    var background: ImageAnnotationDrawing.Background = .transparent
    var dpi = "72"

    init(size: CGSize) {
        width = String(Int(size.width))
        height = String(Int(size.height))
    }

    var options: ImageAnnotationDrawing.Options? {
        guard let w = Int(width), let h = Int(height), let dpi = Double(dpi) else { return nil }
        let options = ImageAnnotationDrawing.Options(width: w, height: h, format: format,
            colorSpace: colorSpace, background: format == .jpeg && background == .transparent ? .white : background,
            dpi: dpi)
        return options.isValid ? options : nil
    }
}

struct ImageAnnotationExportOptionsView: View {
    @Bindable var settings: ImageAnnotationExportSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading) {
                GridRow {
                    Text("Format", tableName: "Editor")
                    Picker("", selection: $settings.format) {
                        Text("PNG").tag(ImageAnnotationDrawing.Format.png)
                        Text("JPEG").tag(ImageAnnotationDrawing.Format.jpeg)
                    }.labelsHidden()
                }
                GridRow {
                    Text("Pixel width", tableName: "Editor")
                    TextField(String(localized: "Pixel width", table: "Editor"), text: $settings.width).labelsHidden()
                }
                GridRow {
                    Text("Pixel height", tableName: "Editor")
                    TextField(String(localized: "Pixel height", table: "Editor"), text: $settings.height).labelsHidden()
                }
                GridRow {
                    Text("Color space", tableName: "Editor")
                    Picker("", selection: $settings.colorSpace) {
                        Text("sRGB").tag(ImageAnnotationDrawing.ColorSpace.sRGB)
                        Text("Display P3").tag(ImageAnnotationDrawing.ColorSpace.displayP3)
                    }.labelsHidden()
                }
                GridRow {
                    Text("Background", tableName: "Editor")
                    Picker("", selection: $settings.background) {
                        if settings.format == .png { Text("Transparent", tableName: "Editor").tag(ImageAnnotationDrawing.Background.transparent) }
                        Text("White", tableName: "Editor").tag(ImageAnnotationDrawing.Background.white)
                        Text("Black", tableName: "Editor").tag(ImageAnnotationDrawing.Background.black)
                    }.labelsHidden()
                    .onChange(of: settings.format) {
                        if settings.format == .jpeg && settings.background == .transparent { settings.background = .white }
                    }
                }
                GridRow {
                    Text("DPI")
                    TextField("DPI", text: $settings.dpi).labelsHidden()
                }
            }
            Text("Export preserves aspect ratio and does not modify the original image.", tableName: "Editor")
                .font(.caption).foregroundStyle(.secondary)
            if settings.options == nil {
                Text("Invalid image export settings.", tableName: "Editor")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(width: 320, alignment: .leading)
    }
}
