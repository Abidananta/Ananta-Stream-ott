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
v1.1.9 notes
Mobile: removed gap above channel list and the logo counter. TV EPG: overlapping duplicate programmes from multiple feeds are merged so one NOW entry shows, and the guide opens on the live programme. Logos + EPG cache live in an 'Ananta OTT' app folder (external app storage, falls back to private storage; old cache is migrated).

v1.1.8 notes (glass UI + local storage)
Glass UI: lib/glass.dart (Glass, GlassBackground, GlassChip) is used by every screen. TV panels use the frosted gradient without live blur by default (kTvLiveBlur in main.dart) because blur over video is heavy on weak TV boxes.
Local storage: lib/local_store.dart keeps EPG downloads (conditional ETag/Last-Modified refresh), the parsed guide and a mirror of the repository's channel_logos folder in the app's private storage (ananta_data/). Logos sync every 12 h, on app resume and on demand; removed logos are deleted. New dependency: path_provider.

Icon update
Launcher icon redesigned as a safe-zone adaptive icon (dark background + inner emblem) so it is never cropped in circle, squircle or square launchers; round legacy and themed icons added.

v1.1.7 notes
`android_template/MainActivity.kt` now holds the native Android code (PiP + in-app installer). Upload this folder too.
Update dialog: resumable download, PackageInstaller install with real error messages, full TV remote support.
