# ``MovieFolderCommon``

Share movie-folder configuration, processing, Finder integration, and typed activity between signed targets.

## Overview

The AppKit host and Finder extension import one common module. It coordinates local Network, FileSystem,
Persistence, Log, and MovieFolderParsing services. The host owns UI and navigation. ``MovieFolderEnvironment`` resolves storage and
assembles shared services in the calling process; the signed executables retain entitlements and explicit
Debug stub selection. The package's Development folder contains the Debug-only deterministic TMDb transport.
Importing the module does not establish filesystem authorization or create background processes.

``CollectionProcessingStorageNamespace`` opens the current CollectionProcessingState directory. Existing legacy
storage requires explicit offline migration after older app/extension processes are stopped. Migration retains
records and reusable locks and leaves a permanent legacy-path marker to prevent older stores from recreating
a second writable namespace. Normal opening never performs the legacy migration implicitly.

Activity is distinct from collection processing state, configuration, caches, and icon ownership.
``MovieFolderActivityLogEvent`` supplies closed result vocabulary, historical root-bound target facts, and fixed
local display templates without arbitrary
message strings, paths, tokens, bookmarks, movie/folder names, URLs, or raw errors. The caller must report actual
operation evidence. ``MovieFolderActivityRecorder`` lazily opens bounded storage and strongly retains its
required payload-free notifier. Change notifications are invalidation hints; consumers reload committed data.

The activity recorder retains at most 500 entries, with an 8 KiB event limit, a 1 MiB serialized history
payload budget before base64 expansion, and a 2 MiB Persistence envelope limit. Activity reads version-one
records and writes version two; older writers reject version two without modifying its bytes.
Persistence access contention retries are cancellation-aware and bounded to approximately one second. Entries retain commit
order independently of occurrence time. Clear preserves the latest sequence; corrupt or unsupported history
fails explicitly, including on Clear. Recording independently awaits a bounded best-effort append so producer
cancellation can be recorded without replacing the producer's result. Read and Clear failures remain throwing.

## Topics

### Typed activity

- ``MovieFolderActivityLogEvent``
- ``MovieFolderActivityLogEntry``
- ``MovieFolderActivityServicing``
- ``MovieFolderActivityRecorder``
- ``MovieFolderActivityChangeNotifying``

### Shared configuration and credentials

- ``MovieFolderEnvironment``
- ``CollectionProcessingStorageNamespace``
- ``CollectionProcessingStorageNamespaceError``
- ``DirectoryConfiguration``
- ``ConfigurationRepository``
- ``CredentialStoring``
- ``KeychainCredentialStore``

### Collection processing state

- ``MovieFolderProcessor``
- ``MovieFolderProcessorConfiguration``
- ``CollectionProcessingStore``
- ``CollectionProcessingState``
- ``CollectionProcessingPresentation``

### Finder integration

- ``MoviePosterRequest``
- ``DirectoryObservationScheduler``
- ``DirectoryObservationSchedulerDelegate``
