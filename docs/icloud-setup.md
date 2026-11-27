# iCloud builds and acceptance

Folio uses iCloud Drive for reading-copy files and a CloudKit private database
for portable identities, reading positions, and deletion tombstones. The native
interfaces are implemented, but ordinary ad hoc macOS builds and unsigned iOS
builds do not establish a working cloud connection. The local test library does
not contact Apple's services.

## Apple account configuration

Use one Apple Developer team for both applications. Register the explicit app
identifiers and enable iCloud with **CloudKit** and **iCloud Documents**. Associate
both applications with the same container, `iCloud.org.popomore.folio`.

The current development identities are `org.popomore.folio.preview` on macOS
and `org.popomore.folio.ios.dev` on iOS. Preserve them when preparing development
profiles; the stable Mac identity remains `org.popomore.folio`. Handoff must use
the same team and the `org.popomore.folio.reading` activity type already declared
in each app's Info.plist.

Both builds must use the same CloudKit environment. Development and Production
databases are separate; the app also separates their local queues and content
directories. iOS Debug defaults to Development and Release to Production.
Choose a profile that grants the corresponding environment. For a production
device check from Debug, explicitly set `FOLIO_ICLOUD_ENVIRONMENT=Production`.
Do not infer the Mac environment from its build name: the signed profile decides
it, and the build script writes the matching Info.plist value. If a profile grants
multiple environments, preview builds select Development and release builds select
Production. Set `FOLIO_ICLOUD_ENVIRONMENT` to select another authorized environment;
an explicit value outside the profile's grant is rejected. Scalar grants and
single-value arrays select their sole environment.

## macOS

Create an iCloud-enabled provisioning profile for the development Mac app ID,
using the same team and certificate as the signing identity. An Apple Development
profile can exercise the Development environment; a Developer ID profile uses
the environment it grants. Pass its local path to the build script:

```sh
FOLIO_ICLOUD_PROFILE=/path/to/Folio.provisionprofile \
FOLIO_APPLE_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' \
scripts/build-macos
```

The script checks expiration, team, app identifier, container, services, and
environment, embeds the profile, and signs the app with the requested iCloud
entitlements. Its default ad hoc build retains the existing preview identity and
shows that iCloud is not enabled for that build.

Stable packaging can use the same `FOLIO_ICLOUD_PROFILE` input alongside its
existing Developer ID, version, appcast, notarization, and release-source checks.
The release workflow does not supply a profile automatically. This change does
not register identifiers, configure release secrets, notarize, or publish builds.

## iPhone and iPad

Open `apps/ios/Folio.xcodeproj`, select the Folio app target, and choose the same
development team in **Signing & Capabilities**. Use a physical device signed in
to the same Apple account as the Mac, with iCloud Drive enabled. Refresh the
provisioning profile after associating the container. Build and run through
Xcode; the existing unsigned compile check is not a device installation.

`Folio.entitlements` declares the shared container and both services. Confirm the
signed entitlements agree with `FolioCloudEnvironment` in the built Info.plist.
The test targets do not receive production cloud credentials.

## CloudKit schema

Folio creates a custom zone named `FolioReadingLibrary` in the private database.
It uses record types `FolioReadingCopy` and `FolioReadingPosition`, each with a
`payload` field of type **Bytes** containing the application data.
It fetches zone changes directly, so no query indexes are required.

Before testing Production, deploy these record types and fields from the
Development schema in CloudKit Console. Schema deployment does not copy private
user records. Keep deleted-copy tombstones; removing them can allow an old client
to recreate a retired generation. This task does not deploy a production schema.

## Physical-device acceptance

1. Start matching signed builds on the Mac and iPhone or iPad. Confirm iCloud is
   connected on both, with the same environment and Apple account.
2. On the Mac, open a separate fixture folder containing Markdown, relative
   images, a linked document, and a PDF. Record its source bytes, then choose
   **Send Folder with Assets** and confirm the copy operation.
3. On the other device, open **Continue Reading**. Confirm all files and assets
   arrive, the copy is read-only, and heading/paragraph or PDF-page continuation
   works across different screen sizes. Follow a relative link, then relaunch.
4. Exercise Handoff in both directions. It carries an identity and location;
   document content comes from iCloud Drive. For a linked user-owned folder,
   grant access through the receiving device's folder picker when requested.
5. In **Settings > iCloud > Manage Reading Copies**, cancel a deletion, remove
   a local download, reopen it, and delete a selected copy or folder. Verify the
   other device retires its entry after refresh, and every source byte remains.
6. Repeat offline, reconnect, change accounts, and check a second offline device.
   Review unresolved file versions and recovery drafts before cleanup. Verify
   linked user-owned documents never appear as deletion candidates.

Provider synchronization, actual server deletion, background arrival, signing,
and Handoff are physical-device acceptance items. A local file path or successful
fixture result alone does not prove another device can retrieve the content.

## Isolated local UI checks

The XCTest cloud tests use filesystem metadata and explicit temporary roots.
iOS UI tests additionally set `FOLIO_CLOUD_TEST_LIBRARY=1` with a unique
`FOLIO_UI_TEST_LIBRARY`. The Mac fixture requires a separate instance:

```sh
FOLIO_CLOUD_FIXTURE=1 \
FOLIO_CLOUD_QA_DIRECTORY=/tmp/FolioCloudQA \
.build/preview/Folio.app/Contents/MacOS/Folio --folio-new-instance
```

The status reads **Local Test Library**. These flags exercise actual native
screens and local file protection without claiming a connection to iCloud.

## Platform references

- [Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)
- [Implementing Handoff in Your App](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app)
- [CloudKit containers and environments](https://developer.apple.com/documentation/cloudkit/ckcontainer)
- [Supported capabilities on macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
