Ananta OTT — Xiaomi TV remote navigation update
This source package updates the existing Ananta OTT Flutter app for Android TV / Xiaomi Mi Box.
Remote behavior
The TV player starts unobstructed with the channel rail hidden.
Enter / Select opens the channel sidebar and focuses the currently playing channel (or first available channel).
Up / Down moves through channels. D-pad repeats use immediate list scrolling rather than queuing an animation per key repeat.
Left while the channel list is open opens the category list.
Up / Down browses categories; Enter applies the focused category; Right returns to channels.
Enter on a channel starts it and hides the sidebar.
UI
The video remains full-screen behind the translucent sidebar.
The transparent channel/programme information card and progress bar use matching left/right margins and a fixed gap, so they align visually without overlapping.
Cloud build
Upload the contents of this folder to the root of a GitHub repository, preserving `.github/workflows/build-apk.yml`. Run Actions → Build Ananta OTT APK and download the `ananta-ott-android-tv-apk` artifact if the workflow succeeds.
The source has not been compiled or tested on physical Xiaomi TV hardware in this environment. Please verify the workflow result and remote behavior on the device.
