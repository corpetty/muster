# Running muster under `--access-policy enforce`

**Default is off.** Without the flag, any loaded module may call any other, and muster
runs with no policy. This note is for when a host turns **inter-module access
enforcement ON** — a real concern, because muster's own UI→backend edge breaks under it
unless it is named.

## The trap

`--access-policy enforce` (logos-basecamp / logoscore) is **deny-by-default**: a module
may only call the modules it declares as `dependencies` in `metadata.json`. The
allow-list is *derived* from those declarations. Basecamp's README records the load-bearing
limitation:

> UI plugins (`ui_qml`) load out-of-process and are **not** tracked as dependents in the
> core module registry, so the derived allow-list never contains them and their calls to
> their own backend module get denied (e.g. `accounts_ui -> accounts_module`).

Muster hits this exactly: **`muster_ui → muster_module`** is the whole app — every
`coordinate_*` / `wallet_*` call the view makes goes over that edge. Under enforce it is
denied, and a denial surfaces only as a mysteriously empty result plus a log line:

```
[capability_module] access policy denies 'muster_ui' -> 'muster_module'
```

muster works today only because enforce is off by default.

## The fix

Ship muster with a policy document that names the `muster_ui → muster_module` edge. A
`restrictions` entry **replaces** the derived allow-list for its target, so this adds
`muster_ui` as an allowed caller of `muster_module` while leaving every other target
(muster_module → `delivery_module` / `lez_core`, which ARE derived from muster_module's
own dependencies) on its derived list.

[`infra/access-policy.json`](../infra/access-policy.json):

```json
{
  "version": 1,
  "mode": "enforce",
  "restrictions": {
    "muster_module": { "allowedCallers": ["muster_ui"] }
  }
}
```

Launch with it:

```bash
LogosBasecamp --access-policy ./infra/access-policy.json
# or, inline / for logoscore:
logoscore ... --access-policy '{"version":1,"mode":"enforce","restrictions":{"muster_module":{"allowedCallers":["muster_ui"]}}}'
```

## Why only `muster_module` needs a restriction

- **`muster_ui → muster_module`** — the ui_qml→backend edge the derivation can't see.
  Named here.
- **`muster_module → delivery_module`, `muster_module → lez_core`** — muster_module
  declares both as `dependencies`, so the derived allow-list already permits these
  core-to-core calls (the sanctioned pattern; see
  `docs/design/basecamp-capability-alignment.md`). No restriction needed — and adding
  one would *replace* their derived lists, so don't.
- **muster_ui → delivery_module / lez_core** — muster_ui lists these as dependencies for
  bundling only; it never calls them (only `muster_module` does), so no edge to allow.

When the coordination capability's provider handler lands (muster_ui `provides
coordinate.request`), the shell dispatches into muster_ui, which calls muster_module —
still the same one edge, already covered.

## Why no release ships it yet (audit P4-01, exo-3b3.17, 2026-11-23)

A Nim provider cannot see its caller (`docs/design/side-modules.md`), so `muster_module`
serves every module in the same host: reading rooms, admitting an identity, posting and
agreeing as the person, signing with the keys Muster holds, `fileshare_share`, `set_setting`.
The policy above is the only gate, and nothing that ships passes it:

- **The AppImage** (`scripts/release-appimage.sh`) repacks Basecamp's released AppImage and
  keeps Basecamp's own `AppRun`; Muster writes no launcher, so there is no command line of
  ours to add the flag to.
- **The catalogue** installs into the person's own Basecamp, launched however they launch it.
- **`scripts/basecamp-profile.sh`** (dev profiles) launches that `AppRun` with `--user-dir`
  only.

Shipping it would take, each still to verify:

1. **A policy for the whole host, not Muster's edge alone.** `enforce` is process-wide and
   deny-by-default. Every other app's `ui_qml → module` edge is then denied too (Basecamp's
   README names `accounts_ui -> accounts_module`), so the document must name each app the
   AppImage bundles: at least the keystore, signer and RPC UIs and Monero Wallet against
   their backends, as installed by `infra/basecamp/bundle-0.3.2.tsv` and
   `infra/basecamp/catalog-0.3.2.tsv`. Muster's run under enforce on Basecamp 0.3.2
   (`docs/labbook/monero-stack-from-muster.md`) exercised Muster's calls only, not the other
   apps.
2. **A launcher of ours in the AppImage**: an `AppRun` wrapper that execs Basecamp's with
   `--access-policy <the bundled document>`, and a check that Basecamp 0.3.2 reads the flag
   from an `AppRun` argument as `LogosBasecamp --access-policy` does (seen only on a direct
   launch so far).
3. **For catalogue installs**, nothing Muster can do: the flag belongs to whoever launches
   Basecamp. The lasting fix is upstream, Basecamp passing the caller's name to a Nim
   provider so `muster_module` serves `muster_ui` alone.

Until then the walkthrough names the gap ("Any module loaded beside Muster can act as you in
your rooms", `contracts/claims/registry.json`), and `fileshare_share` refuses what no room
should be sent even when asked by a module: a hidden path under the home folder, anything in
Muster's own data folder, and anything that is not a regular file.
