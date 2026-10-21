# MovieFolderParsing

This local Swift package owns deterministic release-folder-name parsing and its unit tests. It depends
only on Foundation. `ReleaseNameParser` extracts a title and optional year, or reports why the name is
uncertain. Recognized bracketed database codes are suffix metadata only; this package neither looks up
movies nor establishes identity. `ReleaseNameParser.revision` identifies grammar compatibility for
persisted unresolved decisions. `MovieFolderCommon` owns provider matching and cache decisions.

Run `rtk proxy scripts/test-parser.sh` from the repository root during the Validation Phase.
