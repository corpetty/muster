# Releasing — a download-and-run AppImage

Until the build dependencies are upstream (see the caveat below), other people
can't `make run` from a clone — but they *can* download a self-contained
**AppImage** and run it. This is how you cut one.

The artifact is a `logos-basecamp` AppImage with `muster_module` + `muster_ui`
baked in: one ~270 MB file, no Nix, no build, no basecamp checkout on the user's
side. They download it, `chmod +x`, run it, and click **Muster** in the sidebar.

## Build it

```bash
make appimage        # nix build <basecamp>#bin-appimage → result-appimage/
```

`make appimage` uses `BASECAMP` (defaults to `~/Github/logos-co/logos-basecamp`);
override it if your checkout is elsewhere: `make appimage BASECAMP=/path/to/logos-basecamp`.

It produces `result-appimage/logos-basecamp.AppImage`. Verify it before shipping:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./result-appimage/logos-basecamp.AppImage
# then click "Muster" → the lifecycle dashboard and the walkthrough should render
```

(`APPIMAGE_EXTRACT_AND_RUN=1` avoids needing FUSE; drop it if FUSE is available.)

## Publish it

```bash
gh release create v0.1.0-preview \
  result-appimage/logos-basecamp.AppImage#muster-linux-x86_64.AppImage \
  --repo corpetty/muster \
  --title "Muster preview (Linux x86_64)" \
  --notes "logos-basecamp + muster baked in. Download, chmod +x, run, click Muster."
```

Publishing is outward-facing — it puts a binary on the public repo — so do it
deliberately, and only after the click-test above passes on a real display.

## What builds this (the bake-in)

The AppImage comes from `logos-basecamp`'s own `bin-appimage` pipeline
(`appDistributed` → `dirBundler` → `mkAppImage`), with muster added to the
**distributed** app. Those edits live in your local `logos-basecamp/flake.nix`
(LOCAL-ONLY, not committed there) and are documented in
[`ui/tests/README.md`](ui/tests/README.md) § "Producing the app-under-test" —
both the dev bake-in (for the test harness) and the portable bake-in (for this
AppImage). A `git pull` in that checkout wipes them; re-apply from that doc.

## Honest caveats

- **The build needs a contributor's machine**, not a clone: it depends on the
  local `logos-basecamp` bake-in and the local `logos-module-builder` fork
  commits (the `nim.packages` hook + RUNPATH fix). The *AppImage itself* is
  self-contained once built — that's the whole point — so the person running it
  needs none of that. This asymmetry is why the AppImage exists.
- **Portability is verified-to-launch, not verified-on-a-clean-machine.** The
  AppImage builds, launches, and bundles muster (`muster_module` + `muster_ui`
  with `libsecp256k1.so.5` co-located, confirmed by extracting it). Whether it
  runs on a machine with no Nix store has to be checked on a second machine — the
  one thing the build box can't prove about itself.
- **It ships all of basecamp, not just muster.** A lighter *standalone* AppImage
  (just the muster app, like `make run`) is a follow-up: it needs
  `mkLogosQmlModule` to expose the runner's app derivation so `dirBundler` can
  bundle it, which it does not today.
