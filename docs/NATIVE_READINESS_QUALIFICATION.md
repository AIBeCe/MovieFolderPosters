# Native installation and access checks — R100-01

Publication update — 2026-10-18: the completed work was included in the push of `develop` through `b48d44d`.
Earlier no-push statements below describe the verification date. Native qualification limits remain unchanged.

Date: 2026-10-17, Europe/Stockholm. Issue: [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1).
The implementation and style baseline is commit `ee59871`. These checks supplement the automated evidence in
[Installation readiness](INSTALLATION_READINESS.md). Feature completion was approved and executed on 2026-10-17: local `develop` was fast-forwarded to `55ba0a6`,
`feature/installation-readiness` was deleted, and issue #1 was closed as completed. No push or reboot was performed.

## Live application observations

The existing signed host and Finder extension were running from Xcode DerivedData, both version 1.0, build 2.
These observations identify the running bundle/version; they do not establish that its executable is byte-identical
to the separately verified `/tmp/MovieFolderPosters-Style` build products.

- The Main window exposed four configured collections and accessible row explanations. Each successful row said
  that host preflight passed while Finder access and actual poster writes remained unverified. Missing processing
  outcomes appeared as unavailable, rather than invented zeros.
- **Check Installation…** opened a readable, scrollable native sheet. Its accessibility text exposed the complete
  diagnostic report. Host and embedded extension versions matched; both static signatures were valid; the extension
  setting was enabled; shared App Group read/write checks passed.
- Activation was shown as dated evidence: extension 1.0 (2), observed at `2026-10-17T14:10:37Z`. The report explicitly
  said this does not guarantee current activation. The extension process was also observed in the process list.
- Registration was labeled unknown. A finite read-only `pluginkit -m -A -D -v` query found 17 registered development
  copies. This is not proof of which copy handles a particular Finder window; no registrations were changed.
- **Open Extension Settings** opened macOS Login Items & Extensions and its File Providers sheet, with the
  MovieFolderPosters switch enabled. No extension switches or system preferences were changed.
- Settings navigation exposed the poster-layout controls and a secure TMDb token field; the token itself was neither
  displayed nor read. The Log window exposed its event table and Clear control. No setting was changed or log cleared.

This is live visual/accessibility inspection, not XCUITest execution or a VoiceOver speech session. The user's
existing collection configuration and movie contents were not changed by the qualification steps.

## Mounted filesystem checks

A temporary SwiftPM executable used the actual `Packages/FileSystem` implementation copied from the current source
baseline. It was built with Swift 6.3.3 and the macOS 26.5 SDK. All inspected folders were created inside temporary
APFS and HFS+ sparse images. Only devices belonging to those images were attached or detached.

| Scenario | Native observation |
| --- | --- |
| Writable APFS | `inspectDirectory(at:)` returned `accessible`, with stable identity and mount evidence. |
| Writable HFS+ | Returned `accessible`, with stable identity and mount evidence. |
| Read-only HFS+ mount | Returned `readOnly`; the root identity remained unchanged. |
| Directory rename on APFS/HFS+ | Stable identity was preserved after renaming the directory. |
| Replacement at the original path | The replacement had a different identity; inspection against the saved identity returned `identityChanged`. |
| APFS image detach/reattach | The directory retained its persistent identity after reattaching the same image. |
| Detached HFS+ image | Inspection with the saved mount path returned `disconnected`. |
| exFAT image | The OS rejected 64, 128, and 256 MiB image creation with `hdiutil: create failed - Operation not permitted`. No compatibility result is claimed. |

Both created image volumes were detached after inspection. Disk-image remount evidence does not qualify physical
cable/device reconnects or reboot durability. No poster or custom-icon writes were needed for these access checks.
A writable non-APFS/HFS filesystem remains conservatively unknown in the implementation; that behavior has not been
observed on an exFAT volume in this session.

## Signed sandbox authorization and process restart

Two temporary native apps were compiled against the actual FileSystem package objects from the volume probe and
signed with the existing development identity. They used a new, isolated test App Group and separate host/reader
bundle identifiers. Neither app could read production configuration or tokens through that test container.

Both apps enabled the sandbox, user-selected read/write access, app-scoped bookmarks, and the isolated application
group. One disposable folder containing a sentinel text file was used; no real collection was selected.

| Stage | Observation |
| --- | --- |
| Before folder selection | The signed host's directory inspection returned `accessDenied`. Path existence alone did not establish readiness. |
| Native folder-picker grant | The host created and reopened its security-scoped bookmark, captured stable identity, and created a transfer bookmark. |
| Separate signed reader | The reader resolved the ordinary transfer bookmark with `securityScoped: false`, checked identity, and created its own scoped bookmark. |
| New reader process | After the first reader exited, a new reader process resolved its saved bookmark with `securityScoped: true` and validated the same identity. |
| Content preservation | Sentinel bytes remained unchanged through all stages. |

All stages reported success. This exercises the production bookmark APIs under actual sandbox restrictions,
including process restart, using isolated identities and storage. It does not claim a clean installation of the
production app, the actual Finder process's authorization lifecycle, or reboot persistence.

## Evidence and cleanup

Temporary evidence from this session is under `/tmp/mfp-qualification-20261017-181444b` and
`/tmp/mfp-native-sandbox-3e3eb6d124`; a summarized volume report is `/tmp/mfp-native-volume-results.md`. These temporary
paths are local investigation artifacts and are not durable prerequisites. Raw bookmark data is excluded from this
repository. After retaining sanitized results, the test bookmark payload and disposable selected folder were removed.
The substantive observations are recorded above.

### Cleanup audit — 2026-10-24

The retained qualification record states that the sentinel bytes were unchanged during the signed bookmark handoff
test and that its disposable folder and test bookmark were removed afterward. A follow-up filesystem check found the
three temporary evidence paths listed above absent; consequently, the sentinel files could not be independently
re-hashed during this audit. No new sentinel-content claim is made.

The current production App Group settings store still contains four configured collection records. Their contents
were treated as user data and left unchanged because no record could be positively identified as the disposable
qualification collection. No configuration or icon metadata was removed. The qualification-specific temporary
container and sentinel folder were not found in the checked temporary-directory locations. The poster cache and
custom-icon metadata were not purged because the audit could not reliably separate qualification artifacts from
user-owned collection data. Thus the historical removal is recorded, but absence of every prior icon artifact is not
independently verified.

### Finder extension and File Provider registration audit — 2026-10-24

An elevated PlugInKit query returned one MovieFolderPosters extension registration, marked enabled, at the current
Xcode DerivedData app's embedded `MovieFolderPostersFinder.appex`. Its bundle metadata identifies the extension point
as `com.apple.FinderSync`; it is not a File Provider extension. The elevated PlugInKit query for
`com.apple.fileprovider-nonui` returned five entries (iCloud Drive, OneDrive, Photos, and Proton Drive), none belonging
to MovieFolderPosters. The current Finder Sync extension bundle itself was present at the registered path.

The user observed MovieFolderPosters under Login Items & Extensions → By App → File Providers. These command-line
results did not identify a separate MovieFolderPosters File Provider bundle or establish which registration backs
that Settings row. Therefore the row's exact backing bundle and why macOS presents it under File Providers remain
unresolved. No PlugInKit, LaunchServices, or Settings registration was removed or changed during this audit. A Tahoe
26.5 developer-forum report describes Finder Sync entries appearing under File Provider with duplicate or unreliable
Settings presentation ([Apple Developer Forums, thread 837043](https://developer.apple.com/forums/thread/837043)); this
is supporting context, not proof of the cause on this Mac.

## Remaining qualification limits

- A reboot is optional durability qualification, not an explicit acceptance criterion in issue #1. The user cannot
  reboot now; it remains untested.
- Physical external-device unplug/replug and exFAT/other incompatible metadata filesystems remain unqualified.
- Clean production installation and actual Finder-process bookmark repair/restart were not exercised against the
  user's existing configuration. The isolated signed handoff test provides narrower, reproducible API evidence.
- VoiceOver speech and XCUITest execution were not repeated; live accessibility inspection and the existing AppKit
  regression harnesses provide the recorded UI evidence.

These limits must remain visible during release qualification. They do not invalidate the documented installation
matrix or convert unknown filesystem/registration state into a readiness claim. The user separately approved feature completion, now recorded above. This verification record does not authorize
publication or a production release.

## Review outcome

Independent review: **PASS**. The evidence supports the recorded matrix and preserves unknown states honestly;
no material inaccuracies were found. The issue's acceptance criterion requires a documented installation/access
matrix and bounded readiness evidence, not a reboot or complete production-release qualification. The environment
limits above remain unperformed checks, not newly imposed acceptance requirements. The user subsequently approved completion. The qualification record was committed as `55ba0a6`; local `develop`
was fast-forwarded to that commit, the feature branch was deleted, and issue #1 was closed. All 236 tests passed on
the merged tree. The integration has not been pushed; the release-qualification limits above remain unchanged.
