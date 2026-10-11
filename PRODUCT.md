# Product

## Register

product

## Users

Developers who spend most of their working session in a macOS terminal, often running one or more AI coding agents across active repositories. They need to inspect, curate, and ship agent-written changes without losing terminal context or trusting opaque automation.

## Product Purpose

Kero is a terminal-centered project workspace. The left sidebar owns project scope: users add local or SSH files and directories to one project list, and Files/Git follow the selected item rather than the terminal's current directory. Shells, diffs, repository state, and lightweight controls stay close enough to supervise ongoing work without switching to a full IDE. Success means the terminal remains primary while review and source-control actions stay fast, accurate, and understandable. Projects own their file and Git scope independently; adding a directory never launches a shell, and closing every terminal does not remove the project or its inspection tools.

## Brand Personality

Calm, precise, native. Kero should feel like a focused macOS tool that respects expert workflows, stays out of the way, and communicates state truthfully.

## Anti-references

Do not imitate a web dashboard, add decorative developer-tool chrome, or copy another editor pixel for pixel. Avoid opaque one-click automation, surprising destructive actions, noisy status surfaces, and controls that only work at generous panel widths.

## Design Principles

1. Keep the terminal as the center of gravity.
2. Make agent-written changes easy to review before they are trusted.
3. Prefer explicit scope and inspectable outcomes over clever automation.
4. Put the common action close, and progressively disclose advanced actions.
5. Preserve context across repositories, sessions, tabs, and narrow panel sizes.
6. Keep Files and Git tree interactions consistent; long names may scroll, but fixed actions stay anchored.

## Accessibility & Inclusion

Follow macOS appearance and interaction conventions. Support keyboard and assistive technologies, label icon-only controls, respect reduced motion, and keep core workflows usable from the minimum supported sidebar width. Files and every Git file tree use filename color for Git state; the same state must remain available in tooltips and to assistive technology, without a separate status-letter column.
