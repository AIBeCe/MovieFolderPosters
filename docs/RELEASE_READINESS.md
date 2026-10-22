# Release readiness — R100-09

Status: implementation commit `a08c070` was fast-forwarded into local `develop` on 2026-10-23. The scoped
implementation validation passed, but production release qualification remains open. Issue #9 remains open and no
GitHub Release has been created.

## Delivered implementation

- Added the product app icon resources and applied the app artwork to the Dock tile and product-first About window.
- Kept TMDb attribution in a compact About-window footer with the approved logo and a link to TMDb.
- Added a redacted diagnostics export to the installation-readiness flow.
- Added installation and maintainer release-packaging instructions, plus a runnable About-window prototype.
- Added a release script that archives and exports the app, verifies app signing, signs and verifies the DMG, submits
  it for notarization, staples the ticket, and assesses the result with Gatekeeper.

## Scoped validation

- Focused About-window and diagnostics-export tests passed: 7 passed, 0 failed, 0 skipped.
- SwiftLint 0.65.1 reported zero violations across the five changed Swift files.
- The installed Swift style guide was applied; independent review passed after the DMG signing and style findings
  were corrected.
- The unsigned Release build completed successfully. The package script passed `bash -n`, the export options plist
  passed `plutil -lint`, and `git diff --check` passed.
- A repeat test run after final style and packaging-script corrections was blocked before compilation because the
  sandbox could not write SwiftPM manifest diagnostics in the user cache. Those final Swift changes were whitespace
  only; the earlier focused run passed against the same behavior.

## Release work still required

The signed packaging script was not run. No valid Developer ID code-signing identity was available in the
validation environment, and no `notarytool` Keychain profile was found. Provide a Developer ID Application identity
with its private key and configure a notary profile before producing the release DMG.

The following qualification remains unperformed: signed package creation, notarization, Gatekeeper first-open
behavior, fresh installation and upgrade, live TMDb access, Finder extension activation, and icon persistence
through app/extension termination and Finder restart. The documented macOS 26.5 Apple Silicon APFS/HFS+ target is
not a compatibility claim. Do not publish a supported-platform claim until the release matrix in
[the production roadmap](PRODUCTION_ROADMAP.md#r100-09) is supported by current evidence.
