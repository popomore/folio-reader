# iCloud sharing and manual cleanup

Status: implemented in the shared Swift sources and native macOS/iOS interfaces.
Live synchronization requires [provisioned iCloud-enabled builds](icloud-setup.md).
Automated local-library checks do not establish physical-device cloud or Handoff
acceptance.

## Cross-device reading

Support one person's devices using the same Apple account. A person reading on a
Mac can open Folio on their iPhone or iPad, select a **Continue Reading** entry,
and resume the corresponding document and reading location.

Files already in an accessible iCloud Drive folder stay in that folder. Files
outside iCloud use **Continue on Another Device** to create a reading copy in
Folio's iCloud library. Keep that copy explicitly distinct from its source file.
For Markdown with relative assets and links, allow adding the document folder so
the selected content retains its structure.

Reading copies are read-only snapshots. Sending a source again explicitly creates
a new copy; later source edits do not silently replace an existing snapshot.
Already-linked iCloud documents remain editable in their original folders.
Saves refuse unresolved iCloud versions and preserve recovery drafts.

Use iCloud Drive for content and a shared CloudKit private container for portable
document identities and reading records. Local paths and permission bookmarks
remain device-local. Handoff provides a nearby continuation entry using the same
portable identity; the persistent library remains available without Handoff.
Store heading or paragraph locations and PDF page positions, with reading
progress as a fallback for different screen sizes.

## Entry point

Use **Settings > iCloud > Manage Reading Copies** on all three platforms. On iOS,
use general settings, retaining its appearance and reading sections. On macOS, add an
iCloud settings page alongside the existing settings pages.

The entry opens a native **Reading Copies** list on iPhone, iPad, and Mac.
Each row identifies a Folio-created reading copy and shows its filename, source
device, size when known, last-read date, and any pending operation. Allow sorting
by size or last read, selecting individual rows, and selecting all eligible rows.
Show the known size of the selection without treating unknown sizes as zero.

Only Folio-created cloud reading copies are eligible for deletion here. Existing
user-owned iCloud documents and saved folder permissions are outside this list.
The first version uses manual cleanup. Do not add automatic expiry as part of
this entry point.

## Actions and scope

| Action | Effect |
| --- | --- |
| **Delete iCloud Copy** | Delete the selected Folio-created reading copy and retire its entry across synced Folio libraries. Keep the source file. |
| **Delete Selected Copies** | Apply the same operation to the explicitly selected copies. |
| **Remove Download** | Evict only a clean local download or private reading cache. Keep cloud content and the library entry. |
| Remove a recent-reading entry | Change the recent-reading list only. Keep all files. |

For a copied folder, show that the selection includes its contained documents
and assets, and delete the managed copy as one unit. Never expand a selection
into source directories or other user-owned iCloud folders.

Before cloud deletion, show the selected names or count and a confirmation such
as **Delete 3 iCloud Reading Copies?** Explain: **These reading copies and included
assets will be removed from iCloud and your other devices. Original files will be
kept.** Provide **Cancel** and **Delete Copies**, with the latter
marked as destructive. Do not promise recovery or a specific space-reclamation
time until the implementation and device tests establish that behavior.

An item with unsaved edits, a recovery draft, or a pending save must first offer
review, save, or explicit discard. Cloud cleanup and local-download eviction
must not silently destroy those edits.
The copy manifest records every included file and its hash. Changed or additional
files in a managed copy or private download stop cleanup for review.

## Progress and failures

Show loading, empty, unavailable-account, pending-deletion, and per-item failure
states. If offline, retain an explicit pending operation and allow cancellation
before cloud deletion starts. Report completion only after the cloud operation
succeeds. A partial failure keeps failed items visible with a retry action;
successful deletions remain complete.
An unpublished copy can also be deleted without publishing it on reconnection.
Cancelling its deletion retains the original upload request. Once the server has
accepted deletion, cancellation cannot restore that generation.

Use a portable copy ID and generation for deletion. Reject a stale selection if
the copy was replaced or changed, and request review of the current item. Keep
a synchronized deletion record so stale clients, old reading sessions, and
queued uploads cannot recreate a deleted generation. A later explicit
**Continue on Another Device** action can create a new copy generation.
Retired copies that arrive late from iCloud Drive are cleaned again after their
ownership and content are verified. Account and CloudKit environment changes
isolate cached files and queued work.

Deleting a reading copy must also retire its continuation entry. Other devices
must not offer a broken **Continue Reading** action after receiving the deletion.
They can show pending synchronization while their cached state catches up.
Refresh on foreground activation, iCloud document-query changes, and every
30 seconds while active. The initial implementation does not use background
CloudKit push subscriptions.

## Acceptance before shipping

- Open the management screen on iPhone, iPad, and Mac; verify native selection,
  large text, VoiceOver labels, sizes, and last-read ordering.
- Create a reading copy on Mac, read it on a signed-in physical iPhone, delete
  the copy manually, and verify cloud deletion and both devices' library state.
- Verify the source file's bytes and location are unchanged after copy deletion.
  Verify user-owned iCloud documents never become cleanup candidates.
- Exercise single-copy, batch, and copied-folder deletion, including assets,
  unknown sizes, partial failures, retries, and repeated deletion requests.
- Verify **Cancel** performs no deletion, and **Remove Download** allows the
  cloud copy to be downloaded and read again.
- Verify offline pending deletion, account changes, an outdated selection, an
  offline second device, and a queued upload cannot delete or resurrect the
  wrong generation.
- Verify open editors and recovery drafts survive until explicitly resolved;
  deleting a cloud entry cannot trigger a later stale-session upload.

## Platform references

- [Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)
- [Implementing Handoff in Your App](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app)
- [CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)
