# GitHub Roadmap Tracking

Updated: 2026-10-22. Tracking was initially created and verified on 2026-10-16.
Status: R100-01 and R100-02 are completed; issues #1 and #2 are closed as completed.
R100-02 implementation commit: `049b74b`. Both features are integrated into `develop`; their feature branches
were deleted. `develop` was pushed to GitHub through `b48d44d` on 2026-10-18. No release was published.
See [Processing results](COLLECTION_PROCESSING.md) for verification and native qualification limits.
R100-03 is implemented, independently reviewed, and committed as `e7d404b` on 2026-10-18. The commit is
present in `develop` and the locally recorded `origin/develop` at `fd9eb83`. GitHub issue #3 remains open
at live read-back on 2026-10-18; implementation integration and tracker closure are separate facts.
R100-04 / issue #4 is committed as `008a6f3` and fast-forwarded into local `develop` on 2026-10-20.
[Processing recovery](PROCESSING_RECOVERY.md) records final verification and local feature completion.
No push or GitHub issue closure was performed.
See [Common and Log migration](COMMON_AND_LOG_MIGRATION.md).
Repository: [AIBeCe/MovieFolderPosters](https://github.com/AIBeCe/MovieFolderPosters).
Tracker: repository Issues. No separate Projects board is used.

## Source of scope

[Production roadmap](PRODUCTION_ROADMAP.md) owns release scope and acceptance. [Idea triage](IDEA_TRIAGE.md)
accounts for all 180 original ideas; [UI enhancements](UI_ENHANCEMENTS.md) links ten additional proposals to the
same consolidated deliverables. Issue bodies contain scope, acceptance, dependencies, E/N source names, relevant
U IDs, and verification/approval boundaries, so they remain usable independently of published documentation.
The roadmap documentation commits are local until an explicit push; do not assume they are already on GitHub.

### Recovery and manual-resolution scope clarification — 2026-10-18

R100-04 / issue #4 owns explicit automatic retry eligibility, interruption recovery, one-time legacy
reassessment, and collection labels that distinguish freshness from remaining work. A retry date cannot
establish eligibility. Confirmed Not found and Several matches require user action and never repeat
automatically for the same unchanged folder. R100-05 / issue #5 owns the manual search/selection interface
and bounded user-requested retries. No additional feature issue or background scheduler is introduced.
The [processing policy](COLLECTION_PROCESSING.md#approved-recovery-policy--r100-04-and-r100-05) defines the
state/action mapping and acceptance criteria. Issue #4 behavior is committed and integrated locally; the issue #5 manual
resolution interface remains separately scoped.

There are 10 milestones and 54 coded issues. They represent 176 future-source ideas, not 54 cherry-picked ideas.
The three delivered baseline ideas need no duplicate issue; conditional E40/C01 remains inactive. Merged source
ideas share their owning issue rather than duplicating implementation tasks.

## Completed delivery — R100-01

Issue #1 was closed as completed after the user approved feature completion. Final verification passed 236 tests;
independent reviews, signed builds, and controlled native checks passed. Local `develop` was fast-forwarded to
`55ba0a6`, and `feature/installation-readiness` was deleted. The integration was included in the 2026-10-18 push of `develop`.
See [Native qualification](NATIVE_READINESS_QUALIFICATION.md) for evidence and unperformed release checks.

## Milestones

No arbitrary due dates, assignees, or release tags were added. All entries were open at verification. Open-issue
counts show the creation baseline, not a live progress dashboard. Milestone closure requires the roadmap's
release/decision criteria; a supporting issue is not automatically an application release blocker.

| Target | Milestone | Initial issues | Meaning |
| --- | --- | --- | --- |
| 1.0.0 | [Milestone 2](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | 9 | Planned release, subject to its roadmap gate |
| 1.1.0 | [Milestone 3](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | 5 | Planned release, subject to its roadmap gate |
| 1.2.0 | [Milestone 4](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | 6 | Planned release, subject to its roadmap gate |
| 1.3.0 | [Milestone 5](https://github.com/AIBeCe/MovieFolderPosters/milestone/5) | 4 | Planned release, subject to its roadmap gate |
| 1.4.0 | [Milestone 6](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | 5 | Planned release, subject to its roadmap gate |
| 1.5.0 | [Milestone 7](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | 5 | Planned release; supporting R150-05 does not block app release |
| 1.6.0 | [Milestone 8](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | 5 | Planned release, subject to its roadmap gate |
| 1.7.0 | [Milestone 9](https://github.com/AIBeCe/MovieFolderPosters/milestone/9) | 4 | Planned release; R170-04 remains research-only |
| 1.8.0 | [Milestone 10](https://github.com/AIBeCe/MovieFolderPosters/milestone/10) | 3 | Planned release, subject to its roadmap gate |
| 2.0 candidates | [Milestone 11](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | 8 | Research horizon; decisions, not a committed 2.0 release |

## Deliverable issues

| Code | Issue | Milestone | Kind |
| --- | --- | --- | --- |
| R100-01 | [#1 — Verify installation, access, and platform readiness](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Completed 2026-10-17 |
| R100-02 | [#2 — Persist authoritative processing outcomes and collection summaries](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Completed; issue closed |
| R100-03 | [#3 — Connect bounded Finder and host activity to Log](https://github.com/AIBeCe/MovieFolderPosters/issues/3) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Committed/integrated; issue remains open |
| R100-04 | [#4 — Make network failure and interruption recovery predictable](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Committed/integrated locally; not pushed |
| R100-05 | [#5 — Resolve and retry specific failed folders](https://github.com/AIBeCe/MovieFolderPosters/issues/5) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Implemented and validated; live Finder qualification pending |
| R100-06 | [#6 — Make credential setup and replacement understandable](https://github.com/AIBeCe/MovieFolderPosters/issues/6) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Planned delivery |
| R100-07 | [#7 — Complete essential native usability and accessibility](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Accessible empty state integrated; native qualification pending; issue remains open |
| R100-08 | [#8 — Handle corrupt cached artwork safely](https://github.com/AIBeCe/MovieFolderPosters/issues/8) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Implemented, validated, and integrated locally; native qualification pending; issue remains open |
| R100-09 | [#9 — Qualify and distribute the first production release](https://github.com/AIBeCe/MovieFolderPosters/issues/9) | [1.0.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/2) | Planned delivery |
| R110-01 | [#10 — Simplify collection setup and naming](https://github.com/AIBeCe/MovieFolderPosters/issues/10) | [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | Implemented, validated, and integrated locally at `3c447e0`; Finder Sync/File Providers Settings presentation remains unresolved |
| R110-02 | [#11 — Pause collections and exclude folders reversibly](https://github.com/AIBeCe/MovieFolderPosters/issues/11) | [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | Planned delivery |
| R110-03 | [#12 — Improve result and Log filtering with private history](https://github.com/AIBeCe/MovieFolderPosters/issues/12) | [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | Planned delivery |
| R110-04 | [#13 — Connect results with focused Finder utilities](https://github.com/AIBeCe/MovieFolderPosters/issues/13) | [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | Planned delivery |
| R110-05 | [#14 — Explain local data and produce focused support exports](https://github.com/AIBeCe/MovieFolderPosters/issues/14) | [1.1.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/3) | Planned delivery |
| R120-01 | [#15 — Add verified aliases and language preferences](https://github.com/AIBeCe/MovieFolderPosters/issues/15) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R120-02 | [#16 — Improve year, edition, and spelling evidence](https://github.com/AIBeCe/MovieFolderPosters/issues/16) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R120-03 | [#17 — Search additional pages within a finite budget](https://github.com/AIBeCe/MovieFolderPosters/issues/17) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R120-04 | [#18 — Use explicit identifiers and opt-in local evidence](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R120-05 | [#19 — Remember explicit corrections without renaming](https://github.com/AIBeCe/MovieFolderPosters/issues/19) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R120-06 | [#20 — Make candidate comparison and sequential resolution useful](https://github.com/AIBeCe/MovieFolderPosters/issues/20) | [1.2.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/4) | Planned delivery |
| R130-01 | [#21 — Choose provider alternatives or a local poster](https://github.com/AIBeCe/MovieFolderPosters/issues/21) | [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5) | Planned delivery |
| R130-02 | [#22 — Support local-artwork and offline collection workflows](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5) | Planned delivery |
| R130-03 | [#23 — Select artwork by language and quality](https://github.com/AIBeCe/MovieFolderPosters/issues/23) | [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5) | Planned delivery |
| R130-04 | [#24 — Add style scope and realistic previews](https://github.com/AIBeCe/MovieFolderPosters/issues/24) | [1.3.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/5) | Planned delivery |
| R140-01 | [#25 — Record exact mutation receipts and session summaries](https://github.com/AIBeCe/MovieFolderPosters/issues/25) | [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | Planned delivery |
| R140-02 | [#26 — Preview changes without writing icons](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | Planned delivery |
| R140-03 | [#27 — Run finite batches and explicit queues](https://github.com/AIBeCe/MovieFolderPosters/issues/27) | [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | Planned delivery |
| R140-04 | [#28 — Apply reviewed plans and deferred approvals safely](https://github.com/AIBeCe/MovieFolderPosters/issues/28) | [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | Planned delivery |
| R140-05 | [#29 — Undo the latest eligible poster change](https://github.com/AIBeCe/MovieFolderPosters/issues/29) | [1.4.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/6) | Planned delivery |
| R150-01 | [#30 — Export portable configuration and confirmed decisions](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | Planned delivery |
| R150-02 | [#31 — Review imports, mappings, and root relocation](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | Planned delivery |
| R150-03 | [#32 — Maintain caches and remove app records deliberately](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | Planned delivery |
| R150-04 | [#33 — Recover configuration and evolve stored data safely](https://github.com/AIBeCe/MovieFolderPosters/issues/33) | [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | Planned delivery |
| R150-05 | [#34 — Document reusable service examples](https://github.com/AIBeCe/MovieFolderPosters/issues/34) | [1.5.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/7) | Supporting documentation |
| R160-01 | [#35 — Introduce small reusable processing profiles](https://github.com/AIBeCe/MovieFolderPosters/issues/35) | [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | Planned delivery |
| R160-02 | [#36 — Group collections for bounded operations](https://github.com/AIBeCe/MovieFolderPosters/issues/36) | [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | Planned delivery |
| R160-03 | [#37 — Retain bounded policy versions](https://github.com/AIBeCe/MovieFolderPosters/issues/37) | [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | Planned delivery |
| R160-04 | [#38 — Add constrained name-expansion dictionaries](https://github.com/AIBeCe/MovieFolderPosters/issues/38) | [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | Planned delivery |
| R160-05 | [#39 — Offer restrained matte-frame customization](https://github.com/AIBeCe/MovieFolderPosters/issues/39) | [1.6.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/8) | Planned delivery |
| R170-01 | [#40 — Add native navigation and Finder entry points](https://github.com/AIBeCe/MovieFolderPosters/issues/40) | [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9) | Planned delivery |
| R170-02 | [#41 — Expose bounded Shortcuts operations and status](https://github.com/AIBeCe/MovieFolderPosters/issues/41) | [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9) | Planned delivery |
| R170-03 | [#42 — Apply reviewed local artwork packs](https://github.com/AIBeCe/MovieFolderPosters/issues/42) | [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9) | Planned delivery |
| R170-04 | [#43 — Evaluate a clearly non-movie fallback image](https://github.com/AIBeCe/MovieFolderPosters/issues/43) | [1.7.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/9) | Research decision |
| R180-01 | [#44 — Report outcome patterns without becoming a library](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10) | Planned delivery |
| R180-02 | [#45 — Measure and improve cache reuse across collections](https://github.com/AIBeCe/MovieFolderPosters/issues/45) | [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10) | Planned delivery |
| R180-03 | [#46 — Compare policies using stored evidence](https://github.com/AIBeCe/MovieFolderPosters/issues/46) | [1.8.0](https://github.com/AIBeCe/MovieFolderPosters/milestone/10) | Planned delivery |
| X200-01 | [#47 — Research additional metadata providers and credentials](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-02 | [#48 — Research edition-specific identity](https://github.com/AIBeCe/MovieFolderPosters/issues/48) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-03 | [#49 — Research a finite command-line interface](https://github.com/AIBeCe/MovieFolderPosters/issues/49) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-04 | [#50 — Research a narrow read-only integration API](https://github.com/AIBeCe/MovieFolderPosters/issues/50) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-05 | [#51 — Research explicitly bounded nested roots](https://github.com/AIBeCe/MovieFolderPosters/issues/51) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-06 | [#52 — Research constrained custom parser rules](https://github.com/AIBeCe/MovieFolderPosters/issues/52) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-07 | [#53 — Research specific read-only media-tool import formats](https://github.com/AIBeCe/MovieFolderPosters/issues/53) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |
| X200-08 | [#54 — Research explicit remote artwork URL import](https://github.com/AIBeCe/MovieFolderPosters/issues/54) | [2.0 candidates](https://github.com/AIBeCe/MovieFolderPosters/milestone/11) | Research decision |

## Tracking conventions

- Issue titles begin with the stable roadmap code: `[R100-01] ...` or `[X200-01] ...`.
- Keep one issue per consolidated deliverable. Future bounded implementation subtasks may be added when useful,
  but must link back to the owner and must not duplicate original E/N ideas as separate features.
- The `roadmap` label identifies all 54 entries; `enhancement` identifies planned product work. `research` marks
  the nine decision-only issues. R150-05 uses `documentation` and `supporting`; it is not a new app subsystem.
- A milestone assignment is an ordering/planning target, not authorization or a delivery-date promise.
- Research issues close on reviewed feasibility/scope decisions, with reasons and linked follow-up when approved.
  Do not close them as shipped features merely because an investigation ended.
- Supporting and research issues do not replace release acceptance gates. Do not close milestones mechanically
  without checking their documented meaning and unfinished required work.
- Keep scope/acceptance in the roadmap and issue aligned. Changing release targets requires a recorded decision,
  an issue milestone update, and matching roadmap/triage/UI link updates.
- On completion, attach actual test/build/review/native evidence, record material limitations, and integrate
  approved work using GitFlow. Issue creation, a checked plan box, or an optimistic summary is not that evidence.
- Never write credentials, access bookmarks, sensitive user paths, raw private logs, or movie contents into issues.
- Repository default branch remains unchanged. Publishing documentation and production implementation each need
  their applicable authorization; this tracking setup did not push, create a release, or change product behavior.

## Verification record

Verified via live GitHub read-back on 2026-10-16:

- 10 intended milestones exist with the expected titles, descriptions, and no invented due dates.
- 54 unique coded issues have the expected milestone, type labels, source IDs, and approval boundaries.
- All issues are open; no delivered source ideas were misrepresented as unfinished standalone implementations.
- Documentation links agree with returned GitHub URLs and issue/milestone numbers.
- All 180 original catalogue entries retain exactly one primary disposition, and all ten U-series proposals
  resolve to their owning issues. No application tests were needed for this documentation/tracker-only task.
