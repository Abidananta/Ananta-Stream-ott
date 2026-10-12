Ananta OTT — TV sidebar responsiveness update
Changes
Opening the channel rail with Enter performs one state update and one scheduled focus/scroll pass, instead of triggering a second state update immediately.
The live player is wrapped in a RepaintBoundary so channel-rail animations and list focus changes are less likely to repaint the video surface.
With the rail hidden, Up/Down/Left/Right are intentionally ignored. Enter/Select is the only key that opens the rail; no hidden-rail key changes channel or player controls.
The rail remains an overlay over the player; it does not resize the video area.
Keeps the current video_player/ExoPlayer backend and existing EPG cache logic. This is a source-level optimization, not a verified engine replacement.
Build
Upload the contents of this folder to the GitHub repository root, keeping `.github/workflows/build-apk.yml`. Then run the workflow and test the generated APK on the Android TV device.
Important
This source has not been compiled or tested on a physical Xiaomi Mi TV Box. If force-closing continues, capture Android crash/logcat output; the underlying native playback error cannot be confirmed from source alone.
EPG cache behavior
The app reads the saved EPG from device storage first. It keeps a rolling three-day guide and reuses a cache younger than two hours without downloading the EPG again on app launch. When the cache is absent or at least two hours old, it refreshes from the configured EPG sources and saves successful results. The periodic refresh runs every two hours while the app remains open.
