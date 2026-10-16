# Native UI Enhancements — Versioned Proposals

Date: 2026-10-16
Status: Planning only. Preserve the accepted [native AppKit UI](NATIVE_APPKIT_UI.md).

## Intent and boundaries

Improve clarity, discoverability, accessibility, and recovery using the UI already accepted. Keep three reusable
windows: Main, Settings, and Log. Main stays a compact collection list with Collection +, Done, Not found,
Several matches, Total, hover-only Remove, Log bottom left, and Settings bottom right. Keep standard AppKit
controls/chrome and System/Light/Dark. No SwiftUI, glass theme system, library grid, or permanent fourth window.

Focused result/candidate/review sheets may attach to Main. Future profile/import/support controls belong to their
relevant Settings pane or a finite sheet, not an always-visible Main toolbar. Layout changes need their own
concrete proposal and visual review before implementation.

These ten proposals are additions to the original 180 source ideas. They are integrated into roadmap work rather
than ten independent redesign projects. Accessibility/privacy fundamentals apply from the first feature.

| ID | Improvement | Target / owner | Acceptance |
| --- | --- | --- | --- |
| U01 | Consistent collection-state text and symbols for access, active work, interruption, pause, and stale results | 1.0 R100-02/R100-07; pause added with 1.1 R110-02 | Status never relies on dot color alone; path stays discoverable without cluttering the table. |
| U02 | Open a focused result/evidence sheet from a problem count or collection action | 1.0 R100-05; richer filters/candidates in 1.1/1.2 | Show actual provider data and available correction actions; never present a grid of the movie collection. |
| U03 | Empty and unavailable-data states that explain the next useful step | 1.0 R100-07 | Empty setup points to existing Add; missing summary uses an em dash, not zero; no duplicate prominent controls. |
| U04 | Concise finite-run progress and cancellation beside the affected operation | 1.0 R100-05; queue details in 1.4 R140-03 | Work is labelled active/partial/completed accurately; unknown duration has no fabricated ETA. |
| U05 | Preserve hover-only Remove with keyboard and contextual equivalents | 1.0 R100-07 | Keyboard/VoiceOver users can discover and invoke the same action; asynchronous reload preserves selected identity. |
| U06 | Log search, category/severity filters, copying, and explicit Clear scope | Basic Clear scope in 1.0 R100-03; richer tools in 1.1 R110-03 | Filtering is reversible and keyboard accessible; Clear never resets outcomes, cache, decisions, credentials, or icons. |
| U07 | Short Settings help, effective-value/inheritance explanation, and reviewed reset semantics where needed | Credential help in 1.0 R100-06; artwork in 1.3; profiles in 1.6 | Explain the actual consequence before changing it. No global destructive Reset or arbitrary new setting is implied. |
| U08 | Preview choices expose selection without depending on the blue outline | 1.0 R100-07; new preview sizes in 1.3 R130-04 | Native accessible selected state and keyboard behavior work; add a visible non-color cue if contrast testing shows it is needed. |
| U09 | Contextual error and retry presentation with no modal-alert storm | 1.0 R100-01/R100-04/R100-07 | Different root/network problems have useful explanations; repeated failures do not steal focus or leak paths/tokens. |
| U10 | Conventional menu shortcuts, window restoration, and stable focus | 1.0 R100-07; configuration convenience in 1.1 R110-01 | Command-comma opens existing Settings, navigation is keyboard operable, and reopen/resize/appearance changes do not break layout. |

## Material dependencies

1. Authoritative outcomes and operation identity precede progress/count/result UI. Current placeholders cannot be
   solved by adding labels. Log is a separate bounded activity stream, not the source for collection counts.
2. Cancellation and retry controls must invoke approved application operations; views do not write icons directly.
3. Contextual explanations must distinguish absent movie identity, missing artwork, preserved foreign icons,
   unsupported storage, access denial, and network backoff. Unknown data stays unknown.
4. Candidate sheets reuse confirmed identities and existing matching/correction services. Dry-run comparison and
   approval inbox features arrive only after the 1.4 operation/receipt/validation foundations.
5. Export controls explain what leaves the app, offer local review, and never automatically upload diagnostics.

## Visual and behavioral review process

For each bounded UI point, propose the real AppKit controls and layout against the accepted screenshots, implement
only after approval, and capture the running application for review. Do not generate new idealized mockups as a
substitute for a working AppKit material/control prototype.

Check light/dark, minimum and resized window dimensions, populated/empty/error/busy states, long names and text,
keyboard and VoiceOver, focus after updates, contrast, and close/reopen behavior. Extend meaningful unit/UI tests
where behavior warrants them; native screenshots prove appearance, not backend or sandbox correctness.

No UI code, settings, app preferences, or movie metadata changed while creating this document.
