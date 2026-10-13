# New feature ideas catalogue

Date: 2026-10-14
Status: 100 brainstorming concepts; no implementation is authorized by this document.

## Relationship to the enhancement catalogue

This document adds 100 new capability concepts to the existing
[80 enhancement ideas](ENHANCEMENT_IDEAS.md). The first catalogue improves existing behavior, reliability, and UI.
This catalogue explores additional workflows, operating modes, inputs, integrations, and tools.
Some concepts share a domain with an enhancement, but describe an additional capability rather than repeat its title.
Related concepts are alternatives or may be combined; they do not necessarily justify separate implementations.

## Scope and feasibility

These are candidates for discussion, not a roadmap or a promise that every platform integration is feasible.
Preserve Finder as the movie browser and never rename, move, delete, or modify movie contents.
Local manifests and sidecars, where proposed, are read-only inputs with explicit scope and authorization.
No idea authorizes a permanent background service, filesystem watcher, periodic scan, or automatic external action.
CLI tools, external interfaces, additional providers, and nested processing expand current scope and need explicit review.
All mutations must retain authorization, identity, ownership, suppression, cancellation, and ambiguity protections.
Select ideas first; investigate APIs, licensing, security, persistence, and verification before proposing implementation.

## Collection policies and reusable setups

1. **Named processing profiles.** Save reusable combinations of matching, artwork, and processing policies that can be assigned to collections.
2. **Collection policy templates.** Offer starting templates for conservative automatic assignment, manual approval, or local artwork workflows.
3. **Profile inheritance.** Let collections inherit global policies while showing their deliberate exceptions in a policy comparison.
4. **Configuration import and export.** Transfer a reviewable settings document between installations without exporting credentials or access grants.
5. **Portable path mapping.** Map imported collection paths to a different mount point through explicit user selection and new authorization.
6. **Clone collection policies.** Copy policies from one configured collection to another without copying bookmarks or processing identity.
7. **Collection groups.** Group configured roots for bounded operations, such as processing all selected external-drive collections together.
8. **Policy version snapshots.** Retain named policy versions so users can restore earlier settings without reverting movie-specific decisions.
9. **Configuration comparison.** Show differences between current settings and an imported profile before accepting changes.
10. **Collection onboarding presets.** Guide new collection setup through access, identification policy, and artwork policy as one reviewable flow.

## Additional identification evidence

11. **Read-only NFO identification.** Optionally read recognized NFO metadata for authoritative movie identifiers without editing sidecars.
12. **IMDb identifier resolution.** Resolve an explicitly supplied IMDb identifier through a supported provider lookup before applying artwork.
13. **Movie filename evidence.** Optionally examine immediate video filenames when the containing folder is uninformative; never recurse or rename files.
14. **Movie-name manifest.** Accept a user-authored mapping file that associates child folder names with confirmed movie identifiers.
15. **CSV match import.** Import a reviewed table of folder-to-movie mappings with path, identifier, and conflict validation.
16. **Personal release-name dictionaries.** Apply user-defined expansions for known abbreviations before matching, keeping the original query visible.
17. **Custom parser rule sets.** Allow constrained, previewable parsing rules for a particular naming convention, with ambiguity safeguards.
18. **Cross-provider identity verification.** Compare identifiers across supported metadata providers before trusting conflicting identification evidence.
19. **Identification evidence hierarchy.** Let users explicitly prioritize identifiers, sidecars, saved mappings, and parsed names rather than silently mixing them.
20. **Edition-specific identity records.** Represent a user-confirmed cut or edition separately from the base movie identity when a provider supports it.

## Artwork source policies

21. **Automatic local artwork discovery.** Optionally recognize approved names such as poster.jpg in immediate movie folders and prefer them without downloading.
22. **Artwork language preference.** Prefer artwork in selected languages while defining an explicit fallback when localized posters are unavailable.
23. **Textless artwork policy.** Choose available textless artwork for users who prefer images without embedded titles; do not generate replacements silently.
24. **Minimum artwork resolution.** Require a configurable source-image quality threshold and explain when no available image meets it.
25. **Artwork source priority.** Define whether local artwork, a saved choice, or a provider poster takes precedence for a collection.
26. **Remote artwork URL import.** Accept an explicit image URL with validation and a visible source, rather than assuming it identifies a movie.
27. **Artwork mapping manifest.** Import folder-to-local-image associations for a curated collection without changing its movie identities.
28. **Approved artwork packs.** Apply a user-selected pack of images whose manifest clearly identifies eligible folders and source files.
29. **Artwork license records.** Keep available source and attribution information alongside chosen artwork for traceable personal use.
30. **Collection artwork fallback.** Offer an explicit neutral collection-specific image for unresolved folders, clearly distinguished from a confirmed movie poster.

## Finder and macOS entry points

31. **Finder inspection command.** Open an app detail sheet for the selected folder with its identification evidence and current policy.
32. **Copy confirmed movie title.** Copy the verified title from a Finder action without renaming the folder.
33. **Copy movie identifier.** Copy a confirmed TMDb or supported external identifier for use in other tools.
34. **Reveal unresolved folders.** Select unresolved children in Finder from a processing report so users can act in their existing browser.
35. **Finder toolbar processing action.** Investigate an optional Finder Sync toolbar command for a bounded operation on the current configured collection.
36. **Add collection through macOS Services.** Offer a native service that sends a selected directory into the app authorization and setup flow.
37. **Shortcuts processing action.** Expose explicit, bounded collection processing through Shortcuts without installing a scheduled background service.
38. **Shortcuts status query.** Return collection outcome summaries to a user-invoked shortcut without triggering new network work.
39. **Quick Action for supplied artwork.** Investigate a native Quick Action that applies a selected image to an explicitly chosen authorized movie folder.
40. **Validated app deep links.** Support links to an existing collection or result for navigation; links must not bypass authorization or perform mutations.

## Reviewable processing workflows

41. **Dry-run processing plans.** Identify proposed assignments and skips without writing icons, allowing users to review the result first.
42. **Metadata-only preparation.** Resolve movie candidates on demand while deliberately deferring artwork downloads and icon writes.
43. **Apply a saved processing plan.** Apply a previously reviewed plan only after revalidating folder identities, authorization, settings, and ownership.
44. **Approval inbox.** Hold otherwise eligible new assignments for explicit approval when a collection uses a review-first policy.
45. **Side-by-side icon change review.** Compare a folder's actual current icon with its proposed replacement before a deliberate mutation.
46. **Per-operation change receipts.** Record exactly which authorized icon mutations a completed operation made, rather than only aggregate counts.
47. **Deferred selected assignments.** Let users postpone specific proposed assignments while approving the rest of a reviewed operation.
48. **User-invoked operation queue.** Queue selected finite jobs while the app is open, with no permanent service or automatic schedule.
49. **Maintenance session summary.** Summarize decisions and applied changes across one explicit repair session for review before closing it.
50. **Assignment approval expiry.** Expire saved approvals after relevant movie evidence, folder identity, or processing policy changes.

## Local control and privacy

51. **Offline-only collection mode.** Allow a collection to use confirmed records and local artwork exclusively, rejecting new network lookups.
52. **Per-collection network permission.** Let users disable provider access for selected roots while retaining authorized local processing.
53. **Identification-data preview.** Show the parsed title, year, and other supported fields that a provider request would disclose.
54. **Local data inspector.** Show what settings, decisions, and metadata the app stores without exposing tokens or raw authorization bookmarks.
55. **Collection data deletion.** Offer explicit deletion of app records for a removed collection while preserving movie files and installed icons.
56. **Credential profiles.** Support deliberately selected provider credentials for different setups, stored securely and never embedded in profiles.
57. **Credential replacement workflow.** Provide a guided credential replacement that tests access and preserves collection authorization and confirmed mappings.
58. **Network activity ledger.** Keep an optional bounded record of request purpose and outcome without storing secrets or full private request data.
59. **Strict privacy preset.** Provide a preset that uses minimal identification evidence and disables optional diagnostics and remote artwork imports.
60. **Private collection mode.** Allow a collection's optional history and exported diagnostics to omit identifying paths and names while necessary local state stays functional.

## Transfer, backup, and interoperability

61. **Confirmed-match backup.** Export user-confirmed identities as a portable file independent of transient search results and image caches.
62. **Local artwork choice backup.** Back up references to user-selected artwork with clear handling of missing or moved image files.
63. **Verified backup restoration.** Restore exported app decisions only after remapping roots and validating current child folders.
64. **Backup validation utility.** Inspect an exported backup for compatibility and integrity before attempting restoration.
65. **Cross-Mac decision transfer.** Transfer confirmed identities between Macs without transferring sandbox permissions or assuming identical mount paths.
66. **Collection relocation assistant.** Move app configuration to a user-selected new root after the user has relocated files outside the app.
67. **Collection comparison report.** Compare confirmed identities across two configured roots to identify differing decisions without reorganizing contents.
68. **Read-only media-tool manifest import.** Read supported exports from another media tool as identification evidence without integrating file-management commands.
69. **Interoperable confirmed-match export.** Export confirmed identities in a documented neutral format for use by another tool.
70. **Portable poster source bundle.** Export selected cached source images with a mapping manifest for an explicitly requested offline setup.

## Alternative operating modes and extension points

71. **Local-artwork-only installation mode.** Offer a complete setup path without a TMDb credential when the selected workflow uses local artwork only.
72. **User-invoked command-line interface.** Consider a finite CLI for authorized operations; this expands the distribution scope and requires separate approval.
73. **Command-line dry-run reports.** If a CLI is approved, produce machine-readable proposed assignments without modifying filesystem metadata.
74. **Secondary metadata provider.** Consider a provider with documented APIs and licensing when TMDb lacks needed coverage; new credentials and dependencies require review.
75. **Provider health comparison.** For approved providers, show user-invoked availability checks without silently switching movie identities.
76. **Provider-specific capabilities view.** Explain which approved provider supports identifiers, editions, localized artwork, and relevant evidence.
77. **Search-language profiles.** Allow explicit search-language configurations for collections with international naming conventions.
78. **Read-only integration API.** Consider a narrow local interface for querying app decisions; any external interface changes the architecture and requires approval.
79. **Reusable service examples.** Provide small standalone examples demonstrating Network, FileSystem, or Persistence capabilities for framework consumers.
80. **Opt-in nested collection roots.** Consider explicitly authorized bounded depth for nested collections; this changes the immediate-child-only scope and requires approval.

## Operational insight and reports

81. **Identification source breakdown.** Report how many confirmed matches came from parsed names, explicit IDs, sidecars, or user decisions.
82. **Rejection pattern report.** Aggregate recurring rejection categories to show which parser or matching improvements would help a collection.
83. **Decision correction history.** Show how a folder's confirmed identity changed over time and whether each change was automatic or explicit.
84. **Provider evidence age view.** Distinguish recently fetched evidence from older cached evidence when users evaluate an identification decision.
85. **Cache effectiveness report.** Measure avoided requests and source-image reuse from actual completed operations.
86. **Operation resource estimates.** Estimate likely request and download counts for a dry run without presenting estimates as guarantees.
87. **Processed collection snapshot.** Export a dated report of verified identities and icon outcomes for a collection without creating a movie browsing UI.
88. **Ownership coverage report.** Summarize which children have app-owned, foreign, suppressed, or absent icons based on a bounded inspection.
89. **Matching policy impact comparison.** Compare two policies against stored evidence without applying either policy's proposed icon changes.
90. **Support-session diagnostic package.** Generate a user-reviewed bundle of selected run receipts and redacted decision evidence for a specific support session.

## Installation, recovery, and lifecycle tools

91. **Installation readiness check.** Check app and extension compatibility, signing, shared storage access, and required setup before processing.
92. **Extension registration diagnostics.** Show evidence about registered extension copies to help diagnose an older build being selected.
93. **App-extension version display.** Display both component versions and warn about an observed mismatch instead of assuming matching bundles.
94. **Shared-storage health check.** Run a bounded integrity/access probe of app-owned shared storage with clear failure explanations.
95. **Configuration recovery assistant.** Recover from a damaged settings record using a reviewed backup without silently resetting credentials or authorizations.
96. **Schema migration preview.** Explain significant stored-data migrations before applying a user-visible compatibility change.
97. **Pre-upgrade recovery snapshot.** Save a bounded snapshot of app-owned decisions before a substantial migration; exclude secrets and access grants.
98. **Safe-mode launch.** Open configuration and diagnostics with processing disabled so users can recover from repeated startup or processing failures.
99. **Pre-uninstall export assistant.** Offer export of confirmed decisions and optional cleanup choices before the user removes the app.
100. **Poster metadata cleanup tool.** Offer a separately approved, reviewable operation to remove only verified app-owned icons, preserving foreign icons and movie contents.
