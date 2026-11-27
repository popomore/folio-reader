# Folio website facts

English lives at `/`; Simplified Chinese lives at `/zh/`. The site introduces the native application.

## Folio facts and sources
[README](../../README.md).

- Saved local folders, file tree, multiple tabs, adjustable left/right panes, optional Markdown outline and focused reading.
- Markdown/GFM, UTF-8 text and code, PDF, static HTML, RTF, images, audio/video and CSV/TSV. Image and media decoding depends on macOS. Mermaid and Vega-Lite are supported in the application; avoid claiming all embedded HTML or remote chart resources are supported.
- Reading, source and source/preview modes; supported UTF-8 text can be edited and saved. PDF and other read-only formats are not advertised as editable.
- Independent read-only Git view for changes, file history and diffs. No staging, commit, push or workspace hosting claims.
- Finder Quick Look for Markdown and a bundled `folio` CLI. The preview app and formal distribution have different identities; follow the app's actual setup guide.
- DOCX, EPUB and SVG are not listed as native reader formats. A preview does not actively load online resources; do not generalize this to every app feature requiring no network.

The site links to preview release [v0.1.1.1794846141-a710e4b](https://github.com/popomore/folio-reader/releases/tag/v0.1.1.1794846141-a710e4b), `Folio-0.1.1-1794846141.ga710e4b-arm64.dmg`. The package targets Apple Silicon and macOS 14 or later, with a separate preview identity and update channel. The website does not claim notarization or stable distribution.

Use real application captures. See [asset provenance](assets.md). The build and release procedure is in [the site README](../README.md).
