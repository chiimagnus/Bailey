# AGENTS.md

Kero is a native macOS terminal workspace with projects, panes, a file tree, a git panel,
an editor, and a diff viewer. SwiftUI is the default UI framework; AppKit remains for
native terminal integration and platform capabilities SwiftUI cannot cover.

- [PRODUCT.md](PRODUCT.md) — who Kero is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- No updater or publishing pipeline. Local builds are described in CONTRIBUTING.md.

## Verify

[CONTRIBUTING.md](CONTRIBUTING.md) owns the build and verification procedure. Do not stop at compilation: use its signed Debug install and real-app checks. Never replace Kero while active commands or unsaved work would be lost; clean temporary installation copies after verification.

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- Prefer SwiftUI for layout, controls, file trees and Git trees. Files and Git must reuse the shared tree-row interaction/layout instead of drifting into separate hover, padding, guide, or scrolling behavior.
- Use AppKit only where platform integration requires it, such as the native terminal.
  Preserve responsiveness with lazy rendering and verify large-tree performance.
