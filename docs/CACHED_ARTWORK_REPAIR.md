# Cached artwork repair — R100-08

Status: implemented and validated; feature commits `9229177` and `e9be774` were fast-forwarded into local
`develop` on 2026-10-22. Native Finder and live-provider qualification were not performed. Issue #8 remains open.

## Behavior

The processor distinguishes a missing poster cache entry from bytes that fail ImageIO's complete-image and
thumbnail checks. On a later authorized processing visit, it can use the saved matched movie ID and provider
poster path to repair missing or corrupt source artwork without repeating a movie search.

Each poster path is downloaded at most once per processing visit. Provider bytes must pass image validation
before replacing cached data. A failed download or invalid response records a recoverable artwork failure while
retaining the saved movie decision and poster path. Invalid bytes do not replace the corrupt cache entry.

For an already-owned folder icon, the processor verifies the saved folder fingerprint, current folder identity,
ownership, and suppression state before repairing its source cache. It does not rewrite that icon when only the
source artwork is damaged. Foreign or user-replaced icons remain untouched. When the folder icon itself needs
assignment, the existing identity, authorization, ownership, and suppression checks still apply.

Repair is part of a normal explicit processor invocation. No watcher, timer, polling loop, daemon, or new service
was added. A later authorized visit can retry a recoverable failure under the existing retry policy.

## Verification

- 39 `MovieFolderProcessorTests` passed, including corrupt/truncated and missing cache entries, failed downloads,
  invalid provider bytes, retry preservation of saved movie decisions, credential-revision reconciliation,
  failed icon assignment, foreign-icon preservation, and source-only repair for an existing owned icon.
- 18 Swift Testing integration and credential-revision tests passed across two suites.
- SwiftLint 0.65.1, using `.swiftlint.yml`, reported zero violations in the nine R100-08 Swift files.
- The installed Swift style guide was applied to those files. Independent review found no remaining guard-spacing
  violations; the final review comments on optional comparisons and statement grouping were addressed.
- `git diff --check` passed.

These checks used controlled provider responses and temporary filesystem fixtures. They do not establish live TMDb
availability, Finder callback behavior, or persistent icon rendering in the user's configured collections. Those
native checks remain part of later qualification.
