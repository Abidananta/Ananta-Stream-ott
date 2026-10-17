Ananta OTT — build fixes and fullscreen orientation
Fixes included
Fixed the fullscreen exit transition so the normal player layout is restored
before Android finishes rotating the screen.
On phones, exiting fullscreen requests portrait-up orientation and restores
edge-to-edge system bars.
On Android TV / wide TV layouts, exiting fullscreen keeps landscape orientation.
Added a transition guard to prevent repeated fullscreen taps/back presses from
racing orientation requests.
Updated the release version to `1.0.4+5`.
Ensured the GitHub Actions workflow copies `lib/update_checker.dart`.
Removed Flutter's generated template `test/widget_test.dart` from the temporary
build because it imports `package:ott` and `MyApp`, which are not part of this app.
Added a defensive null guard for the EPG display expression in workflow builds
that contain `Text(_epgLabelForProgram(program), ...)`.
Build
Push the project files to the repository and run the Build Ananta OTT APK
GitHub Actions workflow. The generated APK is uploaded as the
`ananta-ott-android-tv-apk` artifact.
Important note about the supplied logs
The logs contain two different source/build states:
A nullable EPG error at `Text(_epgLabelForProgram(program), ...)`.
Later runs report `lib/update_checker.dart` missing from `build_app`, plus
the generated test importing `package:ott`.
The supplied project archive did not contain the exact `_epgLabelForProgram`
expression seen in the logs, so the workflow applies a defensive null guard only
if that expression exists in the repository revision being built. The current
source's corresponding expression was not present to patch directly.
One earlier log also reports Gradle could not resolve
`org.jetbrains.kotlin:kotlin-stdlib:2.2.21`; this is a dependency-resolution
failure rather than a Dart source error and may be transient repository/network
availability. If that exact error persists after rerunning Actions, the Gradle
dependency repositories/network must be inspected in the failed run.

Mobile PiP and releases (v1.0.5)
Android Home/minimize automatically enters 16:9 Picture-in-Picture while the
existing media_kit player/controller remains alive.
Returning from PiP does not reload the playlist or selected channel.
The mobile channel information/control bar is positioned at the bottom.
GitHub Actions publishes `app-release.apk` automatically into GitHub Releases
as `v1.0.5` on pushes to `main`.
