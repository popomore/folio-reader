# Folio native application design

## Product surface

A person opens a project folder on an iPhone while travelling, or reads reference
material beside other work on an iPad. Ambient light varies, so follow system
appearance and allow an explicit override.

## Color strategy

Restrained. Use UIKit semantic backgrounds, labels, and separators. Keep Folio's
blue accent for selected navigation and actions. Rendered documents use the
existing bundled light and dark reader palettes. Native semantic colors take
precedence over hard-coded colors for accessibility and system integration.

## Typography

Use the system font and Dynamic Type for navigation and controls. Render prose at
17 points before Dynamic Type and reader-size adjustments, with a maximum width
of 700 points. Source uses a system monospaced font. An optional serif reading
setting follows the existing reader's New York/Georgia font stack.

## Navigation and layout

Use a library of saved folders and recently read documents. On iPhone, open the
folder browser and then a document through standard navigation. On iPad, show a
folder sidebar and a reading detail. Folder rows show a meaningful icon, filename,
and file kind; they are a list, not a grid of cards. Search filters the visible
directory and pull to refresh reloads its contents.

## Reading

Keep toolbars compact: outline, appearance, share, and edit where supported.
Show Markdown, text, HTML, CSV/TSV, Mermaid, and Vega-Lite with the shared offline
renderer. Use PDFKit, image and media views for native formats. Unsupported types
have an honest explanation and a system share action.

## Editing and state

A focused native editor has explicit Cancel and Save actions. Disable interactive
dismissal while a draft is dirty. Confirm discarding a draft, keep a failed save
visible, and preserve recoverable drafts. Show errors with a specific recovery
action. Loading, empty folders, missing permissions, and unsupported previews each
have a useful state.

## Motion and assets

Use standard platform transitions and respect Reduce Motion. Reuse assets/folio.png
and SF Symbols. No generated illustration or visual mock is needed for this
extension of the established native product.

## iCloud copy management

Provide **Settings > iCloud > Manage Reading Copies** on iPhone, iPad, and Mac
in iCloud-enabled builds. Show the copies Folio created for
cross-device reading, their sizes, source devices, and last-read dates. Support
selection and explicit cloud deletion, with a confirmation that names the scope
and preserves the source files. Keep removing a local download a separate action.
The initial design uses manual cleanup with no automatic expiry.

The management screen uses the shorter title **Reading Copies**. Continue Reading
opens read-only snapshots for Folio-created copies; explicitly linked iCloud
documents remain editable in their original folder. See
[iCloud sharing and manual cleanup](docs/icloud-sharing.md) for the interaction
contract and [iCloud setup](docs/icloud-setup.md) for signing and physical-device
acceptance. Local fixtures do not establish live cloud synchronization.
