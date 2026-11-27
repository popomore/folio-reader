# Product

## Register

product

## Users

People who read and make small edits to local project files. The existing macOS
application organizes saved folders, documents, and source files. On iPhone and
iPad, the same work begins with a folder chosen in Files or an imported file.

## Product Purpose

Folio is a local project-file reader, as documented in README.md. Keep related
files together, render documents clearly, and make small text edits without
leaving the reading workspace. The iOS application reuses folio-core for document
classification, rendering, workspace boundaries, and revision-checked saves.
Opt-in iCloud reading copies let the same person continue on another device.
Keep the original folder intact, label copied content read-only, and provide
explicit manual cleanup with separate local-download removal.

## Brand Personality

Quiet, direct, practical. Preserve the existing Folio icon, system typography,
standard platform navigation, and restrained document-reading surfaces found in
apps/macos and its bundled themes. User-facing copy describes concrete actions.

## Anti-references

Preserve the existing folder-and-document organization. Avoid a marketing page,
decorative dashboard, cover-grid library, or unrelated account and social flows.

## Design Principles

- The selected folder remains the organizing boundary.
- Give the document more space than the application chrome.
- Use native controls and familiar platform actions.
- Preserve drafts and report conflicts before changing a file.
- Distinguish supported previews from files that need another application.

## Accessibility & Inclusion

Use semantic system controls, labeled icons, Dynamic Type, system appearance,
sufficient contrast, and VoiceOver-readable document content. Avoid decorative
motion. Keep touch actions at least 44 points high and allow long filenames to
wrap. These are implementation defaults for the native application.

## Context evidence

README.md, apps/macos/Sources/WorkspaceStyle.swift,
apps/macos/Resources/reader.css, and apps/macos/Themes define the existing product
and visual context. The iOS request extends that product to another platform.
The iOS application extends that product and keeps the established native reading
workflow.
