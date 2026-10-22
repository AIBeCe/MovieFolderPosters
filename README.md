# Movie Folder Posters

Movie Folder Posters gives supported movie folders persistent poster icons in Finder. Finder remains the place to browse movie folders; the app configures which folders it processes and how it identifies movies.

## Release qualification status

The current qualification target is **macOS 26.5 on Apple Silicon**, using **APFS or HFS+** volumes. This is a target for qualification, not a compatibility claim: release qualification is incomplete until the checks in the [installation guide](docs/INSTALLATION.md#qualification-status) have been recorded as passing. Other macOS versions, processor architectures, and filesystems are not currently qualified.

## Install

Use the signed and notarized release package supplied by the project. Follow the [installation guide](docs/INSTALLATION.md) to install the app, enable its Finder extension, authorize movie folders, and configure TMDb.

## What it does

- Assigns poster icons to folders you explicitly configure.
- Uses Finder folder navigation as its processing trigger; it does not continuously watch folders.
- Supports automatic identification and explicit movie selection in the app's collection results.
- Stores the TMDb API Read Access Token in secure storage.
- Preserves existing folder icons when it cannot safely apply a poster.

The app does not rename, move, delete, or modify movie files.

## Build and package

The project is an Xcode project at `MovieFolderPosters/MovieFolderPosters.xcodeproj`. Release packaging is prepared by `bash scripts/release/package.sh`. It requires Xcode command-line tools, a Developer ID Application identity, and an existing `notarytool` Keychain profile. See the [release packaging instructions](docs/INSTALLATION.md#release-packaging-for-maintainers).

## Third-party services

Movie matching and poster retrieval use TMDb. This product uses the TMDB API but is not endorsed or certified by TMDB. Follow [TMDb's attribution and branding requirements](https://developer.themoviedb.org/docs/faq), including its [approved logo and attribution guidance](https://www.themoviedb.org/about/logos-attribution).
