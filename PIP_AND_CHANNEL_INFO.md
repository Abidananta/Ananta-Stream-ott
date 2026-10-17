Ananta OTT — PiP and channel information UI
Android PiP is enabled in the generated Android project by the GitHub Actions
workflow. On Android 8.0+ compatible devices, pressing Home or switching apps
requests a 16:9 Picture-in-Picture window. Returning to the app should resume
the same Flutter/player state rather than restarting playback.
The channel information card is now shown on mobile and positioned at the
bottom. TV retains overscan-safe bottom spacing.
Channel information timeout is 20 seconds. On TV, pressing remote UP while
the sidebar is hidden continues to reveal the information card.
Version bumped to `1.0.5+6`; `version.json` is updated to build code `6`.
Notes:
PiP support depends on Android version/device settings. Some TV devices do not
support PiP.
This project generates Android scaffolding during GitHub Actions, so native
PiP configuration is applied to the generated manifest and MainActivity in
the workflow.
The APK has not been built or tested on a physical device in this workspace.
