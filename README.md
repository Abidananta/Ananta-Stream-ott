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
Mobile Picture-in-Picture update (v1.0.9)\nOn Android phones/tablets, pressing Home or otherwise leaving the app enters Picture-in-Picture where supported. Tapping the PiP window returns to the same channel and app state. PiP is disabled on Android TV devices. Version: 1.0.9 (version code 10).\n
Version 1.0.10 build output
The GitHub Actions workflow builds the APK and uploads it as an Actions artifact. It intentionally does not create a GitHub Release or Git tag, because repository tag-creation rules and immutable releases can reject automated release publication. To get the APK, open the successful workflow run in the Actions tab and download the `ananta-ott-android-tv-apk` artifact. To publish a GitHub Release later, an administrator must permit the workflow to create a new unique tag and the release should be drafted with assets attached before publishing.
