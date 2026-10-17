Ananta OTT — EPG remote navigation update
Remote controls
Enter/Select while the sidebar is hidden opens the channel list only.
Right while the channel list is open opens the three-day EPG and immediately enables its selection highlight.
Up/Down browses programme entries while EPG is visible; the highlighted programme is scrolled into view.
Enter while the EPG guide is open is ignored so it cannot unexpectedly switch channels.
Left closes the guide / returns to categories; Back hides the sidebar.
Build
Upload the contents of this folder to the repository root. Keep `.github/workflows/build-apk.yml` and remove any duplicate `build-apk-fixed.yml`. Run the workflow in GitHub Actions and install the generated APK.
Audio limitation
This project still uses Flutter `video_player` and Android's native playback stack. Volume is set to 100%, but no app-level volume setting can create a missing audio track or guarantee support for every codec on every Android TV device. Some streams require a supported audio codec or a different native player/decoder implementation. Test the affected stream and inspect Android playback logs before choosing a decoder change.
The source has not been compiled or tested on a physical TV box in this package.

Audio compatibility update
Playback is implemented with media_kit/libmpv rather than Flutter video_player. The bundled native playback libraries provide broader codec support, intended to address MPEG Audio Layer 1/2 (MPGA/MP2) streams. This source has not been compiled or device-tested in this environment; verify the GitHub Actions build and test on the target Android TV device.

In-app update system (GitHub Releases)
The app checks the latest stable GitHub Release after the first frame, so this check does not delay startup. If a release tag is newer than the installed app version, it shows an update dialog, downloads the first `.apk` asset, then opens Android's package installer. Android may require the user to allow “Install unknown apps” for Ananta OTT; installation still requires user confirmation.
Publishing a release
Keep `version:` in `pubspec.yaml` aligned with the release version. For example, `version: 1.0.3+4` should be published with tag `v1.0.3`.
Commit and push the source changes to `main`.
Create and push a version tag, e.g. `git tag v1.0.3 && git push origin v1.0.3`.
The `Build Ananta OTT APK` workflow builds the APK and attaches it to the GitHub Release for that tag. The updater downloads the APK asset from the latest stable release.
Important signing requirement: Android only installs an update over an existing app when both APKs have the same application ID and signing certificate. The current workflow generates Android scaffolding during CI; do not expect APKs built with different ephemeral signing keys to update over each other. Before distributing to users, configure one persistent release keystore in GitHub Actions secrets and use it for every release. If users already installed a differently signed APK, they may need to uninstall it once before installing the consistently signed release (uninstalling removes local app data).
The update check requires internet access and a public GitHub repository/release. The repository configured in `githubReleasesApi` is `Abidananta/Ananta-Stream-ott`; change that constant if the releases are hosted in a different repository.
