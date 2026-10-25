# Common and Log naming review

Date: 2026-10-18
Status: Approved names and explicit offline migration tooling are implemented and independently reviewed.
The approved live storage migration completed after older processes were stopped. Native host tests and normal
startup now pass; verification details are recorded in COMMON_AND_LOG_MIGRATION.md.

Scope: the Common/Log extraction, activity implementation, remaining Shared-file migration, and touched host
presentation. The review applies the user's swift-style-guide naming and DocC rules: identify responsibility
at the point of use, distinguish processing state from configuration and activity status, and document actual
contracts without implying unverified permissions or data validation.

R110-03 subsequently extends the host Log to activity and network history. Its approved presentation names are
now `LogViewModel` and `LogViewModelDelegate`; N04 below records the earlier extraction rename. The current
approved correction set and focused evidence are recorded in [Result filtering and private history](PRIVATE_HISTORY.md).

## Approved names

| ID | Current name | Suggested name | Reason and impact |
| --- | --- | --- | --- |
| N01 | Directory `Outcomes`, notification suffix `CollectionOutcomesChanged`, and `collectionProcessingChanged` | Directory `CollectionProcessingState`, notification suffix `CollectionProcessingStateChanged`, and `collectionProcessingStateChanged` | These refer to saved collection processing state, including active and interrupted work. Directory/notification literal changes require compatibility handling; update notifier methods consistently. |
| N02 | `MovieFolderActivityEvent.Outcome` and `outcome` | `Status` and `status` | `.started` describes progress, not a completed result. Public API change; preserve the existing JSON key `outcome` with explicit CodingKeys if the stored schema remains unchanged. |
| N03 | `MovieFolderActivityEvent.automaticOutcome(for:)` | `automaticProcessingStatus(for:)` | The function derives automatic-processing status from a ProcessingSummary. Source/public API change only. |
| N04 | `HostActivityLog` and `HostActivityLogDelegate` | `ActivityLogViewModel` and `ActivityLogViewModelDelegate` | This type owns presentation, loading, errors, and Clear/reload coordination. It displays both host and Finder events; it is not the storage service. Host-only source/test rename. |
| N05 | `SharedEnvironment` | `MovieFolderEnvironment` | Optional: identify the application-specific environment rather than describing source sharing. Public source API rename, with no persisted-data change. |
| N06 | `SharedEnvironment.container()` | `appGroupContainerURL()` | Identifies the returned location and the App Group boundary; resolving a URL does not establish access. Public source API rename. |
| N07 | `SharedEnvironment.repository()` | `makeConfigurationRepository()` | Identifies the repository and makes construction/opening explicit. Public source API rename. |
| N08 | `SharedEnvironment.privateAuthorizations()` | `makePrivateAuthorizationStore()` | Identifies the returned store instead of suggesting a collection of authorization records. Public source API rename. |
| N09 | `DevelopmentTMDbTransport` | `StubTMDbTransport` | Returns predefined TMDb responses without interaction verification; Debug availability remains separately enforced by `#if DEBUG`. Public Debug-only source/test rename. |
| N10 | `MovieFolderActivityServicing.hasWriteFailure()` | Read-only async property `hasObservedWriteFailure` | The flag remembers a failure for the recorder lifetime; it does not report current storage health. A cheap state query fits a property. Public protocol/implementation/test API change, preserving async access. |
| N11 | `CollectionProcessingStore.rootKey(_:)` | `processingStateKey(for:)` | The function returns the persisted state-record key, distinct from the root coordination key. Public source API rename; retain the current `processing-outcome-v1-` key prefix unless a separate storage migration is approved. |
| N12 | `HostActivityLog.loadFailed`, `clearFailed`, and `writeFailed` | `hasLoadFailure`, `hasClearFailure`, and `hasObservedWriteFailure` | Optional Boolean naming clarification; the last flag is sticky while read/Clear failures describe their respective operations. Host-only source/test rename. |
| N13 | `developmentFixtures` | `usesStubTMDbResponses` | Identifies the enabled Debug behavior. Captured processing contexts use the same name; both persisted models retain the old JSON key through CodingKeys. The related setter is setStubTMDbResponsesEnabled. |

The existing ActivityLog, ActivityEntry, CollectionProcessingStore, CollectionProcessingState, and
Development/Configuration folder ownership describe their responsibilities adequately. Avoid renaming clear
symbols just to change vocabulary. The proposed Activity status is separate from durable collection processing
state and from user configuration.

## Documentation corrections included in the move

- Describe shared environment methods as caller-process operations; a package has no independent entitlement.
- Describe collection processing state consistently in DocC; legacy compatibility strings are not current
  terminology for the stored model.
- State that App Group URL lookup does not verify filesystem access or create the persistence directories.
- Document factory return values and actual thrown failures; private authorizations use Application Support.
- State that the fixture transport returns supplied image bytes unchanged, without validation or decoding.
- Document the explicit public Debug-only initializer and HTTPTransport conformance used by both consumers.

## Compatibility boundary

The source renames preserve actor isolation, async access, callbacks, visibility, serialized payload fields,
and behavior. Canonical legacy JSON tests cover configuration, captured processing context, and activity
events. The async failure query is tested through both concrete and protocol-typed access.

The user selected physical migration to CollectionProcessingState after older app/extension processes are
stopped, rather than retaining the old directory indefinitely. Normal new-version storage access must not
silently open a second namespace while legacy data remains. An explicit offline migration preserves all
records and reusable locks; it is not run against live user data during development. The notification now
uses CollectionProcessingStateChanged consistently. Old participating versions must be stopped before rollout.
The old developmentFixtures/outcome wire keys, processing-outcome-v1- persistence key prefix, and legacy Debug
command-line flags remain solely for compatibility. They are not the current source vocabulary.
