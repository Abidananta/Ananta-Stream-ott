Ananta OTT - EPG info and stream retry update
TV channel info overlay shows for 10 seconds after selecting/changing channel.
Removed the bottom video playback progress bar.
Shows current programme, EPG progress, and next programme in the channel info card.
Retries initialization failures and prolonged buffering up to five times for the selected channel.
Uses the existing GitHub Actions workflow: `.github/workflows/build-apk.yml`.
Upload the contents of this folder to the repository root and run the workflow. The source must be built and tested on the target Android TV device; retries cannot fix an unavailable source or unsupported stream format.
