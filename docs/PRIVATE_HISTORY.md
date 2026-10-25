# Result filtering and private history — R110-03

Status: Combined proposal approved on 2026-10-24; initial implementation and focused checks completed with review
PASS. User-approved naming corrections (points 1–7) completed on 2026-10-25 with focused checks and independent
review PASS. The user approved the completed implementation for commit on 2026-10-25. Formal Validation Phase has
not started and requires separate authorization.
Issue: [#12](https://github.com/AIBeCe/MovieFolderPosters/issues/12).
Branch: `feature/result-log-private-history`; baseline: `5b14ea8`.

## Approved scope and contracts

- Filter Unresolved Results by exact saved state and reason, combined with AND. Preserve natural ordering,
  freshness/incomplete warnings and stable visible selection. Hidden selections are removed. Filtering is local,
  read-only, disabled during selected retries, and shows displayed/recorded counts.
- Keep Main/Settings/Log and programmatic AppKit. Log has Activity/Network source, safe text search,
  category/severity filters, selected-row copying and explicit source-specific Clear of all retained entries,
  including hidden rows. Filter changes must never restore hidden selections; late reads cannot cross sources/Clear.
- Derive activity category from action, severity from status: started/succeeded/cancelled information, partial
  warning, failed/unavailable error. Copy only displayed time/message/category/severity, never stored identifiers.
- Optional network history defaults off, with its control in Log. Activity and Network use separate bounded
  namespaces, each at most 500 entries under the existing 2 KiB event/2 MiB record limits.
- Observe actual TMDb HTTP attempts for credential validation, search, poster configuration and poster download.
  Record terminal HTTP result/time only, optionally a nonprivate collection UUID. No queries, titles, years,
  request URLs/headers/body, credentials, paths, bookmarks or arbitrary errors. A 2xx response is not movie/poster
  success. Debug fixture traffic is omitted. History must not alter a product/network result.
- Network delegates obtain an opaque history-revision ticket before dispatch; check cancellation again before
  sending. Report exactly once per dispatched ticketed attempt. Completion requires recording still enabled,
  a matching history revision, and an existing nonprivate collection when collection-scoped.
- Add/Edit Collection saves Private collection history atomically with the draft. New private activity drops both
  collection/group identifiers; private network history is omitted. Removed-root activity keeps only unlinked
  fixed text. Unreadable configuration skips linked optional writes. Intentional omission is not a storage error.
- Existing history is retained unchanged until the user explicitly clears its source; explain this beside privacy
  controls. Disabling recording retains history. Omitted history is never reconstructed.
- Keep required local outcomes/decisions/caches/authorization and processing behavior. Privacy settings do not
  rotate processing or authorization generations. Rotate history revision across history/private/root changes.
- Configuration schema 4 accepts legacy 1–3 with privacy off, recording off and a deterministic initial history
  revision derived from credential revision. Every writer writes version 4, including credential changes.
- Open history storage before taking configuration access. Privacy-sensitive writes hold configuration access
  through an immediate history append (configuration → history order); no retry wait or network spans that access.
  Add an immediate append option without changing existing bounded-wait callers. Contention is a separate history
  failure, never a product failure. Payload-free notifications occur after releasing accesses.
- Older running binaries cannot inherit the new recorder checks; native qualification requires updated host/Finder.

## Implementation plan and ownership

- [x] Common/storage worker: configuration schema and history revision, network history service/delegate bridge,
  private activity recorder, environment factories and notification names; generic Log immediate append and tests.
- [x] Host worker: collection result filters; Add/Edit private controls and configuration service integration;
  source-aware Log presentation/search/filter/copy/Clear; corresponding host tests.
- [x] Network worker: closed purpose/result vocabulary, request delegate hooks and focused Network tests.
- [x] Root integration: bind recorder delegates to Finder roots/manual actions/credential tests; wire application
  composition and reconcile interfaces. Preserve existing admission, ownership and cancellation safeguards.
- [x] Focused implementation checks and independent review; resolve Important/Critical findings with the same owners.
- [x] Update documentation with implementation evidence and remaining formal/native qualification.

Workers use meaningful failing behavioral tests before implementation, then relevant filtered Swift Testing runs.
No project-wide suite, SwiftLint, formal Validation Phase, commit, merge, push or extension registration is authorized.
The user's lifecycle takes precedence over skill defaults suggesting intermediate commits or repeat approval gates.

## Review focus

1. Late reads/source switches/Clear must not restore stale history or act on hidden selection.
2. Config/privacy changes while a network request is in flight must prevent a stale linked append.
3. Shared history/configuration contention must not inherit the history retry window into product admission.
4. Cancellation during delegate preparation must prevent dispatch; decoding failure must not duplicate observation.
5. Legacy schema/defaults, removed roots and all constructor/copy paths must preserve privacy choices correctly.

## Approved naming corrections — 2026-10-25

Apply these corrections together without changing processing, storage, privacy or request behavior:

- Environment factories use `movieMetadataProvider(...)`, with `makeMovieMetadataProvider(...)` for the private
  factory. Related bindings and injected host collaborators use `movieMetadataProvider`; concrete request-test
  clients use `tmdbClient`.
- Bindings and parameters representing `PersistenceAccess` use `persistenceAccess`, with purpose qualification
  where more than one is in scope. This correction is scoped to issue-modified files and affected callers/tests;
  filesystem `DirectoryAccess` and unrelated Processing/Recovery files are separate concerns.
- Log persistence uses `ActivityHistoryRecord`, `readActivityHistory(using:)`, `activityHistoryRecord` and
  `corruptActivityHistory`; its test helpers and descriptions use the same activity-history vocabulary.
- `appendActivityEvent` returns `ActivityHistoryAppendResult.appended` or `.omitted`; storage failure still throws.
  `appendNetworkHistoryEvent` returns `NetworkHistoryAppendResult.appended`, `.omitted` or `.failed`. Notifications
  are emitted only for appended events, intentional omission remains successful handling, and actual logging
  failures never replace product results. Eligibility is named `canRecordNetworkHistory`.
- Configuration exposes `usesPrivateHistory`, `isNetworkHistoryRecordingEnabled` and
  `networkHistoryConfigurationRevision`. Explicit CodingKeys retain serialized fields `isPrivate`,
  `retainsNetworkHistory` and `historyRevision`; the format, schema version and defaults do not change.
- Network history preparation is `prepareNetworkHistoryRecording`; completion is `recordCompletedNetworkRequest`,
  with `expectedNetworkHistoryConfigurationRevision`. The Network package treats the UUID as an opaque
  `recordingTicket`. Repository, history-service and store collaborators have explicit responsibility names.
- The two-source presentation model is `LogViewModel`/`LogViewModelDelegate`, with nested `HistorySource`,
  `HistoryEntryRow` and `HistoryOperationFailures`. History transforms are `historyRows()`, `filteredHistoryRows()`,
  `historyCategories()` and `textForSelectedHistoryRows()`. Entries, selection, search, read generations, loaded
  results and operation-failure flags identify their contents or purpose.
- Native controls identify their concrete roles: `historySourcePopUpButton`, `historySearchField`,
  `categoryFilterPopUpButton`, `severityFilterPopUpButton`, `networkHistoryRecordingCheckbox`, `historyTableView`,
  `historyScrollView`, `privateHistoryCheckbox`, `processingStateFilterPopUpButton` and
  `processingReasonFilterPopUpButton`. History-retention/Clear explanation labels identify their messages.
- Collection result bindings use `recordedUnresolvedFolders`, `recordedUnresolvedFolderCount` and `resultCountText`;
  the Finder composition recorder stores `collectionIDs`.

Focused compilation/tests and independent re-review completed after these edits. Naming approval does not
authorize commits, the formal Validation Phase, extension registration, merge or push.

Naming correction checks completed on 2026-10-25:

| Focused check | Result | Local raw evidence |
| --- | --- | --- |
| Network observation and credential validation | 16 passed | `/private/tmp/network-observation-renames.log` |
| Common history/configuration and directly affected integration boundaries | 61 passed in 9 suites | `/private/tmp/r11003-naming-common-focused.log` |
| Log persistence, retention, corrupt history and contention | 6 passed | `/private/tmp/r11003-naming-log-focused.log` |
| Host collections, Log, configuration and directly affected UI behavior | 79 passed in 5 suites | `/private/tmp/r11003-host-naming-green.log` |
| Finder, manual actions and root coordinator lifecycle | 50 passed in 3 suites | `/private/tmp/R11003-naming-integration.log` |

The Common checks include an exact schema-4 encoding roundtrip preserving the existing JSON keys, and a history
notification check distinguishing appended, omitted and failed writes after configuration access is released.
Two stale host assertions from the initial R110-03 implementation were updated to the approved behavior:
source-specific `Clear Activity`, and `Configuration` category with `Error` severity. No product behavior changed.
As with the initial evidence below, counts can overlap and are not a unique-test total.

Independent review of the approved naming corrections returned PASS with no Critical or Important findings.
The review confirmed caller updates, preserved serialized keys, explicit append outcomes, privacy checks and
notification behavior. Formal style validation, SwiftLint and native qualification remain unperformed.

## Evidence and remaining work

These are implementation checks, not the separately authorized formal Validation Phase. Test data and history
stores are disposable; no production collection or installed icon was changed.

| Focused check | Result | Local raw evidence |
| --- | --- | --- |
| Network observation and credential validation | 16 passed | `/private/tmp/network-observation-alignment.log` |
| Common history, activity, configuration and directly affected setup/storage boundaries | 54 passed in 8 suites | `/private/tmp/r11003-common-focused.log` |
| Log immediate contention, bounded cancellation, retention and namespace isolation | 4 passed | `/private/tmp/r11003-log-focused.log` |
| Host result/Log/configuration tests | 59 passed; final model follow-up 11 passed | `/private/tmp/r11003-host-final.log`, `/private/tmp/r11003-host-last.log` |
| Manual action and Finder integration | 40 passed | `/private/tmp/R110-03-integration.log` |
| Per-root Finder composition regression | Behavioral failure observed, then passed in 22-test Finder run | `/private/tmp/R110-03-finder-only-red.log`, `/private/tmp/R110-03-finder-green.log` |
| Coordinator failure-message compatibility and Log model follow-up | 12 passed, including both previously failing coordinator assertions | `/private/tmp/r11003-host-coordinator-fix.log` |

The focused runs overlap; their counts must not be added as a unique-test total. Temporary logs are evidence,
not project dependencies. Compilation emitted existing weak-reference warnings and AppKit harness XPC diagnostics.

Independent review identified I1: movie-fixture configuration incorrectly suppressed real credential-validation
history. The eligibility check now relies on actual client composition: fixture clients have no observer, while
real credential HTTP remains observable even when movie fixtures are selected. The regression failed before the
fix and passed afterward. Review also checked the unreadable-configuration omission contract: omission returns
successful handling without notification or write-failure warning, while actual history storage failure remains
separate from product results.

Coordinator integration subsequently exposed two assertions relying on the previous activity write-failure
wording. The owner restored that activity message while retaining source-specific Network wording; both assertions
and the associated Log model tests passed. Independent review then returned PASS with no remaining Critical or
Important findings. The same owners handled fixes and re-review.

Formal validation, SwiftLint, a formal issue-wide Swift style review, native keyboard/VoiceOver, updated host/Finder,
visual/runtime qualification and signed native builds remain unperformed. Implementation approval authorizes its
commit only; no merge, push, issue closure or release has occurred. Existing untracked user/build/Xcode files
remain untouched.
