# Website asset provenance

Captured/verified on 2026-11-16. Migrated byte-for-byte from [Mill 6c68c515](https://github.com/popomore-org/mill/tree/6c68c5157dcc2cc53f1ca8b0816ffd559c4f2b26/products/chuome/apps/folio-site). These are real native application images.

| File | Origin | Treatment |
| --- | --- | --- |
| `public/images/reading.webp` | Current installed Folio 0.1.1 preview, copied into a separate `org.popomore.folio.websiteqa` bundle for capture | Native window screenshot, 2260 × 1520, WebP compression only. No fabricated or redrawn interface. |
| `public/images/split.webp` | Same isolated Folio app, independent left/right reading panes | Same size and compression. |
| `public/images/preview.webp` | Installed Folio preview opened with `folio -n preview Result.md` in a separate `org.popomore.folio.viewqa` app copy | Native 1360 × 1160 quick-preview capture, WebP compression only. Used for the agent companion-view positioning. |
| `public/icon.png` | Installed Folio app's `Folio.icns` | Converted to PNG, preserving the icon. |

Folio's sample documents are tracked in [the original public fixtures](https://github.com/popomore-org/mill/tree/6c68c5157dcc2cc53f1ca8b0816ffd559c4f2b26/.goals/2026-11-16-product-websites/fixtures). Only those documents were opened in the isolated QA workspace. A screenshot may include macOS's screen-sharing indicator in the title bar; this is native capture chrome, not an added Folio feature. The original installed app and its saved folders were not replaced or edited. The temporary QA instance was closed after capture.

The quick-preview sample is [the original quick-preview sample](https://github.com/popomore-org/mill/blob/6c68c5157dcc2cc53f1ca8b0816ffd559c4f2b26/.goals/2026-11-16-product-websites/fixtures/Agent%20Output/Result.md). The user specifically positioned Folio as a simple view alongside an agent, so the real compact preview is now the hero. The full workspace and split-pane image are secondary; no generated software UI or pretend agent conversation is shipped.

During the copy revision, the fixture was changed to ordinary project notes, a file table, and a review checklist. The existing `preview.webp` still shows the earlier fixture: the native capture connection failed to start, including after a runtime reset. A new screenshot has not been captured. The isolated capture app was stopped and removed; the installed application was not modified.


Native screenshots establish visual appearance, not acceptance of every feature or the downloaded binary. Third-party artwork retains its original rights.
