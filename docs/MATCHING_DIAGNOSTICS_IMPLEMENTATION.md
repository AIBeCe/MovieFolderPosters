# Matching diagnostics and reason descriptions

## Authorization and scope

The user explicitly authorized direct implementation after resetting the prior attempt. This work is
separate from R120-05 point 1.13. It adds saved matching evidence to Activity history and a Matching Details
view in Log, and centralizes clear, concise, distinct folder-reason descriptions. Implementation approval
and commit remain pending. Acceptance Testing and Validation have not started.

No collection inventory, processing state lifecycle, matching acceptance rules, scheduling, permissions,
icon operations, or persistence cleanup changes are included.

## Decisions

- Retain typed diagnostics with the terminal activity event, including the supplied matching inputs, actual
  provider query, language/page budget, cache use, completeness, bounded candidate facts and actual matching
  checks. Distinguish an unevaluated check from a failed check.
- Reset evidence for each folder. Capture query context before provider suspension so failures retain context.
- Respect capture-time privacy and current history privacy checks; diagnostics are identifying history and
  must be omitted along with other identifying fields. Decoded data without collection provenance cannot
  bypass redaction. Retain the existing event/history bounds and old-event decoding compatibility.
- Selecting exactly one Activity row with evidence enables Matching Details. The existing coordinator owns
  its resizable native read-only text window. Clear, source/filter or selection changes close stale details.
  Historical records without evidence cannot reconstruct past searches.
- Folder Details and Activity use one canonical description per FolderProcessingReason. The page-limit reason
  is exactly: Search page limit reached before matching finished; choose manually.

## Verification plan

- Common: legacy event decoding, encoding round trip, missing provenance, capture/current privacy, Unicode and
  candidate bounds, actual matcher checks, cache/fresh search evidence, provider failures, per-folder reset,
  and real processor activity emission.
- Presentation: no/multiple/network/legacy selection, selected details content, coordinator ownership,
  selection/filter/clear invalidation, read-only/selectable native text, and existing Log regression tests.
- Reason wording: nonempty, concise, unique descriptions for all reasons and consistent Activity rendering.

## Results

- Common focused serial execution passed: 92 tests in seven suites, including matching decisions, saved
  corrections, diagnostic capture, privacy/redaction, legacy decoding, bounds, and canonical reason wording.
  Evidence: `/private/tmp/mfp-matching-diagnostics-serial.log`.
- Host build-for-testing passed against the current implementation. Eighteen Log tests passed, including
  native details-window lifecycle, selection/filter/Clear invalidation and complete Unicode clipboard export.
  Evidence: `/private/tmp/mfp-matching-ui-build.log`, `/private/tmp/mfp-matching-ui-tests-2.log`, and
  `/private/tmp/mfp-matching-ui-results-2.xcresult`.
- An earlier combined Common run stalled in AppKit/TCC fixture setup and was stopped, not counted as a pass.
  Stack evidence is retained at `/private/tmp/mfp-matching-diagnostics-stack.txt`. Serial focused execution
  passed without escalation. An initial native clipboard test failure was corrected by declaring AppKit's
  supported pasteboard types in the test; its original FAIL log is retained.
- A compiler isolation-inference error in an existing Log fake was resolved by moving its unchanged protocol
  conformance into an extension; production isolation and test call sites are unchanged.
- Independent review PASS: no unresolved Critical/Important findings. Identifier reconciliation outcomes,
  poster failure wording and bounded-candidate summary claims were corrected and re-reviewed.
- Diff whitespace checks passed. SwiftLint/formal Validation have not started. Native Finder, live collection,
  full-app E2E, VoiceOver and Light/Dark visual qualification were not performed. No live collection was
  processed or modified as part of these implementation checks.
- Implementation is uncommitted pending user approval.
