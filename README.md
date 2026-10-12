Ananta OTT — build fix and Android TV BACK fix
This source package is intended to be uploaded to the root of a GitHub repository. It builds an Android APK in GitHub Actions; Flutter/Android Studio are not required on your computer.
What was fixed
Removed an accidental compile error in the phone-layout channel tile (`focusNode`, `focusedByIndex`, and `index` were referenced without being defined). TV-specific focus handling remains in the Android TV sidebar.
Android TV BACK now closes the sidebar first. If the sidebar is already hidden, BACK is allowed to leave the app instead of toggling the sidebar forever.
Build workflow now separates dependency resolution, Dart analysis, and release compilation so failures are easier to identify.
Android manifest setup includes TV launcher support and permits the app's HTTP IPTV stream.
Build the APK
Create a GitHub repository. Choose Private if preferred.
Extract this ZIP and upload its contents to the repository root. Ensure `lib/main.dart`, `pubspec.yaml`, and `.github/workflows/build-apk.yml` are at the repository root (not nested inside another folder).
Commit to the `main` branch.
Open Actions → Build Ananta OTT APK. Wait for the run to finish.
If successful, download the `ananta-ott-android-tv-apk` artifact and extract `app-release.apk`.
If the workflow fails, open the failed step and copy the first actual error lines (usually shown above `Finishing: ...`); that final debug line by itself is not the error message.
This package has not been compiled in this environment or tested on a physical Xiaomi TV Box.
