# Native installation and access checks — R100-01

Date: 2026-10-17, Europe/Stockholm. Issue: [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1).
The implementation and style baseline is commit `ee59871`. These checks supplement the automated evidence in
[Installation readiness](INSTALLATION_READINESS.md). The user authorized feature completion on 2026-10-17 after verification, including a fast-forward integration into
`develop` and issue closure. No reboot was performed.

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

## Remaining qualification limits

- A reboot is optional durability qualification, not an explicit acceptance criterion in issue #1. The user cannot
  reboot now; it remains untested.
- Physical external-device unplug/replug and exFAT/other incompatible metadata filesystems remain unqualified.
- Clean production installation and actual Finder-process bookmark repair/restart were not exercised against the
  user's existing configuration. The isolated signed handoff test provides narrower, reproducible API evidence.
- VoiceOver speech and XCUITest execution were not repeated; live accessibility inspection and the existing AppKit
  regression harnesses provide the recorded UI evidence.

These limits must remain visible during release qualification. They do not invalidate the documented installation
matrix or convert unknown filesystem/registration state into a readiness claim. No issue closure, integration,
push, or release is authorized by this verification record.

## Review outcome

Independent review: **PASS**. The evidence supports the recorded matrix and preserves unknown states honestly;
no material inaccuracies were found. The issue's acceptance criterion requires a documented installation/access
matrix and bounded readiness evidence, not a reboot or complete production-release qualification. The environment
limits above remain unperformed checks, not newly imposed acceptance requirements. The user subsequently authorized committing this documentation, completing the feature through a verified
fast-forward integration into `develop`, and closing issue #1. Git history records the resulting commits and
integration; the release-qualification limits above remain unchanged.
