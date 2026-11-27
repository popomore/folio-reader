# Folio website facts

Historical product and download verification from 2026-11-16/17. Migrated on 2026-11-27 without changing the copy or pinned installer. Reverify each claim before updating it.

English lives at `/`; Simplified Chinese lives at `/zh/`. The site introduces the native application.

## Folio facts and sources
[README](https://github.com/popomore/folio-reader#readme), [reader design](https://github.com/popomore/folio-reader/blob/main/docs/reader-design.md). Local source examined at `1a8e2194c0ea85100d47c39554831cc638bfe14a`; the website's feature inventory describes that current source. Screenshots document their capture separately from the downloadable binary version.

- Saved local folders, file tree, multiple tabs, adjustable left/right panes, optional Markdown outline and focused reading.
- Markdown/GFM, UTF-8 text and code, PDF, static HTML, RTF, images, audio/video and CSV/TSV. Image and media decoding depends on macOS. Mermaid and Vega-Lite are supported in the application; avoid claiming all embedded HTML or remote chart resources are supported.
- Reading, source and source/preview modes; supported UTF-8 text can be edited and saved. PDF and other read-only formats are not advertised as editable.
- Independent read-only Git view for changes, file history and diffs. No staging, commit, push or workspace hosting claims.
- Finder Quick Look for Markdown and a bundled `folio` CLI. The preview app and formal distribution have different identities; follow the app's actual setup guide.
- DOCX, EPUB and SVG are not listed as native reader formats. A preview does not actively load online resources; do not generalize this to every app feature requiring no network.

Release verification changed during implementation: `v0.1.1.1794811700-410a6ad` initially appeared as a public prerelease, then its asset returned HTTP 404 and the GitHub Releases API returned an empty list. The initial site therefore omitted the installer link and release metadata.

On 2026-11-17, public preview [v0.1.1.1794846141-a710e4b](https://github.com/popomore/folio-reader/releases/tag/v0.1.1.1794846141-a710e4b) was verified through the Releases API and an HTTP 200 response from `Folio-0.1.1-1794846141.ga710e4b-arm64.dmg`. Its release notes specify Apple Silicon and macOS 14 or later. The site now pins that preview, restores the installer action, and emits its `downloadUrl` and version. The release describes an ad hoc preview with a separate identity/update channel; the website does not claim notarization or stable distribution. This checks availability, not installation or all native features.

Use real application captures. See [asset provenance](assets.md). The build and release procedure is in [the site README](../README.md).
