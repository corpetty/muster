# LEZ wallet setup: readiness in muster, provisioning in the LEZ Wallet App

**Status:** design assessment, 2026-09-17. Upstream asks written up in `docs/upstream/` (LEZ Wallet App + Basecamp broker) (epic `exo-45e` follow-on; pebble `exo-44b`).
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

## 4b. Two blockers, not one — and muster's fallbacks (2026-09-17)

The automatic hand-off (L4) needs **two** independent things, and muster is only truly blocked on one of them:

- **Blocker A — no app declares the capability.** Confirmed: `lez_wallet_ui` (the LEZ Wallet App) declares no `provides`, so there is no capability to `logos.request`. **muster can fix this itself with a shim** — a thin `ui_qml` app that depends on `lez_core`, declares `provides: ["lez.wallet.setup"]`, and drives `lez_core`'s `create_account` / `register` / `claim_pinata` / `transfer_shielded` (all headless `lp_*` calls) in its handler. We do not have to wait on the wallet app; we (or a responsive community maintainer) can ship the provider.
- **Blocker B — the shell does not dispatch `logos.request`.** A shim does **not** fix this: if the Basecamp app-to-app broker is not routing intents, *no* provider — official, community, or our own shim — is reachable through `logos.request`. This one is the shell's, and the sharp upstream ask (`docs/upstream/app-to-app-intent-broker.md`).

**The de-risking move: muster can provision LEZ directly over `lez_core`, no broker, no wallet app.** Account creation, activation, and the pinata faucet are the *same kind* of `lp_*` call muster already makes for the transfer. `LezAdapter.provision(ks, pinataId)` + `wallet_lez_setup` ensure a public account and (with a faucet challenge id) fund it, core-to-core (the sanctioned pattern, §6.4). This is the **fallback**, not the default — delegating to the wallet app stays preferred for UX and for keeping keys in one home — but it means muster is **not hard-blocked** on either upstream piece for a working LEZ flow.

| Situation | muster's path |
|---|---|
| broker dispatches **and** a provider declares the capability | **delegate** — best UX, keys in the wallet app |
| broker dispatches, no provider yet | **ship a `ui_qml` shim over `lez_core`** — don't wait on `lez_wallet_ui` |
| broker does not dispatch | **provision via `lez_core` directly** (`wallet_lez_setup`, headless faucet/activate) |

Only the shell's dispatch has no muster-side fallback. Everything else muster can do itself.

## 5. What this is NOT

- **Not a faucet/shield/activation UI in muster.** Those stay in the LEZ Wallet App (§1).
- **Not a change to the send path.** Execution stays `muster → lez_core` direct (§6.4).
- **Not a new trust surface.** The sequencer and the wallet app are untrusted infra (inv 8); muster reads public state and coordinates, it does not custody LEZ funds or keys.

## 6. Plan (slices under `exo-44b`)

| Slice | Does | Verifiable |
|---|---|---|
| **L1 — readiness for a LEZ account** | a `lez-account` requirement + a `probeFromFacts` probe over `listAccounts`/`getBalanceRaw`; `met/missing/unknown` with the LEZ-Wallet-App remedy. | unit-testable with `FakeLezCore` (an unprovisioned core → missing; a funded one → met; an unreachable one → unknown) |
| **L2 — the prompt (works today)** | the wallet tab + the LEZ action card render the readiness item; a "Set up in LEZ Wallet" affordance (informational until the broker). | build-verified (module + UI `.lgx`, offscreen) |
| **L3 — declare the capability wiring — done/blocked 2026-09-17** | `muster_ui` already `provides coordinate.request` and `infra/access-policy.json` names the `muster_ui → muster_module` edge (both pre-existing). The `uses` for the LEZ Wallet App is **blocked upstream**: `lez_wallet_ui` declares no `provides` (Q1), so there is no capability to name. Filed as an upstream ask. | the declarable parts validate; the `uses` entry waits on the wallet app |
| **L4 — automatic hand-off** | the remedy fires `logos.request`; consume the return by re-reading readiness. | **needs the Basecamp broker (Blocker B)** — the one hard external dependency; upstream. |
| **L5 — provisioning fallback — landed 2026-09-17** | `LezAdapter.provision` + `wallet_lez_setup`: ensure an account + faucet-fund it directly over `lez_core`, core-to-core, so muster is not hard-blocked when the hand-off is unavailable. | `lez_provision_test` (create+activate; faucet-fund; idempotent; raise-on-failure); module + UI `.lgx` build. |

Order: L1 (the model) → L2 (the visible prompt) → L3 (the honest declaration) → L4 (rides the broker).

## 7. Open questions

1. **The capability name — ANSWERED 2026-09-17, and it is a blocker.** The LEZ Wallet App is `lez_wallet_ui` (v1.1.1, `github:logos-blockchain/logos-execution-zone-wallet-ui`, branch `master`). Its `metadata.json` declares **no `provides`** — `type: ui_qml`, `dependencies: ["lez_core"]`, and nothing else. So there is **no capability to `logos.request`**: the delegation (L4) is blocked not only on the Basecamp broker but on `lez_wallet_ui` declaring a provisioning capability (e.g. `wallet.setup` / `lez.account`). That is an **upstream change to the wallet app**, tracked as the L3/L4 blocker. Until it lands, muster's `uses` stays empty (honest — there is nothing to use), and L1/L2 name the *app* as the remedy, not a capability.
2. **What counts as "set up" per rail.** A public send needs an activated, funded public account; a shielded send needs private notes (a shield). The requirement should be rail-specific (the LEZ driver's manifest declares which), so the prompt asks for the right thing.
3. **Standalone runner with no broker.** There the remedy can only inform ("open the LEZ Wallet App"), or muster keeps the direct `lez_core` provisioning calls as a runner-only fallback. Decide whether the runner gets a minimal in-app fund path or simply documents the dependency.
4. **Does muster need the account id back at all?** For a solo send from muster's own account, muster reads its own `lez_core` account directly (no return needed). For a coordinated send, the recipient's public key comes via the room (K5), not via the intent return. So L4's return payload may be empty — confirm the wallet app's intent contract.
