Ananta OTT - Android TV Category & Search Fix
This package updates the Flutter source for the Ananta OTT Android TV layout.
TV remote behavior
Press Enter/Select while the player is visible to open the channel sidebar at the currently selected channel.
Use Up/Down to move the highlighted channel. Holding the direction should continue through the list.
Press Left while the channel list is open to show channel categories.
Use Up/Down to browse categories, then Enter/Select to apply a category.
Press Right in categories to return to channels.
From the first channel, press Up to focus search. Type using the TV keyboard, then press Enter/Search; press Down to return to results.
Press Enter/Select on a highlighted channel to play it.
The player remains full screen behind the transparent sidebar.
A transparent channel information bar appears above the progress bar.
Build using GitHub Actions
Create/open a GitHub repository.
Upload the contents of this folder to the repository root, preserving `.github/workflows/build-apk.yml`.
Open Actions and run Build Ananta OTT APK.
Download the `ananta-ott-android-tv-apk` artifact after a successful run.
This source has not been compiled or tested on physical Xiaomi TV hardware in this environment. Verify the Actions build and remote behavior before distribution.
