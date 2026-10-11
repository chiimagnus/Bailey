# AGENTS.md

Kero is a native macOS terminal workspace with projects, panes, a file tree, a git panel,
an editor, and a diff viewer. Existing SwiftUI code is legacy; AppKit is the UI foundation.

- [PRODUCT.md](PRODUCT.md) — who Kero is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- No updater or publishing pipeline. Local builds are described in CONTRIBUTING.md.

## Verify

Every code change must end with a signed Debug build, replacing `/Applications/Kero.app`, and validating the changed behavior in the newly launched app. Verify the restored projects and sessions, not just the build log. Do not force-quit active commands or discard unsaved work; if safe installation is blocked, report the blocker explicitly and complete it as soon as possible. Clean up temporary installation copies after verification.

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- SwiftUI is legacy and must not be introduced or expanded. Build all new UI in AppKit;
  when materially changing an existing SwiftUI view, migrate the affected UI to AppKit.
  UI architecture must prioritize maximum runtime performance over implementation convenience.
