Ananta OTT – EPG logos and guide progress update
Included
Loads XMLTV programme data from the three configured EPG feeds.
Reads channel `<icon src="...">` entries from EPG and matches logos by EPG channel ID/name.
Stores logo URLs alongside the three-day EPG cache and uses `cached_network_image` for on-device image caching.
Shows a programme progress bar under the current programme in the channel sidebar and channel info card, plus current/next programme text in the info card.
Removes the player timeline/progress bar from the bottom control row.
Explicitly sets playback volume to 100% after stream initialization.
Keeps the Android TV D-pad UP/DOWN channel list navigation.
Build
Upload the contents of this folder to the repository root and run `.github/workflows/build-apk.yml` in GitHub Actions.
Note: source-level changes have not been compiled or tested on a physical TV box. A stream with an unsupported audio codec or no audio track cannot be made audible solely by setting player volume; that requires stream/decoder verification.
