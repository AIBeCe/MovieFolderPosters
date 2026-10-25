# Informative activity Log — additional R110-03 implementation point

Status: Proposal and final `MovieFolderActivityLog…` names approved on 2026-10-25. Implementation complete; independent review PASS.
Baseline: `bfd2b25` on `feature/result-log-private-history`. The user approved the implementation on 2026-10-25;
it was committed as `e4d8ad5` after review findings were resolved and focused checks passed.
Formal Validation Phase was authorized on 2026-10-25; see [formal validation](INFORMATIVE_ACTIVITY_LOG_VALIDATION.md).

## Approved behavior

- New Activity messages identify the collection display name, immediate child folder, confirmed movie and actual
  action/result when these facts are available. Capture historical names at the event, not through later inventory
  reconstruction. Old entries remain readable and explicitly identify missing recorded collection context.
- Keep structured facts and fixed rendering templates. Never persist arbitrary caller-written messages, raw error
  descriptions, request URLs/queries/headers, tokens, bookmarks, or full filesystem paths.
- Use `MovieFolderActivityLogTarget`, `MovieFolderActivityLogEvent`, and `MovieFolderActivityLogEntry`. The target
  has optional `collectionName`, `childFolderName`, `movieID`, `movieTitle`, and `movieYear` fields. Movie fields
  describe confirmed identity, never a search query or guessed title.
- Event enrichment includes optional target, folder result, existing typed `FolderProcessingFailure`, retry date,
  and actual `ProcessingSummary`. Make ProcessingSummary Codable without changing its processing contract.
- Emit folder terminal events at actual operation-result boundaries: applied, restyled, not found, several matches,
  unresolved, preserved, suppressed, excluded, deferred, failed or cancelled. Existing Done alone is not applied.
  Do not flood each revisit with unchanged successes; unchanged folders contribute to actual visit summary.
- Use the actual processing-run counters; unresolved is not interchangeable with not-found. Explain safe failure
  stage/reason and supported next action/deadline. Retry eligibility never claims a scheduled retry.
- Both capture-time and current private-history choices prevent identifying fields from entering new history.
  Clear target fields and group/collection identifiers when privacy requires it. Identifying context must have
  verified collection provenance; nil collection ID must never bypass privacy for a names-bearing event.
- Capture successful removal name/privacy under the repository's committed removal access in an immutable
  `CommittedCollectionRemoval` receipt (public type, internal initializer, not Codable). A dedicated recorder
  entry point may retain a nonprivate removed name, rechecking current configuration and any reused ID. Remove
  the ViewModel's duplicate success event; the service owns reporting the committed removal.
- Activity event limit is 8 KiB; Network retains its 2 KiB default. Activity retains at most 500 entries and
  1 MiB serialized history payload (Persistence's 2 MiB envelope includes base64 expansion). Trim oldest entries
  on either bound. An oversized event falls back to explicit fixed detail-omission text, never silent clipping.
- Activity storage reads legacy record version 1 and writes version 2. Old writers must reject version 2 and leave
  bytes intact. Network and existing generic Log callers keep version 1/default limits.
- All four native Log columns wrap, with constrained reusable cells, unlimited lines and automatic row heights.
  Recalculate on resize/reload, preserve selection, and keep the full rendered message consistent across display,
  search, copying and accessibility. No ellipsis or hover-only access to the full message.
- Preserve product results, existing authorization/identity/ownership checks, bounded work and cancellation.
  Optional logging failure never changes a processing or configuration result. No filesystem mutation expansion,
  new dependency, daemon, watcher, polling, registration or live credential operation is authorized.

## Interfaces and ownership

- [x] Root first renames event/entry type references across source/tests and the source file; this mechanical
  prerequisite happens before parallel editors. Existing persisted `operationID`/`outcome` keys stay unchanged.
- [x] Common/storage owner: Common Activity types/recorder, ConfigurationRepository removal receipt, generic Log
  options/version/byte retention, Activity/Configuration compatibility tests. Owns target/result/context types.
- [x] Processor owner: Common Processing sources and tests, including Codable ProcessingSummary and actual
  operation reporting. Consume optional retained `activityHistoryService` and immutable root-bound
  `activityLogContext` initializer collaborators; defaults preserve existing isolated consumers.
- [x] Host presentation owner: host Features/Log and its tests; reusable `LogHistoryTextCellView`, multiline sizing,
  rendered/search/copied text consistency. No event storage or producer ownership.
- [x] Root: host configuration/manual-action producers, Finder composition/runtime and corresponding tests;
  wire the canonical interfaces, contextual events and committed removal path.
- [x] Focused checks and independent review, with same owners handling corrections.
- [x] Record current evidence and limitations here and link from PRIVATE_HISTORY.md/NATIVE_APPKIT_UI.md.

Meaningful new behavior uses failing tests before implementation, then focused Swift Testing runs. Apply the
installed swift-style-guide skill. Implementation approval originally excluded formal validation and commit;
implementation was subsequently approved and committed as `e4d8ad5`. The separately authorized formal validation
and its pending approval are recorded in [formal validation](INFORMATIVE_ACTIVITY_LOG_VALIDATION.md).

## Review focus

1. Every identifying field is removed for private capture/current state, including movie IDs and names without IDs.
2. Committed removal reporting cannot leak a private name or duplicate success after a later summary failure.
3. Actual icon application remains distinct from preserved/unchanged results, including cached artwork repair.
4. Version/byte retention never corrupts or silently erases detailed events through an older writer.
5. Full text remains readable at narrow widths and after column resizing, and Copy matches rendered content.

## Evidence

Focused implementation checks (not formal validation):

| Area | Result | Local evidence |
| --- | --- | --- |
| Common history/configuration compatibility/privacy | 59 passed across 6 suites | `/private/tmp/r11003-informative-common-focused.log` |
| Generic Log version/retention/concurrency boundaries | 18 passed | `/private/tmp/r11003-informative-log-focused.log` |
| Processor outcomes, cancellation, persistence-failure reporting | 76 passed across 4 suites, serialized | `/private/tmp/processor-activity-regressions-final.log` |
| Full-text native AppKit layout and model | 14 passed across 2 suites, 1 known issue | `/private/tmp/r11003-informative-host-complete.log` |
| Host configuration, manual actions, diagnostics and Finder integration | 108 passed across 6 suites | `/private/tmp/R11003-informative-producers-final.log` |
| Primary Add/Edit/inclusion routes, privacy and authorization lifetime | 49 passed across 2 suites after final correction | `/private/tmp/r11003-I8-host-green2.log` |

The AppKit known issue is the sandbox's unavailable pasteboard service: a dedicated named-board probe could not
write or read a string. Display/search/copy projection/accessibility and actual installed-cell row geometry passed;
actual system clipboard/Cmd-C still requires native qualification. A parallel processor test invocation timed out
and was stopped; the repository-conventional serialized affected suite passed. No parallel qualification is claimed.

Review corrections preserve privacy when current capture choices are unavailable, keep diagnostics exports
non-identifying despite richer local Log text, retain explicit failure evidence after a real poster result, and
cover the primary Add/Edit configuration routes. New `collectionConfigurationSaved` activity describes the whole
committed Edit draft; the service owns Add/removal success to avoid duplicate ViewModel events. Unknown capture
privacy emits unlinked history. Diagnostics exports project only fixed action/status and typed failure evidence.
Inclusion retains bookmark/root authorization through the synchronous settings commit; notifications and history
run after required accesses release. The focused lifetime probe verifies committed state and access release.
Independent review resolved all Important findings (I2–I8), then returned PASS. A final indentation-only correction
requires no behavioral rerun. The implementation remains on the feature branch; no merge or push is authorized.

The implementation evidence above predates formal validation. See [formal validation](INFORMATIVE_ACTIVITY_LOG_VALIDATION.md)
for current verification, tests, SwiftLint, style review and remaining native qualification limits.
