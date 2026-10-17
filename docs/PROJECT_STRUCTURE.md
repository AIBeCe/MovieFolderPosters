# Project structure

The user approved this organization on 2026-10-17. These are real filesystem folders reflected in Xcode.
The reorganization preserves existing behavior and service boundaries, including the pending R100-01 implementation.

```text
MovieFolderPosters/
├── MovieFolderPosters.xcodeproj/
├── MovieFolderPosters/                 # Host target
│   ├── Application/                    # App lifecycle and app-wide window coordination
│   ├── Features/
│   │   ├── Collections/
│   │   ├── Settings/
│   │   ├── Log/
│   │   ├── PosterActions/
│   │   └── Installation/
│   ├── UI/Controls/                    # Reusable AppKit controls
│   ├── Resources/                      # Assets, localized nib, and preview artwork
│   └── Configuration/                  # Host plist and entitlements
├── Shared/                             # Application source compiled by host and Finder
│   ├── Configuration/
│   ├── Processing/
│   ├── FinderIntegration/
│   ├── Security/
│   └── Development/
├── MovieFolderPostersFinder/
│   ├── Integration/
│   ├── Configuration/
│   └── Resources/
├── MovieFolderPostersTests/
│   ├── Features/                       # Collections, Installation, PosterActions
│   ├── Shared/                         # Configuration, FinderIntegration, Processing
│   └── Resources/
└── MovieFolderPostersUITests/

Packages/
├── Network/
├── FileSystem/
└── Persistence/
```

## Ownership and dependencies

Keep each feature's views, view models, coordinators, and application services together. App-wide coordination
belongs in Application; a feature coordinator remains with its feature. MVVM-C describes responsibilities within
these folders. No global Views/ViewModels/Services hierarchy or additional module is needed for navigation alone.

Shared contains movie-specific application logic needed by both executables. It remains shared target source,
not a new package. In particular, Processing now physically owns the parser, matcher, and processor; the old
top-level virtual Movie Processing group has been removed. Development owns the shared, explicitly opt-in fixture
transport; Release transport behavior is unchanged. Finder remains the thin integration layer.

Network, FileSystem, and Persistence remain independent local SPM service modules with their existing public APIs
and tests. Folders express ownership; modules enforce dependency boundaries. Services must not depend on the app.

## Xcode and verification scripts

The host and test directories retain Xcode's folder-synchronized groups. Shared and Finder use explicit groups
with paths matching the physical subfolders. Shared processing sources have explicit membership in both executable
targets, replacing host compilation through the former flat synchronized directory. Other source memberships and
resource memberships are preserved. Host plist/entitlements are excluded from automatic resource membership and
referenced through the updated configuration paths.

The existing scripts/test-*.sh harnesses copy production sources from the new locations while keeping their temporary
SwiftPM modules flat. The parser test filename now matches its actual ReleaseNameParserTests type. No test assertions,
production Swift code, resource contents, credentials, or signing entitlements changed during the moves.

## Verification record

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
The user authorized committing the verified work. Integration, push, and issue closure remain on hold.
