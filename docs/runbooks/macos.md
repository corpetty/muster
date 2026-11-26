# Build and check Muster on macOS (Apple Silicon)

**As of 2026-10-16, on macOS 26.5 on Apple Silicon with Logos Basecamp 0.3.2 (the `aarch64` DMG), Muster 0.3.0 (`15f7dc2`) and 0.3.1.** Muster builds and runs on macOS from the same sources as on Linux. This page is how to build the two packages on a Mac and run them in a Basecamp profile, for maintainers and acceptance; what was checked is in [`docs/design/platforms.md`](../design/platforms.md). A person who just wants Muster installs it from the catalogue ([`install-from-catalogue.md`](install-from-catalogue.md)): every release since 0.3.4 carries `darwin-arm64`. The code wins over this page.

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

Pass `--version` for `delivery_module`, to get the one this page was checked with. Muster declares `>=0.3.2`. On 2026-10-16 the catalogue's newest was 0.4.0, which Logos Official has since withdrawn.

## Tests and releases on a Mac

- `module/tests/run-suite.sh` runs as on Linux. With no `nim` on `PATH` it takes the nim and clang the `.lgx` compiles with; see `module/tests/README.md`.
- The `Makefile`'s capped targets (`make build`, `make build-lgx`) cap with `systemd-run`, which macOS lacks, so they refuse to start there. The runner has not been built on a Mac; see `.claude/doctrine/codebase.md` § Runner builds before building one.
- `scripts/catalog-release.sh --local <dir> --base-url https://x` builds the `darwin-arm64` packages into a local catalogue, to test. A release run on a Mac is refused, since every release carries `linux-amd64`: releases come from the workflow (`--from-run`).

## Known rough edges

- **A second Basecamp's storage node.** With another Basecamp running, the profile's `storage_module` failed to start ("Failed to create Storage: Should create metadata store!"). The cause, found on Linux, is LevelDB's lock: both nodes opened `~/.logos_storage/data`. Since `ae4e62eb` (exo-4d0.2), where Muster has to start a storage node itself it keeps it to its own data folder. FileShare uses `storage_module`, and `muster_ui` lists it as a dependency since FileShare landed. The fix has not been re-checked on macOS.
- **Not yet run on macOS:** the catalogue install (releases carry the variant since 0.3.4; an install from it on a Mac is not recorded here), `scripts/ui-parity.sh` and the other offscreen self-tests (they use Xvfb), two instances in one room, and the Monero and chain-bound flows.
- **No macOS download-and-run bundle.** The AppImage has no DMG counterpart; `scripts/release-appimage.sh`, `make appimage` and `scripts/basecamp-profile.sh` are Linux only on purpose (`docs/design/platforms.md`).
