# LEZ wallet setup: readiness in muster, provisioning in the LEZ Wallet App

**Status:** design assessment, 2026-09-17 (epic `exo-45e` follow-on; pebble `exo-44b`).
**Reads with:** `basecamp-capability-alignment.md` (§4 musters compose above app-to-app intents; §6.4 the solo-send decision), `lez-adapter.md` (the rails + the `LpLezCore` seam), `material-and-disclosure.md` (the readiness + remedy model this extends), the LEZ CLI get-started flow (`docs.logos.co/lez/get-started/run-lez-wallet-via-cli`).

## 1. The question, and the honest answer

Prompted 2026-09-16/17: a LEZ transfer needs a set-up, funded LEZ account (the CLI flow is `change-network → account new public → auth-transfer init → pinata claim → transfer`). Should muster build that setup/funding into its own wallet tab and prompt the user through it?

**No — muster should not reimplement it.** Basecamp already ships a first-party **LEZ Wallet App** (`logos-execution-zone-wallet-ui`: init accounts, inspect balances, public/private transfers, the faucet). `basecamp-capability-alignment.md` §3 already flags muster's direct-drive "Send λ" as gap #1 precisely because it *re-implements* that app. Building a faucet/shield/activation UI inside muster would deepen the duplication our own design argues against.

The split that resolves it:

| Concern | Where it lives | Why |
|---|---|---|
| Wallet **provisioning** — create/activate accounts, claim the faucet, shield, manage balances | the **LEZ Wallet App** (delegated) | first-party, already exists; not muster's value; user-mediated setup |
| **Transfer execution** — the actual send, solo or room-coordinated | **muster → `lez_core`** direct (core-to-core) | decided in `basecamp-capability-alignment.md` §6.4: works in the standalone runner (no broker), and one mechanism serves both solo and Mode B |
| **Readiness + coordination** — "do you have a funded LEZ account for this?", and the k-of-n room agreement | **muster** | this is muster's layer: detect, prompt, coordinate |

So muster's job for wallet setup is **detect and delegate**, never provision. This note is only about the provisioning delegation; the send stays as §6.4 decided.

## 2. What "set up" means, and how muster already detects it

A LEZ action is *ready* on this instance when a usable account exists and (for a spend) holds funds. Muster already reads this through `lez_core` over `lp_*` — no new backend call:

- `LpLezCore.listAccounts` — does a public and/or private account exist?
- `LpLezCore.getBalanceRaw` — does it hold a spendable balance (never a false zero — a failed read raises, `lez-adapter.md`)?

That is exactly the shape of the **readiness model** the epic already built (`coordination/readiness.nim`, M2): a requirement graded `met | missing | unknown` with a remedy. LEZ setup is one more requirement, detected the same way.

## 3. The model: a requirement whose remedy is another app

Extend the action manifest (K1 vocabulary) so a LEZ action declares a requirement for a provisioned account, and readiness grades it:

```
Requirement{ kind: infra, name: "lez-account", party: instance,
             needs: MaterialNeed{ class: infra, target: "lez:testnet" } }
```

Readiness (`probeFromFacts`) grows a probe for it:

- `met` — `listAccounts` returns an account and (for a spend) `getBalanceRaw` > required amount.
- `missing` — no account, or balance below the amount → **remedy: open the LEZ Wallet App**.
- `unknown` — the zone could not be read (sequencer unreachable, inv 8) → shown as unknown, never a silent met.

The **remedy is the new part**: today every readiness remedy names an action the *host* performs (configure an RPC in Settings, install a module). The LEZ remedy names **another Basecamp app** — "set up in the LEZ Wallet App". That is the cross-app generalisation of the remedy the card and the wallet tab already render.

Nothing about the credential leaves muster: the account keys and the faucet PoW live in `lez_core` / the wallet app. Muster only ever reads the public state (an account exists, a balance) and, for a coordinated transfer, receives the recipient's **public** receiving key as counterparty material (the K5 material-share path). Invariant 3 (muster describes/detects, the wallet app + `lez_core` do), invariant 8 (the sequencer is untrusted infra), and the material/disclosure boundary (only the public face crosses) all hold.

## 4. The delegation mechanism, and what it needs

Provisioning is a **user-mediated, single-user** action — precisely what Basecamp's **app-to-app intents** are for (`basecamp-capability-alignment.md` §1). The clean hand-off:

1. `muster_ui` declares in `metadata.json` that it **`uses`** the LEZ wallet capability (name **to confirm** from `logos-execution-zone-wallet-ui`'s `provides` — a `wallet.*` or LEZ-specific capability, §7 Q1).
2. When a LEZ action is `missing` its account, the remedy fires `logos.request("<lez-wallet-capability>", { … }, cb)`.
3. The **shell** resolves the capability to the LEZ Wallet App, brings it forward, the user creates/activates/funds, and the shell routes the single result back to `muster_ui`.
4. Muster re-checks readiness (`listAccounts`/`getBalanceRaw`) — now `met` — and the action proceeds.

Muster consumes **no secret** back: the "result" is just that provisioning happened; muster re-reads the public state through `lez_core`. For a coordinated (Mode B) transfer the *recipient* likewise gets their shielded receiving key from *their* LEZ Wallet App and shares its public face into the room (K5). Both ends use the wallet app; muster coordinates.

**What works today vs. what needs the broker:**

- **Detection works now** — the `lez_core` reads are already available over `lp_*`.
- **The prompt/remedy works now** — muster can render "set up in the LEZ Wallet App" as the readiness remedy on the card and in the wallet tab, informational.
- **The automatic hand-off needs the app-to-app broker** — `muster_ui` declaring `uses`, and the shell dispatching `logos.request`. That is the same not-yet-wired broker piece the epic tracks for M7 / the `coordinate.request` provider (`basecamp-access-policy.md`). In the **standalone runner** there is no broker at all (`basecamp-capability-alignment.md` §6.4), so there the remedy stays a prompt that names the app.

So the honest staging: **detect + prompt now; automatic hand-off when the broker lands.** The prompt is not a stopgap that gets thrown away — it is the same readiness remedy, later given a live target.

## 5. What this is NOT

- **Not a faucet/shield/activation UI in muster.** Those stay in the LEZ Wallet App (§1).
- **Not a change to the send path.** Execution stays `muster → lez_core` direct (§6.4).
- **Not a new trust surface.** The sequencer and the wallet app are untrusted infra (inv 8); muster reads public state and coordinates, it does not custody LEZ funds or keys.

## 6. Plan (slices under `exo-44b`)

| Slice | Does | Verifiable |
|---|---|---|
| **L1 — readiness for a LEZ account** | a `lez-account` requirement + a `probeFromFacts` probe over `listAccounts`/`getBalanceRaw`; `met/missing/unknown` with the LEZ-Wallet-App remedy. | unit-testable with `FakeLezCore` (an unprovisioned core → missing; a funded one → met; an unreachable one → unknown) |
| **L2 — the prompt (works today)** | the wallet tab + the LEZ action card render the readiness item; a "Set up in LEZ Wallet" affordance (informational until the broker). | build-verified (module + UI `.lgx`, offscreen) |
| **L3 — declare the capability wiring** | `muster_ui metadata.json` `uses` the LEZ wallet capability; `provides coordinate.request` (the §6 step-1 declaration), even before the broker. | metadata validates; the access-policy note updated |
| **L4 — automatic hand-off** | the remedy fires `logos.request`; consume the return by re-reading readiness. | **needs the Basecamp broker** — upstream, tracked with M7 |

Order: L1 (the model) → L2 (the visible prompt) → L3 (the honest declaration) → L4 (rides the broker).

## 7. Open questions

1. **The capability name.** What does `logos-execution-zone-wallet-ui` declare in `provides`? The remedy's `logos.request` target and muster's `uses` entry both key on it. To confirm from the app's `metadata.json`; until then L1/L2 name the *app*, not a capability.
2. **What counts as "set up" per rail.** A public send needs an activated, funded public account; a shielded send needs private notes (a shield). The requirement should be rail-specific (the LEZ driver's manifest declares which), so the prompt asks for the right thing.
3. **Standalone runner with no broker.** There the remedy can only inform ("open the LEZ Wallet App"), or muster keeps the direct `lez_core` provisioning calls as a runner-only fallback. Decide whether the runner gets a minimal in-app fund path or simply documents the dependency.
4. **Does muster need the account id back at all?** For a solo send from muster's own account, muster reads its own `lez_core` account directly (no return needed). For a coordinated send, the recipient's public key comes via the room (K5), not via the intent return. So L4's return payload may be empty — confirm the wallet app's intent contract.
