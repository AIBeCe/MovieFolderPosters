# Finder poster actions

Phase 7 adds four **Movie Poster:** commands to Finder's contextual menu for one selected immediate child directory of a configured
collection. Files, hidden folders, nested descendants, unrelated locations, and multiple selections do not receive it.

The actions are **Refresh Poster**, **Change Movie Match**, **Remove Poster**, and **View on TMDb**. Each opens a small
AppKit host window for that folder. Opening a window performs no network request or icon change. Choose its explicit
button to proceed. The host remains a configuration and manual-action utility; Finder remains the movie browser.

## Behavior

- Refresh downloads the saved match's poster again. Without a saved match, it performs a fresh conservative search.
  An unresolved result remains unchanged and can be handled with Change Movie Match.
- Change searches the entered title and optional year. Only results with posters can be applied. Candidate titles,
  original titles, years, and TMDb IDs distinguish results; the selected movie's TMDb page provides further details.
  The user must explicitly select and apply a result. Incomplete first-page searches are labeled rather than guessed.
- Remove clears only a verifiably application-assigned icon. It stores suppression metadata first so automatic
  processing does not immediately restore the poster, including after a credential revision. Explicit refresh or
  selection can assign it again.
- View opens the saved matched movie's exact HTTPS TMDb URL. It does not need a credential or metadata request.

Removing a root from Settings retains its icons. Removing a poster does not rename or change movie files.
Old poster icons installed before ownership recording, unrelated custom icons, and icons the user replaces are
preserved. If an old icon has no ownership proof, remove it manually in Finder before assigning a new poster.

## Ownership and filesystem effects

Finder stores the actual icon resource on the hidden regular `Icon\r` file. A native probe showed its ResourceFork
changing when a red icon was replaced with blue, while the folder FinderInfo custom-icon flag alone was insufficient.
FileSystem records the directory identity and a SHA-256 digest of that file's data and ResourceFork in an ownership
xattr. Before replacement or removal, it checks identity, the current Finder custom-icon flag, and the current digest.
A user replacement invalidates ownership even if it leaves the old marker behind. Missing or unreadable evidence is
handled conservatively. No-follow descriptors reject symlink evidence and reads have a size bound.

Removal writes a suppression xattr on the folder before clearing its icon. A failure to persist suppression prevents
removal. Assignment records ownership on a best-effort basis; filesystems that cannot retain that proof still display
posters, but subsequent replacement/removal will preserve them. Native icon metadata and these xattrs are the only
movie-folder changes. The icon-assignment mutex serializes operations within a process; root leases serialize app
operations across processes. Other applications do not participate in those locks.

## Integration and permissions

Finder reads selected-item URLs only while building the menu or handling its action, as required by Apple's API.
It captures a configured root ID, immediate child name, and directory identity, then opens the containing host application with that captured identity. The custom URL scheme carries no credential or bookmark. Unique scalar tags keep stale menu callbacks from targeting a newer selection. Strict parsing
rejects extra/duplicate fields, traversal names, unexpected hosts, and oversized requests. External invocation can
only open the confirmation window; it cannot authorize filesystem access or trigger a mutation.

The host independently finds the configured root, acquires its own persistent authorization, and validates the child.
Scoped access remains alive throughout awaited work. Close the window or change settings to cancel pending UI work.
Before a manual write, a synchronous settings lease validates the current grant, root path, credential revision, and
fixture mode, and stays held through the icon and record update. Network waits do not hold that settings lease.

Automatic and manual processing share revision-independent `ProcessingLocks` root leases. Processing records remain
under the credential revision, as established in Phase 6. Consequently saved match lookup after a credential change
may require a new explicit selection, while icon ownership and removal suppression remain available on the folder.
No background process, watcher, polling scan, new package, or third-party dependency was introduced.

The host now needs outgoing network access for explicit movie searches and poster downloads. Credentials remain in
the shared Data Protection Keychain. Release always uses live TMDb; Debug fixture transport remains explicitly opt-in
and requires a configured credential.

## Verification

See [Phase 7 verification](PHASE_7_VERIFICATION.md) for executed evidence and limits.

Relevant Apple API documentation:

- [Finder Sync contextual menus](https://developer.apple.com/documentation/findersync/fifindersyncprotocol/menu(for:))
- [Selected item URL callback restrictions](https://developer.apple.com/documentation/findersync/fifindersynccontroller/selecteditemurls())
- [Finder Sync lifecycle guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
