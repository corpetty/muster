# Build and check Muster on macOS (Apple Silicon)

**As of 2026-10-16, on macOS 26.5 on Apple Silicon with Logos Basecamp 0.3.2 (the `aarch64` DMG), Muster 0.3.0 (`15f7dc2`) and 0.3.1.** Muster builds and runs on macOS from the same sources as on Linux. This page is how to build the two packages on a Mac and run them in a Basecamp profile, for maintainers and acceptance; what was checked is in [`docs/design/platforms.md`](../design/platforms.md). A person who just wants Muster installs it from the catalogue ([`install-from-catalogue.md`](install-from-catalogue.md)) once a release carries `darwin-arm64`. The code wins over this page.

## What you need

- **A Mac with Apple Silicon.** An Intel Mac (`darwin-amd64`) is untested, and no Logos Official package ships that variant.
- **Logos Basecamp 0.3.2**, the `-aarch64.dmg` from [its releases](https://github.com/logos-co/logos-basecamp/releases/tag/0.3.2), in `/Applications`.
- **[Nix](https://nixos.org/download) with flakes.** The Determinate Systems installer turns flakes on: `curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install`. It asks for your password.
- **About 15 minutes.** On 2026-10-15 a first build took about 6 minutes for `muster_module` and 3 for `muster_ui`, with nothing cached beyond `cache.nixos.org`. An untrusted Nix user (the installer's default) ignores the `--extra-substituters https://cache.nix.logos.co/public` the Makefile passes, so the Logos parts build from source; that is still quick.

## 1. Build the two packages

From the repository root. A `git+file` build reads the git-tracked files: uncommitted edits to them are included, untracked files are not. (`scripts/catalog-release.sh` also refuses a dirty `module/` or `ui/`.) Commit, or at least `git add`, anything new first.

```bash
nix build "git+file://$PWD?dir=module#lgx-portable" --no-eval-cache -o .run/mac/module-lgx
nix build "git+file://$PWD?dir=ui#lgx-portable" --no-eval-cache \
  --override-input muster_module "git+file://$PWD?dir=module" -o .run/mac/ui-lgx
```

Each `.lgx` carries one variant, `darwin-arm64`. `lgx manifest <file> --json` shows it under `main`.

**Check it before you trust it.** macOS links a module with `-undefined dynamic_lookup`, so a missing symbol fails when the module loads, never at build time. Load it (step 3, or the headless check below) rather than taking a green build as proof. To look at the plugin itself:

```bash
d=$(mktemp -d); tar -xzf .run/mac/module-lgx/*.lgx -C "$d"
otool -L "$d/variants/darwin-arm64/muster_module_plugin.dylib"   # every non-system library is @loader_path/… or @rpath/…
nm -u "$d/variants/darwin-arm64/muster_module_plugin.dylib" | grep _logos_module_   # prints nothing
```

The plugin links as the Logos Official `blockchain_module` 0.3.2 does. Its own libraries (libsodium, OpenSSL, Boost) sit beside it as `@loader_path`. Qt and `libintl` resolve through `@rpath` to what Basecamp ships in `Contents/lib → Frameworks`. Its protocol stamp is `0.2.0`, the same as the Linux build.

## 2. Install them in a Basecamp profile

A local install resolves no dependencies, so the Logos Official packages Muster needs go in first. `infra/basecamp/bundle-0.3.2.tsv` pins them, each with its sha256: they are what the release AppImage carries, and every one of them ships a `darwin-arm64` variant. `lgpm` is the macOS build of the release Basecamp 0.3.2's Package Manager links (0.3.1).

```bash
B=.run/basecamp; P=$PWD/$B/mac; mkdir -p "$B/catalog-0.3.2" "$B/tools"
curl -sSfL -o "$B/tools/lgpm.tar.gz" \
  https://github.com/logos-co/logos-package-manager/releases/download/0.3.1/lgpm-aarch64-macos.tar.gz
echo "ce8750707abc813b84e980d5251e5c22280dcbe6f78b8a65a2d9da081002b1d8  $B/tools/lgpm.tar.gz" | shasum -a 256 -c
tar -xzf "$B/tools/lgpm.tar.gz" -C "$B/tools"; LGPM=$B/tools/lgpm-aarch64-macos/bin/lgpm
grep -v '^#' infra/basecamp/bundle-0.3.2.tsv | while IFS=$'\t' read -r pkg url sha; do
  curl -sSfL -o "$B/catalog-0.3.2/$pkg.lgx" "$url"
  echo "$sha  $B/catalog-0.3.2/$pkg.lgx" | shasum -a 256 -c
done
inst() { "$LGPM" --modules-dir "$P/modules" --ui-plugins-dir "$P/plugins" --allow-unsigned install "$@"; }
inst --dir "$B/catalog-0.3.2"
inst --file .run/mac/module-lgx/*.lgx
inst --file .run/mac/ui-lgx/*.lgx
```

`lgpm … list` then names ten packages: the eight dependencies, `muster_module` and `muster_ui`. The lgpm digest above is the one GitHub publishes for the release asset.

## 3. Run it

```bash
/Applications/LogosBasecamp.app/Contents/MacOS/LogosBasecamp --user-dir "$P"
```

Click **M** in the sidebar. ✓ on 2026-10-15, with the 0.3.0 build: the log had `Module loaded: muster_module`, Needs you rendered with the Getting started list, **Start something → Just talk → Open the room** opened a room that read **live**, and a message sent in it showed in the room.

The profile is its own: its keys, chains and Muster identity live under `$P`, and your everyday Basecamp is untouched. It can run beside a Basecamp you already have open.

## Headless check, without Basecamp

`logosctl` 0.3.2 ships an `aarch64-macos` build ([release](https://github.com/logos-co/logos-logoscore-cli/releases/tag/0.3.2)). In a throwaway session:

```bash
export LOGOSCTL_CONFIG_DIR=$(mktemp -d)
printf '{}\n' | logosctl daemon config set -
logosctl daemon start --detach && logosctl catalog refresh
logosctl package install .run/mac/module-lgx/*.lgx --yes
for p in lez_core keystore_module eth_rpc_module tx_sender_module; do logosctl package install $p --yes; done
logosctl package install delivery_module --version 0.3.2 --yes
logosctl module load muster_module && logosctl call muster_module health     # "result":"ok"
logosctl daemon stop
```

Pass `--version` for `delivery_module`: installed by name, it takes the catalogue's newest (0.4.0), not the `~0.3.2` Muster declares.

## Tests and releases on a Mac

- `module/tests/run-suite.sh` runs as on Linux. With no `nim` on `PATH` it takes the nim and clang the `.lgx` compiles with; see `module/tests/README.md`.
- The `Makefile`'s capped targets (`make build`, `make build-lgx`) cap with `systemd-run`, which macOS lacks, so they refuse to start there; `BUILD_MEM=` builds uncapped (see `.claude/doctrine/codebase.md` § Runner builds first). **The runner does not build on a Mac yet.** On 2026-10-22 (macOS 26.5, Command Line Tools, no Xcode) `BUILD_MEM= make build` ran 1 h 28 min from cold and stopped in lez_core 0.5.0's Rust dependencies (`logos-execution-zone-wallet-ffi-deps`): `risc0-sys` 1.5.0's build script runs `xcrun --sdk macosx metal`, the Command Line Tools have no Metal compiler (`unable to find utility "metal"`), and `risc0-build-kernel` panics "Could not build metal kernels". `libmuster_module`, the `muster_ui` plugin and `logos-standalone-app` had built by then. Whether a full Xcode's Metal toolchain is enough is not tried.
- `scripts/catalog-release.sh --local <dir> --base-url https://x` builds the `darwin-arm64` packages into a local catalogue, to test. A release run on a Mac is refused, since every release carries `linux-amd64`: releases come from the workflow (`--from-run`).

## Known rough edges

- **A second Basecamp's storage node.** With another Basecamp running, the profile's `storage_module` failed to start ("Failed to create Storage: Should create metadata store!"). Muster does not use it, and nothing else was affected. The cause was not looked into.
- **Not yet run on macOS:** the catalogue install (no release carries the variant), `scripts/ui-parity.sh` and the other offscreen self-tests (they need the runner, above; `scripts/lib/ui-build.sh` launches and cleans up there since voice notes' S9, and `MUSTER_UI=dev` and `scripts/ui-screenshot.sh` need Xvfb), two instances in one room in Basecamp's window or in runners, and the Monero and chain-bound flows. Headless, it has run: on 2026-10-22 three logosctl 0.3.2 hosts, each its own daemon, joined one room on `logos.dev`, the two joiners asking and being admitted, and passed a voice note from one to another, with no UI (`docs/design/voice-notes.md` §15). Headless, nothing sends a join request again for you: send `coordinate_request_join` every few seconds, as the UI does every 3 s. Sent once, it was not admitted in 180 s; sent every 3 s, in about 7 s.
- **`scripts/ui-parity.sh` needs bash 4 or later**, for its associative arrays, and macOS's only bash is `/bin/bash` 3.2. It refuses that bash (exit 2; before, it failed on its first table and exited 0 having run nothing), so on a Mac run it as `nix shell nixpkgs#bash -c scripts/ui-parity.sh`; under it, each self-test also runs on that bash. `scripts/voice-self-test.sh` has run under 3.2 itself, against a stand-in runner; the others have not been tried there.
- **No macOS download-and-run bundle.** The AppImage has no DMG counterpart; `scripts/release-appimage.sh`, `make appimage` and `scripts/basecamp-profile.sh` are Linux only on purpose (`docs/design/platforms.md`).
