# Release-name parser

`Packages/MovieFolderParsing` is a Foundation-only local Swift package. The AppKit host and
`MovieFolderCommon` import its `ReleaseNameParser`; the parser has no Finder, filesystem, network,
or persistence dependency. It returns either a title and optional year or an explicit unresolved issue.
Parsing never establishes movie identity or authorizes poster assignment. `MovieFolderCommon` continues
to require a conservative TMDb title/year match before assigning an icon.

## Supported behavior

Dots, underscores, and whitespace separate words. Case, accents, apostrophes, and title hyphens remain.
Only full folder names are accepted; paths and names containing ellipses are rejected. Years are four
ASCII digits from 1888 through 2099. A leading year-shaped number can be a title, so `1917` stays a title.
Conflicting explicit years and uncertain metadata remain unresolved.

Technical tokens form a suffix boundary only when context supports that interpretation. Resolution,
source, codec, HDR, audio, and common edition tags are recognized case-insensitively. These words are
not removed globally: `The.Remux.Movie.2020` retains `Remux` in the title.

Standalone bracketed database-code tokens in a supported suffix position are discarded before title/year
parsing. Accepted forms include `[tt0091251]`, `[imdb-tt0091251]`, `[tmdb-438631]`, `[tvdb-12345]`,
and `[wikidata-Q25188]`. A code may be at the end of the name or immediately before a recognized
technical suffix. It is **not** looked up or used as identity evidence. An unknown or malformed code,
arbitrary bracketed text, and a code embedded in title words are not silently discarded.

| Folder name | Parse result |
| --- | --- |
| `Come and See (1985) [tt0091251]` | Come and See, 1985 |
| `Dune (2021) [tt1160419] 2160p WEB-DL` | Dune, 2021 |
| `Dune (2021) [unknown-12345]` | Unresolved: ambiguous metadata |
| `Blade.Runner.2049.2017.2160p.WEB-DL` | Unresolved: ambiguous year |

## Existing cached folders

The processor records `ReleaseNameParser.revision` with new unresolved decisions. An unchanged folder with an
older unresolved `parsingProblem`, `noSuitableMovie`, or `ambiguousMovie` result is reassessed when its
name contains a newly recognized database-code suffix. A cached search for the newly parsed title/year
is evicted before the fresh provider request; unrelated cached searches remain. Once reassessed, the
current parser revision prevents repeated automatic attempts at the same unchanged unresolved result.
Existing processed icons are preserved.

## Verification

Run `rtk proxy scripts/test-parser.sh` from the repository root for the parser package's Swift Testing
fixtures. The complete package, application, and coverage checks belong to the Validation Phase.
