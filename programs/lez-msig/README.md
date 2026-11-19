# lez-msig

An M-of-N multisig program for the Logos Execution Zone (LEZ v0.3), private by default. Built
for RFP-005; the roadmap is `docs/proposals/RFP-005-roadmap.md`.

- **The program** enforces the quorum itself. Members' BIP-340 approvals are verified inside its
  execution, with roles, expiry, a time lock, spending limits and weighted approvals.
- **One program, two postures.** It runs over a public PDA (the public posture) or a group-owned
  private PDA (the private posture: on chain, one proof with no member, approval or config in
  it).
- **No coordination layer is required.** The program does not care how approvals were
  collected. Muster's encrypted room is one way; your own transport is another.

Design and decision log: `docs/design/lez-msig.md`. What a signer signs, byte for byte:
`docs/design/lez-msig-signing.md`. Benchmarks (real proving): `BENCHMARKS.md`.

## Layout

| Path | What it is |
|---|---|
| `core/` | `msig_core`: the rules as pure functions, with no LEZ dependency. Every rule is tested here. |
| `v03/` | LEZ v0.3 wire types and the account derivation, shared by the guest and the host |
| `methods/` | the guest, and the deployed build in `artifacts/msig.bin` (its image id is the program's identity) |
| `host/` | `msig_host`: the client (`public.rs`, `exec.rs`), the `msig_exec` CLI, the benchmark and the vectors |
| `module/` | `lez_msig_module`: the same operations as a Logos module (`lez_msig_module.lidl`) |

## Build and test

```
cargo build -p msig_methods        # the guest; ~3 min the first time (rzup's risc0 toolchain)
cargo test                         # core rules, the program on LEE's own state, the module trait
```

## Deploy, on a local zone

```
infra/lez/localnet.sh                                          # a LEZ v0.3.0 zone on :3040 (from the repo root)
infra/lez/localnet.sh deploy programs/lez-msig/artifacts/msig.bin   # prints the program's account id
```

On the public testnet use `infra/lez/funder.sh --zone testnet deploy …`. It needs the testnet
funder funded, because v0.3 has no faucet. Then run the live tests against your zone:

```
MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<program id hex> \
  cargo test -p msig_host --test live_public --test live_private -- --nocapture
```

## Use it without Muster (public posture)

Every operation is one JSON request and one JSON answer, with no key involved. They are
available from three places, which share one implementation (`msig_host::exec::exec_request`):

- the CLI, `msig_exec` (`cargo run --release -p msig_host --bin msig_exec`), which reads the
  request on stdin;
- the Logos module `lez_msig_module`, one method per mode, callable from any module or from
  `logoscore -c`;
- the Rust library, `msig_host::public`.

The journey, with `R='"rpc":"http://127.0.0.1:3040","program":"<id>","createKey":"<32 random bytes>"'`:

1. **Create.** Send `{"mode":"prepare",R,"kind":"create","zone":<32 bytes>,"config":{"members":[{"key","roles":7,"weight":1},…],"threshold":2},"payerKey":<your x-only key>}`.
   The answer is `{sign, message}`. Sign `sign` with the payer's key (BIP-340), then send
   `{"mode":"send_public","rpc":…,"message":…,"witnesses":[{"signature","publicKey"}]}`.
2. **Read.** `{"mode":"state",R}` returns the config, epoch, free nonces, vault balance and
   queue.
3. **Propose.** `{"mode":"propose",R,"action":{"kind":"transfer","to","amount"},"proposer":<a member's key>,"expiresMs"}`
   returns `{proposal, approveMsg, …}`. Show each signer the decoded action, then have them sign
   `approveMsg`. The proposer signs too.
4. **Check.** `{"mode":"check",R,"kind":"execute","proposal":…,"approvals":[{"key","sig"},…]}`
   returns the program's own verdict against the state now: `{ok:true}`, or `{ok:false, refusal}`
   with a stable code such as `below-threshold` or `stale-epoch`.
5. **Execute.** `prepare` with the same instruction plus `payerKey`, then `send_public`, as in
   step 1. Use `kind: "queue"` (then `"execute-queued"` after the ETA) when the multisig has a
   time lock.
6. **Judge by the state.** On v0.3 a refused transaction is still included. Read `state` again:
   the nonce is spent, or the action is queued.

Spends under a spending limit follow the same shape: `spend` returns `{spend, spendMsg, period,
periodMs}`, the limit's signers sign `spendMsg`, and you `check`, `prepare` and send with
`kind: "spend"`. Config changes are proposals with `action.kind = "config"`; see the module
contract for each change's fields.

The payer gains no authority: the approvals inside the instruction are the program's only gate.
`live_public.rs` runs this whole journey against a real sequencer.

## The private posture

A private multisig's transactions are proved on the member's machine (minutes per transaction,
see `BENCHMARKS.md`). Proving needs the group's secret, which only members hold. `exec`, `fund`,
`scan` and `send` in `msig_exec` and the module do it, and the module holds no key: the secret
arrives with each request and is dropped with its job. Muster carries the secret and each new
note between members in its encrypted room (`docs/design/lez-msig.md` §8).

## Status

LEZ v0.3 only. The LEZ 0.4 port (the actor model) is roadmap milestone M3. The program has not
been audited; that is M5. Do not hold real value in it.
