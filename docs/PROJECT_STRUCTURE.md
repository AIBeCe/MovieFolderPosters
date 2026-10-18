# Project structure

The user approved the original feature organization on 2026-10-17 and the Common/Log package extraction on
2026-10-18. These are real filesystem folders and local package modules. The extraction is implemented and reviewed;
see [Common and Log migration](COMMON_AND_LOG_MIGRATION.md) for current scope and verification.

```text
MovieFolderPosters/
├── MovieFolderPosters.xcodeproj/
├── MovieFolderPosters/                 # Host target
│   ├── Application/                    # App lifecycle and app-wide window coordination
│   │   ├── AppDelegate.swift
│   │   └── AppCoordinator.swift        # Root routing and app-wide policies
│   ├── Features/
│   │   ├── Collections/
│   │   ├── Settings/
│   │   ├── Log/
│   │   ├── PosterActions/
│   │   └── Installation/
│   ├── UI/Controls/                    # Reusable AppKit controls
│   ├── Resources/                      # Assets, localized nib, and preview artwork
│   └── Configuration/                  # Host plist and entitlements
├── MovieFolderPostersFinder/
│   ├── Integration/
│   ├── Configuration/
│   └── Resources/
├── MovieFolderPostersTests/
│   ├── Application/                    # Root routing and cross-feature lifecycle
│   ├── Features/                       # Collections, Installation, Log, PosterActions
│   └── Resources/
└── MovieFolderPostersUITests/

Packages/
├── Network/
├── FileSystem/
├── Persistence/
├── Log/
│   ├── Sources/Log/Activity/
│   └── Tests/LogTests/Activity/
└── MovieFolderCommon/
    ├── Sources/MovieFolderCommon/
    │   ├── Activity/
    │   ├── Configuration/
    │   ├── Development/               # Debug-only deterministic TMDb transport
    │   ├── Processing/Collections/
    │   ├── FinderIntegration/
    │   └── Security/
    └── Tests/MovieFolderCommonTests/    # Mirrors source responsibility folders
```

## Ownership and dependencies

Keep each feature's views, view models, coordinators, and application services together. App-wide coordination
belongs in Application; a feature coordinator remains with its feature. MVVM-C describes responsibilities within
these folders. No global Views/ViewModels/Services hierarchy or additional module is needed for navigation alone.

AppDelegate retains AppCoordinator, which owns ConfigurationCoordinator, LogCoordinator, and
MoviePosterActionCoordinator as sibling flows. The configuration coordinator lives under Features/Collections
and owns Main, Settings, and their related sheets. Log owns its own window, activity view model, and
invalidation subscription independently of configuration startup. Root-owned appearance applies to all host
windows. Required collection cleanup belongs to the configuration service after a committed removal, not to
view rendering. See [Host coordinator architecture](COORDINATOR_ARCHITECTURE.md) for decisions and verification.

MovieFolderCommon contains application logic consumed by both executables through a public module API. It owns
parsing, matching, processing, collection state, configuration records, reusable security/request support,
typed movie activity, shared environment setup, and the Debug-only stub transport. MovieFolderEnvironment runs
in its caller's process; moving it into a package does not change App Group or process-private storage lookup.
The former Shared source folder/group is removed. Entitlements and explicit fixture selection remain on the
executable targets. Finder remains the thin integration layer.

Development contains StubTMDbTransport; the usesStubTMDbResponses setting explicitly selects its predefined
responses in Debug. Configuration owns the shared environment and explicit processing-state namespace migration.
The former HostActivityLog presentation model is ActivityLogViewModel under the host Log feature.

Log owns generic bounded activity storage and depends on Persistence. MovieFolderCommon depends on Log,
Network, FileSystem, and Persistence; those services do not depend on MovieFolderCommon or either executable.
Folders express ownership within one module per package; modules enforce dependency boundaries.

## Xcode and verification scripts

The host and test directories retain Xcode's folder-synchronized groups. Both executable targets link
MovieFolderCommon instead of compiling its sources directly. Finder integration sources retain explicit
membership. Host plist/entitlements remain excluded from automatic resource membership.

Verification scripts consume the Common package. Package-owned tests exercise the actual
module; host-only harnesses retain the AppKit/configuration composition required for presentation tests.

## Historical verification record — 2026-10-17 organization

- All 46 moved files retain their pre-move SHA256 content hashes.
- Both executable source sets match their pre-move membership: 23 host sources, 11 Finder sources, no duplicates.
- Xcode project parsing, explicit reference resolution, script syntax checks, and git diff whitespace checks passed.
- Fresh signed Debug build-for-testing and Release build passed; strict deep signatures passed for both app bundles.
- Built host, Finder, and unit-test resource lookup locations were inspected. Preview artwork and localized MainMenu
  remain available; plist and entitlement inputs do not leak into bundled resources.
- All eight moved-path harnesses passed: configuration 30, configuration UI 19, installation readiness 16, parser 7,
  matching 19, processing/manual actions 42, poster request 2, and poster action UI 5 tests.
- Independent structural review: PASS, with no Important findings.

Build/test results establish relocation integration, not new Finder runtime or native qualification evidence.
Existing R100-01 native limitations in [Installation readiness](INSTALLATION_READINESS.md) remain in effect.
The reorganization was committed in `c2cec93`. The complete readiness feature was subsequently fast-forwarded into
local `develop` at `55ba0a6` on 2026-10-17; issue #1 is closed and its feature branch was deleted. The integration was included in the 2026-10-18 push of `develop`.
Later native evidence is recorded in [Native qualification](NATIVE_READINESS_QUALIFICATION.md).

## Protocol-based communication

R100-02 introduced application models/repository in `Shared/Processing/Collections`; the package extraction moves
them into MovieFolderCommon/Processing/Collections with mirrored test ownership. Host-only summary reading, presentation, and read-only details
remain in `Features/Collections`. FileSystem owns read-only inventory and icon assessment; Persistence owns
generic bounded record access and pruning. The test-only child-process probe is under `scripts/test-support`
and never enters a synchronized application/test target. See [Processing results](COLLECTION_PROCESSING.md).

Existing object callbacks use focused delegate protocols. UI delegates are weak and main-actor isolated;
configuration presentation supports multiple weak subscribers. Required service collaborators and mutation guards
remain strongly owned. See [Delegate refactor](DELEGATE_REFACTOR.md) for scope and verification.
