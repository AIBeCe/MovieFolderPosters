# Installation and first-run setup

## Qualification status

The current release qualification target is macOS 26.5 on Apple Silicon with APFS and HFS+ volumes. This target is **not qualified yet**. The project deployment target and successful builds do not prove runtime support. Do not describe this target or any other platform/filesystem as supported until fresh-install and upgrade, live TMDb, Finder activation, and persistent icon checks have been completed and recorded.

No compatibility is claimed for other macOS releases, Intel Macs, or filesystems such as ExFAT, network shares, or removable media. Their behavior is unqualified.

## Install the app

1. Obtain the release DMG from the project's release channel.
2. Open the DMG and drag **Movie Folder Posters.app** to **Applications**.
3. Eject the mounted disk image.
4. Open the app from Applications. If macOS asks you to confirm the first launch, follow the system prompt for the signed, notarized app.

The app includes a Finder Sync extension. In macOS, enable **Movie Folder Posters** in **System Settings → General → Login Items & Extensions → Finder Extensions**. The exact labels can vary by macOS release. Opening Extension Settings from the app takes you to Apple's extension management UI; it does not itself enable the extension.

## Configure folders and TMDb

1. In the app's main window, choose **Add Collection** and select the movie folder you want the app to process. Grant the folder access requested by macOS.
2. Choose **Check Installation…** to inspect component versions, extension enablement and observed activation, shared-storage readiness, and folder access status. A passed access preflight is not proof that a poster can be persistently written on every volume.
3. Open **Settings → TMDb**. In your TMDb account's API settings, copy the **API Read Access Token** and paste it without the `Bearer` prefix. Save it, then use **Test Saved Token** to verify the saved credential.
4. Open the configured collection in Finder. Finder navigation triggers processing; there is no background folder watcher.

The app does not store the candidate token in its configuration UI state. Viewing settings or previewing a folder name does not make a TMDb request. Debug builds can opt into controlled fixtures; Release builds use the configured live token.

## Use the app

- Use the collection results to review unresolved folders. **Choose Movie…** lets you search TMDb and explicitly select a match.
- Retry eligible results or cancel active work from the results window.
- Change poster finish and frame appearance in Settings.
- If a folder's permission or volume changes, use **Refresh Status** from the collection menu. Reconnection alone does not schedule a retry.

The app preserves existing icons when it cannot safely assign or update a poster. It does not modify movie contents.

## Troubleshooting

### The extension is disabled or posters do not update

Use **Check Installation…** and inspect extension enablement and last-observed activation. Enable the extension in System Settings if needed, then close and reopen Finder windows showing the collection. The activation timestamp is an observation, not proof that the extension is currently running. If the app offers **Open Extension Settings**, use it to reach Apple's extension controls.

### A collection reports missing or stale access

Use **Locate Folder…** on that collection and select the intended folder to restore its authorization. Adding a folder to the app does not by itself ensure that Finder has permission to write custom icon metadata.

### TMDb search or processing reports an authentication problem

In **Settings → TMDb**, confirm that the saved value is an API Read Access Token, without a `Bearer` prefix, and run **Test Saved Token**. Network errors and provider rate limits require retrying later; repeated requests during a provider backoff may be deferred.

### The volume is unavailable or its filesystem is unqualified

Reconnect the volume and choose **Refresh Status**. APFS and HFS+ are the only filesystems in the current qualification target, which is itself still unqualified. No poster persistence claim is made for other filesystems.

### The folder keeps its previous icon

This is expected when the app cannot safely verify the folder, authorization, identity, or supported metadata behavior. Review the collection status and preserve the existing icon until the underlying condition is resolved.

## Privacy and attribution

Folder names used for identification may be sent to TMDb when processing or a user-requested search requires it. The app does not send folder paths as part of its identification preview. The TMDb token is stored in secure storage and is not included in diagnostic messages. Review the project's privacy documentation before deployment if additional policy text is required.

This product uses the TMDB API but is not endorsed or certified by TMDB. Follow [TMDb's attribution and branding requirements](https://developer.themoviedb.org/docs/faq), including its [approved logo and attribution guidance](https://www.themoviedb.org/about/logos-attribution).

## Release packaging for maintainers

`bash scripts/release/package.sh` archives and exports the Release app, verifies the exported app's code signature, creates a compressed DMG, submits it to Apple's notary service using an existing Keychain profile, staples the notarization ticket, and runs Gatekeeper assessment. It does not publish or upload a release.

Requirements: macOS, Xcode command-line tools, a valid **Developer ID Application** signing identity, the matching Apple Developer Team ID, and a `notarytool` Keychain profile created separately with `xcrun notarytool store-credentials`. The script never accepts or writes an Apple ID password or app-specific password.

Run from the repository root:

```sh
bash scripts/release/package.sh \
  --identity 'Developer ID Application: Example, Inc. (TEAMID1234)' \
  --team-id TEAMID1234 \
  --notary-profile movie-folder-posters-notary \
  --output-dir /path/to/release-output
```

The output directory must not already exist. Protect the resulting artifacts according to your release process. A successful local packaging run does not replace fresh-install, upgrade, live-provider, Finder-process, or persistent-icon qualification.
