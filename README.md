Ananta OTT — Xiaomi Android TV update
This package contains the Flutter source and GitHub Actions workflow for building an Android TV APK in the cloud. It is a source/build package, not a precompiled APK.
TV remote behavior
Enter/Select while watching: opens the channel sidebar and focuses the currently playing channel.
Up/Down: browse channel rows; held-button `KeyRepeatEvent`s are handled too.
Enter/Select in the sidebar: plays the highlighted channel and hides the sidebar.
Left/Right: switches to previous/next channel and hides the sidebar.
Back: closes the sidebar when open; with the sidebar hidden, Android handles Back so the app can exit.
Sidebar and search
Translucent left overlay; video remains full-screen behind it.
Search filters channel names and groups as you type.
Submitting search focuses the first result.
The instruction text at the bottom of the sidebar has been removed.
Playback changes
When changing channels, the current player stays visible while the next stream initializes. The app swaps players after the new stream is ready, reducing black-screen gaps during channel switching. Actual buffering smoothness still depends on the stream source and network.
Build in GitHub Actions
Create a GitHub repository.
Upload the contents of this ZIP to the repository root, preserving `.github/workflows/build-apk.yml`.
Open Actions → Build Ananta OTT APK and run the workflow, or push to `main`.
Download the `ananta-ott-android-tv-apk` artifact after the run succeeds.
The source has not been compiled or tested on a Xiaomi TV Box in this environment. If Actions fails, share the first actual compiler/dependency error from the expanded log (not only the `Finishing:` line).
