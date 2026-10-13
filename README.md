Ananta OTT — Channel browsing, EPG scroll and stream recovery update
Included source changes
Removes the duplicate inner ListTile focus highlight so only one channel selection border is visible.
Makes the 3-day EPG panel respond to remote UP/DOWN and displays a scrollbar thumb.
Keeps cached EPG logos loaded through `cached_network_image`.
Removes the bottom favourite button strip beneath the channel info card.
Adds up to five retries for stream initialization failures/timeouts, with increasing delays.
Adds a playback health check that retries a stream after a prolonged buffering state or player error.
Sets player volume to 100% and disables audio mixing with other apps.
Preserves the current/next EPG information card and EPG progress bar.
Build
Upload the contents of this folder to the GitHub repository root and run `.github/workflows/build-apk.yml`.
Important limitations
This is a source patch and has not been compiled or tested on a physical TV box. Retries can recover transient network errors, but cannot repair an unavailable stream or a stream with an absent/unsupported audio track. Android HLS playback requires the stream's audio and video sample codecs to be supported by the device's media decoder.
