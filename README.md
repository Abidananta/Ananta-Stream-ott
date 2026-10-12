Ananta OTT — second Enter / sidebar focus fix
This source update keeps TV remote focus anchored to the player when opening the channel sidebar. It avoids auto-focusing a channel tile during the overlay transition, preventing a stale tile key handler from receiving the next Enter after Back and starting an unintended channel change. Back hides the sidebar and returns focus to the player.
Build with GitHub Actions using `.github/workflows/build-apk.yml`. This source has not been compiled or tested on a physical TV box.
