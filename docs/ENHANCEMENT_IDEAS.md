# Enhancement ideas catalogue

Date: 2026-10-14
Status: Brainstorming candidates; not an approved implementation plan.

## Purpose and boundaries

Improve the reliability, clarity, and presentation of movie poster folder icons while Finder remains the movie browser.
The 80 ideas below extend existing behavior or suggest new capabilities. They are not promises or implementation tasks.
Each selected idea requires investigation, a focused proposal, and approval before product changes.
Preserve AppKit, MVVM-C, local in-process SPM services, configured directory scope, and movie contents.
Do not introduce permanent services, filesystem watchers, or periodic scans through these suggestions.

## Proposed UI direction

The UI design consultation recommended a compact Movie Folders window for collections and processing outcomes,
with selected-folder details and contextual corrective actions. A separate Settings window would contain global
credentials and poster appearance preferences. Finder would remain the browsing interface.

Liquid Glass is optional. Prefer standard AppKit toolbar/window styling and keep result tables and explanations legible.
A single-window form is a simpler alternative; a sidebar with separate activity navigation should wait for demonstrated need.
Accessibility, focus behavior, and reduced-transparency support take priority over decorative effects.

References: [Apple Liquid Glass adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
and [Apple materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials).

## Processing results and explanations

1. **Collection processing summaries.** Show processed, unresolved, skipped, and failed counts so users can assess each collection at a glance.
2. **Unresolved-folder list.** List folders needing attention, with actions to resolve them while Finder remains the movie browser.
3. **Match rejection explanations.** Persist and display the actual rejection reason, such as ambiguity or a title/year mismatch.
4. **Metadata versus poster failures.** Explain whether no movie was identified or a confirmed movie lacks usable poster artwork.
5. **Next retry time.** Display when a deferred folder becomes eligible for automatic processing again.
6. **Last processing timestamp.** Show the last completed collection run so users can tell whether Finder observation triggered work.
7. **Assigned movie identity.** Expose the applied movie title, year, and TMDb identifier to help verify the chosen match.
8. **Preserved-icon explanation.** Explain when an existing or user-replaced custom icon prevented automatic assignment.
9. **Bounded processing history.** Retain a limited history of runs and outcomes without growing storage indefinitely.
10. **Result filters.** Filter outcomes by ambiguity, year mismatch, permissions, or network failure to focus corrective work.

## Better movie identification

11. **Verified alternative titles.** Consult provider-confirmed aliases before rejecting a movie whose displayed title differs from the folder name.
12. **Original-language titles.** Handle international title variants and normalization more effectively while retaining conservative matching.
13. **Nearby release years.** Evaluate nearby years when titles agree, accepting only sufficiently supported matches and retaining ambiguity safeguards.
14. **Premiere versus theatrical years.** Use available release-date evidence to distinguish festival premieres from later theatrical releases.
15. **Explainable candidate comparisons.** Show which title, year, and other evidence supports or weakens a candidate rather than presenting an opaque score.
16. **Probable spelling errors.** Suggest candidates for likely misspellings without silently applying uncertain matches.
17. **Edition and cut parsing.** Improve recognition of remasters and special editions without stripping words that belong to the title.
18. **Identifiers in folder names.** Recognize explicitly labelled TMDb identifiers and validate the referenced movie before assigning its poster.
19. **Saved title/year overrides.** Allow users to correct identification inputs for a folder without renaming it or changing movie contents.
20. **Reuse confirmed matches.** Offer reuse of an explicitly confirmed identity for equivalent releases, with a clear and reviewable scope.

## Resolving problematic folders

21. **Choose Movie beside results.** Open the existing movie-selection flow directly from an unresolved folder result.
22. **Candidate comparison.** Present candidate posters, titles, years, and descriptions together to make manual selection easier.
23. **Additional candidate context.** Show country, language, and director when available to distinguish otherwise similar movies.
24. **Remember rejected candidates.** Retain deliberate candidate rejections so later suggestions can respect previous user decisions.
25. **Retry selected unresolved folders.** Let users request a bounded retry immediately instead of waiting for the automatic retry window.
26. **Guided ambiguity resolution.** Walk through selected unresolved folders sequentially without creating a separate movie library.
27. **Batch change preview.** Show proposed changes and preserved folders before a user confirms a batch operation.
28. **Batch refresh of owned posters.** Extend explicit refresh to selected application-owned icons while preserving unrelated custom icons.
29. **Ignore folder action.** Offer a clear exclusion action distinct from poster removal, with an explicit way to reverse it.
30. **Undo the last poster change.** Retain enough prior icon state to reverse the latest app mutation; validate ownership and identity before restoring.

## Main window and Settings

31. **Separate operational and global settings.** Keep collections and results in the main window, with credentials and global preferences in Settings.
32. **Conventional Settings shortcut.** Expose the Settings window through the app menu and Command-comma keyboard shortcut.
33. **Helpful empty state.** Explain the first setup step and provide one prominent Add Folder action when no collections are configured.
34. **Drag collections into the app.** Accept dropped collection folders through the same authorization and validation path as the native picker.
35. **Friendly collection names.** Let users name configured collections for display while retaining the actual filesystem path.
36. **Access problems beside collections.** Show unavailable or unauthorized status in the affected row rather than only in a general alert.
37. **Contextual corrective actions.** Place retry, locate-folder, and choose-movie actions beside the problem they address.
38. **Explicit credential test.** Validate the saved TMDb credential on demand and show a safe result without exposing the token.
39. **Credential setup guidance.** Provide concise instructions explaining where to obtain the required TMDb read access token.
40. **Unsaved-edit handling.** If editable settings introduce deferred saving, warn before discarding changes; unnecessary for immediately saved controls.

## Poster presentation

41. **Live style previews.** Render representative previews of Raw, Soft finish, and Matte frame before changing actual folder icons.
42. **Light and dark preview backgrounds.** Show how a poster style reads against both Finder appearances without changing system settings.
43. **Finder-size previews.** Preview representative icon sizes so users can assess edges and framing at realistic scales.
44. **Collection style overrides.** Allow a configured collection to use its own style while other collections follow the global default.
45. **Individual folder style overrides.** Allow a specific movie folder to retain a different style, with clear precedence over collection and global choices.
46. **Adjustable matte-frame width.** Offer a restrained frame-width range that preserves poster proportions and readability.
47. **Accessible frame colors.** Provide a small palette of frame colors with previews and adequate contrast against light and dark backgrounds.
48. **Alternative poster selection.** Let users choose among available artwork for an already confirmed movie without changing its identity.
49. **Local poster image.** Allow an explicitly selected local image as artwork, using the same validation and ownership safeguards.
50. **Apply appearance explicitly.** Provide a bounded action to restyle existing owned posters immediately instead of relying on another Finder observation.

## Folder access and filesystem reliability

51. **Unmounted versus unauthorized volumes.** Distinguish a disconnected volume from a missing access grant so the app recommends the correct recovery.
52. **Read-only collection detection.** Explain insufficient write access before attempting custom-icon assignment.
53. **Filesystem compatibility feedback.** Identify and explain observed custom-icon failures on particular filesystems rather than claiming universal support.
54. **Overlapping root detection.** Warn when configured roots overlap and explain immediate-child processing and coordination implications.
55. **Explicit collection exclusions.** Allow selected child folders to be excluded from processing while the surrounding collection stays enabled.
56. **Temporarily disable a collection.** Suspend observation and processing while retaining configuration and existing poster icons.
57. **Verified icon ownership status.** Expose whether the current icon still matches the application ownership proof.
58. **User-replaced icon detection.** Show that an externally replaced icon is preserved and explain why automatic restyling will not touch it.
59. **Safe rename reconciliation.** Recognize folder renames using stable identity where supported, without inheriting stale matches after replacement.
60. **Obsolete record cleanup review.** List inactive collection records and let users review a deliberate cleanup without deleting movie contents.

## Performance, networking, and cache

61. **Visible rate-limit backoff.** Display detected provider throttling and the earliest retry time rather than leaving processing apparently stalled.
62. **Distinct network failure states.** Separate offline, authentication, and server failures so users know which problems they can correct.
63. **Shared rate-limit coordination.** Coordinate provider backoff across extension instances to avoid independent processes repeating throttled requests.
64. **Resume interrupted processing.** Use persisted progress to continue safely after extension termination without repeating completed assignments.
65. **Cross-collection search deduplication.** Reuse equivalent metadata queries across configured roots with appropriate freshness and credential boundaries.
66. **Bounded search pagination.** Retrieve additional result pages within a request budget while keeping incomplete searches explicitly unresolved.
67. **Cancel collection processing.** Allow cancellation of a selected run while preserving completed work and preventing later unwanted writes.
68. **Cache size visibility.** Show storage usage for poster sources and processing records so users understand local disk consumption.
69. **Selective cache cleanup.** Provide controlled cleanup of reusable image/search data while preserving confirmed identities and suppression choices.
70. **Cached poster integrity checks.** Detect corrupt cached artwork and offer explicit repair rather than repeatedly trying to apply invalid image data.

## Accessibility, polish, and distribution

71. **VoiceOver support.** Give result rows, statuses, controls, and corrective actions meaningful accessibility descriptions.
72. **Complete keyboard navigation.** Support all workflows without a mouse and preserve useful focus after asynchronous operations.
73. **Text with status symbols.** Pair colors and icons with readable labels so status never depends on color perception alone.
74. **Accessibility appearance verification.** Check layout and contrast with increased contrast and reduced transparency, including any optional glass surfaces.
75. **Polished application icon.** Create a recognizable native app icon that conveys folder posters at Dock and Finder sizes.
76. **Finder extension onboarding.** Explain how to enable the extension and distinguish setup guidance from verified activation state.
77. **Not-updating diagnostic checklist.** Guide users through configured scope, access, credentials, observation triggers, and recorded match outcomes.
78. **Privacy-conscious diagnostic export.** Export useful failure evidence with deliberate redaction of tokens, bookmarks, and user paths.
79. **Signed and notarized installer.** Prepare a distribution package with verified signing, notarization, and clear installation instructions.
80. **Window lifecycle regressions.** Add meaningful checks for view loading, resizing, reopening, and appearance changes to catch startup/layout failures.

## Suggested first shortlist

- Processing summaries and rejection explanations (1–4).
- Direct correction of unresolved results (21–23).
- Verified alternative titles and conservative year handling (11–14).
- Separate operational and global settings surfaces (31–32).
- Poster style previews before applying changes (41–43).

This shortlist is a recommendation for discussion, not an approved order or scope. Validate current behavior and
provider evidence before changing matching rules. Ambiguous matches must continue to require explicit user selection.
