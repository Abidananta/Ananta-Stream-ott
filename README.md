Ananta OTT — stability and EPG guide toggle update
This package contains the Flutter source and GitHub Actions cloud build workflow.
Changes:
EPG refresh interval set to every 2 hours.
Prevents overlapping EPG downloads/parses when a refresh is already running.
Keeps the saved EPG cache available while refreshes happen.
Channel sidebar opens without showing the 3-day guide by default.
Press Right on the Xiaomi/Android TV remote while the channel list is open to show/hide the 3-day EPG panel.
Press Left while the channel list is open to enter category browsing; Right in category browsing returns to channels.
EPG panel is hidden when the sidebar closes.
Build from GitHub Actions: run `Build Ananta OTT APK` and download the artifact only after a successful run. This source has not been compiled or tested on physical TV hardware in this environment.

Stability update: only `.github/workflows/build-apk.yml` is retained (the duplicate root `build-apk-fixed.yml` has been removed). EPG data is cached on-device and startup reuses a cache younger than two hours instead of immediately downloading the feeds again. Holding Enter on a TV remote no longer repeats the confirm action.
