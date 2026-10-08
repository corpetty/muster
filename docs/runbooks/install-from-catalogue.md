# Install Muster from its catalogue

**As of 2026-10-08 (exo-dcc.3).** For anyone with Logos Basecamp who wants to try Muster. You add Muster's catalogue once, then install Muster like any other app; its dependencies come from the official Logos catalogue. Every label below was read on screen in Basecamp 0.3.2 on 2026-10-08, from a catalogue served locally (`docs/design/catalogue-install.md`, §7). The code wins over this page.

> **Before the first release.** Muster appears in the catalogue once `muster-v0.2.0` is published and `catalog/index.json` is on `main`. Until then, adding the URL succeeds but lists nothing.

## What you need

- **Linux on x86_64.** Muster is built for nothing else yet, so Basecamp on another platform cannot install it.
- **Logos Basecamp 0.3.2**, from [its releases](https://github.com/logos-co/logos-basecamp/releases).
- **About 650 MB of downloads and ten minutes.** Most of it is Muster's dependencies, which come from the official Logos catalogue.

## What adding the catalogue trusts

- **It publishes two packages, `muster_module` and `muster_ui`, and nothing else.** Basecamp takes the newest version of a package across every catalogue you enable, so a catalogue that listed an official package's name could replace it. Muster's never does; its release script refuses to.
- **Nothing is signed.** That is true of the official catalogue too. Basecamp checks each download against the hash the catalogue lists, so you get the file the catalogue names. Nothing proves who built it.
- **Muster runs inside your Basecamp with no sandbox**, like every Basecamp module. Adding a catalogue means trusting its publisher with that.
- **Everything else comes from the official Logos catalogue.** Package Manager's install dialog names each package's catalogue: `delivery_module (Logos Official)`, `muster_module (Muster)`.

## 1. Add the catalogue

1. Open **Settings** (the bottom icon in the sidebar) → **Package Repositories**.
2. Under **Add a repository**, paste:

   ```
   https://raw.githubusercontent.com/corpetty/muster/main/catalog/logos-repo.json
   ```

3. Press **Add**. A **Muster** entry appears under **Logos Official**, enabled.

Basecamp accepts only `https://` repository URLs. Any other URL is refused with "unsupported URL scheme (https required in v1)".

## 2. Install Muster

**Install from Applications**, not from Package Manager (see "Known rough edges").

1. Open **Applications** (the top icon at the bottom of the sidebar).
2. Search `muster`. Muster appears under a **Muster** heading; click it. The **Add Application** dialog opens.
3. Untick what you don't want (below), then press **Install**. When it finishes, the button reads **Launch**.

The link `basecamp://app/muster_ui` does the same thing once the catalogue is added. Basecamp asks **Install an app for this?** ("muster_ui can handle this, but it is not installed yet"), and **Install** opens the same dialog.

The dialog lists:

- **Required (10):** Muster 0.2.0 and Muster Module 0.2.0 from the Muster catalogue. From Logos Official: Delivery Module 0.3.2, LEZ Core Module 0.5.0, keystore_module 0.1.0, eth_rpc_module 0.1.0, EVM Fee Estimator 0.1.0, EVM Transaction Sender 0.1.0, LEZ RLN Module 4.2.1 and RLN Module 0.10.0.
- **Optional, all pre-ticked:** libp2p Networking 1.1.0, Module State 0.1.0 (already installed: Basecamp ships it), Verified Proxy Module 0.1.3, **Monero Node (local)** 0.1.1, and Monero Wallet Backend 0.1.1. The Monero Wallet Backend brings `monero_node_module` and `monero_wallet_core_module` with it.

### What to untick

**Untick Monero Node (local)**, `monerod_module` by its package name. It is a full Monero node, about 47 MB to download, and Muster does not need it: the Monero wallet can use a remote node. Keep it only if you mean to run your own node.

Keep the rest:
- **Monero Wallet Backend** is how Muster reaches a Monero wallet (Muster declares it optional).
- **Verified Proxy Module** lets Ethereum balances be proven rather than trusted.
- **libp2p Networking** is an optional transport of Delivery, which carries Muster's rooms.

## 3. Open Muster

Press **Launch**, or later click Muster's icon in the sidebar. Home reads **Nothing waiting on you** and **Set up an Ethereum account**. Your account and chains are set up from there: [`basecamp-fresh-install.md`](basecamp-fresh-install.md), §1 on.

Installing starts nothing. Opening Muster starts the modules it declares.

## Updating

Basecamp shows a new Muster release after **Package Repositories → Refresh** or a restart. Members of a room should run the same version; a room may not work across versions.

## Known rough edges

- **Package Manager times out on Muster.** Package Manager → search `muster` → **INSTALL** downloads Muster and all its dependencies in one request, with a five-minute limit for the whole set (`DOWNLOAD_TIMEOUT_MS` in logos-package-manager-ui). The default download source, **Any**, tries each official package over Logos Storage first, and a stalled attempt waits a minute or two before falling back to GitHub. On 2026-10-08 the result was **Install Failed: Download failed** with nothing installed, twice. **RETRY** started over and failed the same way. Setting Settings → Package Repositories → **Download source: HTTP only** let the third try finish, in 4 min 50 s, just inside the limit. Applications, and the `basecamp://app/muster_ui` link, download one package at a time with five minutes for each, and finished first time.
- **The install dialog's size doesn't change when you untick.** It reads 658.7 MB either way.
- **The link's prompt names the package, not the app**: "muster_ui can handle this".
- **A `basecamp://` link reaches only Basecamp's default profile.** The handler Basecamp registers starts it without `--user-dir`.

## Testing a release locally (maintainers)

`scripts/catalog-release.sh --local <dir> --base-url https://127.0.0.1:<port>` writes a whole catalogue (both files, the icons and the two `.lgx` files) for a local server. Because Basecamp requires `https://` for the repository and for every download, the server needs TLS:

1. Make a throwaway CA and a certificate for `127.0.0.1` (`openssl`).
2. Serve `<dir>` over https with that certificate.
3. Start Basecamp with `SSL_CERT_FILE` set to the system bundle plus that CA. Its downloader reads `CURL_CA_BUNDLE`, `SSL_CERT_FILE` or `NIX_SSL_CERT_FILE`, in that order, before the system bundle.

Use a fresh `--user-dir` and `HOME`, so that nothing is installed beforehand. This is how the acceptance run of 2026-10-08 was done (`docs/design/catalogue-install.md`, §7).
