# Installing Muster from a catalogue (exo-dcc.3)

Status: **done** (exo-dcc.3, closed 2026-10-09). The catalogue is live on `main`; the current release is [`muster-v0.5.0`](https://github.com/corpetty/muster/releases/tag/muster-v0.5.0) (2026-11-24), and how to cut one is `RELEASING.md`. §1–§6 came from reading before the build; §7 records the acceptance run on screen. *(unverified)* marks what was not checked at the time. Part of the Monero plan (`docs/design/monero-in-rooms.md`, Phase 1).

The goal: a stranger adds a catalogue, installs Muster, and its dependencies resolve. When this was written (2026-10-08) none of that was possible:
- there was no current public binary (the v0.2.0-demo AppImage is wire-incompatible);
- Muster was in no catalogue;
- a local `.lgx` install resolved no dependencies, so about 13 packages were installed by hand first.

Since then Muster's own catalogue (`catalog/`) lists every `muster-v<version>` release.

## 1. How catalogues work in Basecamp 0.3.2

- **What a catalogue is.** It is the https URL of a `logos-repo.json`: `name`, `displayName`, `indexUrl`, `trustedSigners`, and an optional `includesUrl`.
  - Its `index.json` lists each package version: url, sha256, `rootHash` and the embedded manifest.
  - The `.lgx` files can live on any https host.
- **How the official catalogue publishes** (`logos-co/logos-modules-release`):
  - Each module is a submodule with a generated release workflow. That workflow calls `logos-modules-release-action/release.yml@v1.9`.
  - The action builds `.#lgx-portable` per variant: darwin-arm64, linux-amd64, linux-arm64, windows-x86_64.
  - It merges and verifies the `.lgx`, and cuts a release `<name>-v<version>` holding the `.lgx` and a `sidecar.json`.
  - `rebuild-index` rolls the sidecars into a rolling `index` release.
  - Signing is `signing_mode: none`.
- **How a person adds one.** Settings → Package Repositories → paste the URL → Add. The Package Manager's `basecamp.repositories.manage` intent opens the same view.
- **How dependencies resolve.** The resolver takes the newest version that meets the range, **across every enabled catalogue** (`logos-package-downloader` docs/spec.md, "Dependency Resolution"). So a Muster catalogue only has to publish `muster_module` and `muster_ui`; the official catalogue, enabled by default, supplies the rest.
- **What the load gate checks.** liblogos refuses to load a module whose declared range isn't met, or isn't parseable (`dependency_gate.h`). It carries a `signer` pin but does not enforce it.
- **Signatures.** None today: 0 of the official index's 118 versions carry one (fetched 2026-10-08), and `trustedSigners: []`.

## 2. Official catalogue versus our own

**The official catalogue is closed to Muster under current policy.** A Logos maintainer, closing logos-modules-release#98 on 2026-10-06: "The default catalog is only meant for apps developed by the Logos team… we expect developers to create and run their own catalog." Even if Muster counted, every campaign fix would wait on someone else's merge and dispatch.

**Our own catalogue takes about a day and releases on our schedule.** Two worked examples exist:
- **gateway-fm.** `mandrigin/logos-modules-release-base`, a fork of the release template plus the release action. Its `modules.txt` names two package subdirectories of one submodule, which is Muster's `module/` + `ui/` shape.
- **Logos Forum.** `edenbd1/logos-forum-catalog` has no CI: `index.json` is committed, and the `.lgx` files are release assets.

**Adding our catalogue asks a stranger for trust:**
- Its code runs inside their Basecamp session with no sandbox.
- Because the highest version wins across catalogues, a catalogue could shadow an official package. Ours publishes only its own names (`muster_*`, and since 0.3.3 the provers `lez_msig_*`), and the install page says so.
- Signatures add nothing until a client acts on them.

## 3. Recommended path

Run our own catalogue now, for linux-amd64. **The forked builder does not block it:**
- the module built on the fork loads in Basecamp 0.3.1 and 0.3.2;
- the release tooling builds `.#lgx-portable`, which `scripts/basecamp-profile.sh` already runs.

**What the fork does break.** Its bundler (`nix-bundle-lgx` b49074a) copies `dependencies` into the manifest but drops `optional_dependencies` and `provides`; the current bundler (c8c4659) copies all three. Until that is fixed, an optional dependency never reaches an installed manifest.

| # | Step | Effort | Blocked by |
|---|---|---|---|
| 1 | **Metadata.** <br>• A version range on every dependency (`delivery_module ~0.3.2`, `lez_core ~0.5.0`, the EVM modules `~0.1.0`, the RLN modules at their tested versions). <br>• `muster_ui` depends on the exact `muster_module` release, so the pair can't drift apart. <br>• Bump both versions together. <br>• Replace the "loading spike" descriptions the install dialog shows. | ½ d | Whether the fork embeds dependency objects and the 0.3.2 gate reads them *(unverified)* |
| 2 | **The catalogue repo, Forum-style.** <br>• `logos-repo.json` plus an `index.json` built with `logos-modules-release-tool/index.py add --with-local`. <br>• The `.lgx` files as release assets, built locally as `basecamp-profile.sh` builds them. <br>• `run-suite.sh` and `ui-parity.sh` before each release. <br>**Done 2026-10-08:** `scripts/catalog-release.sh` and `catalog/` (in this repo, by the operator's decision). Published since `muster-v0.2.0` (2026-10-09). | ½–1 d | — |
| 3 | **Acceptance.** <br>• Two fresh 0.3.2 profiles: add the URL → install Muster. <br>• Dependencies come from the official catalogue; nothing is installed by hand. <br>• A `--catalog` mode for `basecamp-profile.sh`. <br>**Done 2026-10-08, from a local https server (§7).** The `--catalog` mode is not built. | 1 d | Cross-catalogue resolution: seen on screen (§7) |
| 4 | **Campaign install page.** <br>• The URL, plus the `basecamp://app/muster_ui` and `basecamp://intent/basecamp.repositories.manage` links. <br>• What to untick. <br>• The trust statement from §2. <br>**Done:** `docs/runbooks/install-from-catalogue.md` and the site's install section. | ½ d | exo-dcc.2 (which network) |
| 5 | **CI.** <br>• The release template plus the action. <br>• `modules.txt` naming `module` and `ui`. <br>• linux-amd64 and linux-arm64. <br>• Committed flake locks for release builds. <br>**Done:** `.github/workflows/lgx-variants.yml` builds both packages on hosted runners for linux-amd64, linux-arm64 and darwin-arm64 and merges them; `scripts/catalog-release.sh` takes that build (`exo-04f`, still open as of 2026-11-26). The suite itself still has no CI job (exo-1ec.2). | 1–3 d | — |
| 6 | **exo-d4d.8.** <br>• The current module ABI. <br>• Off the forked builder. <br>• logos-module-builder#226. | 3–5 d + upstream review | #226, open with no review since 2026-09-02 |
| 7 | **darwin-arm64.** <br>**Done:** built by the same workflow; releases carry it since `muster-v0.3.4`. | 2–5 d + a Mac | — |

Steps 1–4 give strangers an installable Muster within about a week, whatever happens with steps 5–7. As of 2026-11-26 only step 6 (exo-d4d.8) is open.

## 4. What a stranger still meets

- **Linux and Apple Silicon only.** Until 0.3.4 releases carried only linux-amd64, and elsewhere Muster showed as "Not Available". Since 0.3.4 `muster_module` and `muster_ui` carry linux-amd64, linux-arm64 and darwin-arm64; windows-x86_64 is not built (`docs/design/platforms.md`). The `lez_msig_*` provers are linux-amd64 only.
- **A paste, then a click.** No deep link carries a repository URL.
- **Pre-ticked optional packages.** For example, `monero_node_module` brings `monerod_module`, a full node. The page says what to untick.
- **EVM dependencies arrive even for a Monero-only participant**, unless they become optional.
- **"Use this app? Muster wants to …" on every hand-off**, never remembered.
- **An install does not start a module.** Muster's declared dependencies start when it opens. An undeclared one stays silent (exo-dcc.11).
- **A new release appears only after Refresh or a restart.** Members on different versions may not share a room, so release rarely during the campaign.
- **Everything is unsigned**, and the chooser says so.

## 5. Decisions for the operator

What was built, as of 2026-11-26, follows each item.

1. **Ask Logos to list Muster?** Recommendation: build our own catalogue regardless, and ask only for a link. Built: our own catalogue.
2. **The catalogue URL.** It is chosen once: strangers save it, and it is the catalogue's identity. **Decided 2026-10-08: this repo.** The catalogue is `catalog/` on `main`, served raw (`https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json`), and the `.lgx` files are assets of `muster-v<version>` releases.
3. **Where releases build.** Recommendation: locally for the campaign, CI afterwards. Built: `muster_module` and `muster_ui` from CI's `lgx-variants` run (`--here` builds locally); the provers are built locally (`RELEASING.md`).
4. **Signing.** Recommendation: unsigned now, like everyone else; choose a publisher key before 1.0. Built: unsigned, `trustedSigners` empty (`catalog/README.md`).
5. **How the Monero modules are declared.**
   - Try a bundler-only bump to c8c4659, so optional dependencies reach the manifest.
   - Otherwise required: every install pulls them in, and a Monero load failure fails Muster.
   - The card-only install works today, but the modules stay silent (exo-dcc.11).

   Built: `monero_wallet_backend` is an optional dependency of `muster_module` (`module/metadata.json`).
6. **EVM dependencies:** optional in the same move, or kept required. Built: kept required (`keystore_module`, `eth_rpc_module`, `tx_sender_module`).
7. **Platforms promised.** Recommendation: "Linux x86_64". Built: linux-amd64, linux-arm64 and darwin-arm64 since 0.3.4 (step 7).
8. **Pin our dependencies to the official catalogue** (`repositoryUrl`), so another added catalogue cannot shadow them. Supported by the resolver spec; lgpm and the load gate are *(unverified)*. Not built: no dependency carries a `repositoryUrl`.

## 6. Fallback if this is blocked past ~2026-11-01

Not needed: the catalogue shipped on 2026-10-09. Kept as written.

The catalogue is ours, so nobody can refuse it. What can fail, and what to do, in order:
1. **The CI build fails:** publish locally built `.lgx` files. That is already step 2.
2. **Cross-catalogue resolution fails:** list the exact dependency versions in our own index by their official release URLs. `index.py` takes any URL, and files are checked by `rootHash` *(unverified whether Basecamp shows the duplicates)*.
3. **The catalogue install is unusable:** a GitHub release with both `.lgx` files and a Linux install script cut down from `basecamp-profile.sh`.
4. **Last resort:** exo-070's AppImage, Basecamp with Muster baked in. It is heavy, blocked by SDK skew on 2026-09-17, and must be labelled as not Logos's release.

## 7. Acceptance, 2026-10-08 (step 3)

**Result: a stranger's install works.** In fresh Basecamp 0.3.2 profiles, each with its own `--user-dir` and `HOME`, adding Muster's catalogue and installing Muster resolved every dependency from the official catalogue, with nothing installed by hand, and Muster opened. The stranger-facing steps are `docs/runbooks/install-from-catalogue.md`.

**Setup.**
- `scripts/catalog-release.sh --local <dir> --base-url https://127.0.0.1:8743` built both packages from `9823a2e` and wrote the catalogue: `muster_module` rootHash `c87e7cbf…`, `muster_ui` rootHash `8095d444…`.
- A Python https server served `<dir>` with a throwaway CA. Basecamp ran under Xvfb with `SSL_CERT_FILE` set to the system bundle plus that CA.

**Basecamp needs https.** `http://127.0.0.1:8743/logos-repo.json` is refused on Add: "unsupported URL scheme (https required in v1)". The same rule covers every download.
- In logos-package-downloader @a539fbb (the rev 0.3.2 locks), `RepositoryRegistry::addRepository` and `refreshOne` require `https://`.
- `HttpsFetcher::canHandle` accepts only `https://` for downloads.
- `RepositoriesView.qml` does no checking of its own.
- The downloader reads `CURL_CA_BUNDLE`, `SSL_CERT_FILE` or `NIX_SSL_CERT_FILE`, in that order, before the system bundle. So a local https server with its own CA is the way to test a catalogue before publishing; no code changes.

**What resolved.** Every installed manifest's `hashes.root` matches the index that lists it.
- **From Logos Official:** `delivery_module` 0.3.2, `lez_core` 0.5.0, `keystore_module` 0.1.0, `eth_rpc_module` 0.1.0, `fee_module` 0.1.0, `tx_sender_module` 0.1.0, `liblogos_lez_rln_module` 4.2.1 and `liblogos_rln_module` 0.10.0 (`muster_ui`'s plain-name dependencies). The optional `libp2p_module` 1.1.0, `verified_proxy_module` 0.1.3, `monero_wallet_backend` 0.1.1, `monero_node_module` 0.1.1 and `monero_wallet_core_module` 0.1.1.
- **From Muster's catalogue:** only `muster_module` and `muster_ui`. The local server was asked for nothing but `logos-repo.json`, `index.json` and the two `.lgx` files: 16 requests from three profiles and one manual check, all 200. No request came for the icon sidecar.
- **`modules_state`** is not in the official catalogue. Basecamp 0.3.2 ships it, and the dialog shows it ticked and INSTALLED.
- **`monerod_module`**, pre-ticked as `monero_node_module`'s optional dependency, was unticked as the runbook says, and stayed out.
- The log's install plan: `Install plan for "muster_ui" — needs: delivery_module, lez_core, keystore_module, eth_rpc_module, fee_module, tx_sender_module, muster_module, liblogos_lez_rln_module, liblogos_rln_module, muster_ui, libp2p_module, monero_node_module, monero_wallet_core_module, monero_wallet_backend, verified_proxy_module`.
- Each install: `Downloaded "delivery_module" from "https://github.com/logos-co/logos-modules-release/releases/download/delivery_module-v0.3.2/…"` … `Downloaded "muster_module" from "https://127.0.0.1:8743/muster_module-0.2.0-linux-amd64.lgx"`. Some official packages came over Logos Storage instead (`from "logos:logos.test:…"`).
- **On opening Muster:** `Loading core dependencies for "muster_ui"`, then `Module loaded:` for each, ending with `Module loaded: muster_module`. Home reads "Nothing waiting on you" / "Set up an Ethereum account".

**Three ways in, three results.**
1. **`basecamp://app/muster_ui`** (profile 1). It was forwarded to the running instance by a second process with `--uri`, which is what the registered handler runs. Basecamp asked "Install an app for this? muster_ui can handle this, but it is not installed yet" → Install. That opens Applications' **Add Application** dialog for Muster: 658.7 MB, 10 required packages, the optional ones pre-ticked. Install → **Launch** about nine minutes later.
2. **Applications → search `muster` → Muster** (profile 3). The same dialog. Seen, not installed again.
3. **Package Manager → search `muster` → Muster → INSTALL** (profile 2). The **Install Package?** dialog names each package's catalogue (`delivery_module (Logos Official)`, `muster_module (Muster)`). It failed twice with **Install Failed: Download failed**, nothing installed:
   - The Package Manager fetches the whole set in one `downloadResolvedDependenciesAsync` call, with one five-minute deadline (`DOWNLOAD_TIMEOUT_MS = 300000`, logos-package-manager-ui @8b67bf0).
   - The default download source, Any, tries Logos Storage first, and stalled storage fetches waited 60–120 s each before falling back to GitHub.
   - The third try, with Download source set to **HTTP only**, finished in 4 min 50 s, just inside the limit.
   - Applications goes through Basecamp's own `PackageCoordinator`, which downloads one package per call with five minutes each. It is the path the runbook gives.

**Other findings.**
- **The registered handler cannot reach a profile.** Basecamp writes `~/.local/share/applications/logos-basecamp.desktop` with `Exec=… --uri=%u` and no `--user-dir`, so a clicked link reaches only the default profile.
- **xdg was not tested.** `xdg-open` is not installed on this host. The test drove the same entry point the handler runs.
- **The extracted AppImage writes the wrong `Exec` path.** Under the extracted AppImage (no `$APPIMAGE`), the entry points at the squashfs `.LogosBasecamp.elf`.
- **The dialog's size doesn't track the selection.** It stays 658.7 MB after unticking.
- **The link prompt shows the package name**, "muster_ui", not "Muster".
- **Every package is unsigned, ours and the official ones alike.** The package manager logs `Warning: Package is unsigned: …` for all 15 and installs them.

**What publishing needed** (as of 2026-10-08; done for `muster-v0.2.0` on 2026-10-09). The current procedure is `RELEASING.md`.
1. Run `scripts/catalog-release.sh` on a clean `main`.
2. `gh release create muster-v0.2.0` with the two `.lgx` files; the script prints the command.
3. Commit `catalog/index.json` and `catalog/icons/` to `main`.

Until step 3, the committed `catalog/logos-repo.json` pointed at an index that did not exist. Add still succeeded, because it fetches only `logos-repo.json` (`refreshOne`), but the catalogue then listed no packages.

## Sources

- **The official catalogue.**
  - Policy: logos-modules-release#98 (comment of 2026-10-06).
  - Layout: logos-co/logos-modules-release @7eb9ac0 (`logos-repo.json`, `_release-module.yml`, `rebuild-index.yml`).
- **Release tooling.**
  - logos-modules-release-base README.
  - logos-modules-release-action README and `release.yml@v1.9`.
  - logos-modules-release-tool (`index.py`).
- **Third-party catalogues.** mandrigin/logos-modules-release-base; gateway-fm/lez-atomic-swaps README; edenbd1/logos-forum-catalog.
- **Platform internals.**
  - logos-package-downloader docs/spec.md @5f394fa.
  - logos-basecamp 0.3.2 (`RepositoriesView.qml`, `ShellIntents.h`, `MainUIBackend.cpp`, `docs/app-to-app-intents.md`).
  - nix-bundle-lgx bundle.sh @b49074a and @c8c4659.
  - logos-liblogos `dependency_gate.h` @00f19ef.
- **The logos-module-atlas plugin.** `guides/compatibility.md`, `guides/calling-official-modules.md`, `stacks/platform.md`.
