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
| U01 | Consistent collection-state text and symbols for access, active work, interruption, pause, and stale results | [R100-02 / #2](https://github.com/AIBeCe/MovieFolderPosters/issues/2), [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7), [R110-02 / #11](https://github.com/AIBeCe/MovieFolderPosters/issues/11); 1.0 states; pause in 1.1 | Status never relies on dot color alone; path stays discoverable without cluttering the table. |
| U02 | Open a focused result/evidence sheet from a problem count or collection action | [R100-05 / #5](https://github.com/AIBeCe/MovieFolderPosters/issues/5), [R110-03 / #12](https://github.com/AIBeCe/MovieFolderPosters/issues/12), [R120-06 / #20](https://github.com/AIBeCe/MovieFolderPosters/issues/20); 1.0 results; 1.1 filters; 1.2 candidate details | Show actual provider data and available correction actions; never present a grid of the movie collection. |
| U03 | Empty and unavailable-data states that explain the next useful step | [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7); 1.0 | Empty setup points to existing Add; missing summary uses an em dash, not zero; no duplicate prominent controls. |
| U04 | Concise finite-run progress and cancellation beside the affected operation | [R100-05 / #5](https://github.com/AIBeCe/MovieFolderPosters/issues/5), [R140-03 / #27](https://github.com/AIBeCe/MovieFolderPosters/issues/27); 1.0 progress/cancel; 1.4 queue details | Work is labelled active/partial/completed accurately; unknown duration has no fabricated ETA. |
| U05 | Preserve hover-only Remove with keyboard and contextual equivalents | [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7); 1.0 | Keyboard/VoiceOver users can discover and invoke the same action; asynchronous reload preserves selected identity. |
| U06 | Log search, category/severity filters, copying, and explicit Clear scope | [R100-03 / #3](https://github.com/AIBeCe/MovieFolderPosters/issues/3), [R110-03 / #12](https://github.com/AIBeCe/MovieFolderPosters/issues/12); 1.0 Clear scope; 1.1 richer Log tools | Filtering is reversible and keyboard accessible; Clear never resets outcomes, cache, decisions, credentials, or icons. |
| U07 | Short Settings help, effective-value/inheritance explanation, and reviewed reset semantics where needed | [R100-06 / #6](https://github.com/AIBeCe/MovieFolderPosters/issues/6), [R130-02 / #22](https://github.com/AIBeCe/MovieFolderPosters/issues/22), [R130-04 / #24](https://github.com/AIBeCe/MovieFolderPosters/issues/24), [R160-01 / #35](https://github.com/AIBeCe/MovieFolderPosters/issues/35); 1.0 credential help; 1.3 artwork; 1.6 profiles | Explain the actual consequence before changing it. No global destructive Reset or arbitrary new setting is implied. |
| U08 | Preview choices expose selection without depending on the blue outline | [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7), [R130-04 / #24](https://github.com/AIBeCe/MovieFolderPosters/issues/24); 1.0 accessible choices; 1.3 preview sizes | Native accessible selected state and keyboard behavior work; add a visible non-color cue if contrast testing shows it is needed. |
| U09 | Contextual error and retry presentation with no modal-alert storm | [R100-01 / #1](https://github.com/AIBeCe/MovieFolderPosters/issues/1), [R100-04 / #4](https://github.com/AIBeCe/MovieFolderPosters/issues/4), [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7); 1.0 | Different root/network problems have useful explanations; repeated failures do not steal focus or leak paths/tokens. |
| U10 | Conventional menu shortcuts, window restoration, and stable focus | [R100-07 / #7](https://github.com/AIBeCe/MovieFolderPosters/issues/7), [R110-01 / #10](https://github.com/AIBeCe/MovieFolderPosters/issues/10); 1.0 shortcuts/lifecycle; 1.1 configuration convenience | Command-comma opens existing Settings, navigation is keyboard operable, and reopen/resize/appearance changes do not break layout. |

The owning issue links above cover the scoped portion in each release; they do not move later UI features into
1.0. All ten proposals are tracked through existing deliverables rather than duplicate standalone UI issues.

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
