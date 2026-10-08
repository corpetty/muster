# Muster's Basecamp catalogue

A package repository for [Logos Basecamp](https://github.com/logos-co/logos-basecamp) that serves **Muster**. To install it, add this URL in Basecamp under Settings → Package Repositories:

```
https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json
```

The steps for a person installing Muster are in [`docs/runbooks/install-from-catalogue.md`](../docs/runbooks/install-from-catalogue.md).

## What adding it trusts

- **This catalogue publishes two packages: `muster_module` and `muster_ui`.** It lists no other name. Basecamp takes the newest version of a package across every catalogue you have enabled, so a catalogue that listed `delivery_module` could replace the official one. This one never does: `scripts/catalog-release.sh` refuses to write an index that names anything else.
- **Every dependency comes from the official Logos catalogue**, which Basecamp enables by default: `delivery_module`, `lez_core`, the EVM modules, the RLN modules, and the optional Monero wallet modules.
- **Nothing is signed.** `trustedSigners` is empty, as it is in the official catalogue. Basecamp checks each download against the `rootHash` this index names, so the `.lgx` you get is the one indexed here. Nothing proves who built it.
- **Muster runs inside your Basecamp session with no sandbox.** That is true of every Basecamp module; adding a catalogue means trusting its publisher with it.
- **Linux x86_64 only.** On other platforms Basecamp shows Muster as "Not Available".

## What is here

| File | |
|---|---|
| `logos-repo.json` | the repository descriptor Basecamp reads first; its `indexUrl` is `index.json` beside it, on `main` |
| `index.json` | each package version: its download URL, `rootHash`, sha256 and embedded manifest. Generated, never hand-edited. Committed only after its release assets are up |
| `icons/` | each package's icon, shown before it is installed (written beside `index.json`) |
| releases `muster-v<version>` | the `.lgx` files: `muster_module-<version>-linux-amd64.lgx`, `muster_ui-<version>-linux-amd64.lgx` |

The format is that of the official [`logos-modules-release`](https://github.com/logos-co/logos-modules-release) catalogue, written with [`logos-modules-release-tool`](https://github.com/logos-co/logos-modules-release-tool)'s `index.py`, the way the [Logos Forum catalogue](https://github.com/edenbd1/logos-forum-catalog) publishes.

## Publishing a release

`scripts/catalog-release.sh` builds both packages from the committed tree, writes `logos-repo.json` and `index.json`, and leaves the `.lgx` files in `.run/catalog-release/muster-v<version>/`. It publishes nothing; it prints the commands. In order:

1. On a clean, up-to-date `main`, run `module/tests/run-suite.sh` and `scripts/ui-parity.sh`. Both must be green.
2. `scripts/catalog-release.sh`. The release targets this commit, so it must be on GitHub.
3. Create the GitHub release `muster-v<version>` with the two `.lgx` files, using the `gh release create` line the script prints.
4. Commit `catalog/index.json` and `catalog/icons/` to `main`. Basecamp sees the release once it does.

Design: [`docs/design/catalogue-install.md`](../docs/design/catalogue-install.md).
