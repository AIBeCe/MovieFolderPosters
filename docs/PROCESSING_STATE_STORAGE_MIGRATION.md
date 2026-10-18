# Collection processing storage migration

Date: 2026-10-18
Status: Implemented and executed against the developer's live App Group with explicit approval on 2026-10-18.

## Purpose

Current code stores collection processing state under `CollectionProcessingState` and publishes
`CollectionProcessingStateChanged`. Older builds use the `Outcomes` directory and the earlier notification
identifier. The user selected physical migration after older host and Finder extension processes are stopped.
This is app-owned state maintenance, not a movie-directory operation.

The current factory does not silently open an empty replacement store while older records remain. It reports
`CollectionProcessingStorageNamespaceError.legacyMigrationRequired`. The host startup alert identifies that
maintenance prerequisite instead of suggesting that reopening a signed build will resolve it.

## Before running the command

1. Quit every older MovieFolderPosters app copy.
2. Disable older Finder extension copies and make sure their processes have exited; prevent relaunch throughout
   maintenance. A process-list snapshot alone cannot guarantee that Finder will not launch an enabled copy.
3. Keep the app and extension stopped until the command completes, then use the rebuilt matching app/extension.
   Do not re-enable an older build against the migrated store.

Run from the repository root only after meeting those conditions:

```sh
rtk proxy ./scripts/migrate-collection-processing-state.sh --older-processes-stopped
```

The assertion is required. The bounded developer tool builds a temporary executable linked to MovieFolderCommon,
checks one process-list snapshot for known host/extension executables, resolves the App Group with
MovieFolderEnvironment, and invokes the explicit migration API. It does not quit applications, change extension
registrations, enable/disable extensions, poll, or scan movie folders. A build or storage access failure is
reported; an unsandboxed maintenance process still needs actual access to the resolved container.

This command has been build-verified and its missing-assertion rejection tested. With explicit user approval,
it was invoked successfully against the live App Group after stopping the app and disabling extension launching.

## How data and coordination are preserved

All new-version opens and migrations hold the same nonblocking parent-directory migration lease. The migration
inspects fixed immediate children without following symlinks. It prepares a recognized regular-file marker at
the new name, then atomically swaps that marker with the old directory using Darwin `RENAME_SWAP`.

After migration:

- `CollectionProcessingState` is the original directory, with the original records and reusable lock files.
- The legacy `Outcomes` name contains a permanent regular-file marker. Keep that marker: old Persistence stores
  reject it as a directory, preventing two independently writable namespaces.
- Record bytes, per-key lock identities, serialized fields, and existing `processing-outcome-v1-` keys remain
  unchanged. This migration does not rename individual record keys or rewrite saved JSON.

An existing pinned directory descriptor survives a rename, which is why the marker does not replace the offline
prerequisite. The marker blocks future old-version opens; it does not terminate existing writers.

## Failure and retry behavior

- Both directory names present: fail and preserve both; never merge or choose one silently.
- Symlinks, special files, unrelated regular files, or malformed markers: fail without treating them as storage.
- Unsupported atomic exchange: fail without a rename-then-marker fallback. The source records remain intact.
- Interrupted marker preparation: a fully written recognized marker can resume; partial or malformed markers
  fail closed and require inspection while offline.
- Already migrated: the same operation is idempotent.
- New installation: create the legacy blocking marker before opening the new directory.
- Another new-version opener/migrator holds the lease: report busy and retry later while still offline.

The operation makes no power-loss durability claim beyond the existing filesystem and Persistence guarantees.
If a filesystem error occurs after the exchange, inspect/retry while offline rather than deleting either name.

## Verification

Temporary-directory tests cover unchanged record bytes and directory/record/lock inodes, held lock continuity,
rejection of old-style reopening, fresh initialization, explicit migration requirements, idempotency, conflicts,
symlink/foreign-file rejection, interrupted preparation, and migration-lease contention. The tests do not establish
that real older processes have stopped; that is a deployment precondition.

## Approved live migration qualification

On 2026-10-18, extension launching was disabled and the Xcode-suspended host process was stopped before
maintenance. A bounded process snapshot confirmed that no known host or extension executable remained.
The maintenance command completed successfully. A before/after integrity manifest confirmed that the original
directory inode and all seven record/lock file inodes and SHA-256 hashes were unchanged. The legacy name is
now a regular-file blocker. Finder extension registrations were already disabled and remain disabled; older
builds must not be re-enabled against this installation.

Native startup and test results following migration are recorded in COMMON_AND_LOG_MIGRATION.md.
