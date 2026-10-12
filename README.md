Ananta OTT — Android TV stability update
Changes
Allows choosing a different channel while a stream is buffering. A newer selection supersedes and disposes the previous pending request.
Keeps the channel rail open during buffering, so the user can move and confirm another channel.
Avoids changing channels while the rail is hidden. Enter opens the rail; Enter on a focused channel starts it.
Uses only one active native video controller at a time to reduce Android TV decoder exhaustion and force-closes.
Commits the selected channel only after the stream initializes successfully; stream initialization timeout reduced to 20 seconds.
Retains local EPG caching and the two-hour refresh policy from the previous version.
Only `.github/workflows/build-apk.yml` is included. `build-apk-fixed.yml` is intentionally absent.
Build
Upload the contents of this folder to the repository root, replacing existing files. In GitHub Actions, run the `build-apk.yml` workflow and download the generated APK artifact.
Note: Source changes are not a substitute for testing on the target device. If force-closing persists, capture the Android crash log and the GitHub Actions build log to identify the exact native failure.
