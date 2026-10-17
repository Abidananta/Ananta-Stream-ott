Automatic APK release guide — Ananta OTT
Repository: https://github.com/Abidananta/Ananta-Stream-ott
The GitHub Actions workflow now behaves like this:
Push to `main`: builds the APK and stores it as a workflow artifact.
Push a version tag such as `v1.0.5`: builds the APK and automatically creates
a GitHub Release with `app-release.apk` attached.
Release a new app version
Edit `pubspec.yaml` and increase the version/build number. For example:
```yaml
   version: 1.0.5+6
   ```
The part after `+` is Android's version code and must increase for every
published APK.
Update `version.json` in the repository's `main` branch to match:
```json
   {
     "version": "1.0.5",
     "versionCode": 6,
     "releaseNotes": "Bug fixes and improvements.",
     "downloadUrl": "https://github.com/Abidananta/Ananta-Stream-ott/releases/latest/download/app-release.apk"
   }
   ```
Commit and push these changes to `main`.
Create and push a tag matching the version:
```bash
   git tag v1.0.5
   git push origin v1.0.5
   ```
Open the repository's Actions tab and watch Build Ananta OTT APK.
When the tagged build succeeds, GitHub creates the release `v1.0.5` and
attaches `app-release.apk` automatically.
The tag should be created after the version changes are committed. Use a new,
unique tag for each release; do not reuse an existing tag.
One-time GitHub setting
Open Settings → Actions → General → Workflow permissions and ensure the
workflow is allowed to have read and write permissions. The workflow itself
declares `contents: write`, which is required to publish the Release.
Android update requirements
The app's update checker reads `version.json`; update that file for each
release so installed apps see the newer version.
Publish APKs signed with the same persistent Android signing key and use the
same application ID as the installed app, or Android may refuse to update.
Existing installed app builds need to include the update-checker feature before
they can show the in-app update dialog.

The in-app updater uses the direct APK asset URL ending in `/latest/download/app-release.apk`, not the release landing page.
