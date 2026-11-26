# Muster on every platform Basecamp ships on

**As of 2026-10-15 (exo-b89); darwin-arm64 2026-10-16.** What it takes to build Muster for each platform Basecamp
0.3.2 is released for, and what is left for the ones not built yet. The code and the
workflow win over this page.

## How a package carries a platform

A `.lgx` is a container of native builds, one directory per platform under `variants/`, and
Basecamp installs the one matching its own platform. Both of Muster's packages are native:
`muster_module` is Nim compiled into a shared library, and `muster_ui` carries a compiled C++
Qt plugin beside its QML. So a package with no variant for a platform cannot be installed
there at all.

Basecamp 0.3.2 is released for four platforms, and the official catalogue builds for the
same four (`logos-co/logos-modules-release-action`, `release.yml@v1.9`):

| Platform | Basecamp 0.3.2 | Muster |
|---|---|---|
| `linux-amd64` | AppImage | built since the first release |
| `linux-arm64` | AppImage (aarch64) | **built** by `.github/workflows/lgx-variants.yml` on `ubuntu-24.04-arm` (exo-b89) |
| `darwin-arm64` | `.dmg` (aarch64) | **built** by the same workflow on `macos-latest` (PR #321, 2026-10-17), and checked by hand on a Mac (below); served by the catalogue since 0.3.4 |
| `windows-x86_64` | `setup.exe` | not built; mapped below |

## How the variants are built and released

`.github/workflows/lgx-variants.yml` builds `.#lgx-portable` for each package natively on
each platform's GitHub runner. It checks that each build is tagged with the variant it is
for, then merges each package's variants into one `.lgx` with `lgx merge`. It runs on pull
requests that touch `module/` or `ui/`, on `v*` tags, and by hand. It publishes nothing: its
`lgx-merged` artifact holds `muster_module.lgx` and `muster_ui.lgx`.

`scripts/catalog-release.sh --from-run <run id>` takes those packages into a release. The
run must be that workflow, it must have succeeded, and it must have built exactly HEAD.
Each package's manifest must carry every variant the workflow builds. The assets are named
`<package>-<version>.lgx`, as the official catalogue names its own. Without `--from-run`,
the script builds this host's variant locally; a release carries `linux-amd64`, so one built
on any other host is refused (`--local` stays open, e.g. for a Mac to test its own build).

Adding a platform means: the flake builds it; a matrix row for it in the workflow, and the
merge job's expected variant count; the platform added to the `--from-run` `PLATFORMS` in the
release script; and, for local builds there, its spelling in `lgx_variant`
(`scripts/lib/portable.sh`).

## What Muster depends on, per platform

Each dependency's newest version in the official catalogue index, 2026-10-15:

| Package | Muster needs it | linux-amd64 | linux-arm64 | darwin-arm64 | windows-x86_64 |
|---|---|---|---|---|---|
| delivery_module | required | ✓ | ✓ | ✓ | ✓ |
| lez_core | required (module and ui) | ✓ | ✓ | ✓ | **✗** |
| keystore_module, eth_rpc_module, tx_sender_module, fee_module | required | ✓ | ✓ | ✓ | ✓ |
| liblogos_lez_rln_module | required (ui) | ✓ | ✓ | ✓ | **✗** |
| liblogos_rln_module | required (ui) | ✓ | ✓ | ✓ | ✓ |
| verified_proxy_module | optional | ✓ | ✓ | ✓ | ✓ |
| libp2p_module | optional (via delivery) | ✓ | ✓ | ✓ | ✗ |
| monero_wallet_backend and its modules | optional | ✓ | ✓ | ✓ | ✓ |

linux-arm64 and darwin-arm64 have every dependency. Windows lacks two that Muster requires.

## darwin-arm64: checked on a Mac

Checked on macOS 26.5 (Apple Silicon) with Basecamp 0.3.2's `aarch64` DMG, 2026-10-15/16, on
Muster 0.3.0 (`15f7dc2`) and 0.3.1. The steps this page listed:

1. **libsodium was already bundled.** The concern was that it would resolve through its
   absolute `/nix/store` install name. It does not: the portable bundle's `nix-bundle-dir`
   copies `libsodium.26.dylib` beside the plugin and rewrites the reference to
   `@loader_path/./libsodium.26.dylib`, as it does for OpenSSL and Boost. No load command or
   rpath in either package names `/nix/store` (`otool -L`, `otool -l`). The plugin links as
   the catalogue's `blockchain_module` 0.3.2 does, with Qt and `libintl` resolving on
   `@rpath` to the app's `Contents/lib → Frameworks`. So macOS needs no static libsodium. A
   static one would still let the module drop the fork's Linux-only RUNPATH commit (#226,
   R8), and Windows needs one (below).
2. **The matrix row** is `darwin-arm64` on `macos-latest`, with the official action's "Ensure
   Metal Toolchain" step (both packages built on a Mac with the Command Line Tools alone, no
   `metal`, so it should find nothing to do). The build step parses under macOS's
   `/bin/bash` 3.2, which is what `shell: bash` runs there: no `$(case …)`, and empty arrays
   as `${a[@]+"${a[@]}"}`. It was run locally with this leg's values. The merge job expects
   three variants.
3. **The fork's Nim link line on Apple** builds and loads. The plugin's protocol stamp is
   `0.2.0`, and it defines the 0.2 export set as on Linux, with nothing undefined
   (`nm -u … | grep _logos_module_` is empty). That matters on macOS, where
   `-undefined dynamic_lookup` would otherwise hide a missing export until load.
4. **The test harness.** `module/tests/run-suite.sh` runs on a Mac: 262 passed, 0 failed for
   Muster 0.3.1, 2026-10-16. Two tests needed fixing for it:
   - `rpc_budget_test`'s SYN-dropping fixture, because macOS does not read `listen(0)` as a
     one-slot queue;
   - `host_return_harness`'s `main`, whose `void*` argv clang refuses.

   `tests/probes/config.nims` and the grader path of `probe_return_marshalling_host` still
   look for `libsodium.so`. `scripts/grade-specs.sh` has not been run on a Mac.
5. **Acceptance, so far.**
   - **Basecamp, 0.3.0 build.** Installed with the macOS lgpm 0.3.1 release into a
     `--user-dir` profile of the DMG, with `infra/basecamp/bundle-0.3.2.tsv`'s dependencies:
     Needs you rendered, a room opened live, and a message sent.
   - **logosctl 0.3.2's macOS build.** `muster_module` 0.3.0 and 0.3.1 loaded, and `health`
     answered `ok`.
   - **A merged package.** One carrying `darwin-arm64` and `linux-amd64` (0.3.0) installed
     its `darwin-arm64` variant.
   - **The workflow's macOS leg** runs on GitHub's runner since PR #321 (2026-10-17).
   - **Not yet:**
     - a room between a Mac and a Linux instance, as R6 did
       (`docs/labbook/muster-in-basecamp-031.md`);
     - the 0.3.1 `muster_ui` in Basecamp.

How to build and check it on a Mac: [`docs/runbooks/macos.md`](../runbooks/macos.md).

## windows-x86_64: what is left

Larger, and it rests on two things outside Muster's code.

1. **The builder.** Neither builder Muster pins has a Windows path:
   - `module/` pins the fork `corpetty/logos-module-builder@c10a94c`;
   - `ui/` pins `logos-co/logos-module-builder@4717b9a`.

   Upstream builders since then do: `lib/resolvePlatforms.nix`, and a mingw
   `packages.x86_64-windows` built from Linux, which is how the official catalogue builds
   Windows (`.#packages.x86_64-windows.lgx-portable`). The fork's three Nim commits
   (`nim.packages`, `nim c --app:staticlib`, the link line) would need to move onto it. That
   is R8 (`exo-d4d.8`: Muster leaves the forked builder), so **Windows waits on R8.**
2. **Nim cross-compiles to mingw.** The fork runs the native `nim c --app:staticlib`; Windows
   needs `--os:windows --cpu:amd64` with the mingw gcc. On the link line,
   `pthread dl m` becomes `ws2_32 bcrypt advapi32`, since chronos needs Winsock.
3. **libsodium for mingw:** a static `pkgsCross.mingwW64.libsodium`. (macOS needed none:
   its portable bundle carries the dylib; see darwin step 1.)
4. **Two required dependencies have no Windows build:** `lez_core` and
   `liblogos_lez_rln_module`. Either:
   - upstream builds them for Windows; or
   - Muster declares them optional there and hides what needs them (the LEZ wallet, the
     private split, LEZ multisig and FROST on LEZ). `modules_state` already shows how Muster
     runs without a module.

   This is a product decision, not a build fix.
5. **Code, small:**
   - `module/src/transport/delivery.nim:114` imports `stderr` from `<stdio.h>` as a variable.
     Under mingw it is a macro, so use Nim's own `stderr`.
   - `module/src/crypto/keystore.nim:278` sets the keyfile owner-only with
     `setFilePermissions`. On Windows that only toggles read-only, so the keyfile would be
     readable by other local users unless an ACL is set. This is a security gap; fix it
     before shipping Windows, not after.
   - The default data directory falls back to the temp directory when the host gives no
     persistence path (`muster_module.nim`, `MUSTER_DATA_DIR`). The hosts always give one,
     but the fallback is wrong everywhere.
6. **The ui plugin.** The C++ is portable Qt (no POSIX calls, no `Q_OS` branches), so it
   needs only the builder's Windows path from step 1.
7. **Acceptance:** Basecamp's `setup.exe` on Windows, with a room against a Linux instance.

Estimate: medium, after R8 and the LEZ decision.

## What stays Linux-only

Linux-only on purpose:
- the AppImage release (`scripts/release-appimage.sh`, `make appimage`);
- the hands-on scripts that unpack it (`basecamp-profile.sh`, `basecamp-local-catalogue.sh`,
  `demo-peer.sh`);
- the `systemd-run` memory cap in the `Makefile`.

People on macOS and Windows install Muster from its catalogue
(`docs/runbooks/install-from-catalogue.md`) into the Basecamp they already run.
