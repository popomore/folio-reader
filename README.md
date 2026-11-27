<p align="center">
  <img src="assets/folio.png" width="112" height="112" alt="Folio app icon">
</p>

<h1 align="center">Folio</h1>

Folio is an open-source reader for local project files. Browse saved folders, read documents, and make small edits without leaving the workspace. The macOS app supports tabs and split panes; the iPhone and iPad app uses native folder navigation and currently builds from source. The Rust core can also be embedded in other applications.

## Highlights

- **Read local files.** Preview Markdown, text, static HTML, RTF, PDF, images, audio, video, and 3D models. Browse archives, view CSV and TSV as tables, and render Mermaid or Vega-Lite diagrams.
- **Keep related files together.** Save multiple folders, open tabs and split panes, jump to Markdown headings, and inspect Git history and diffs.
- **Customize reading.** Choose a light or dark appearance and edit the JSON palettes in **Settings → Appearance → Themes**.
- **Edit in place.** Switch between reading, source, and source with live preview. Use Command-S to save.
- **Preview from Finder or Raycast.** Press Space in Finder for Quick Look, or use the bundled CLI to open a floating Folio preview.

## Install on macOS

Folio builds for Apple Silicon and requires macOS 14 or later. Download a build from [GitHub Releases](https://github.com/popomore/folio-reader/releases), open the DMG, and drag the app to Applications. Releases marked **Pre-release** are preview builds.

Open Folio once to register its Finder extension. Manage it under **System Settings → General → Login Items & Extensions → Quick Look**. macOS chooses the provider when multiple apps support the same file type.

## Themes

In **Settings → Appearance → Themes**, choose **Open Theme Folder** to find
[folio-light.json](apps/macos/Themes/folio-light.json) and
[folio-dark.json](apps/macos/Themes/folio-dark.json). Edit either file and choose
**Reload Themes**. Omitted colors inherit the defaults. Finder Quick Look uses
the bundled colors.

## 3D models and printing

Open **STL, OBJ, PLY, glTF, GLB, and 3MF** files in a workspace or floating preview.
Drag to rotate, scroll to zoom, and right-drag to pan. Use **Reset view** or **R**
to fit the model and **Wireframe** or **W** to inspect its mesh. Finder Quick Look
shows a still image of self-contained models. If a glTF or GLB needs sibling
buffers or textures, Quick Look reports that it must be opened in Folio; the
workspace and floating preview can load those files from the model folder.

3MF previews include mesh geometry, component and build transforms, physical
units, base materials, vertex colors, and production-extension references to
other model parts in the archive, including common Bambu Studio and PrusaSlicer
projects. Texture maps, slicer paint, printer settings, and toolpaths are not
shown. A sliced `.gcode.3mf` without model geometry reports that no model is
available. This preview does not check whether a model can be printed.

Models render offline. glTF buffers and textures must be embedded or stored in
the model's folder or its subfolders; network resources and parent-directory
references are blocked. OBJ previews show geometry and vertex colors without
external MTL materials. glTF extensions that need separate compression decoders
are not supported. Preview limits are 128 MiB per file, 256 MiB of local resources
or unpacked 3MF model XML, and two million displayed triangles.

## Archives

Open ZIP, TAR, 7Z, and RAR archives, including TAR compressed with gzip, bzip2,
or xz (`.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz`, `.tbz2`, `.tar.xz`, and `.txz`).
Standalone `.gz`, `.bz2`, and `.xz` files are also supported. Browse the file
tree or filter by path, then select a file to preview it. Relative links and
local images work within the archive. Floating previews use the same browser;
Finder Quick Look shows a file listing.

Archive contents are read only. Folio unpacks them into a private temporary
folder and removes it when the preview is released, without changing the
archive or writing into its original folder. Password-protected archives are
not supported. Links, special files, and Git metadata are not previewed.
Limits are 128 MiB per input archive or unpacked file, 256 MiB total unpacked,
10,000 entries including parent directories, and three nested archive levels.
Quick Look lists up to 500 entries and identifies longer listings.

## Command line

Once Folio is in Applications, install the bundled command into `~/.local/bin`. For the original preview, replace `Folio.app` in the path with `Folio Preview.app`.

```sh
/Applications/Folio.app/Contents/Helpers/folio install
```

Add that directory to `PATH` if needed.

```sh
folio .                        # Open the current folder
folio "Project Notes.md"       # Open a file in the workspace
folio preview "Project Notes.md"
folio --reuse .                # Use an existing Folio instance if available
folio --help
```

By default, `folio` and `folio preview` start a separate Folio process with an independent workspace. `-n` and `--new-instance` also select that behavior.

To use Raycast, add [integrations/raycast](integrations/raycast) to its Script Commands and run **Preview in Folio**.

## Build macOS from source

Use an Apple Silicon Mac with Xcode 27.2 and the Rust and Node toolchains pinned in the repository.

```sh
app="$(scripts/build-macos)"
open "$app"
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cargo test --locked -p folio-core --no-default-features
npm test --prefix renderer
scripts/check-consumer
scripts/check-quicklook "$app"
scripts/check-model-preview "$app"
scripts/check-archive-preview "$app"
```

## Build iOS from source

The iOS app supports iPhone and iPad on iOS 17 or later. Add a folder from Files
to read and edit in place, or import individual files to keep a copy in Folio.
It includes Markdown, source text, HTML, tables, Mermaid and Vega-Lite previews,
native PDF, image and media readers, and revision-checked Markdown/text editing
with recovery drafts. Git, archive browsing, and interactive 3D previews remain
macOS features.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ios simulator
scripts/check-ios
scripts/build-ios device
```

Open `apps/ios/Folio.xcodeproj` and select the **Folio** scheme to run from Xcode.
Device installation needs your signing team; the command-line device build only
checks compilation. See the [iOS development guide](docs/ios.md) for setup,
simulator selection, file-access behavior, and validation boundaries.

## Embed the Rust core

Use [folio-core](crates/folio-core) as a Cargo `path` or `git` dependency. The default `git` feature adds local read-only history and change inspection. Set `default-features = false` to use document and workspace APIs without Git support.

```rust
use folio_core::Workspace;

let folder = Workspace::open("/path/to/workspace")?;
let document = folder.read("notes/readme.md")?;
if let Some(preview) = document.preview {
    for heading in preview.headings {
        println!("{}", heading.title);
    }
}
# Ok::<(), folio_core::Error>(())
```

The caller grants access to a workspace and decides how to present its files. The macOS app supplies its own renderer and chart engines.

## Contribute

Open an [issue](https://github.com/popomore/folio-reader/issues) for a bug or feature request. Include your macOS version, Folio version, and a sample file you can share when the issue depends on specific file content. Send changes through pull requests. Use English for commit messages and pull request titles and descriptions. [Contributor instructions](AGENTS.md)

[macOS release and update guide](docs/macos-updates.md)

## License

Folio is released under the [MIT License](LICENSE). Third-party dependencies and bundled assets retain their respective licenses.
