# Installing Muster from a catalogue (exo-dcc.3)

Status: **proposal, 2026-10-08.** It comes from reading only; nothing in it has been built. *(unverified)* marks what still needs checking. Part of the Monero plan (`docs/design/monero-in-rooms.md`, Phase 1).

The goal: a stranger adds a catalogue, installs Muster, and its dependencies resolve. Today none of that is possible:
- there is no current public binary (the v0.2.0-demo AppImage is wire-incompatible);
- Muster is in no catalogue;
- a local `.lgx` install resolves no dependencies, so about 13 packages are installed by hand first.

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
- Because the highest version wins across catalogues, a catalogue could shadow an official package. Ours must publish only `muster_*` names, and the install page says so.
- Signatures add nothing until a client acts on them.

## 3. Recommended path

Run our own catalogue now, for linux-amd64. **The forked builder does not block it:**
- the module built on the fork loads in Basecamp 0.3.1 and 0.3.2;
- the release tooling builds `.#lgx-portable`, which `scripts/basecamp-profile.sh` already runs.

**What the fork does break.** Its bundler (`nix-bundle-lgx` b49074a) copies `dependencies` into the manifest but drops `optional_dependencies` and `provides`; the current bundler (c8c4659) copies all three. Until that is fixed, an optional dependency never reaches an installed manifest.

| # | Step | Effort | Blocked by |
|---|---|---|---|
| 1 | **Metadata.** <br>• A version range on every dependency (`delivery_module ~0.3.2`, `lez_core ~0.5.0`, the EVM modules `~0.1.0`, the RLN modules at their tested versions). <br>• `muster_ui` depends on the exact `muster_module` release, so the pair can't drift apart. <br>• Bump both versions together. <br>• Replace the "loading spike" descriptions the install dialog shows. | ½ d | Whether the fork embeds dependency objects and the 0.3.2 gate reads them *(unverified)* |
| 2 | **The catalogue repo, Forum-style.** <br>• `logos-repo.json` plus an `index.json` built with `logos-modules-release-tool/index.py add --with-local`. <br>• The `.lgx` files as release assets, built locally as `basecamp-profile.sh` builds them. <br>• `run-suite.sh` and `ui-parity.sh` before each release. | ½–1 d | — |
| 3 | **Acceptance.** <br>• Two fresh 0.3.2 profiles: add the URL → install Muster. <br>• Dependencies come from the official catalogue; nothing is installed by hand. <br>• A `--catalog` mode for `basecamp-profile.sh`. | 1 d | Cross-catalogue resolution, seen on screen *(unverified for Muster)* |
| 4 | **Campaign install page.** <br>• The URL, plus the `basecamp://app/muster_ui` and `basecamp://intent/basecamp.repositories.manage` links. <br>• What to untick. <br>• The trust statement from §2. | ½ d | exo-dcc.2 (which network) |
| 5 | **CI.** <br>• The release template plus the action. <br>• `modules.txt` naming `module` and `ui`. <br>• linux-amd64 and linux-arm64. <br>• Committed flake locks for release builds. | 1–3 d | exo-1ec.2. Whether a hosted runner can build the forked SDK set *(unverified)* |
| 6 | **exo-d4d.8.** <br>• The current module ABI. <br>• Off the forked builder. <br>• logos-module-builder#226. | 3–5 d + upstream review | #226, open with no review since 2026-09-02 |
| 7 | **darwin-arm64.** | 2–5 d + a Mac | Step 5. The Nim cdylib has never been built on darwin |

Steps 1–4 give strangers an installable Muster within about a week, whatever happens with steps 5–7.

## 4. What a stranger still meets

- **Linux x86_64 only.** Elsewhere Muster shows as "Not Available".
- **A paste, then a click.** No deep link carries a repository URL.
- **Pre-ticked optional packages.** For example, `monero_node_module` brings `monerod_module`, a full node. The page says what to untick.
- **EVM dependencies arrive even for a Monero-only participant**, unless they become optional.
- **"Use this app? Muster wants to …" on every hand-off**, never remembered.
- **An install does not start a module.** Muster's declared dependencies start when it opens. An undeclared one stays silent (exo-dcc.11).
- **A new release appears only after Refresh or a restart.** Members on different versions may not share a room, so release rarely during the campaign.
- **Everything is unsigned**, and the chooser says so.

## 5. Decisions for the operator

1. **Ask Logos to list Muster?** Recommendation: build our own catalogue regardless, and ask only for a link.
2. **The catalogue URL.** It is chosen once: strangers save it, and it is the catalogue's identity. Recommendation: a dedicated repo, e.g. `corpetty/muster-catalog`.
3. **Where releases build.** Recommendation: locally for the campaign, CI afterwards.
4. **Signing.** Recommendation: unsigned now, like everyone else; choose a publisher key before 1.0.
5. **How the Monero modules are declared.**
   - Try a bundler-only bump to c8c4659, so optional dependencies reach the manifest.
   - Otherwise required: every install pulls them in, and a Monero load failure fails Muster.
   - The card-only install works today, but the modules stay silent (exo-dcc.11).
6. **EVM dependencies:** optional in the same move, or kept required.
7. **Platforms promised.** Recommendation: "Linux x86_64".
8. **Pin our dependencies to the official catalogue** (`repositoryUrl`), so another added catalogue cannot shadow them. Supported by the resolver spec; lgpm and the load gate are *(unverified)*.

## 6. Fallback if this is blocked past ~2026-11-01

The catalogue is ours, so nobody can refuse it. What can fail, and what to do, in order:
1. **The CI build fails:** publish locally built `.lgx` files. That is already step 2.
2. **Cross-catalogue resolution fails:** list the exact dependency versions in our own index by their official release URLs. `index.py` takes any URL, and files are checked by `rootHash` *(unverified whether Basecamp shows the duplicates)*.
3. **The catalogue install is unusable:** a GitHub release with both `.lgx` files and a Linux install script cut down from `basecamp-profile.sh`.
4. **Last resort:** exo-070's AppImage, Basecamp with Muster baked in. It is heavy, blocked by SDK skew on 2026-09-17, and must be labelled as not Logos's release.

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
