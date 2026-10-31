# R120-02 Acceptance Tests

Issue: [#16 — Improve year, edition, and spelling evidence](https://github.com/AIBeCe/MovieFolderPosters/issues/16)

Acceptance criterion: realistic ambiguous fixtures and adversarial title/year cases must not choose the first
provider result automatically; spelling differences must remain suggestions when evidence is insufficient.

## Scenario matrix

| ID | Requirement | Given–When–Then | Automated test | Coverage | Status |
| --- | --- | --- | --- | --- | --- |
| ED-01 | Edition suffix recovery | Given a saved unresolved `Dune (2021) Director’s Cut` folder, when collection processing runs, then it searches the parsed `Dune` title, saves the matching decision, and does not repeat the search after restart. | `cachedEditionSuffixDecisionIsReassessedOnce` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/MovieFolderProcessorRecoveryEligibilityTests.swift` | Existing processor and persistent-cache integration | PASS |
| YR-01 | Nearby-year corroboration | Given `Alien (1980)` and one 1979 provider movie with 1979 and 1980 theatrical events, when processing runs, then the provider identity is saved with its primary year and dated events. | `releaseYearProcessingRetainsProvenanceAndUnfilteredDiscovery` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/VerifiedReleaseYearTests.swift` | Existing processor, assignment-adapter, and cache integration | PASS |
| YR-02 | Competing qualified candidates | Given `Dune (1984)` and ordered provider results containing a 1984 movie followed by a 1983 movie with 1983 and 1984 theatrical events, when processing runs, then the saved outcome is ambiguous, has no movie ID, and attempts no assignment. | `competingQualifiedYearCandidatesRemainAmbiguous` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/MovieFolderProcessorMatchingAcceptanceTests.swift` | New processor and persistence acceptance test | PASS |
| YR-03 | Fuzzy title refusal | Given `Alian (1980)` and an `Alien` result with otherwise qualifying 1979 and 1980 theatrical evidence, when processing runs, then the folder remains unresolved without an identity or assignment. | `spellingSimilarityWithYearEvidenceDoesNotAssign` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/MovieFolderProcessorMatchingAcceptanceTests.swift` | New processor and persistence acceptance test | PASS |
| YR-04 | Insufficient or ineligible dates | Given `Alien (1980)` and a 1979 result with missing, one-sided, digital, physical, or television dates, when processing runs, then the nearby result is not assigned. | `incompleteOrIneligibleReleaseEventsDoNotAssign(eventType:)` in `Packages/MovieFolderCommon/Tests/MovieFolderCommonTests/Processing/MovieFolderProcessorMatchingAcceptanceTests.swift` | New parameterized processor and persistence acceptance test; each event type is an executable case | PASS |
| SP-01 | Explicit spelling suggestion | Given an unresolved `The Last Frane` folder, when the user searches in Choose Movie, then `The Last Frame` appears as a possible spelling difference while Apply remains disabled; after the user explicitly selects it, Apply becomes enabled. | `testSpellingSuggestionRequiresExplicitSelection` in `MovieFolderPosters/MovieFolderPostersUITests/MovieFolderPostersUITests.swift` | New full-app XCUITest | PASS |

## Fixture and isolation contract

- Processor tests use temporary folder, cache, and persistence stores with deterministic metadata providers. They observe
  saved folder outcomes and the recording poster adapter; they never write Finder icons or use TMDb credentials.
- The spelling UI test uses the Debug-only local `StubTMDbTransport` fixture. The host app routes shared settings and
  private authorization to a UUID-named directory beneath `/private/tmp/MovieFolderPostersAcceptance`, and replaces
  Keychain access with a fixture credential store.
- UI tests launch only the host app. They do not launch or register the Finder extension and do not open user movie
  folders. The scoped temporary host-app LaunchServices registration is inspected and removed after the run if present.

## Execution report

- **SP-01 — PASS.** The full host app and `MovieFolderPostersUITests-Runner` launched using temporary ad-hoc
  signatures and test entitlements limited to `/private/tmp/MovieFolderPostersAcceptance`. The UI test added the
  isolated collection through the native chooser, opened its saved unresolved row, and started the deterministic
  fixture search. Before selection, `Apply Selected Movie` was disabled. After selecting the popup item whose value
  contains `Possible spelling difference`, the button became enabled. Evidence: test log
  `/private/tmp/R120-02-acceptance-signed-derived/spelling-final.log`; result bundle
  `/private/tmp/R120-02-acceptance-signed-derived/TestResults/R120-02-spelling-final.xcresult`.
- **ED-01 — PASS.** Processing recovered the parsed edition title, persisted the match, and made no second search
  after restart.
- **YR-01 — PASS.** Processing assigned the candidate, retained its 1979 primary year and both theatrical release
  events, and preserved that provenance during saved-artwork reassignment and cache repair.
- **YR-02 — PASS.** Both qualified candidates remained ambiguous; the saved result had no movie ID and the poster
  assignment adapter recorded zero assignments.
- **YR-03 — PASS.** The fuzzy-only `Alian` → `Alien` candidate remained unresolved with no saved identity or
  assignment.
- **YR-04 — PASS.** All five event-type cases (0, 1, 4, 5, and 6) remained unresolved and recorded no assignment.
  Evidence for ED-01 and YR-01–YR-04: `/private/tmp/R120-02-acceptance-signed-derived/year-edition-warnings-fixed.log`.
- **Overall Acceptance Testing: PASS** — 6 scenarios PASS, 0 FAIL, 0 BLOCKED, 0 NOT TESTED; 10 executable cases
  passed across the six scenarios. YR-04 contributes five parameterized cases. SP-01 full-app UI evidence is listed
  above.

## Final regression run and scope

- The final full macOS Xcode scheme run passed 294 unit tests, 5 UI tests, and 2 launch tests. The captured output is
  `/private/tmp/R120-02-final-tests.log`.
- The acceptance run used test-only entitlements granting the XCTest runner and fixture-mode host app access to
  `/private/tmp/MovieFolderPostersAcceptance`. Derived-data signing was temporary. No Release or production
  entitlements or project signing settings changed. Test fixture directories created during retries were removed.
- No live TMDb credentials, real movie folders, Finder registration, or icon writes were used. Finder extension
  runtime behavior, actual Finder icon persistence, and signed/notarized release qualification remain unverified.
