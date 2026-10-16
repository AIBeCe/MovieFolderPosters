# Idea Triage — Complete Catalogue Coverage

Date: 2026-10-16
Status: Recorded versioned planning decisions; no implementation authorization.

## Reading this index

E1–E80 are the numbered entries in [Enhancement ideas](ENHANCEMENT_IDEAS.md).
N1–N100 are the numbered entries in [New feature ideas](NEW_FEATURE_IDEAS.md).
Each appears exactly once below, retaining its original title and one primary destination. A deliverable may
implement several related ideas; this does not erase their distinct requirements. Later refinements can name
additional dependencies without counting an idea twice.

- **Delivered:** current native UI provides the capability; release regressions still apply.
- **Planned:** future work, including related ideas grouped into one implementation stream.
- **Partial:** relevant behavior exists, but the complete catalogue intent or production verification remains.
- **Merged:** no separate duplicate task; the named canonical idea/stream preserves its intent.
- **Research:** requires a feasibility/scope decision; a version label is an investigation horizon, not a promise.
- **Conditional:** no active release task until a documented prerequisite exists.
- **Supporting:** optional developer documentation, not a production release blocker.

Original catalogues remain unchanged historical sources. There are no permanent deletions or rejections in this
versioned plan: previously excluded 1.0 concepts are retained in later releases, research, or conditional work.
A later rejected candidate must keep its row and record the evidence/reason instead of disappearing.
The original 40-deliverable/143-retained proposal is superseded; it is not the scope of 1.0 or the current total.

## GitHub issue mapping

Every future/research/supporting destination below links to the single issue for its consolidated deliverable.
Delivered baseline entries have no duplicate implementation issues. Conditional E40/C01 has no active issue until
its prerequisite exists. See [GitHub tracking](GITHUB_TRACKING.md) for milestone links and maintenance rules.

## Coverage summary

- 1.0.0: 47 original ideas.
- 1.1.0: 16 original ideas.
- 1.2.0: 20 original ideas.
- 1.3.0: 16 original ideas.
- 1.4.0: 14 original ideas.
- 1.5.0: 23 original ideas.
- 1.6.0: 9 original ideas.
- 1.7.0: 8 original ideas.
- 1.8.0: 10 original ideas.
- 2.0 candidates: 13 original ideas.
- Delivered baseline: 3 original ideas.
- Conditional: 1 original idea.
- Total: 180 original ideas, with zero missing or duplicate primary assignments.

The roadmap contains 54 consolidated deliverables/research items. They are not 54 selected
ideas: they account for 176 source ideas plus the three delivered and one conditional entry.
Ten additional U-series UI proposals are recorded separately in [UI enhancements](UI_ENHANCEMENTS.md).

## Enhancements

Source: [ENHANCEMENT_IDEAS.md](ENHANCEMENT_IDEAS.md).

| ID | Original idea | Decision | Target / deliverable | Interpretation and consolidation |
| --- | --- | --- | --- | --- |
| E1 | Collection processing summaries | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E2 | Unresolved-folder list | Planned | 1.0.0 / [**R100-05**](PRODUCTION_ROADMAP.md#r100-05) · [#5](https://github.com/AIBeCe/MovieFolderPosters/issues/5) | Resolve and retry specific failed folders. |
| E3 | Match rejection explanations | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E4 | Metadata versus poster failures | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E5 | Next retry time | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E6 | Last processing timestamp | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E7 | Assigned movie identity | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E8 | Preserved-icon explanation | Planned | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Persist authoritative processing outcomes and collection summaries. |
| E9 | Bounded processing history | Planned | 1.0.0 / [**R100-03**](PRODUCTION_ROADMAP.md#r100-03) · [#3](https://github.com/AIBeCe/MovieFolderPosters/issues/3) | Connect bounded Finder and host activity to Log. |
| E10 | Result filters | Planned | 1.1.0 / [**R110-03**](PRODUCTION_ROADMAP.md#r110-03) · [#12](https://github.com/AIBeCe/MovieFolderPosters/issues/12) | Improve result and Log filtering with private history. |
| E11 | Verified alternative titles | Planned | 1.2.0 / [**R120-01**](PRODUCTION_ROADMAP.md#r120-01) · [#15](https://github.com/AIBeCe/MovieFolderPosters/issues/15) | Add verified aliases and language preferences. |
| E12 | Original-language titles | Partial | 1.2.0 / [**R120-01**](PRODUCTION_ROADMAP.md#r120-01) · [#15](https://github.com/AIBeCe/MovieFolderPosters/issues/15) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Add verified aliases and language preferences. |
| E13 | Nearby release years | Planned | 1.2.0 / [**R120-02**](PRODUCTION_ROADMAP.md#r120-02) · [#16](https://github.com/AIBeCe/MovieFolderPosters/issues/16) | Improve year, edition, and spelling evidence. |
| E14 | Premiere versus theatrical years | Planned | 1.2.0 / [**R120-02**](PRODUCTION_ROADMAP.md#r120-02) · [#16](https://github.com/AIBeCe/MovieFolderPosters/issues/16) | Improve year, edition, and spelling evidence. |
| E15 | Explainable candidate comparisons | Planned | 1.2.0 / [**R120-06**](PRODUCTION_ROADMAP.md#r120-06) · [#20](https://github.com/AIBeCe/MovieFolderPosters/issues/20) | Make candidate comparison and sequential resolution useful. |
| E16 | Probable spelling errors | Planned | 1.2.0 / [**R120-02**](PRODUCTION_ROADMAP.md#r120-02) · [#16](https://github.com/AIBeCe/MovieFolderPosters/issues/16) | Improve year, edition, and spelling evidence. |
| E17 | Edition and cut parsing | Partial | 1.2.0 / [**R120-02**](PRODUCTION_ROADMAP.md#r120-02) · [#16](https://github.com/AIBeCe/MovieFolderPosters/issues/16) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Improve year, edition, and spelling evidence. |
| E18 | Identifiers in folder names | Planned | 1.2.0 / [**R120-04**](PRODUCTION_ROADMAP.md#r120-04) · [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | Use explicit identifiers and opt-in local evidence. |
| E19 | Saved title/year overrides | Planned | 1.2.0 / [**R120-05**](PRODUCTION_ROADMAP.md#r120-05) · [#19](https://github.com/AIBeCe/MovieFolderPosters/issues/19) | Remember explicit corrections without renaming. |
| E20 | Reuse confirmed matches | Planned | 1.2.0 / [**R120-05**](PRODUCTION_ROADMAP.md#r120-05) · [#19](https://github.com/AIBeCe/MovieFolderPosters/issues/19) | Remember explicit corrections without renaming. |
| E21 | Choose Movie beside results | Partial | 1.0.0 / [**R100-05**](PRODUCTION_ROADMAP.md#r100-05) · [#5](https://github.com/AIBeCe/MovieFolderPosters/issues/5) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Resolve and retry specific failed folders. |
| E22 | Candidate comparison | Planned | 1.2.0 / [**R120-06**](PRODUCTION_ROADMAP.md#r120-06) · [#20](https://github.com/AIBeCe/MovieFolderPosters/issues/20) | Make candidate comparison and sequential resolution useful. |
| E23 | Additional candidate context | Planned | 1.2.0 / [**R120-06**](PRODUCTION_ROADMAP.md#r120-06) · [#20](https://github.com/AIBeCe/MovieFolderPosters/issues/20) | Make candidate comparison and sequential resolution useful. |
| E24 | Remember rejected candidates | Planned | 1.2.0 / [**R120-05**](PRODUCTION_ROADMAP.md#r120-05) · [#19](https://github.com/AIBeCe/MovieFolderPosters/issues/19) | Remember explicit corrections without renaming. |
| E25 | Retry selected unresolved folders | Planned | 1.0.0 / [**R100-05**](PRODUCTION_ROADMAP.md#r100-05) · [#5](https://github.com/AIBeCe/MovieFolderPosters/issues/5) | Resolve and retry specific failed folders. |
| E26 | Guided ambiguity resolution | Planned | 1.2.0 / [**R120-06**](PRODUCTION_ROADMAP.md#r120-06) · [#20](https://github.com/AIBeCe/MovieFolderPosters/issues/20) | Make candidate comparison and sequential resolution useful. |
| E27 | Batch change preview | Planned | 1.4.0 / [**R140-02**](PRODUCTION_ROADMAP.md#r140-02) · [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | Preview changes without writing icons. |
| E28 | Batch refresh of owned posters | Partial | 1.4.0 / [**R140-03**](PRODUCTION_ROADMAP.md#r140-03) · [#27](https://github.com/AIBeCe/MovieFolderPosters/issues/27) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Run finite batches and explicit queues. |
| E29 | Ignore folder action | Planned | 1.1.0 / [**R110-02**](PRODUCTION_ROADMAP.md#r110-02) · [#11](https://github.com/AIBeCe/MovieFolderPosters/issues/11) | Pause collections and exclude folders reversibly. |
| E30 | Undo the last poster change | Planned | 1.4.0 / [**R140-05**](PRODUCTION_ROADMAP.md#r140-05) · [#29](https://github.com/AIBeCe/MovieFolderPosters/issues/29) | Undo the latest eligible poster change. |
| E31 | Separate operational and global settings | Delivered | Baseline / 1.0 regression | Separate Main/Settings/Log is delivered; retain regression coverage. |
| E32 | Conventional Settings shortcut | Planned | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Complete essential native usability and accessibility. |
| E33 | Helpful empty state | Planned | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Complete essential native usability and accessibility. |
| E34 | Drag collections into the app | Planned | 1.1.0 / [**R110-01**](PRODUCTION_ROADMAP.md#r110-01) · [#10](https://github.com/AIBeCe/MovieFolderPosters/issues/10) | Simplify collection setup and naming. |
| E35 | Friendly collection names | Planned | 1.1.0 / [**R110-01**](PRODUCTION_ROADMAP.md#r110-01) · [#10](https://github.com/AIBeCe/MovieFolderPosters/issues/10) | Simplify collection setup and naming. |
| E36 | Access problems beside collections | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |
| E37 | Contextual corrective actions | Planned | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Complete essential native usability and accessibility. |
| E38 | Explicit credential test | Planned | 1.0.0 / [**R100-06**](PRODUCTION_ROADMAP.md#r100-06) · [#6](https://github.com/AIBeCe/MovieFolderPosters/issues/6) | Make credential setup and replacement understandable. |
| E39 | Credential setup guidance | Planned | 1.0.0 / [**R100-06**](PRODUCTION_ROADMAP.md#r100-06) · [#6](https://github.com/AIBeCe/MovieFolderPosters/issues/6) | Make credential setup and replacement understandable. |
| E40 | Unsaved-edit handling | Conditional | [C01](PRODUCTION_ROADMAP.md#c01) | No deferred settings edits exist; add apply/discard protection when an approved draft-edit flow needs it. |
| E41 | Live style previews | Delivered | Baseline / 1.0 regression | Three selectable poster examples use the production renderer. |
| E42 | Light and dark preview backgrounds | Delivered | Baseline / 1.0 regression | Current app light/dark appearance makes previews inspectable without changing system appearance. |
| E43 | Finder-size previews | Planned | 1.3.0 / [**R130-04**](PRODUCTION_ROADMAP.md#r130-04) · [#24](https://github.com/AIBeCe/MovieFolderPosters/issues/24) | Add style scope and realistic previews. |
| E44 | Collection style overrides | Planned | 1.3.0 / [**R130-04**](PRODUCTION_ROADMAP.md#r130-04) · [#24](https://github.com/AIBeCe/MovieFolderPosters/issues/24) | Add style scope and realistic previews. |
| E45 | Individual folder style overrides | Planned | 1.3.0 / [**R130-04**](PRODUCTION_ROADMAP.md#r130-04) · [#24](https://github.com/AIBeCe/MovieFolderPosters/issues/24) | Add style scope and realistic previews. |
| E46 | Adjustable matte-frame width | Planned | 1.6.0 / [**R160-05**](PRODUCTION_ROADMAP.md#r160-05) · [#39](https://github.com/AIBeCe/MovieFolderPosters/issues/39) | Offer restrained matte-frame customization. |
| E47 | Accessible frame colors | Planned | 1.6.0 / [**R160-05**](PRODUCTION_ROADMAP.md#r160-05) · [#39](https://github.com/AIBeCe/MovieFolderPosters/issues/39) | Offer restrained matte-frame customization. |
| E48 | Alternative poster selection | Planned | 1.3.0 / [**R130-01**](PRODUCTION_ROADMAP.md#r130-01) · [#21](https://github.com/AIBeCe/MovieFolderPosters/issues/21) | Choose provider alternatives or a local poster. |
| E49 | Local poster image | Planned | 1.3.0 / [**R130-01**](PRODUCTION_ROADMAP.md#r130-01) · [#21](https://github.com/AIBeCe/MovieFolderPosters/issues/21) | Choose provider alternatives or a local poster. |
| E50 | Apply appearance explicitly | Planned | 1.3.0 / [**R130-04**](PRODUCTION_ROADMAP.md#r130-04) · [#24](https://github.com/AIBeCe/MovieFolderPosters/issues/24) | Add style scope and realistic previews. |
| E51 | Unmounted versus unauthorized volumes | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| E52 | Read-only collection detection | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| E53 | Filesystem compatibility feedback | Planned | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Verify installation, access, and platform readiness. |
| E54 | Overlapping root detection | Planned | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Verify installation, access, and platform readiness. |
| E55 | Explicit collection exclusions | Merged | 1.1.0 / [**R110-02**](PRODUCTION_ROADMAP.md#r110-02) · [#11](https://github.com/AIBeCe/MovieFolderPosters/issues/11) | Consolidated with E29; no duplicate standalone implementation. Pause collections and exclude folders reversibly. |
| E56 | Temporarily disable a collection | Planned | 1.1.0 / [**R110-02**](PRODUCTION_ROADMAP.md#r110-02) · [#11](https://github.com/AIBeCe/MovieFolderPosters/issues/11) | Pause collections and exclude folders reversibly. |
| E57 | Verified icon ownership status | Partial | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Persist authoritative processing outcomes and collection summaries. |
| E58 | User-replaced icon detection | Partial | 1.0.0 / [**R100-02**](PRODUCTION_ROADMAP.md#r100-02) · [#2](https://github.com/AIBeCe/MovieFolderPosters/issues/2) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Persist authoritative processing outcomes and collection summaries. |
| E59 | Safe rename reconciliation | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| E60 | Obsolete record cleanup review | Planned | 1.5.0 / [**R150-03**](PRODUCTION_ROADMAP.md#r150-03) · [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | Maintain caches and remove app records deliberately. |
| E61 | Visible rate-limit backoff | Partial | 1.0.0 / [**R100-04**](PRODUCTION_ROADMAP.md#r100-04) · [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Make network failure and interruption recovery predictable. |
| E62 | Distinct network failure states | Partial | 1.0.0 / [**R100-04**](PRODUCTION_ROADMAP.md#r100-04) · [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Make network failure and interruption recovery predictable. |
| E63 | Shared rate-limit coordination | Partial | 1.0.0 / [**R100-04**](PRODUCTION_ROADMAP.md#r100-04) · [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Make network failure and interruption recovery predictable. |
| E64 | Resume interrupted processing | Partial | 1.0.0 / [**R100-04**](PRODUCTION_ROADMAP.md#r100-04) · [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Make network failure and interruption recovery predictable. |
| E65 | Cross-collection search deduplication | Planned | 1.8.0 / [**R180-02**](PRODUCTION_ROADMAP.md#r180-02) · [#45](https://github.com/AIBeCe/MovieFolderPosters/issues/45) | Measure and improve cache reuse across collections. |
| E66 | Bounded search pagination | Planned | 1.2.0 / [**R120-03**](PRODUCTION_ROADMAP.md#r120-03) · [#17](https://github.com/AIBeCe/MovieFolderPosters/issues/17) | Search additional pages within a finite budget. |
| E67 | Cancel collection processing | Partial | 1.0.0 / [**R100-05**](PRODUCTION_ROADMAP.md#r100-05) · [#5](https://github.com/AIBeCe/MovieFolderPosters/issues/5) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Resolve and retry specific failed folders. |
| E68 | Cache size visibility | Planned | 1.1.0 / [**R110-05**](PRODUCTION_ROADMAP.md#r110-05) · [#14](https://github.com/AIBeCe/MovieFolderPosters/issues/14) | Explain local data and produce focused support exports. |
| E69 | Selective cache cleanup | Planned | 1.5.0 / [**R150-03**](PRODUCTION_ROADMAP.md#r150-03) · [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | Maintain caches and remove app records deliberately. |
| E70 | Cached poster integrity checks | Partial | 1.0.0 / [**R100-08**](PRODUCTION_ROADMAP.md#r100-08) · [#8](https://github.com/AIBeCe/MovieFolderPosters/issues/8) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Handle corrupt cached artwork safely. |
| E71 | VoiceOver support | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |
| E72 | Complete keyboard navigation | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |
| E73 | Text with status symbols | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |
| E74 | Accessibility appearance verification | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |
| E75 | Polished application icon | Planned | 1.0.0 / [**R100-09**](PRODUCTION_ROADMAP.md#r100-09) · [#9](https://github.com/AIBeCe/MovieFolderPosters/issues/9) | Qualify and distribute the first production release. |
| E76 | Finder extension onboarding | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| E77 | Not-updating diagnostic checklist | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| E78 | Privacy-conscious diagnostic export | Planned | 1.0.0 / [**R100-09**](PRODUCTION_ROADMAP.md#r100-09) · [#9](https://github.com/AIBeCe/MovieFolderPosters/issues/9) | Qualify and distribute the first production release. |
| E79 | Signed and notarized installer | Partial | 1.0.0 / [**R100-09**](PRODUCTION_ROADMAP.md#r100-09) · [#9](https://github.com/AIBeCe/MovieFolderPosters/issues/9) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Qualify and distribute the first production release. |
| E80 | Window lifecycle regressions | Partial | 1.0.0 / [**R100-07**](PRODUCTION_ROADMAP.md#r100-07) · [#7](https://github.com/AIBeCe/MovieFolderPosters/issues/7) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Complete essential native usability and accessibility. |

## New features

Source: [NEW_FEATURE_IDEAS.md](NEW_FEATURE_IDEAS.md).

| ID | Original idea | Decision | Target / deliverable | Interpretation and consolidation |
| --- | --- | --- | --- | --- |
| N1 | Named processing profiles | Planned | 1.6.0 / [**R160-01**](PRODUCTION_ROADMAP.md#r160-01) · [#35](https://github.com/AIBeCe/MovieFolderPosters/issues/35) | Introduce small reusable processing profiles. |
| N2 | Collection policy templates | Planned | 1.6.0 / [**R160-01**](PRODUCTION_ROADMAP.md#r160-01) · [#35](https://github.com/AIBeCe/MovieFolderPosters/issues/35) | Introduce small reusable processing profiles. |
| N3 | Profile inheritance | Planned | 1.6.0 / [**R160-01**](PRODUCTION_ROADMAP.md#r160-01) · [#35](https://github.com/AIBeCe/MovieFolderPosters/issues/35) | Introduce small reusable processing profiles. |
| N4 | Configuration import and export | Planned | 1.5.0 / [**R150-01**](PRODUCTION_ROADMAP.md#r150-01) · [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | Export portable configuration and confirmed decisions. |
| N5 | Portable path mapping | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N6 | Clone collection policies | Planned | 1.6.0 / [**R160-01**](PRODUCTION_ROADMAP.md#r160-01) · [#35](https://github.com/AIBeCe/MovieFolderPosters/issues/35) | Introduce small reusable processing profiles. |
| N7 | Collection groups | Planned | 1.6.0 / [**R160-02**](PRODUCTION_ROADMAP.md#r160-02) · [#36](https://github.com/AIBeCe/MovieFolderPosters/issues/36) | Group collections for bounded operations. |
| N8 | Policy version snapshots | Planned | 1.6.0 / [**R160-03**](PRODUCTION_ROADMAP.md#r160-03) · [#37](https://github.com/AIBeCe/MovieFolderPosters/issues/37) | Retain bounded policy versions. |
| N9 | Configuration comparison | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N10 | Collection onboarding presets | Planned | 1.1.0 / [**R110-01**](PRODUCTION_ROADMAP.md#r110-01) · [#10](https://github.com/AIBeCe/MovieFolderPosters/issues/10) | Simplify collection setup and naming. |
| N11 | Read-only NFO identification | Planned | 1.2.0 / [**R120-04**](PRODUCTION_ROADMAP.md#r120-04) · [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | Use explicit identifiers and opt-in local evidence. |
| N12 | IMDb identifier resolution | Planned | 1.2.0 / [**R120-04**](PRODUCTION_ROADMAP.md#r120-04) · [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | Use explicit identifiers and opt-in local evidence. |
| N13 | Movie filename evidence | Planned | 1.2.0 / [**R120-04**](PRODUCTION_ROADMAP.md#r120-04) · [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | Use explicit identifiers and opt-in local evidence. |
| N14 | Movie-name manifest | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N15 | CSV match import | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N16 | Personal release-name dictionaries | Planned | 1.6.0 / [**R160-04**](PRODUCTION_ROADMAP.md#r160-04) · [#38](https://github.com/AIBeCe/MovieFolderPosters/issues/38) | Add constrained name-expansion dictionaries. |
| N17 | Custom parser rule sets | Research | 2.0 candidates / [**X200-06**](PRODUCTION_ROADMAP.md#x200-06) · [#52](https://github.com/AIBeCe/MovieFolderPosters/issues/52) | Separate feasibility/design approval; may be rejected with evidence. Research constrained custom parser rules. |
| N18 | Cross-provider identity verification | Research | 2.0 candidates / [**X200-01**](PRODUCTION_ROADMAP.md#x200-01) · [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | Separate feasibility/design approval; may be rejected with evidence. Research additional metadata providers and credentials. |
| N19 | Identification evidence hierarchy | Planned | 1.2.0 / [**R120-04**](PRODUCTION_ROADMAP.md#r120-04) · [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18) | Use explicit identifiers and opt-in local evidence. |
| N20 | Edition-specific identity records | Research | 2.0 candidates / [**X200-02**](PRODUCTION_ROADMAP.md#x200-02) · [#48](https://github.com/AIBeCe/MovieFolderPosters/issues/48) | Separate feasibility/design approval; may be rejected with evidence. Research edition-specific identity. |
| N21 | Automatic local artwork discovery | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N22 | Artwork language preference | Planned | 1.3.0 / [**R130-03**](PRODUCTION_ROADMAP.md#r130-03) · [#23](https://github.com/AIBeCe/MovieFolderPosters/issues/23) | Select artwork by language and quality. |
| N23 | Textless artwork policy | Planned | 1.3.0 / [**R130-03**](PRODUCTION_ROADMAP.md#r130-03) · [#23](https://github.com/AIBeCe/MovieFolderPosters/issues/23) | Select artwork by language and quality. |
| N24 | Minimum artwork resolution | Planned | 1.3.0 / [**R130-03**](PRODUCTION_ROADMAP.md#r130-03) · [#23](https://github.com/AIBeCe/MovieFolderPosters/issues/23) | Select artwork by language and quality. |
| N25 | Artwork source priority | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N26 | Remote artwork URL import | Research | 2.0 candidates / [**X200-08**](PRODUCTION_ROADMAP.md#x200-08) · [#54](https://github.com/AIBeCe/MovieFolderPosters/issues/54) | Separate feasibility/design approval; may be rejected with evidence. Research explicit remote artwork URL import. |
| N27 | Artwork mapping manifest | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N28 | Approved artwork packs | Planned | 1.7.0 / [**R170-03**](PRODUCTION_ROADMAP.md#r170-03) · [#42](https://github.com/AIBeCe/MovieFolderPosters/issues/42) | Apply reviewed local artwork packs. |
| N29 | Artwork license records | Planned | 1.3.0 / [**R130-01**](PRODUCTION_ROADMAP.md#r130-01) · [#21](https://github.com/AIBeCe/MovieFolderPosters/issues/21) | Choose provider alternatives or a local poster. |
| N30 | Collection artwork fallback | Research | 1.7.0 / [**R170-04**](PRODUCTION_ROADMAP.md#r170-04) · [#43](https://github.com/AIBeCe/MovieFolderPosters/issues/43) | Separate feasibility/design approval; may be rejected with evidence. Evaluate a clearly non-movie fallback image. |
| N31 | Finder inspection command | Planned | 1.1.0 / [**R110-04**](PRODUCTION_ROADMAP.md#r110-04) · [#13](https://github.com/AIBeCe/MovieFolderPosters/issues/13) | Connect results with focused Finder utilities. |
| N32 | Copy confirmed movie title | Planned | 1.1.0 / [**R110-04**](PRODUCTION_ROADMAP.md#r110-04) · [#13](https://github.com/AIBeCe/MovieFolderPosters/issues/13) | Connect results with focused Finder utilities. |
| N33 | Copy movie identifier | Planned | 1.1.0 / [**R110-04**](PRODUCTION_ROADMAP.md#r110-04) · [#13](https://github.com/AIBeCe/MovieFolderPosters/issues/13) | Connect results with focused Finder utilities. |
| N34 | Reveal unresolved folders | Planned | 1.1.0 / [**R110-04**](PRODUCTION_ROADMAP.md#r110-04) · [#13](https://github.com/AIBeCe/MovieFolderPosters/issues/13) | Connect results with focused Finder utilities. |
| N35 | Finder toolbar processing action | Planned | 1.7.0 / [**R170-01**](PRODUCTION_ROADMAP.md#r170-01) · [#40](https://github.com/AIBeCe/MovieFolderPosters/issues/40) | Add native navigation and Finder entry points. |
| N36 | Add collection through macOS Services | Planned | 1.7.0 / [**R170-01**](PRODUCTION_ROADMAP.md#r170-01) · [#40](https://github.com/AIBeCe/MovieFolderPosters/issues/40) | Add native navigation and Finder entry points. |
| N37 | Shortcuts processing action | Planned | 1.7.0 / [**R170-02**](PRODUCTION_ROADMAP.md#r170-02) · [#41](https://github.com/AIBeCe/MovieFolderPosters/issues/41) | Expose bounded Shortcuts operations and status. |
| N38 | Shortcuts status query | Planned | 1.7.0 / [**R170-02**](PRODUCTION_ROADMAP.md#r170-02) · [#41](https://github.com/AIBeCe/MovieFolderPosters/issues/41) | Expose bounded Shortcuts operations and status. |
| N39 | Quick Action for supplied artwork | Planned | 1.7.0 / [**R170-01**](PRODUCTION_ROADMAP.md#r170-01) · [#40](https://github.com/AIBeCe/MovieFolderPosters/issues/40) | Add native navigation and Finder entry points. |
| N40 | Validated app deep links | Planned | 1.7.0 / [**R170-01**](PRODUCTION_ROADMAP.md#r170-01) · [#40](https://github.com/AIBeCe/MovieFolderPosters/issues/40) | Add native navigation and Finder entry points. |
| N41 | Dry-run processing plans | Planned | 1.4.0 / [**R140-02**](PRODUCTION_ROADMAP.md#r140-02) · [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | Preview changes without writing icons. |
| N42 | Metadata-only preparation | Merged | 1.4.0 / [**R140-02**](PRODUCTION_ROADMAP.md#r140-02) · [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | Consolidated with N41; no duplicate standalone implementation. Preview changes without writing icons. |
| N43 | Apply a saved processing plan | Planned | 1.4.0 / [**R140-04**](PRODUCTION_ROADMAP.md#r140-04) · [#28](https://github.com/AIBeCe/MovieFolderPosters/issues/28) | Apply reviewed plans and deferred approvals safely. |
| N44 | Approval inbox | Planned | 1.4.0 / [**R140-04**](PRODUCTION_ROADMAP.md#r140-04) · [#28](https://github.com/AIBeCe/MovieFolderPosters/issues/28) | Apply reviewed plans and deferred approvals safely. |
| N45 | Side-by-side icon change review | Planned | 1.4.0 / [**R140-02**](PRODUCTION_ROADMAP.md#r140-02) · [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | Preview changes without writing icons. |
| N46 | Per-operation change receipts | Planned | 1.4.0 / [**R140-01**](PRODUCTION_ROADMAP.md#r140-01) · [#25](https://github.com/AIBeCe/MovieFolderPosters/issues/25) | Record exact mutation receipts and session summaries. |
| N47 | Deferred selected assignments | Planned | 1.4.0 / [**R140-04**](PRODUCTION_ROADMAP.md#r140-04) · [#28](https://github.com/AIBeCe/MovieFolderPosters/issues/28) | Apply reviewed plans and deferred approvals safely. |
| N48 | User-invoked operation queue | Planned | 1.4.0 / [**R140-03**](PRODUCTION_ROADMAP.md#r140-03) · [#27](https://github.com/AIBeCe/MovieFolderPosters/issues/27) | Run finite batches and explicit queues. |
| N49 | Maintenance session summary | Planned | 1.4.0 / [**R140-01**](PRODUCTION_ROADMAP.md#r140-01) · [#25](https://github.com/AIBeCe/MovieFolderPosters/issues/25) | Record exact mutation receipts and session summaries. |
| N50 | Assignment approval expiry | Planned | 1.4.0 / [**R140-04**](PRODUCTION_ROADMAP.md#r140-04) · [#28](https://github.com/AIBeCe/MovieFolderPosters/issues/28) | Apply reviewed plans and deferred approvals safely. |
| N51 | Offline-only collection mode | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N52 | Per-collection network permission | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N53 | Identification-data preview | Planned | 1.0.0 / [**R100-06**](PRODUCTION_ROADMAP.md#r100-06) · [#6](https://github.com/AIBeCe/MovieFolderPosters/issues/6) | Make credential setup and replacement understandable. |
| N54 | Local data inspector | Planned | 1.1.0 / [**R110-05**](PRODUCTION_ROADMAP.md#r110-05) · [#14](https://github.com/AIBeCe/MovieFolderPosters/issues/14) | Explain local data and produce focused support exports. |
| N55 | Collection data deletion | Planned | 1.5.0 / [**R150-03**](PRODUCTION_ROADMAP.md#r150-03) · [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | Maintain caches and remove app records deliberately. |
| N56 | Credential profiles | Research | 2.0 candidates / [**X200-01**](PRODUCTION_ROADMAP.md#x200-01) · [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | Separate feasibility/design approval; may be rejected with evidence. Research additional metadata providers and credentials. |
| N57 | Credential replacement workflow | Partial | 1.0.0 / [**R100-06**](PRODUCTION_ROADMAP.md#r100-06) · [#6](https://github.com/AIBeCe/MovieFolderPosters/issues/6) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Make credential setup and replacement understandable. |
| N58 | Network activity ledger | Planned | 1.1.0 / [**R110-03**](PRODUCTION_ROADMAP.md#r110-03) · [#12](https://github.com/AIBeCe/MovieFolderPosters/issues/12) | Improve result and Log filtering with private history. |
| N59 | Strict privacy preset | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N60 | Private collection mode | Planned | 1.1.0 / [**R110-03**](PRODUCTION_ROADMAP.md#r110-03) · [#12](https://github.com/AIBeCe/MovieFolderPosters/issues/12) | Improve result and Log filtering with private history. |
| N61 | Confirmed-match backup | Planned | 1.5.0 / [**R150-01**](PRODUCTION_ROADMAP.md#r150-01) · [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | Export portable configuration and confirmed decisions. |
| N62 | Local artwork choice backup | Planned | 1.5.0 / [**R150-01**](PRODUCTION_ROADMAP.md#r150-01) · [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | Export portable configuration and confirmed decisions. |
| N63 | Verified backup restoration | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N64 | Backup validation utility | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N65 | Cross-Mac decision transfer | Merged | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Consolidated with N63; no duplicate standalone implementation. Review imports, mappings, and root relocation. |
| N66 | Collection relocation assistant | Planned | 1.5.0 / [**R150-02**](PRODUCTION_ROADMAP.md#r150-02) · [#31](https://github.com/AIBeCe/MovieFolderPosters/issues/31) | Review imports, mappings, and root relocation. |
| N67 | Collection comparison report | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N68 | Read-only media-tool manifest import | Research | 2.0 candidates / [**X200-07**](PRODUCTION_ROADMAP.md#x200-07) · [#53](https://github.com/AIBeCe/MovieFolderPosters/issues/53) | Separate feasibility/design approval; may be rejected with evidence. Research specific read-only media-tool import formats. |
| N69 | Interoperable confirmed-match export | Planned | 1.5.0 / [**R150-01**](PRODUCTION_ROADMAP.md#r150-01) · [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | Export portable configuration and confirmed decisions. |
| N70 | Portable poster source bundle | Planned | 1.5.0 / [**R150-01**](PRODUCTION_ROADMAP.md#r150-01) · [#30](https://github.com/AIBeCe/MovieFolderPosters/issues/30) | Export portable configuration and confirmed decisions. |
| N71 | Local-artwork-only installation mode | Planned | 1.3.0 / [**R130-02**](PRODUCTION_ROADMAP.md#r130-02) · [#22](https://github.com/AIBeCe/MovieFolderPosters/issues/22) | Support local-artwork and offline collection workflows. |
| N72 | User-invoked command-line interface | Research | 2.0 candidates / [**X200-03**](PRODUCTION_ROADMAP.md#x200-03) · [#49](https://github.com/AIBeCe/MovieFolderPosters/issues/49) | Separate feasibility/design approval; may be rejected with evidence. Research a finite command-line interface. |
| N73 | Command-line dry-run reports | Research | 2.0 candidates / [**X200-03**](PRODUCTION_ROADMAP.md#x200-03) · [#49](https://github.com/AIBeCe/MovieFolderPosters/issues/49) | Separate feasibility/design approval; may be rejected with evidence. Research a finite command-line interface. |
| N74 | Secondary metadata provider | Research | 2.0 candidates / [**X200-01**](PRODUCTION_ROADMAP.md#x200-01) · [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | Separate feasibility/design approval; may be rejected with evidence. Research additional metadata providers and credentials. |
| N75 | Provider health comparison | Research | 2.0 candidates / [**X200-01**](PRODUCTION_ROADMAP.md#x200-01) · [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | Separate feasibility/design approval; may be rejected with evidence. Research additional metadata providers and credentials. |
| N76 | Provider-specific capabilities view | Research | 2.0 candidates / [**X200-01**](PRODUCTION_ROADMAP.md#x200-01) · [#47](https://github.com/AIBeCe/MovieFolderPosters/issues/47) | Separate feasibility/design approval; may be rejected with evidence. Research additional metadata providers and credentials. |
| N77 | Search-language profiles | Planned | 1.2.0 / [**R120-01**](PRODUCTION_ROADMAP.md#r120-01) · [#15](https://github.com/AIBeCe/MovieFolderPosters/issues/15) | Add verified aliases and language preferences. |
| N78 | Read-only integration API | Research | 2.0 candidates / [**X200-04**](PRODUCTION_ROADMAP.md#x200-04) · [#50](https://github.com/AIBeCe/MovieFolderPosters/issues/50) | Separate feasibility/design approval; may be rejected with evidence. Research a narrow read-only integration API. |
| N79 | Reusable service examples | Supporting | 1.5.0 / [**R150-05**](PRODUCTION_ROADMAP.md#r150-05) · [#34](https://github.com/AIBeCe/MovieFolderPosters/issues/34) | Optional service-consumer examples; not an app feature or release gate. |
| N80 | Opt-in nested collection roots | Research | 2.0 candidates / [**X200-05**](PRODUCTION_ROADMAP.md#x200-05) · [#51](https://github.com/AIBeCe/MovieFolderPosters/issues/51) | Separate feasibility/design approval; may be rejected with evidence. Research explicitly bounded nested roots. |
| N81 | Identification source breakdown | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N82 | Rejection pattern report | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N83 | Decision correction history | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N84 | Provider evidence age view | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N85 | Cache effectiveness report | Planned | 1.8.0 / [**R180-02**](PRODUCTION_ROADMAP.md#r180-02) · [#45](https://github.com/AIBeCe/MovieFolderPosters/issues/45) | Measure and improve cache reuse across collections. |
| N86 | Operation resource estimates | Planned | 1.4.0 / [**R140-02**](PRODUCTION_ROADMAP.md#r140-02) · [#26](https://github.com/AIBeCe/MovieFolderPosters/issues/26) | Preview changes without writing icons. |
| N87 | Processed collection snapshot | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N88 | Ownership coverage report | Planned | 1.8.0 / [**R180-01**](PRODUCTION_ROADMAP.md#r180-01) · [#44](https://github.com/AIBeCe/MovieFolderPosters/issues/44) | Report outcome patterns without becoming a library. |
| N89 | Matching policy impact comparison | Planned | 1.8.0 / [**R180-03**](PRODUCTION_ROADMAP.md#r180-03) · [#46](https://github.com/AIBeCe/MovieFolderPosters/issues/46) | Compare policies using stored evidence. |
| N90 | Support-session diagnostic package | Planned | 1.1.0 / [**R110-05**](PRODUCTION_ROADMAP.md#r110-05) · [#14](https://github.com/AIBeCe/MovieFolderPosters/issues/14) | Explain local data and produce focused support exports. |
| N91 | Installation readiness check | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| N92 | Extension registration diagnostics | Planned | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Verify installation, access, and platform readiness. |
| N93 | App-extension version display | Planned | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Verify installation, access, and platform readiness. |
| N94 | Shared-storage health check | Partial | 1.0.0 / [**R100-01**](PRODUCTION_ROADMAP.md#r100-01) · [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1) | Existing mechanisms or UI are partial; complete the specific intent and verify it. Verify installation, access, and platform readiness. |
| N95 | Configuration recovery assistant | Planned | 1.5.0 / [**R150-04**](PRODUCTION_ROADMAP.md#r150-04) · [#33](https://github.com/AIBeCe/MovieFolderPosters/issues/33) | Recover configuration and evolve stored data safely. |
| N96 | Schema migration preview | Planned | 1.5.0 / [**R150-04**](PRODUCTION_ROADMAP.md#r150-04) · [#33](https://github.com/AIBeCe/MovieFolderPosters/issues/33) | Recover configuration and evolve stored data safely. |
| N97 | Pre-upgrade recovery snapshot | Planned | 1.5.0 / [**R150-04**](PRODUCTION_ROADMAP.md#r150-04) · [#33](https://github.com/AIBeCe/MovieFolderPosters/issues/33) | Recover configuration and evolve stored data safely. |
| N98 | Safe-mode launch | Planned | 1.0.0 / [**R100-04**](PRODUCTION_ROADMAP.md#r100-04) · [#4](https://github.com/AIBeCe/MovieFolderPosters/issues/4) | Make network failure and interruption recovery predictable. |
| N99 | Pre-uninstall export assistant | Planned | 1.5.0 / [**R150-03**](PRODUCTION_ROADMAP.md#r150-03) · [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | Maintain caches and remove app records deliberately. |
| N100 | Poster metadata cleanup tool | Planned | 1.5.0 / [**R150-03**](PRODUCTION_ROADMAP.md#r150-03) · [#32](https://github.com/AIBeCe/MovieFolderPosters/issues/32) | Maintain caches and remove app records deliberately. |

## Consolidation decisions worth preserving

- E29 and E55 use one reversible child-exclusion policy; removal suppression remains a different safety concept.
- E27, N41, N42, and N45 use one dry-run/review pipeline. Metadata-only preparation is a bounded mode of that
  pipeline, not another processing service. Saved plan application remains a later validation step.
- E15, E22, E23, and E26 share candidate evidence and correction UI while keeping their distinct acceptance cases.
- N1, N2, N3, and N6 share reusable policy data, effective-value presentation, and copy semantics; no four engines.
- N4/N61/N62/N69/N70 and N5/N9/N14/N15/N27/N63/N64/N65/N66 share neutral export/import contracts; CSV and manifests
  are validated adapters. Cross-Mac transfer is restore plus fresh mapping/authorization, not permission transfer.
- N72 and N73 are one conditional CLI product proposal including dry-run output; neither bypasses normal safeguards.
- N18/N56/N74/N75/N76 are one multi-provider investigation; keep credentials and provider identity boundaries explicit.
- Raw/Soft/Matte and System/Light/Dark already exist. E43/E44/E45 and E46/E47 extend those features in later releases;
  they do not justify reimplementing the accepted Settings design or reinstating G0–G3 themes.

Each source idea's meaning remains available in its original catalogue. Removing a duplicate task never silently
removes a meaningful behavior or test case. Planning targets may move only with an explicit recorded decision.
