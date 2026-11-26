# Muster's Basecamp catalogue

A package repository for [Logos Basecamp](https://github.com/logos-co/logos-basecamp) that serves **Muster**. To install it, add this URL in Basecamp under Settings → Package Repositories:

```
https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json
```

The steps for a person installing Muster are in [`docs/runbooks/install-from-catalogue.md`](../docs/runbooks/install-from-catalogue.md).

## What adding it trusts

- **This catalogue publishes `muster_module` and `muster_ui`, and the private LEZ multisig's two provers**: `lez_msig_module` for a LEZ v0.3 zone (since 0.3.3, exo-e77, versioned from `programs/lez-msig/metadata.json`) and `lez_msig_v04_module` for a LEZ v0.4 zone (since 0.4.0, exo-cc7, versioned from `programs/lez-msig/lez04/metadata.json`). Both are optional dependencies of `muster_module`, Linux x86-64 only; Muster calls the one its zone needs. It lists no other name. Basecamp takes the newest version of a package across every catalogue you have enabled, so a catalogue that listed `delivery_module` could replace the official one. This one never does: `scripts/catalog-release.sh` refuses to write an index that names anything else.
- **Every dependency comes from the official Logos catalogue**, which Basecamp enables by default: `delivery_module`, `lez_core`, the EVM modules, the RLN modules, and the optional Monero wallet modules.
- **Nothing is signed.** `trustedSigners` is empty, as it is in the official catalogue. Basecamp checks each download against the `rootHash` this index names, so the `.lgx` you get is the one indexed here. Nothing proves who built it.
- **Muster runs inside your Basecamp session with no sandbox.** That is true of every Basecamp module; adding a catalogue means trusting its publisher with it.
- **Platforms.** `muster_module` and `muster_ui` are built for Linux x86_64, Linux arm64 and Apple Silicon macOS (since 0.3.4). The two provers are Linux x86_64 only: elsewhere Muster runs, and a private multisig names the prover it cannot get.

## What is here

| File | |
|---|---|
| `logos-repo.json` | the repository descriptor Basecamp reads first; its `indexUrl` is `index.json` beside it, on `main` |
| `index.json` | each package version: its download URL, `rootHash`, sha256 and embedded manifest. Generated, never hand-edited. Committed only after its release assets are up |
| `icons/` | each package's icon, shown before it is installed (written beside `index.json`) |
| releases `muster-v<version>` | the `.lgx` files: `muster_module-<version>.lgx` and `muster_ui-<version>.lgx` (every platform in one; releases before 0.3.4 were `-linux-amd64` only), `lez_msig_module-<its version>-linux-amd64.lgx` and `lez_msig_v04_module-<its version>-linux-amd64.lgx` |

The format is that of the official [`logos-modules-release`](https://github.com/logos-co/logos-modules-release) catalogue, written with [`logos-modules-release-tool`](https://github.com/logos-co/logos-modules-release-tool)'s `index.py`, the way the [Logos Forum catalogue](https://github.com/edenbd1/logos-forum-catalog) publishes.

## Publishing a release

`scripts/catalog-release.sh` takes `muster_module` and `muster_ui` from CI's every-platform build of the committed tree, builds the two provers here, writes `logos-repo.json` and `index.json`, and leaves the `.lgx` files in `.run/catalog-release/muster-v<version>/`. It publishes nothing; it prints the commands. In order:

1. On a clean, up-to-date `main`, run `module/tests/run-suite.sh` and `scripts/ui-parity.sh`. Both must be green.
2. `scripts/catalog-release.sh`. The release targets this commit, so it must be on GitHub.
3. Create the GitHub release `muster-v<version>` with the four `.lgx` files and the AppImage, using the `gh release create` line the script prints ([`RELEASING.md`](../RELEASING.md) has every step).
4. Commit `catalog/index.json` and `catalog/icons/` to `main`. Basecamp sees the release once it does.

Design: [`docs/design/catalogue-install.md`](../docs/design/catalogue-install.md).
