# Local Data and local exports

Open **Local Data** with the internaldrive icon immediately to the right of Log in Main. Repeated clicks bring
its existing window forward. Settings contains configuration choices only.

Refresh reads metadata in known app-owned locations: cached posters, all processing revisions, collection results
and legacy Outcomes, settings, Activity and Network history, recovery/coordination, migration backups and host
authorization. The report includes logical byte estimates, regular-file counts, completeness and capture times.
These are not allocated or reclaimable bytes, movie counts or decision counts. Missing, partial and unavailable
storage remain distinguishable. Inspection does not read payloads, create stores, repair or remove anything.
Movie content, Finder icons, Keychain and extension-private authorization are excluded.

Export Selected Local Data opens a finite selection and exact JSON preview flow. Activity defaults on and Network
off, the initial range is the previous 24 hours, and no entries start selected. Select entries explicitly and choose
whether to include installation checks and storage estimates. Current retained history limits apply; absent private
history cannot be reconstructed, and HTTP results do not imply product success or complete operation correlation.

The versioned UTF-8 JSON is limited to 2 MiB and contains only allowlisted fields. Paths, names, movie identifiers,
bookmarks, grants, credentials, raw errors and request details are excluded. Review frozen bytes before saving
through NSSavePanel. Relevant changes to selection, retained evidence or privacy invalidate the preview. Export
writes locally and sends nothing to third parties. Temporary writes run away from UI callbacks; the final atomic
publication is serialized with closure/cancellation. Cleanup is best effort. Closing an unrelated window preserves
Local Data exports; closing the owning window revokes its work.

## Architecture and validation

FileSystem owns the instance-based DirectoryStorage inspector and bounded descriptor-relative traversal.
MovieFolderCommon owns LocalStorageReport and category summaries. The host LocalData feature owns read services,
selection, preview, window routing and file writing. No packages, schema migrations, background watchers or
persistent export sessions were introduced. Mutation receipts remain deferred to R140-01.

Integrated into develop after implementation b91da2a and validation f80420b. Final scoped checks passed: 31 host,
8 FileSystem and 2 Common tests; SwiftLint zero violations across 21 issue files; Swift style and independent
review PASS; final unsigned Debug host/Finder build passed. DocC accuracy review covered 13 affected host files,
not all app documentation or generated DocC compilation.

Native rendered Light/Dark/resizing, keyboard/VoiceOver, real save-panel/security-scoped access and filesystem
platform qualification remain unperformed. This delivery does not establish release qualification or publication.
Two unintended broad test invocations are recorded in the implementation plan; out-of-scope failures have no
established baseline classification. See [implementation and validation record](R110-05_IMPLEMENTATION_PLAN.md).
