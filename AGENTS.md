# Contributions

- Write commit subjects and bodies, and pull request titles and descriptions, in English.
- Open a pull request against `main`. Include the reason for the change and the checks that cover it.
- Maintainers run the organization’s Meta merge check before merging and use the Meta merge command after explicit merge approval.
- Keep user-facing UI strings and source comments in English. Put translations in locale resources when localization is available.

# macOS

- Build with `scripts/build-macos`. Verify changes to reading or saving from the native app with separate fixtures. Preserve the development bundle identity.
- Run `scripts/check-quicklook` against the built app when changing Finder previews.

# Rust

- Manage the minimum Rust version in `Cargo.toml` and the compiler toolchain in `rust-toolchain.toml`.
- Use `scripts/check-consumer` to verify public `folio-core` APIs. Keep AppKit, Finder, and other platform integration in the macOS app.

# iOS

- Build with `scripts/build-ios [simulator|device]` or the shared Folio Xcode scheme. Preserve the `org.popomore.folio.ios.dev` development identity.
- Run `scripts/check-ios` for native fixture and UI tests. Use `FOLIO_IOS_SIMULATOR` to select a simulator; verify iPhone and iPad navigation when changing layout.
- Keep document-picker permissions, security-scoped bookmarks, and file coordination in the iOS app. Build `folio-bridge` with `--no-default-features` for iOS.
- Verify reading and saving with separate fixtures, including conflicts and draft recovery. Keep simulator, unsigned device compilation, signed device use, and TestFlight evidence separate.

# Releases

- Use a clean checkout of `origin/main` with passing Folio CI. Derive the release version from the tag.
- Check existing tags before creating a release tag. Get approval before moving a pushed tag.
- Verify the Release Folio for macOS workflow, published files, and signed update feed.
