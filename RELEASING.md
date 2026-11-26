# Releasing Muster

A release is one GitHub release, `muster-v<version>`, carrying two ways to run Muster. People pick one:

| Asset | For whom | What it is |
|---|---|---|
| `Muster-<version>-Basecamp-<tag>-linux-x86_64.AppImage` | someone who wants to download one file and run it | Basecamp's own released AppImage with Muster and the Logos Official modules it needs already installed inside. `chmod +x`, run, click **Muster**. |
| `muster_module-<version>.lgx` and `muster_ui-<version>.lgx`, one per package holding every platform (linux-amd64, linux-arm64, darwin-arm64; `--here` builds `-<platform>` ones for this host only), and `lez_msig_module-<its version>-linux-amd64.lgx` and `lez_msig_v04_module-<its version>-linux-amd64.lgx`, the private LEZ multisig's provers for LEZ v0.3 and v0.4 (optional; since 0.3.3 and 0.4.0) | someone who already runs Basecamp, or `logoscore` | the portable packages. Basecamp installs them from Muster's catalogue (`catalog/`, [`docs/runbooks/install-from-catalogue.md`](docs/runbooks/install-from-catalogue.md)) and fetches the dependencies from Logos Official; `lgpm install --file` installs them by hand. |

Both are built from the same commit, and the AppImage contains exactly the four `.lgx` files the release publishes (their linux-amd64 parts).

## Cut one

1. **Version.** Bump `"version"` in `module/metadata.json` and `ui/metadata.json` (both the same), merge it, and update a clean local `main`.
2. **Green.** `module/tests/run-suite.sh` and `scripts/ui-parity.sh` (`MUSTER_FLEET=local` needs no fleet; the split test needs foundry on `PATH`, e.g. `nix shell nixpkgs#foundry`).
3. **The packages and the catalogue.** `scripts/catalog-release.sh`. The release targets this commit, so it must be on GitHub.
   - **Every platform by default** (exo-04f). `muster_module` and `muster_ui` come from the `lgx variants` workflow's build of this commit: `linux-amd64`, `linux-arm64` and `darwin-arm64`, merged into one `.lgx` per package ([`docs/design/platforms.md`](docs/design/platforms.md)). When no run built this commit, the script dispatches one on its branch and waits for it (about 20 minutes). `--from-run <id>` names a run.
   - **`lez_msig_module` and `lez_msig_v04_module`** are built here, for `linux-amd64` only. Their build needs risc0's recursion circuit (`744b999f…8849.zip`); since 2026-11-23 risc0's bucket answers 403, and the flakes fall back to the copy attached to `muster-v0.4.0` (exo-ba5). Keep that asset on that release.
   - **Output.** Everything goes into `.run/catalog-release/muster-v<version>/`, and the script writes `catalog/index.json` and `catalog/icons/`.
   - **`--here`** builds the two packages on this machine, for its platform only.
4. **The AppImage, from those same files.**

   ```bash
   scripts/release-appimage.sh --lgx-dir .run/catalog-release/muster-v<version>
   ```

   It downloads the Basecamp release named in `infra/basecamp/release-<tag>.env` and checks its sha256. It then installs the two `.lgx` files and the Logos Official packages pinned in `infra/basecamp/bundle-<tag>.tsv`, each checked against its sha256, into the release's built-in module and plugin directories, with the `lgpm` that release links. Finally it repacks the image behind the release's own AppImage runtime, as `.run/appimage/Muster-<version>-Basecamp-<tag>-linux-x86_64.AppImage`.
5. **Look at it.** Run it with a fresh profile, on a display or under Xvfb:

   ```bash
   .run/appimage/Muster-*.AppImage --user-dir "$(mktemp -d)"
   ```

   ✓ Muster is in Basecamp's app list with nothing to install. Launch it: Needs you renders, **Start something** opens a room, and the log has `Successfully loaded UI module: muster_ui` and no `muster_ui` QML errors. `APPIMAGE_EXTRACT_AND_RUN=1` avoids needing FUSE.
6. **Publish.** This is outward-facing: it puts binaries on the public repo.

   ```bash
   gh release create muster-v<version> --target <commit> --title "Muster <version>" --notes-file <notes> \
     .run/catalog-release/muster-v<version>/*.lgx \
     .run/appimage/Muster-<version>-Basecamp-<tag>-linux-x86_64.AppImage
   ```

7. **Catalogue.** Commit `catalog/index.json` and `catalog/icons/` to `main` only after the assets are up, because Basecamp offers whatever the index names.

## Moving to a newer Basecamp

Add `infra/basecamp/release-<tag>.env` (the AppImage URL and sha256, the design-system rev, and the `lgpm` rev from that release's `flake.lock`). Add `infra/basecamp/bundle-<tag>.tsv`: the dependencies Basecamp's Package Manager would install for Muster from the Logos Official index, closed over their own dependencies, each with its sha256. Then point `scripts/release-appimage.sh` and `scripts/ui-lint.sh` at the new env file.

## Caveats

- **What is checked where.** The AppImage was run on the build machine (bugger), with a fresh profile under Xvfb. Its portability is Basecamp's: Muster adds only portable packages, the same ones a catalogue install puts in a profile.
- **Updating inside the AppImage.** The baked-in Muster is part of the image. A newer Muster from the catalogue installs into the profile beside it; to move a person to a new Muster, ship a new AppImage.
- **Retired:** the `v0.1.0-demo` and `v0.2.0-demo` AppImages were built from a local Basecamp checkout with uncommitted bake-in edits (`make appimage`). They cannot share a room with today's builds. Neither can any release before 0.5.0, which signs every frame on a room's wire.
