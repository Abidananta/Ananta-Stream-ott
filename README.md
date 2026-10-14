Ananta OTT — EPG remote navigation update
Remote controls
Enter/Select while the sidebar is hidden opens the channel list only.
Right while the channel list is open opens the three-day EPG and immediately enables its selection highlight.
Up/Down browses programme entries while EPG is visible; the highlighted programme is scrolled into view.
Enter while the EPG guide is open is ignored so it cannot unexpectedly switch channels.
Left closes the guide / returns to categories; Back hides the sidebar.
Build
Upload the contents of this folder to the repository root. Keep `.github/workflows/build-apk.yml` and remove any duplicate `build-apk-fixed.yml`. Run the workflow in GitHub Actions and install the generated APK.
Audio limitation
This project still uses Flutter `video_player` and Android's native playback stack. Volume is set to 100%, but no app-level volume setting can create a missing audio track or guarantee support for every codec on every Android TV device. Some streams require a supported audio codec or a different native player/decoder implementation. Test the affected stream and inspect Android playback logs before choosing a decoder change.
The source has not been compiled or tested on a physical TV box in this package.

TV remote controls
Remote key mappings and the channel-information display duration are centralized in
`lib/tv_remote_control.dart`, which is imported by `lib/main.dart`. The Up button shows the channel information card for
15 seconds while the sidebar is hidden. Changing channels also displays the card
for 15 seconds. Existing remote navigation remains in `lib/main.dart`: Up/Down
navigate the sidebar when it is open, OK/Enter selects or opens the channel rail,
Left/Right follow the existing guide/navigation behavior, and Back closes the
sidebar before allowing the app to exit.
