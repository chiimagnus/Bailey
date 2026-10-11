# Localizing Kero

Kero follows the macOS language selected by the user, including the per-app
language in System Settings. Users can also choose a language from
**Kero → Settings → Appearance → Language**; Kero asks to relaunch so native
menus, dialogs, and SwiftUI views all change together. English is the
development language. The currently maintained localizations are:

| Language | Identifier |
| --- | --- |
| English | `en` |
| Chinese (Simplified) | `zh-Hans` |

## Translate existing text

Open `kero.xcodeproj` in Xcode and edit the catalogs under
`kero/Resources/Localization/`. Choose the catalog for the feature:

- `Git`, `Sidebar`, `Terminal`, `Workspace`, `Browser`, `Settings` — feature UI.
- `Localizable` — shared labels and SwiftUI strings using the default table.
- `InfoPlist` — privacy permission text; `ServicesMenu` — Finder Services.

Xcode keeps placeholders, plural variants, and translation state visible.
When moving a key between catalogs, update its Swift lookup table as well.

Keep placeholders such as `%@` and `%lld` intact. Preserve product and
technology names such as Kero, Git, Finder, and VS Code, as well as keyboard
shortcut symbols. Translation-only pull requests are welcome.

For work outside Xcode, use **Product → Export Localizations…** to produce
XLIFF, then **Product → Import Localizations…** when the translation is ready.
XLIFF is the easiest way to send a language to a translator without exposing
the source code.

## Add localizable text in Swift

SwiftUI string literals are extracted automatically:

```swift
Button("Create New Branch…") {
    createBranch()
}
```

When an API requires a runtime `String`, use `String(localized:table:comment:)`
for the matching feature catalog. Describe placeholders when not obvious:

```swift
let message = String(
    localized: "Choose the directory for “\(project.name)”.",
    table: "Workspace",
    comment: "The placeholder is the project name."
)
```

Use complete sentences instead of assembling translated fragments. Put
count-dependent grammar in a plural variant in the corresponding catalog. Mark
user content, file names, terminal output, and other non-language data as
verbatim so it is not treated as a lookup key:

```swift
Text(verbatim: file.path)
```

The build has string extraction enabled. After adding source text, build once,
then translate the new entry in its catalog.

## Test a localization

In Xcode, choose **Product → Scheme → Edit Scheme… → Run → Options**, then set
**App Language** and **App Region**. Test English and Simplified Chinese.
The in-app picker offers those two languages and **System Default**; the latter
follows macOS and falls back to English when macOS uses another language.
