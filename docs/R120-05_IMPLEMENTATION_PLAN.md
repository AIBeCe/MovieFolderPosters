# R120-05 — Remember explicit corrections without renaming

Issue: https://github.com/AIBeCe/MovieFolderPosters/issues/19

## Phase and authorization

Implementation is integrated on `develop`. Acceptance Testing and formal Validation were not performed;
the user instructed feature completion after the implementation commit. The focused Common checks below
are implementation evidence, not formal Validation.

## Existing implementation

- Points 1.1–1.9: verified folder identity, saved title/year corrections, authorized host editing,
  Choose Movie controls, correction revisions, local-information precedence, automatic matching,
  selected retry, and removal of corrections for removed collections.
- Point 1.10: deliberate folder movie rejection storage (`44dd89e`).
- Point 1.11: authorized host rejection reads and edits (`a381f11`).

## Point 1.12 — Choose Movie rejection controls

Approved behavior:

- Load saved rejections locally when Choose Movie opens. Retain independent search/correction behavior.
- Keep rejected search results visible and selectable with an explicit Rejected label; disable applying them.
- Provide Reject Selected Movie and a separate saved-rejections picker with Undo Rejection so a movie absent
  from current search results can still be inspected and its rejection undone.
- Update displayed decisions only after successful writes. Preserve decisions on failed writes.
- If rejection storage cannot be read, permit search but disable applying results and rejection edits.
- Recheck rejection at the authorized service boundary before provider work and inside the existing final
  icon-change configuration fence. Rejection edits hold the same settings lock, preventing a concurrent edit
  between the final check and assignment.
- Preserve identity, authorization, cancellation, and configuration invalidation safeguards.

The view model owns rejection presentation state; the existing service owns authorization and storage;
the AppKit view controller renders controls and forwards actions. No new module or service is introduced.
The immutable versioned rejection result gains a public initializer so service test doubles can construct
the existing return contract.

### Scenario inventory and verification

| ID | Scenario and observable outcome | Focused verification |
| --- | --- | --- |
| P12-01 | Opening loads saved rejections without searching TMDb. | View-model test; existing durable service reopen tests. |
| P12-02 | Rejected/unrejected results remain visible; only the unrejected selection can apply. | View-model and real AppKit control tests. |
| P12-03 | Reject saves the selected provider identity and marks the retained result Rejected. | View-model and AppKit control tests. |
| P12-04 | Undo removes a saved rejection absent from the current search; it does not apply a poster. | View-model and AppKit control tests. |
| P12-05 | Read failure permits search, blocks apply/edits, and displays unavailable guidance. | View-model test. |
| P12-06 | Failed rejection/undo writes preserve the prior decision and display an error. | View-model tests. |
| P12-07 | A rejection saved after presentation or during artwork download prevents assignment. | Real service tests with disposable directories and a deterministic provider. |
| P12-08 | Cancellation/configuration invalidation prevents late state publication. | View-model tests and existing lifecycle regressions. |
| P12-09 | Invalid IDs, rename/replacement, revoked access, paused/excluded folders and contention retain existing safeguards. | Existing rejection store/service regression tests. |
| P12-10 | Corrections, spelling/incomplete-results guidance, other actions and lifecycle controls remain functional. | Existing affected view-model/coordinator/service suites. |

Focused implementation checks use isolated host startup and disposable fixtures. They are not full-app E2E
qualification. Keyboard/VoiceOver and Light/Dark rendered validation remain unperformed in this phase.

## Point 1.12 implementation evidence

- Implemented the approved controls, local rejection state, and initial/final service rejection guards.
  Choose Movie content size is now 620×540 points.
- Test-first build demonstrated missing view-model APIs before implementation. Build-for-testing succeeded:
  `/private/tmp/mfp-r120-05-ui-build.log`.
- Final focused execution: 73 tests in five host suites passed; Xcode reported TEST EXECUTE SUCCEEDED.
  Evidence: `/private/tmp/mfp-r120-05-ui-tests-final.log`. This covers view-model, AppKit controller,
  service, and directly affected presentation regressions using isolated host startup.
- The first execution retained one fixture failure: another authorized host rejection edit was blocked by
  the existing authorization lock during application. The corrected fixture asserts that busy outcome and
  unchanged storage, then injects a persisted storage change during download to exercise the final fence.
  The original result is preserved in `/private/tmp/mfp-r120-05-ui-tests.log`.
- Independent source review PASS with no Critical/Important findings. Diff whitespace and changed Swift
  line-length checks passed. SwiftLint and formal Validation have not started. Native rendered keyboard,
  VoiceOver, Light/Dark appearance and full-app E2E behavior remain unverified.
- The user approved the completed implementation for commit.

## Approved automatic folder-title retry

The user approved a follow-up to automatic matching after observing that TMDb manual search found a
movie from the collection folder title when the automatic filename-based query found none.

Approved behavior:

- After a complete search returns zero movies, automatic matching parses the immediate folder title and
  retries once when that title differs from the selected title.
- Keep the automatic TMDb query year unrestricted; use the parsed folder year as matcher evidence.
- Do not retry after incomplete searches, provider failures, nonempty candidate responses, saved
  corrections, explicit identifiers, or when the parsed folder title is equivalent to the selected title.
- Retain both attempts in bounded, backward-compatible Matching Details evidence.

Implementation is complete. Focused Common execution passed 66 tests across three matching-related suites.
The filter included automatic-correction, local-information, processor-activity, and matching-diagnostics
test names. The new regressions cover successful
retry, both searches empty, incomplete first search, cached first search, equivalent titles, nonempty rejected
candidates, retained two-search evidence, legacy decoding, and accurate incomplete-search wording. The test
command was `common_swift test --no-parallel --filter
"MovieFolderProcessorActivityTests|MovieMatchingDiagnosticsTests|LocalMovieInformationTests|AutomaticSearchCorrectionTests"`
through `scripts/test-support/common-tests.sh`. SwiftPM emitted an existing unnecessary-`await` warning in
unchanged `MovieFolderProcessorMatchingAcceptanceTests.swift:130`. A broader unfiltered Common run was
stopped after stalling in unrelated keychain tests and exposed two unrelated history-configuration version
expectation failures; it is not counted as passing evidence. No live collection was processed for these
checks. Acceptance Testing and Validation remain separate authorization gates.

## Feature completion

- Feature branch `feature/remember-explicit-corrections` fast-forwarded into `develop` at `fc37878`.
- The automatic folder-title retry and matching evidence are included in that implementation commit.
- Focused Common verification passed 66 tests across three matching-related suites; details and limits are
  recorded above. Formal Validation, SwiftLint, Acceptance Testing, full-app E2E and live Finder qualification
  were not performed.
- User requested feature completion; this documentation update is committed separately on `develop`.

## Remaining implementation scope

Automatic rejection enforcement, removal of rejection records for removed collections, and reviewed reuse
of confirmed identity for equivalent releases require subsequent individually approved proposals.
