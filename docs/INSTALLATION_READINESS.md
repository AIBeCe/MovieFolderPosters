# Installation and access readiness — R100-01

Issue: [#1](https://github.com/AIBeCe/MovieFolderPosters/issues/1).
Implementation authorized as a whole on 2026-10-16. **Completed on 2026-10-17:** issue #1 is closed; the verified
feature was fast-forwarded into local `develop` at `55ba0a6`, and `feature/installation-readiness` was deleted.
Final verification passed 236 tests and independent review. Signed Debug/Release builds and controlled native checks
passed. No push or release was performed. See [Native qualification](NATIVE_READINESS_QUALIFICATION.md) for the
recorded checks and remaining physical-device, reboot, filesystem, and clean production-install limits.

## Design and implementation

Keep programmatic AppKit/MVVM-C and the existing Network, FileSystem, Persistence service boundaries.
FileSystem owns read-only root inspection. Shared application configuration owns overlap and identity policy.
The host presents explicit installation checks in a scrollable sheet attached to Main. Finder records dated
activation evidence on configuration load; enablement and receipts do not prove a process is currently running.

- [x] Read-only FileSystem inspection: bounded directory descriptors, access/write preflight, filesystem metadata
  capability, and stable-identity validation of resolved bookmarks; no collection enumeration during access checks.
- [x] Optional root identity/volume evidence decodes old configuration without inventing historical identity.
  Reject new overlaps; explain legacy overlaps and block their automatic/manual processing.
- [x] Reconcile a bookmark-resolved rename only with matching saved root identity. Preserve collection UUID and
  authorization version; refresh host/transfer bookmarks. A legacy root without saved identity needs Locate Folder
  if its resolved path changes. Replacement at the same path cannot inherit authorization by path alone.
- [x] Recheck root identity at processing entry and immediately before assignment/restyling. Hold a settings lease
  across automatic/manual mutation after checking live overlaps, authorization version, identity, and policy.
- [x] Explicit installation checks: embedded component versions, enablement, dated observed activation, shared-storage
  integrity/read/write probe, and native extension-settings guidance. Signing checks use public Security APIs with strict static validation.
- [x] Complete final signed builds and focused/regression verification; record native limits below.
- [x] Final independent review PASS: I1–I5 resolved; no open Critical or Important findings.
  Review covers implementation correctness, not unperformed native qualification or issue closure.

Check Installation never refreshes roots, notifies processing, or writes movie/custom-icon metadata. It writes only
one fixed-key app-owned shared-storage probe. Refresh Status is a separate explicit operation that can renew
configuration/bookmarks and resume Finder processing. Finder activation updates one fixed-key receipt on reload.
No watcher, timer, polling, daemon, new package, or third-party dependency is added.

Root identity uses volume UUID, inode, and birth time. Device numbers remain useful for checking a descriptor against
its current path, but are excluded from persisted root identity because mount device numbers can change. Existing
child snapshot identities retain their earlier contract. Filesystems without volume UUID evidence retain unknown
readiness and can be configured for diagnostics; automatic/manual writes fail closed when identity cannot be verified.
Actual detach/reconnect and reboot behavior of the durable format remains a native qualification requirement.

## User workflow

1. Choose **Check Installation…** in Main. The explicit check displays last-loaded setup (labeled potentially stale),
   component versions, signing evidence, extension enablement, dated activation, and shared-storage results.
2. Use **Open Extension Settings** if needed. This opens Apple's management interface; it does not grant folder access,
   select an installed development copy, or prove a Finder process activated the extension.
3. Add a collection with the folder picker. If access is missing/stale/denied, use **Locate Folder…**. Roots must be
   separate; a collection cannot contain another collection or refer to the same saved root identity.
4. Check collection row text for missing/disconnected/read-only/unsupported/unknown/replaced/overlapping conditions.
   Refresh Status retries on demand; reconnecting a volume does not schedule a background retry.
5. Configure a TMDb read access token in Settings. Presence is reported without reading it into the UI; this check
   does not validate the provider account or make network requests.
6. Close all Finder views of the collection and reopen it. Duplicate windows need not generate another observation.
   Finder navigation is the processing trigger, not a continuous filesystem-change monitor.

A passed host access preflight is not an actual poster-write test or proof that the Finder process has authorization.
APFS/HFS plus readable metadata and write preflight is qualified as preflight evidence only. Other filesystems remain
unknown unless an actual unsupported metadata operation establishes incompatibility. Scope/permission/identity checks
remain required at actual mutations. Rows expose explanations as text and accessibility labels, with tooltips for
truncated text; color is supplemental.

## Extension copies and not-updating checklist

The host uses public FinderSync enablement APIs and inspects its embedded extension. There is no public registration
inventory API used by this app; the report explicitly labels registration unknown. A receipt contains the last
observed extension version/build and timestamp; stale/future dates and build mismatch are independent conditions.
Matching versions are never presented as proof of current execution or of a unique registered copy.

For development diagnosis, a finite read-only command can inspect registered copies:

```sh
rtk proxy pluginkit -m -A -D -i dag.fikios.MovieFolderPosters.Finder
```

On 2026-10-16 the development Mac returned multiple registered copies. This establishes registration evidence only;
it does not prove which copy handles a particular Finder window. The application reports unknown rather than using
private APIs, spawning a shell from the sandbox, or registering/unregistering copies itself. App and extension build
numbers advance together to 2 in this implementation so an older build-1 receipt can be distinguished.

If posters do not update: check signing/enablement and versions; Refresh Status; repair the requested collection
access; confirm token presence; reconnect unavailable media; remove an overlapping collection; then close/reopen
Finder views. Keep foreign icons preserved. Unknown filesystem support requires a controlled native check before
claiming compatibility. Shared-storage errors are sanitized and do not reset settings or reveal user paths/tokens.

## Installation/access matrix

| Scenario | Required behavior | Evidence / remaining qualification |
| --- | --- | --- |
| Fresh setup | Explain roots/token and enablement; show component checks | Controlled report/configuration tests; clean-install native check unperformed |
| Missing/stale access | Preserve root and offer Locate Folder | Configuration tests; current signed sandbox handoff/restart check unperformed |
| Unplugged known volume | Report disconnected from saved volume evidence; retain settings | Absence classification and stale-bookmark regression pass; physical removal unperformed |
| Missing folder | Distinguish missing path from known disconnected volume | Real temporary-directory and host tests pass |
| Read-only storage | Explain write limitation without attempting writes | Real 0555 directory test passes; read-only mounted-volume check unperformed |
| Denied access | Explain repair; never claim volume disconnection without evidence | Real 000 directory test passes; signed sandbox denial check unperformed |
| Unsupported metadata | Report observed unsupported operation without blanket claims | Implementation inspected; incompatible filesystem fixture unperformed |
| Unknown compatibility | Preserve uncertainty, especially missing stable volume identity | Fail-closed source review; non-APFS/HFS native fixture unperformed |
| Overlapping roots | Reject new overlap; block legacy/live overlaps | Policy/configuration tests and overlap-during-manual-search regression pass |
| Replaced directory | Reject identity mismatch despite identical path | Real replacement tests; automatic root-swap test preserves child identity and assigns nothing |
| Renamed directory | Reconcile only matching saved stable identity | Actual temporary-directory rename/bookmark test passes; signed sandbox repair unperformed |
| Component mismatch | Show embedded and observed versions independently of receipt age | Controlled recent/stale/mismatched/missing metadata tests pass |
| Shared storage failure/contention | Show failure/unknown and preserve configuration | Real temporary Persistence roundtrip/contention/corruption tests pass |
| Enabled without observation | Separate enablement from observed activation | Controlled report tests pass; live settings-to-Finder activation check unperformed |
| Old/future observation | Show dated evidence without a current-running claim | Controlled stale/future-date tests pass |
| Reconnect/reboot | Preserve/revalidate authorization and stable identity | Physical reconnect and reboot unperformed; no durability qualification claimed |

## Verification

Focused results recorded on 2026-10-16:

- FileSystem: 55 tests, including actual denied/read-only directory permissions, rename, replacement, descriptor
  identity checks, and unchanged movie bytes during inspection.
- Configuration: 30 tests, including optional-field compatibility, contention, renamed root, missing/disconnected
  evidence, overlap detection, and mutation-lease rejection when another root moves inside an unchanged target.
- AppKit configuration UI: 19 tests, including visible/accessibility explanations and a diagnostic pipeline that makes no configuration-service calls.
- Installation diagnostics: 16 tests pass, including actual temporary-store health checks, metadata/version mismatch,
  stale/future receipts, signature valid/invalid/unknown evidence, and safe unknown/error states.
- Processing/manual actions: 42 XCTest cases pass, including root replacement during provider suspension and a new
  overlapping root during manual search. Network 21, Persistence 8, parser 7, matching 19, poster-request 2, and
  poster-action UI 5 regression tests pass. Scale probe completed with 500 unchanged folders in about 0.078 seconds;
  timings are local observations, not performance guarantees.
- Final-tree signed Debug build-for-testing and Release build passed; strict deep signature verification passed
  for both complete app bundles. Host and embedded extension Info.plist values were read back: version 1.0, build 2
  in both configurations. Xcode test targets compiled; this is not XCUITest execution. The only build warnings were
  skipped App Intents metadata extraction because the app does not depend on AppIntents.
- XCUITest execution, live installation sheet/VoiceOver inspection, actual external-volume filesystems, fresh install,
  current sandbox handoff, and reboot remain unperformed. Unit/harness results do not establish those behaviors.

The contention and stale/disconnected regressions were observed failing before their fixes. Initial installation
formatter tests were added after implementation; later storage and reporting regressions were checked before fixes.
Standalone configuration tests inject ordinary bookmark creation/acquisition to exercise real rename/persistence
behavior without the unavailable ScopedBookmarksAgent; they do not prove signed security-scoped authorization.

No real collection contents or custom icons were changed for this work. Tests use isolated temporary fixtures.
At the original 2026-10-16 checkpoint, feature integration and issue closure were held for approval and qualification.
The user subsequently approved completion on 2026-10-17; the current completion state is recorded above. This record
must not be used as complete production release qualification.

## Native follow-up on 2026-10-17

See [Native installation and access checks](NATIVE_READINESS_QUALIFICATION.md) for the later evidence. Live installation
report/accessibility inspection, native extension-settings navigation, APFS/HFS+ image access/rename/replacement,
read-only mounting, image disconnection/remount identity, and isolated signed bookmark handoff/process restart passed.
The earlier matrix and automated counts above are the original 2026-10-16 record; their "unperformed" entries should
be read with this follow-up rather than overwritten as if those observations had existed earlier.

Reboot is optional durability qualification and is deferred at the user's request. Physical media and incompatible
filesystems, a clean production installation, actual Finder-process authorization repair, and VoiceOver speech remain
unqualified. The OS denied exFAT test-image creation; no exFAT compatibility claim is made. The user approved completion after verification on 2026-10-17; the feature was integrated into local `develop`
at `55ba0a6`, its branch was deleted, and issue #1 was closed. Publication remains unperformed.
