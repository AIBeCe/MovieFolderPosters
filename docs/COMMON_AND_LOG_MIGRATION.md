# Common and Log package implementation

Date: 2026-10-18
Status: Implemented, independently reviewed, and committed as `e7d404b` on 2026-10-18.
The commit is present in `develop` and the locally recorded `origin/develop` at `fd9eb83`.
GitHub issue #3 remains open at live read-back on 2026-10-18.

## Current delivery handoff — 2026-10-18

The current Git evidence supersedes the uncommitted/unmerged review boundaries recorded below, which
describe earlier checkpoints. The implementation is integrated; tracker closure remains outstanding.
No additional native qualification is inferred from integration. Existing verification limitations remain.
The user requested moving to the R100-04 / issue #4 proposal; product changes still await code approval.

## Approved design

The host application and Finder extension consume one local `MovieFolderCommon` module instead of compiling
the same application sources into each executable. Organize its sources and tests by Activity, Configuration,
Processing (including Collections), Development, FinderIntegration, and Security. Keep entitlements and explicit
Debug fixture selection on executable targets. Shared setup and fixture implementations live in Common.
Preserve the App Group and Keychain identifiers, configuration/processing-state serialization, record keys,
and existing processing behavior. The subsequently approved namespace rename uses an explicit offline migration.

A separate local `Log` module owns reusable bounded activity history and depends on `Persistence`.
Its Activity folder owns entries, append/read/clear operations, committed ordering, and retention. It does not
depend on the application or own movie-specific event definitions, AppKit presentation, or App Group selection.
Typed application events belong to MovieFolderCommon/Activity; target composition supplies shared storage.

The user approved implementing the presented structure and then waiting for review. Leave changes uncommitted
and unmerged at that review boundary. Do not push, publish, close issue #3, or claim native qualification.
The user confirmed that approval includes both packages, migration, and the full issue #3 behavior.

## Implementation sequence

- [x] Migrate shared implementation and appropriate tests into MovieFolderCommon; expose only consumer APIs.
- [x] Update host/extension target dependencies/imports and verification harnesses; remove duplicate compilation.
- [x] Implement independently tested Log activity storage using existing Persistence leases.
- [x] Connect typed movie-specific host/Finder events and persistent Log presentation for issue #3.
- [x] Run package, harness, and native build/test verification appropriate to the final scope.
- [x] Complete independent review, fix blocking findings, and record remaining platform checks.
- [x] Present changes for user review; implementation is now committed as `e7d404b` and integrated into `develop`.

## Verification and boundaries

Migration uses existing behavioral tests rather than tests that merely assert file layout. Log tests exercise
concurrent writers, ordering, count/byte bounds, cancellation, restart, corrupt/versioned data, and isolation of
Clear. Actual Finder callbacks, cross-process signed App Group authorization, and window behavior require
separate native evidence. Builds and unit tests do not establish those runtime observations.

Saved collection processing state, mutation receipts, configuration, caches, icon ownership, and future policy histories are
not activity-log records. Clear Log must never erase them. Existing untracked user data and Xcode settings are
preserved. No service introduces a separate process, daemon, watcher, or observation polling.

## Activity contract

Log accepts a Codable/Sendable event payload so the application can use a closed typed vocabulary rather than
arbitrary text. Entries include identity, observation time, and committed sequence. Reads return committed order;
sequence survives Clear. The default retention is the newest 500 entries, with bounded event and envelope sizes.
All store access uses a dedicated Activity namespace and the existing Persistence service, with short exclusive
leases and bounded cancellation-aware contention retries away from the main actor. No lease spans network work.
Unreadable, corrupt, and unsupported history remains an explicit error, including on Clear; it is not silently
replaced. Activity recording failure never changes processing authorization or the result of an icon operation.

MovieFolderCommon supplies movie-specific event construction and privacy-safe fixed display messages. No token,
bookmark, user path, folder/movie name, remote URL, or raw underlying error description is recorded. The host and
extension record actual operations; the Log window loads committed history and treats change notifications as
invalidation hints without data. Reload on opening/reopening and activation recovers from missed notifications.
Clear changes only activity history. Search/category/severity controls remain issue #12 scope.

## Implementation decisions

MovieFolderEnvironment in MovieFolderCommon/Configuration supplies caller-process App Group locations and payload-free
invalidation notifications. Its immutable configuration values use the closed `EnvironmentKey` enum, whose string raw
values are retrieved through `env(_:)`; the public API does not expose standalone mutable configuration storage.
StubTMDbTransport in MovieFolderCommon/Development supplies Debug-only stub
responses; explicit selection remains at the existing executable entry points. These implementations originally
remained in Shared during extraction; the follow-up migration removes that unnecessary source-sharing boundary.
MovieFolderCommon's Keychain adapter accepts its access group from shared environment setup; no package
depends on an executable's source. Public initializers and access levels support actual module consumers while
preserving existing JSON keys, raw values, query identifiers, and App Group data locations.

The Log package uses Swift tools 6.0; MovieFolderCommon uses tools 6.2, matching the existing verification
toolchain's concurrency features. Both use Swift 6 language mode and the existing macOS 26.5 deployment floor.
Host harnesses preserve Xcode's main-actor default isolation and consume the real Common product. Package-owned
tests move with their implementation; AppKit host/composition tests remain in the host target/harness.

Event payloads are limited to 2 KiB; Persistence envelopes are limited to 2 MiB. Retention accepts 1 through 500
entries, with 500 as the production default. Lease contention retries are bounded to approximately one second
and cancellation-aware. Generic service cancellation remains explicit. The application recorder independently
awaits a bounded write so a cancelled producer can still record its terminal cancelled event; logging failure
never replaces the producer's original result. A regression test exercises this with real persisted records.

The native Log has fixed safe categories/messages and an accessible explanation of Clear's limited scope.
Opening/reopening, activation, and coalesced notification hints load committed data; a generation fence prevents
older reads from restoring cleared entries. Shared recorder state reports dropped writes separately from history
load and Clear failures. No token, remote provider call, icon write, or configuration reload is needed to open Log.

## Verification record

Final verification completed on 2026-10-18. These checks do not imply release qualification.

| Check | Result |
| --- | --- |
| MovieFolderCommon full package suite | 44 XCTest tests and 82 Swift Testing tests in 9 suites passed |
| Focused movie activity tests | 5 passed, including real-recorder cancellation |
| Collection probe harness | 20 passed, including a separate-process reader |
| Host feature harness | 72 tests in 5 suites passed |
| Signed Debug build-for-testing | Passed for host, Finder extension, and test bundles |
| Signed Release build | Passed for host and Finder extension |
| Final native unit-target run | 72 tests / 73 parameterized executions passed, zero failures or skips |
| Log final suite after test-folder relocation | 13 tests passed; three separate processes committed 90 ordered entries |
| Log probe with a custom scratch directory | Passed; probe lookup uses the executing test bundle |
| Independent generic Log review | PASS; no blocking findings |
| Independent migration/activity review | PASS; cancellation finding fixed and no open Critical/Important findings |
| Git whitespace verification | Passed |

Final build/test logs are `/tmp/mfp-common-tests-final.log`, `/tmp/mfp-common-host-tests-final.log`, and
`/tmp/mfp-common-xcode-{build,release,tests}.log`. These temporary artifacts are evidence, not dependencies.

Direct package runs intentionally skip the opt-in 10,000-record benchmark and standalone collection-reader
probe. The probe ran through its dedicated harness. No live TMDb run, new signed Finder-process activity
exchange/restart scenario, visual/VoiceOver inspection, reboot, or physical-volume qualification was performed.
The new Log process probe verifies concurrent storage independently of signed Finder activation.

## Review handoff

Both packages and the full issue #3 implementation are ready for user review. The generic Log service and
Common migration/activity integration received independent PASS verdicts. The only blocking review finding
concerned cancellation suppressing the terminal activity write; it is resolved with a real-recorder test.
Existing signed-target setup, fixture transport, data namespaces, and movie-content boundaries are preserved.
Wait for user approval before committing, integrating into develop, updating GitHub issue completion, or
starting another deliverable. No push or release publication is authorized by this handoff.

## Unit-test and API-documentation follow-up

The user requested additional unit tests, project documentation, Apple-style API documentation, and a fresh
validation pass. Package READMEs and DocC catalogs explain the consumer API and ownership boundary. Additional
tests cover real configuration/outcome preservation on Clear, recovery after write failure, missed notifications,
and Clear/read failure races. The recovery regression exposed an async overload mismatch: the concrete recorder
now explicitly implements the async hasWriteFailure requirement so callers receive its retained failure state.

Follow-up verification and independent review passed on 2026-10-18. Prior verification above remains the record
for the initial implementation; the following table records the fresh follow-up results.

| Check | Follow-up result |
| --- | --- |
| Log full package suite | 13 tests passed |
| MovieFolderCommon full package invocation | Passed; 83 Swift Testing tests in 9 suites reported |
| Network / FileSystem / Persistence package suites | 21 / 59 / 13 tests passed |
| Focused real movie activity tests | 6 passed |
| Full host feature harness | 74 tests passed |
| Focused host activity tests | 7 passed |
| Collection processing cross-process probe | 20 tests passed |
| Configuration UI wrapper | 30 tests passed |
| Debug build-for-testing / Release build | Both passed for host and Finder extension |
| Native unit-target run | 74 passed, zero failures and zero skips |
| Strict deep bundle signature checks | Debug and Release passed with normal trust-store access |
| DocC compilation | Both module archives passed with warnings treated as errors and zero diagnostics |
| README Swift examples | Both independently typechecked |
| Independent code/test/documentation review | PASS; no open Critical/Important findings |
| Project parsing / shell syntax / Git whitespace | Passed |

The initial 44 XCTest compatibility cases remain recorded above; the follow-up runner retained the final full
Common invocation's success and its 83-test Swift Testing summary, rather than a separate XCTest count.
The concrete and protocol-typed recorder failure queries now agree before and after recovered writes.

Package documentation starts at [Log](../Packages/Log/README.md) and
[MovieFolderCommon](../Packages/MovieFolderCommon/README.md). DocC source catalogs live under each module's
Sources directory. The compiled local archives are `/private/tmp/mfp-docc-log/Log.doccarchive` and
`/private/tmp/mfp-docc-common/MovieFolderCommon.doccarchive`; each has an adjacent empty diagnostics.json report.
The catalogs build from module-only symbol graphs with the bundled toolchain, without a plugin or download.

Fresh native logs are `/tmp/mfp-final-xcode-{build,release,tests}.log`; native results are
`/tmp/mfp-common-xcode/Logs/Test/Test-MovieFolderPosters-2026.10.18_10-07-23-+0200.xcresult`.
Sandbox cache/trust-store access initially prevented some checks; reruns with writable caches and normal
trust-store access passed. The earlier sandbox-only signature trust failures are not the final result.
Remaining non-blocking compiler diagnostics are five unused record-result warnings in host tests, two existing
weak-variable mutability suggestions, and skipped App Intents metadata extraction without an AppIntents dependency.
Native Finder exchange, visual/VoiceOver checks, live TMDb, reboot, and physical-volume qualification remain
unperformed as described above. Changes remain uncommitted/unmerged for user review.

## Apple platform documentation

References checked on 2026-10-18; these explain API contracts, not native qualification of this build.

- [DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
  documents cross-process delivery, potentially delayed/dropped notifications, and untrusted notification data.
  The application sends payload-free hints and reloads committed storage on open/activation to recover missed hints.
- [App Group container lookup](https://developer.apple.com/documentation/foundation/filemanager/containerurl%28forsecurityapplicationgroupidentifier%3A%29)
  requires a matching entitlement and warns that macOS can return a URL even for an invalid group. Resolving a URL
  does not prove usable storage; opening the bounded Persistence store must succeed independently.
- [Task](https://developer.apple.com/documentation/swift/task/) documents cooperative cancellation and explicit task
  lifetime/result handling. [Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/)
  distinguishes explicitly cancelled unstructured tasks from child-task cancellation. The generic log propagates
  caller cancellation; the recorder awaits its independent terminal-event write and preserves product cancellation.
- [Writing documentation](https://developer.apple.com/documentation/xcode/writing-documentation) describes DocC
  comments, symbol links, and catalogs. [Distributing documentation](https://developer.apple.com/documentation/xcode/distributing-documentation-to-other-developers)
  describes the compiled .doccarchive format. Archives here are local validation artifacts, not a published release.

## Remaining Shared-file migration — before naming cleanup

The user approved moving both remaining shared implementations into MovieFolderCommon. The environment now
lives in Configuration and the Debug transport in Development. Both targets access the public module API;
Xcode's former Shared group, duplicate source build entries, and source-copy harness setup are removed.
Environment storage lookup and notifications still execute in the calling process. Signed entitlements and
explicit fixture selection remain on each executable; the fixture implementation retains its Debug-only guard.

Public API visibility and the fixture transport initializer are the only implementation changes needed for
module consumption. Existing App Group/Keychain identifiers, persisted directory/key names, notification
strings, processing state schema, and fixture responses remain unchanged. DocC now describes caller-process
lookup precisely, avoids implying that a URL proves access, and states that fixture image bytes are returned
unchanged without validation. No independent process or new dependency was introduced.

The [naming review](NAMING_REVIEW.md) records improvements under the Swift style guide. It separates
source/API renames from stored-data and cross-process compatibility changes. These table suggestions are not
implemented by the file move itself; they were subsequently approved and implemented below. The transport's new tests exercise the real TMDb client,
supported fixture responses, unmatched searches, rejected endpoints, and cancellation without network requests.

Post-move verification and independent review passed on 2026-10-18. Earlier records above remain evidence for
their respective snapshots. Fresh results for this correction are:

| Check | Remaining-file migration result |
| --- | --- |
| Common full suite | 44 XCTest and 87 Swift Testing tests in 10 Swift suites passed |
| Debug fixture public API/real-client tests | 4 tests / 6 parameterized cases passed |
| Full host harness | 74 passed |
| Collection processing cross-process probe | 20 passed |
| Signed Debug build-for-testing / Release build | Both passed |
| Native host tests | 74 passed, zero failures and zero skips |
| Strict deep signatures | Debug and Release passed |
| Common symbol compilation and DocC conversion | Warnings treated as errors; empty DocC diagnostics |
| Project parsing / shell syntax / Git whitespace | Passed |
| Independent migration review | PASS; no open Critical/Important findings |

Logs are under `/tmp/mfp-shared-final-*`; the rebuilt Common archive is
`/private/tmp/mfp-shared-final-docc/MovieFolderCommon.doccarchive`. Common compiler warnings were absent.
Xcode still reports test-only unused-result/weak-variable warnings and the existing App Intents metadata notice.
No live TMDb, Finder registration, new signed-process activity exchange, visual/VoiceOver, reboot, or volume
qualification was performed. Changes remained uncommitted/unmerged, with naming candidates awaiting the later approval.

## Approved naming and offline namespace migration

The approved naming table is implemented, with the user's final StubTMDbTransport and usesStubTMDbResponses
choices. MovieFolderEnvironment/factories, ActivityLogViewModel/delegate, Activity Status/status and summary
projection, processingStateKey(for:), and the explicit async hasObservedWriteFailure property are used consistently
across Common, host, Finder, tests, and scripts. Configuration/context developmentFixtures and activity outcome
remain only as legacy CodingKeys; canonical JSON compatibility tests retain their original encoding. The
processing-outcome-v1- record key prefix and the existing Debug command-line flags also remain compatible.

Current directory and notification names are CollectionProcessingState and CollectionProcessingStateChanged.
The user chose physical migration after older app/extension processes have stopped. The
[offline migration guide](PROCESSING_STATE_STORAGE_MIGRATION.md) describes the explicit maintenance command,
operator prerequisite, atomic directory/marker exchange, preserved records/lock identities, retry/failure states,
and permanent legacy-path blocker. Normal factory calls refuse legacy storage rather than opening a second
empty store. Opening configuration first preserves initial App Group directory creation before namespace access.

No migration command has been executed against the live App Group during development. Unit/integration
migration checks use disposable directories. Source compatibility, migration code, and maintenance-command
build/assertion checks passed. Independent review of naming, migration, factory ordering, and the startup
message returned PASS with no open Critical or Important findings.

Final combined-snapshot verification on 2026-10-18:

| Check | Result |
| --- | --- |
| Common full suite | 44 XCTest and 101 Swift Testing tests in 12 Swift suites passed |
| Full host harness | 74 passed |
| Collection processing cross-process probe | 20 passed |
| Signed Debug build-for-testing / Release build | Both passed after the final factory change |
| Strict deep signatures | Debug and Release valid on disk; designated requirements satisfied |
| Common symbol compilation / DocC conversion | Swift warnings treated as errors; empty DocC diagnostics |
| README activity example | Compiles with Swift warnings treated as errors |
| Maintenance tool | Build passed; missing required assertion rejected with exit 2 |
| Project parsing / all shell syntax / Git whitespace | Passed |
| Native Xcode host unit tests | Incomplete: test session never started because startup awaited offline migration |

Logs are under `/tmp/mfp-naming-final-*`; the current Common archive is
`/private/tmp/mfp-naming-final-docc/MovieFolderCommon.doccarchive`. Builds reported only the App Intents
metadata extraction notice. The test host displayed the expected migration-specific alert for the existing
live legacy namespace. Attempts to acknowledge that informational alert through the UI did not release
startup; only the verification-owned test processes were stopped. No XCTest session or xcresult was created.
The earlier native 74-test pass above applies only to the earlier snapshot; the current host harness pass
does not establish successful native startup. Normal startup and signed host/Finder runtime qualification
remain unverified until the offline deployment prerequisite is completed.

Changes remain uncommitted and unmerged pending user review. No live storage migration, publication, or
Finder registration change was performed.

## Approved live migration and native startup qualification

The user explicitly approved live migration on 2026-10-18 after observing the migration-required startup alert.
Extension launching was disabled, the Xcode-suspended host was stopped, and a process snapshot confirmed no
known host/extension writers remained. The documented maintenance command succeeded. Before/after checks
confirmed the original directory inode and all seven file inodes and SHA-256 hashes were preserved; the legacy
path is now the regular-file blocker. This supersedes the earlier no-live-migration and native-blocked status.

A fresh signed Debug build-for-testing passed. The native host suite then completed with 74 passed, zero
failures, and zero skips on macOS 26.5.1 arm64. Logs are `/tmp/mfp-postmigration-build.log` and
`/tmp/mfp-postmigration-tests.log`. After the test host exited, the rebuilt app was launched normally and its
configuration window was inspected through accessibility: saved collections and existing processing results
were visible, with no migration alert. No poster processing was requested. Finder extension registrations were
already disabled and remain disabled; Finder callbacks and poster writes are not qualified by this check.

Changes remain uncommitted and unmerged pending user review.
