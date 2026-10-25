# Informative Activity Log — formal validation

Status: Issue-scoped validation completed and approved on 2026-10-25; committed as `87d0567`.
The feature was fast-forwarded into `develop` under the user's feature-completion authorization.
Implementation: `e4d8ad5` on `feature/result-log-private-history`.
Scope: approved [informative Activity Log point](INFORMATIVE_ACTIVITY_LOG.md), compared with `bfd2b25`.
Starting validation did not authorize integration. The later explicit “finish the feature” instruction authorized
the validation commit, fast-forward integration, documentation commit and push. Release qualification is separate.

## Verification

Static review checked the approved behavior against the final event, recorder, processor, configuration,
manual-action, Finder, diagnostics-export, and AppKit presentation boundaries. No new product correctness
blocker was found. The implementation review's privacy and authorization-lifetime corrections remain intact.

| Requirement | Evidence |
| --- | --- |
| Historical collection/folder/confirmed-movie facts and truthful counters | Renderer, real processor and host/Finder producer tests |
| Applied/restyled versus unchanged or source-cache-only repair | Processor Activity and collection integration tests |
| Typed failure, cancellation, retry eligibility and post-result storage failure | Processor/manual-action regression tests; fixed safe rendering review |
| Capture/current privacy, unavailable capture, unlinked fallback and committed removal | Activity/configuration tests and actual Finder/private-to-public regression |
| Activity v1/v2 compatibility, count/byte retention and explicit detail omission | Generic Log and Common Activity storage tests |
| Primary setup/edit/removal/inclusion reporting and authorization lifetime | Actual setup/edit ViewModels, configuration service and grant-release probe |
| Full text at narrow widths, resize and selection stability | Real AppKit installed-cell geometry tests with Unicode and explicit newlines |
| Display/search/copy/accessibility use complete canonical text | AppKit and model assertions; actual copy action passed outside the restricted sandbox |
| Diagnostics export remains non-identifying | Contextual-event export regression with historical names and movie identity |

## Unit and integration testing

All commands use repository-local writable caches and `--no-parallel`. Tests remain scoped to the changed
behavior and directly affected integration points; no entire-project suite was run. Counts below overlap and
must not be summed into a unique-test total.

| Run | Result | Local raw evidence |
| --- | --- | --- |
| Common Activity/configuration/processing and collection integration | 98 tests, 7 suites passed | `/private/tmp/R11003-validation-common.log` |
| Expanded file-scope Activity and manual-resolution coverage | 22 tests, 2 suites passed | `/private/tmp/R11003-validation-common-activity-expanded.log` |
| Generic Log Activity storage | 18 tests passed | `/private/tmp/R11003-validation-log.log` |
| Final Common privacy/vocabulary/configuration/manual-resolution recheck | 38 tests, 5 suites passed | `/private/tmp/R11003-validation-final-common.log` |
| Final combined host/Finder/configuration/manual-action/Log/diagnostics | 133 tests, 10 suites passed | `/private/tmp/R11003-validation-final-host.log` |
| Isolated copy/display/search/accessibility test outside restricted sandbox | 1 test passed, no known issue | `/private/tmp/R11003-validation-pasteboard-unsandboxed.log` |

The first host validation run failed one stale test expecting identifiers without verified collection context.
The approved privacy contract intentionally omits those identifiers. The expectation now requires absent
collection/group/target fields and preserves the actual invalid-selection failure reason; the final run passes.

The restricted host run records one known pasteboard-service issue. The exact same test passed in its isolated
unsandboxed rerun; the relevant UI source is unchanged. This verifies the actual Copy action, not native keyboard
shortcut handling or an end-to-end VoiceOver session. An initial direct test invocation could not use a global
Clang cache; the repository-local-cache invocation compiled and passed.

## SwiftLint

SwiftLint 0.65.1 uses the unchanged repository `.swiftlint.yml`, with explicit paths for the 51 existing Swift
files changed by this point. No project-wide lint or rule weakening was performed. Baseline findings come from
the corresponding files at `bfd2b25`, copied to a temporary directory and checked with the same configuration.

Final command: `swiftlint lint --config .swiftlint.yml --no-cache --reporter json` followed by the 51 changed
Swift file paths. Exit status 0: **0 errors and 40 warnings**. This is not a warning-free result.

| Classification | Count | Assessment |
| --- | --- | --- |
| Unchanged pre-existing findings | 23 | Outside the behavior/style delta; not refactored |
| Existing metrics whose measured size/complexity increased | 6 | Directory service file, Finder test file, directory service test file/type, automatic-processing function length/complexity |
| Newly triggered numerical metrics | 11 | Failure mapper length/complexity, manual-action actor/test type size, service helper parameters, processor helper lengths/parameters and automatic-processing file size |

The 17 introduced or increased metric warnings were reviewed as nonblocking. These units retain cohesive
transaction, operation or allowlisted failure-mapping responsibilities; the repository explicitly prohibits
splitting solely to satisfy numerical thresholds. No rule or threshold was disabled or weakened. The redundant
memberwise initializer warning was corrected. Three earlier baseline warnings are absent from the final files.

Raw reports: `/private/tmp/R11003-validation-lint-current.json`,
`/private/tmp/R11003-validation-lint-baseline.json`, and
`/private/tmp/R11003-validation-lint-comparison.json`. The comparison initially groups new/increased metrics;
the six-versus-eleven split above also checks the corresponding pre-change declarations.

## Swift style guide

The installed `swift-style-guide` skill was applied to modified Swift code. Review covers required DocC,
parameter/return documentation, guard spacing, meaningful naming, organization, line width and safe optionals.
Validation corrections are documentation/spacing, a redundant internal memberwise initializer replaced by the
compiler's equivalent internal synthesis, and the stale privacy-test expectation described above.

The review found missing DocC on three new test collaborator properties, missing parameter/return documentation
on new helpers, and guard spacing omissions. Those are corrected. Root checked the final correction diff,
including accurate nil-setting semantics, retry eligibility wording, saved-movie provenance, and explicit guard
separation. No remaining required style deviation was found in the changed code. No added code line exceeds
120 columns, introduces force-unwrapping, or uses a prohibited Snapshot name. `git diff --check` passes.

Numerical size/complexity warnings are assessed as indicators under repository policy; cohesive transaction,
processing-operation and closed failure-mapping units do not warrant extraction solely to meet a threshold.
Unchanged pre-existing style violations remain outside this point. Final post-test edits were DocC and blank
lines only; no behavioral rerun was warranted.

## Limits and approval

Native keyboard shortcuts, an end-to-end VoiceOver session, live signed host/Finder registration, signing and
release qualification were not performed. These results cover issue-scoped code, tests, AppKit geometry and
copy behavior; they do not claim those wider platform qualifications. No live credential operation or network
request was required.

Validation changes were approved and committed as `87d0567` before integration. The fast-forward merged tree
was verified identical to the validated feature tree; only delivery documentation changed afterward. No tests
were repeated for an identical tree or documentation-only changes. The feature-completion instruction authorizes
publishing the resulting `develop` commits; it does not publish a release or close a GitHub issue.
