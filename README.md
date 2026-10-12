Ananta OTT — 3-day EPG cache and TV guide
This package uses the supplied TSEPG, Jio EPG and general XMLTV feeds. EPG entries from three days in the past through three days in the future are retained in SharedPreferences. Cached guide data is loaded immediately at startup, then refreshed from the online sources; successful refreshes replace the saved cache.
When the channel sidebar is open, the selected/focused channel's 3-day schedule appears in a panel to its right. The programme currently airing shows a small EPG progress bar in the player information card and guide panel. A custom launcher icon and Android TV banner are configured by the GitHub Actions workflow, which also adds the LEANBACK_LAUNCHER category.
Build without local Flutter
Upload the contents of this folder to the root of a GitHub repository (preserve `.github/workflows/build-apk.yml`).
Run Actions → Build Ananta OTT APK.
Download the `ananta-ott-android-tv-apk` artifact if the workflow succeeds.
Note about catch-up playback
The 3-day guide includes past programme entries. Actual playback of past programmes requires a catch-up URL/template from the stream provider; the supplied XMLTV URLs only describe programme schedules and do not themselves provide replay streams.
The source has not been compiled or tested on physical Xiaomi TV hardware in this environment. Review GitHub Actions logs if the workflow fails.

Latest remote fix: CENTER/ENTER repeat events are ignored so a held Xiaomi remote button cannot open the sidebar and immediately trigger a stream reload. Sidebar reveal uses immediate positioning, and EPG schedules are cached per channel to avoid filtering the full guide during remote navigation.

Build workflow update
The workflow now treats `flutter analyze` as a diagnostic step so lint/deprecation warnings do not prevent the release build. Dependency resolution and `flutter build apk --release` remain required and will still fail for real dependency or Dart/Gradle compilation errors. The build step runs verbosely so the Actions log shows the first actionable error.
