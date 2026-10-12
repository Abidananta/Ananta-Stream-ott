# Ananta-Stream-ott

Ananta OTT cloud APK build
This repository package is intended for building the app on GitHub Actions, so you do not need to install Flutter or Android Studio locally.
Steps
Create a new GitHub repository (a private repository is fine).
Extract this ZIP on your computer.
In the repository, choose Add file → Upload files and upload the extracted contents, including the `.github` folder, `lib` folder, `pubspec.yaml`, and this README. Commit to the `main` branch.
Open the repository's Actions tab. Select Build Ananta OTT APK.
Click Run workflow if it has not started automatically after your commit.
Open the completed workflow run and download the artifact named `ananta-ott-android-tv-apk`.
Extract the downloaded artifact ZIP; it contains `app-release.apk`.
Important
This workflow creates the standard Android/Gradle wrapper files using the hosted Flutter SDK and then builds the APK.
The Dart source and Android TV manifest configuration have not been compiled or tested in this environment. A successful GitHub build is required before installing the APK.
`usesCleartextTraffic=true` is needed for the HTTP PTV stream URL currently present in the app. Prefer HTTPS streams when available.
