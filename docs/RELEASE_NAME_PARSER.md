# Release-name parser

Phase 3 keeps movie-specific parsing in the application target. The parser imports Foundation only and has no
Finder, AppKit, filesystem, network, or persistence dependencies. Immutable Sendable results and explicit
nonisolated types allow callers to use it outside the UI actor under Swift 6.

## Supported behavior

`ReleaseNameParser.parse(_:)` returns either a title and optional year or an explicit unresolved issue.
Dots, underscores, and whitespace become word separators. Case, accents, apostrophes, and title hyphens remain.
Only full folder names are accepted; paths and names containing ellipses are rejected.

Years are four ASCII digits from 1888 through 2099. A leading number can be a title, so `1917` stays a title.
A trailing year can identify the release; multiple unbracketed year candidates remain ambiguous. One bracketed
release year can disambiguate earlier numbers in the title, such as `Blade.Runner.2049.[2017].2160p.WEB-DL`.

An explicit year without a preceding title is unresolved. Conflicting explicit years anywhere in the name remain
ambiguous; a year found beyond an earlier technical boundary makes that boundary uncertain.

Technical tokens form a suffix boundary when their context supplies evidence of release metadata. Resolution,
source, codec, HDR, audio, and common edition tags are recognized case-insensitively. These words are not
removed globally: `The.Remux.Movie.2020` and `The.Dolby.Vision.2020` retain their title words.
Release-group suffixes are discarded with the technical suffix, not removed from arbitrary titles.

Examples:

| Folder name | Result |
| --- | --- |
| `The.Drama.2026.2160p.WEB-DL.DDP5.1.Atmos.H265-GROUP` | The Drama, 2026 |
| `North.Star.WEB-DL.x264-GROUP` | North Star, no year |
| `2001.A.Space.Odyssey.1968.1080p.BluRay` | 2001 A Space Odyssey, 1968 |
| `Blade.Runner.2049.2017.2160p.WEB-DL` | Unresolved: ambiguous year |
| `Movie.2020.Special.Edit.1080p` | Unresolved: ambiguous metadata |

## Limits

This is a deterministic release-name heuristic, not movie identification. Parsing success does not establish
that a movie exists or authorize poster assignment. TMDb matching must independently assess confidence.
Unknown naming conventions may be retained as title text or remain unresolved. Year-shaped title endings and
technical-looking title endings can be inherently ambiguous without metadata; the supported grammar cannot
resolve every possible human title. Use the full filesystem name rather than Finder's shortened label.

No parser invocation has been wired into Finder or automatic processing in this phase.

## Verification

Run `rtk proxy scripts/test-parser.sh` from the repository root. It copies the production parser and its actual
Swift Testing fixtures into a disposable local harness, runs them in Swift 6, and removes the harness afterward.
It adds no production package or third-party dependency. Xcode target compilation is checked separately:

```sh
rtk proxy xcodebuild -project MovieFolderPosters/MovieFolderPosters.xcodeproj -scheme MovieFolderPosters \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/MovieFolderPosters-Phase3 build-for-testing
```

TDD began with four basic cases: three failed against an empty parser and all four passed after minimal
implementation. Expanded realistic and ambiguous fixtures then produced 28 assertion issues against that
minimal implementation before suffix and ambiguity handling were added.

On this development machine, Xcode's hosted test assertions finished, but `xcodebuild test` stalled while
finalizing its result bundle. The precise cause remains unresolved. The independent harness provides a completed
command and exit status for these pure parser tests; it does not verify AppKit or Finder behavior.

Final fixture coverage includes 47 cases across seven test functions: four initial cases, 12 full release names,
16 legitimate-title cases, and 15 unresolved cases. Independent review identified two ambiguity issues; six
additional regression cases failed before the correction and passed afterward.

Independent review returned PASS after verifying both corrected findings and their regression results.
