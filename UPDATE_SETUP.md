Ananta OTT — direct APK updates and automatic releases
The app checks this public manifest:
`https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/refs/heads/main/version.json`
The manifest's `downloadUrl` points directly to the APK asset:
`https://github.com/Abidananta/Ananta-Stream-ott/releases/latest/download/app-release.apk`
The GitHub Actions workflow attaches the build output as `app-release.apk`, so
this URL downloads that APK directly instead of opening the release landing page.
Publish a new release
Increase the version and Android build number in `pubspec.yaml`, e.g.
`version: 1.0.5+6`.
Update `version.json` with the same version/build number and keep
`downloadUrl` set to the direct APK URL above.
Commit and push the changes to `main`.
Create and push a new tag, e.g. `git tag v1.0.5` then `git push origin v1.0.5`.
GitHub Actions builds the APK and creates the GitHub Release with the
`app-release.apk` asset. The direct URL then serves the latest release APK.
Required GitHub permission
In Settings → Actions → General → Workflow permissions, allow read and write
permissions. The workflow requests `contents: write` to publish releases.
Android notes
The app opens the direct APK URL in the external browser/download handler.
Android may require the user to open the downloaded APK and approve installation.
Updates must use the same application ID and the same signing key as the
installed app. The first version that contains this update-checker must be
installed manually before existing users can receive in-app update prompts.
