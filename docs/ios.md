# Folio for iPhone and iPad

The native iOS application uses SwiftUI for navigation and editing, WebKit for
offline rendered documents, PDFKit for PDFs, and AVKit for media. It shares
`folio-core`, the Foundation-only Swift bridge models, reader themes, and renderer
assets with macOS. It requires iOS 17 or later.

## Build and run

Use an Apple Silicon Mac, Xcode 27.2, and the repository's pinned Rust and Node
toolchains. Install the iOS Rust targets once:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ios simulator
```

The build prints the path to `Folio.app`. Install it on a booted simulator with:

```sh
xcrun simctl install booted .build/ios/Build/Products/Debug-iphonesimulator/Folio.app
xcrun simctl launch booted org.popomore.folio.ios.dev
```

Alternatively, open `apps/ios/Folio.xcodeproj`, select **Folio**, and run on an
iPhone or iPad simulator. The build phase compiles the Rust bridge without Git
and bundles the offline renderer. No Xcode project generator is required.

```sh
scripts/build-ios device
```

This command produces an unsigned device build for compilation checks. To install
on a physical device, select your development team in Xcode's Signing &
Capabilities panel and run from Xcode. The development identifier is
`org.popomore.folio.ios.dev`; it does not change the macOS bundle identities.
There is no iOS release or TestFlight upload workflow in this change.

## Reading and editing

- **Add Folder** uses the system Files picker and opens the selected directory
  in place. Saved folders survive restarts through security-scoped bookmarks.
- **Import Files** copies only the selected files into Folio's Imported Files
  folder. Name collisions receive a numeric suffix. Editing the copy leaves the
  original unchanged. Files shared to Folio use this same import flow.
- **Explore Sample Folder** installs a separate, editable sample project inside
  Folio. Reopening it preserves any edits; it does not reset the project.
- Folder search filters the current directory. Pull to refresh or use
  **Refresh Folder** after external changes. **Reload Document** refreshes a
  document; unsaved recovery drafts remain available for review.
- Markdown, UTF-8 text/source, sanitized HTML, CSV/TSV, Mermaid, and Vega-Lite use
  the shared renderer. Relative document links and local images stay within the
  selected folder. Remote images, scripts, and chart datasets are blocked.
  Tapped HTTP, HTTPS, and mail links open through the system.
- PDF, common images, RTF, audio, and video use native readers. Native previews
  use temporary private copies and do not hold a File Provider operation open.
  Media does not start automatically.
- **Edit Document** is available for Markdown and plain text. **Save** checks
  the exact content revision read from disk, preserves UTF-8 BOM and CRLF, and
  refuses to replace a file changed elsewhere. The editor keeps its draft and
  offers a share action if saving fails.
- Recovery drafts are kept in Application Support, protected when the device is
  locked, and restored on reopening the document. Review the recovered draft,
  save it if the revision still matches, or explicitly discard it.
- **Settings** controls system/light/dark appearance, text size, and serif text,
  and provides the iCloud library and reading-copy manager. Native controls and
  document typography follow Dynamic Type.
- In an iCloud-enabled build, **Continue on Another Device** sends a document;
  **Send Folder with Assets** preserves its relative documents and images.
  **Continue Reading** resumes a read-only copy at its heading, paragraph, or
  PDF page. A separately linked iCloud document stays editable in its folder.
- **Settings > iCloud > Manage Reading Copies** supports selection, cloud
  deletion, pending-operation retry/cancellation, and **Remove Download**.
  Cleanup keeps the original files and excludes linked user-owned documents.

The Rust core limits text previews and edits to 8 MiB and directory listings to
5,000 entries. Imports, exports, and native snapshots are limited to 128 MiB per
file, and inline images to 24 MiB. Hidden files and symbolic links are not listed.
Unknown formats, archives, and 3D models have a share action but no iOS preview.
Git, archive browsing, and interactive 3D viewing remain macOS features.

## Validate

```sh
scripts/check-ios
FOLIO_IOS_SIMULATOR=<simulator-uuid> scripts/check-ios
FOLIO_IOS_RESULT_BUNDLE=/tmp/Folio-iOS.xcresult scripts/check-ios
cargo test --locked -p folio-bridge --no-default-features
```

`scripts/check-ios` uses a booted iPhone or another available iPhone when no UUID
is supplied, and waits for the selected simulator to finish booting before
starting XCTest. Set the UUID to an iPad to run the same suite against the split-view
layout. The suite includes coordinated read/write, content conflicts, selected
folder boundaries, import copies, persisted bookmarks, native snapshot limits,
draft recovery, and native UI navigation, rendering, saving, cancellation,
settings, and system picker presentation. UI tests use separate app-local fixture
directories, and retain screenshots in the Xcode test result.

The CI gate requires iOS checks alongside the existing Rust, macOS, and release
checks. It compiles simulator and device targets, runs the iOS suite, and retains
the `.xcresult` bundle and its screenshots as a seven-day workflow artifact.

Simulator checks do not establish physical-device performance, VoiceOver
acceptance, third-party or iCloud File Provider behavior, device signing, or
TestFlight availability. Those remain separate acceptance steps.

Cross-device reading and management are implemented in source. Follow
[iCloud setup](icloud-setup.md) to provision matching builds and validate actual
cloud synchronization and Handoff. The automated local library exercises the
[sharing and cleanup contract](icloud-sharing.md) without contacting iCloud.

The file-access implementation follows Apple's
[directory access guidance](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
and uses a per-operation
[file coordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator).
Rust targets follow the official
[iOS platform support guide](https://doc.rust-lang.org/stable/rustc/platform-support/apple-ios.html).
