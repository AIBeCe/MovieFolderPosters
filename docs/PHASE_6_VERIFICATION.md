# Phase 6 verification

Scope: minimal AppKit configuration, authorized folders, shared settings and secure credential configuration.
Branch: `feature/directory-configuration`, created from develop. Earlier approved source dependencies were carried
forward without merging their feature branches. No push, merge, or Phase 7 implementation is included.

Environment: macOS 26.5, Xcode 26.6, Swift 6 with complete concurrency checking. Verification ran on 2026-10-11/12.

## Automated evidence

| Check | Result |
| --- | --- |
| FileSystem package | 29 tests passed, including transfer and persistent access leases, cancellation lifetime, and symlink rejection |
| Persistence package | 8 tests passed with sandbox-compatible search-only ancestor traversal |
| Configuration view model | 5 tests passed; actual AppKit UI sources compiled |
| Configuration repository, host service, and observation scheduler | 16 tests passed in Debug and 16 in Release |
| Processing regression | 19 tests passed, including cancellation, preservation, caching, and 498 cached folders plus 2 new folders |
| Signed Debug app and extension | Final build and native window startup passed |
| Signed Release app and extension | Final build and strict signature checks passed for both bundles |
| Xcode build-for-testing | Passed |
| Native launch UI test | 1 passed; configuration controls appeared without a startup alert |
| Independent source/security review | PASS; cancellation ownership, reload observation, credential transaction, and reopen findings resolved |

The final incremental review also passed bounded contention retry, authorization version protection, selection handling,
and removal of the obsolete hardcoded development configuration. Source checks enforce the 120-character Swift limit.
The expected App Intents metadata warning does not indicate a source or signing failure.

## Native sandbox and Finder evidence

A collection outside the original hardcoded sandbox exception was selected through the actual host NSOpenPanel.
The UI reported available access. An invalid fixture credential was stored through the UI in the shared Data Protection
Keychain, and the secure text field cleared. The extension read it successfully without a prompt.

With explicitly enabled Debug fixture transport, opening that collection in Finder produced a poster for
`The.Last.Frame.2026.1080p.WEB-DL`; `Unknown.Movie.2026.1080p.WEB-DL` retained its default folder icon.
Extension logs recorded two searches, one configuration request, one poster download, and one unresolved result.
The image remained proportional and Finder remained responsive.

For a stronger persistent-access probe, the host was closed and the shared ordinary transfer bookmark was deliberately
made unusable. Finder and the extension were restarted, and a new matching child folder was added. A fresh extension
process assigned its poster using its own persistent bookmark and cached image. No new metadata request was needed.
The original settings were restored after the probe. Movie file hashes stayed unchanged throughout.

Host-owned authorization was temporarily removed for the isolated fixture record. The UI correctly showed that access
needed restoration. **Locate Folder** authorized the same directory again and returned it to available status.
**Remove** unregistered the root; **Remove Token** reported no configured token. The invalid fixture credential was
removed and development fixture mode was disabled after verification. Poster icons remained on the test folders.

Screenshots captured during verification:

- `/tmp/MovieFolderPosters-Phase6-finder.png`
- `/tmp/MovieFolderPosters-Phase6-config.png`

These are local evidence artifacts, not committed application assets.

## Failures investigated and corrected

- Removing the nib exposed the default AppKit entry-point dependency. An explicit application/delegate lifetime
  restored programmatic window startup.
- The reported storage alert came from read-opening sandbox-restricted ancestors before reaching the App Group.
  `O_SEARCH` traversal fixed the actual signed host; no sandbox relaxation was introduced.
- Simultaneous Finder extension processes could contend for the shared configuration lease and lose registration.
  Event-triggered reads now retry contention for a finite maximum of 140 ms. Other failures are not retried.
- UI selection callbacks reloaded the table. They now update controls without recursive reloads.

## Limits and remaining work

- No valid production TMDb credential or live API request was used. Network behavior remains covered by controlled tests.
- Reboot and physically unmounted external-volume recovery were not tested. Process restart and native authorization
  repair were tested; unavailable and missing authorization states have unit coverage.
- Finder observation is not a file watcher. Duplicate windows may not trigger processing; reopening a collection may
  be necessary after additions. Separate Open/Save dialog extension instances share records and leases.
- The implicit bookmark handoff can expire before an extension establishes persistent access; reopening the host and
  refreshing or locating the directory supplies a new handoff.
- Multiple copies of development builds can be registered by PluginKit; launch the intended build when testing.
- Old private bookmark records and poster caches are retained; no cleanup service was introduced.

The preferred extension-only processing architecture remains viable on the tested Mac: arbitrary selected-root access,
shared credentials, Finder-triggered assignment, and access after host/extension termination were demonstrated.
Phase 7 remains pending separate authorization.
