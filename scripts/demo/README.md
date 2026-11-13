# The landing page's recordings

The clips under "See it run" on the landing page (`site/media/`) are real recordings. They show
two Logos Basecamp installs, each with its own keys, doing real transactions on Sepolia. This
folder holds the tools that recorded and cut them, so they can be shot again after the UI
changes.

| Clip | Shows | Edit list |
|---|---|---|
| `start` | start a split with someone; they join from Home; each names the other | `clips/start.json` |
| `split` | propose, agree, pay through the Logos Signer, confirmed by the creditor's own read | `clips/split.json` |
| `safe` | a 2-of-2 Safe disclosed and checked against the chain; both owners approve; settled | `clips/safe.json` |
| `explain` | the card's "Who sees this?" view and the room history | `clips/explain.json` |
| `fileshare` | share a file into the room; another member fetches it and seeds it, through Logos Storage | `clips/fileshare.json` |
| `xmr-multisig` | three members set up a 2-of-3 Monero multisig on stagenet, fund it, and spend from it by two approvals | `clips/xmr-multisig.json` |

## The tools

- `rec.sh start <display> <out.mkv>` / `rec.sh stop <out.mkv>`: record an X display
  (ffmpeg `x11grab`, near-lossless), stopped cleanly by its pid file.
- `drive.sh <display> click|glide|type|paste|key|scroll|shot …`: drive one display the way a
  person would. The pointer glides to each target instead of jumping, and typing goes at a
  human pace.
- `edit.py clips/<name>.json`: cut one clip from the raw takes into
  `site/media/<name>.mp4` plus a poster image `.jpg`.
  - Each segment plays at real speed.
  - A wait is time-lapsed (`lapse`), never cut.
  - `hold` freezes a beat worth reading; `crop` frames part of the window.
  - A final `pair` segment shows both people's screens at the same moment.

## Shooting again

1. **Hosts.** Run the release AppImage (`gh release download muster-v<ver> --pattern
   '*.AppImage'`, then `--appimage-extract`) once per person, each with its own
   `--user-dir`, on its own Xvfb display (1600×1000). Use `QT_SCALE_FACTOR=1.25` and
   `LIBGL_ALWAYS_SOFTWARE=1`: Qt's own software renderer (`QT_QUICK_BACKEND=software`)
   draws Basecamp's sidebar icons as empty circles, and Mesa's llvmpipe draws them
   correctly.
2. **Each person, off camera:**
   - install the Keystore and Signer apps from Basecamp (Muster's "Create or import an
     account" offers to);
   - import a Sepolia account;
   - in Muster's Settings, name yourself and use the account for approvals; approve the
     link in the Signer.

   The payer needs a little Sepolia ETH. The Safe is any 2-of-2 the two accounts own (Safe
   v1.4.1's factory on Sepolia).
3. **Record each scene** on both displays at once (`rec.sh start` per display), drive it
   with `drive.sh`, and stop.
4. **Find the beats.** Run ffmpeg's scene detection
   (`select='gt(scene,0.004)',showinfo`) over each take: every burst of on-screen change is
   a beat. Contact sheets (`tile=`) show what each beat looks like.
5. **Cut and check.** Update the clip's edit list, run `edit.py`, and look at a contact
   sheet of the result before replacing what is in `site/media/`.

The raw takes (`.run/demo/raw/`, ~100 MB) and the profiles stay out of git. The edit lists
are the source of truth for each cut.
