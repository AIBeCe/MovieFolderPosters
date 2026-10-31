# R120-03 Acceptance Tests

This document records user-observable acceptance scenarios for bounded TMDb
search pagination. UI journeys use the host app's isolated acceptance-test
storage and deterministic Debug transport; no real TMDb credential or movie
folder is used.

| ID | Given | When | Then | Requirement | Automated coverage |
| --- | --- | --- | --- | --- | --- |
| PG-01 | The isolated app has default matching settings | The user selects a page limit and relaunches the app | Matching Defaults shows the saved limit | Global setting persists and defaults to 3 | `testMaximumSearchPagesPersistsAcrossRelaunch`, full-app XCUITest |
| PG-02 | A folder requires explicit movie matching and the fixture has two pages | The user searches with a one-page limit | The app explains that results are incomplete and does not enable Apply | Stop at configured budget and preserve explicit selection | `testOnePageBudgetShowsIncompleteSearchWithoutApplyingResult`, full-app XCUITest |
| PG-03 | A folder requires explicit movie matching and the fixture has two pages | The user searches with a two-page limit | The app fetches page two, exposes its movie, and shows no incomplete warning | Continue through available pages within budget | `testTwoPageBudgetCompletesPaginationFixture`, full-app XCUITest |
| PG-04 | A search is interrupted, fails, or is cancelled | The search pipeline handles the event | No partial result is cached or applied; a later eligible search can recover | Failure/cancellation atomicity and recovery | Existing `BoundedMovieSearchTests`, Common integration tests |
| PG-05 | A request starts with one saved limit | The user changes the limit while it is in flight and searches again | The stale request is not applied; the new search uses the new limit | Configuration revision gates stale results | Existing page-limit host integration tests |
| PG-06 | A persisted configuration predates the page-limit setting | The app loads it | The migrated setting is the default limit of 3 | Backward-compatible configuration migration | Existing `SearchPageLimitTests` |

PG-04 through PG-06 reuse existing automated behavioral coverage only where it
asserts the complete relevant boundary and observable outcome. They are reported
separately from the full-app UI journeys because those Common and host tests are
integration or unit level, not full-app E2E.

## Execution status and deferred tests

| ID | Status | Evidence or blocker |
| --- | --- | --- |
| PG-01 | BLOCKED | The UI test compiled. Its first runner was built without code signing and macOS displayed “MovieFolderPostersUITests-Runner is damaged and can’t be opened.” A later test build using the repository's prior ad-hoc signing setup succeeded, but the targeted test execution was interrupted before test results were collected. |
| PG-02 | BLOCKED | Same XCUITest runner execution interruption as PG-01; no scenario result was collected. |
| PG-03 | BLOCKED | Same XCUITest runner execution interruption as PG-01; no scenario result was collected. |
| PG-04 | PASS | The focused `MovieFolderCommon` run executed 14 bounded-search and page-limit tests; all passed, including failure atomicity, cancellation, budget handling, and migration. |
| PG-05 | BLOCKED | `pageLimitChangeDuringSearchRejectsResults` was selected for the focused Xcode run, but execution was interrupted before its result was collected. |
| PG-06 | PASS | `searchPageLimitMigratesSchemaSixWithoutChangingOtherSettings` passed in the focused `MovieFolderCommon` run. |

The first Xcode build also exposed a pre-existing actor-isolation compile error
in `CoordinatorLifecycleTests.swift`. Its preference helper was marked
`@MainActor`, matching the suite and `AppAppearanceSettings`; the subsequent
ad-hoc-signed `build-for-testing` completed successfully. That change unblocks
compilation but does not count as a test pass.

The XCUITest scenarios and the focused host integration test remain deferred.
The prior test attempt destabilized the computer and was stopped at the user's
request. Resume only when the environment is stable, using the ad-hoc signing
configuration and isolated `/private/tmp/MovieFolderPostersAcceptance` storage
described above. Do not interpret a successful test build as execution evidence.
