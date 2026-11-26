# lez-msig benchmarks (RFP-005 P.1, P.2)

Real proving only: `msig_bench` refuses `RISC0_DEV_MODE`. Reproduce with:

```
cd programs/lez-msig
cargo run --release -p msig_host --bin msig_bench -- 1 3 5 10
```

For each M, it runs these steps on LEE's own v0.3 state machine (LEZ v0.3.0, risc0-zkvm 3.0.5,
the local CPU prover):

- create a multisig of max(M, 3) members with threshold M, over a group-owned **private** PDA;
- fund it with a shield from a public account;
- pay a public recipient with exactly M BIP-340 approvals. That is ONE privacy-preserving
  transaction, and the program verifies all M signatures inside its proof.

Every transaction below was accepted by the state machine.

## 2026-11-20: LEZ v0.4.0-rc3, the same machine (AMD EPYC 7C13, 64 cores, 503 GB)

`cargo run --release -p msig_host04 --bin msig_bench04 -- 1 3 5 10` in `lez04`. On v0.4 every private
transaction pays its fee inside its proof (D17), so each step below carries a second private account,
the group's fee account (witnessed `FeeOnly`). The exception is the top-up, where the fee account is
the only private account and pays out of the credit it receives. The program is named directly
(disclosed); D18's undisclosed claim changes what the proof claims, not what it proves. The machine was
otherwise idle.

| M | step | prove (s) | tx size (bytes) |
|---|---|---|---|
| 1 | top-up of the fee account (public → private, one private account) | 75.0 | 229,025 |
| 1 | create (3 members) | 184.1 | 237,441 |
| 1 | deposit (public → the vault) | 169.0 | 238,217 |
| 1 | **execute: pay, 1 signature** | **195.1** | 237,905 |
| 3 | **execute: pay, 3 signatures** | **209.4** | 237,905 |
| 5 | create (5 members) | 184.1 | 237,441 |
| 5 | **execute: pay, 5 signatures** | **234.8** | 237,905 |
| 10 | create (10 members) | 192.1 | 237,441 |
| 10 | **execute: pay, 10 signatures** | **297.6** | 237,905 |

Every transaction was accepted. Top-ups and deposits repeat within a second across M (74–77 s,
169–170 s). Peak resident memory: 9.6 GB. The whole run took 45 min.

What changed from v0.3 (against the idle v0.3 run below, 111 s + 12.0 s · M, on the same machine):
- **A payment proves in about 182 s + 11.5 s · M.** The cost per approval is about the same; the base
  rose by about 70 s.
- **The in-proof fee costs about 95 s per step.** A deposit and a top-up are the same public → private
  transfer; the deposit's second private account, the fee witness, is the difference (169 s against
  75 s). The v0.3 deposit, with no fee, proved in 77 s.
- **The transaction stays flat in M**, 229–238 KB (v0.3: 228 KB). Its fee is flat too: about 5.07M at
  base fee 8, whatever M (`docs/upstream/lez-v04-field-report.md`).

## 2026-11-19: AMD EPYC 7C13, 64 cores, idle (exo-0d3.15)

440 GB of memory. The same program build (`artifacts/msig.bin`) and accelerated k256.
Nothing else was running when the run started: the load average was 3.2, left over from compiling
the benchmark. During the run it was the prover's own, about 36. The run took 23 min 47 s, with a
peak resident memory of 9.6 GB.

| M | step | prove (s) | tx size (bytes) |
|---|---|---|---|
| 1 | create (3 members) | 109.6 | 227,751 |
| 1 | fund (shield, native only) | 77.4 | 227,976 |
| 1 | **execute: pay, 1 signature** | **125.5** | 228,010 |
| 3 | create (3 members) | 108.5 | 227,751 |
| 3 | **execute: pay, 3 signatures** | **144.0** | 228,010 |
| 5 | create (5 members) | 108.9 | 227,751 |
| 5 | **execute: pay, 5 signatures** | **170.6** | 228,010 |
| 10 | create (10 members) | 116.9 | 227,751 |
| 10 | **execute: pay, 10 signatures** | **232.0** | 228,010 |

A least-squares fit through M = 1–10 gives about **111 s + 12.0 s · M**. M = 5 proves in
under 3 minutes. M = 32, the members limit, extrapolates to about 8 minutes; it has not been
measured. These figures replace the shared-machine ones below for P.2, which were about 15 s per
approval.

## 2026-10-23: AMD EPYC, 64 cores, 503 GB. The guest uses RISC Zero's accelerated k256

The machine was shared: Nim builds and a local sequencer ran alongside. Treat these as upper
bounds.

| M | step | prove (s) | tx size (bytes) |
|---|---|---|---|
| 1 | create (3 members) | 129.6 | 227,751 |
| 1 | fund (shield, native only) | 91.9 | 227,976 |
| 1 | **execute: pay, 1 signature** | **150.7** | 228,010 |
| 3 | **execute: pay, 3 signatures** | **171.5** | 228,010 |
| 5 | create (5 members) | 128.6 | 227,751 |
| 5 | **execute: pay, 5 signatures** | **208.5** | 228,010 |
| 10 | create (10 members) | 140.1 | 227,751 |
| 10 | **execute: pay, 10 signatures** | **288.1** | 228,010 |

Peak resident memory: 9.6 GB. The whole run took 28 min 40 s.

The same 1-signature payment with stock (unaccelerated) k256 took **439.0 s**. Acceleration
cuts it by 2.9×.

## What the numbers say

From the two idle runs above, both on the same 64-core machine.

- **P.2 (approval verification as a function of M).**
  - Each further approval adds about 12 s of proving on v0.3 and about 11.5 s on v0.4.
  - A payment proves in about **111 s + 12.0 s · M** on v0.3 and **182 s + 11.5 s · M** on v0.4.
    The v0.4 base is higher because each step proves a second private account, the group's fee
    account (D17), which costs about 95 s.
  - **M ≥ 5 is viable:** M = 5 proves in about 3 minutes on v0.3 and 4 minutes on v0.4.
  - A private transaction does not grow with M (below), so the ceiling is the members limit (32),
    not the block. M = 32 extrapolates to about 8 minutes on v0.3 and 9 on v0.4; it has not been
    measured.
- **P.1 (transaction size and cost).**
  - Every private transaction is about 228 KB on v0.3 and 229–238 KB on v0.4: the succinct
    proof, plus notes padded to a fixed size. It does not grow with M, because the approvals are
    inside the proof.
  - On v0.3, private transactions are neither metered nor charged.
  - On v0.4 each pays a flat fee inside its proof: about 5.07M at base fee 8, whatever M
    (`docs/upstream/lez-v04-field-report.md`).
- **Memory.** Peak resident memory is 9.6 GB on both lines.
- **Not yet measured:** a laptop-class machine (exo-0d3.15) and a GPU prover. Every figure here is
  from a 64-core server.
- **The public posture.** These figures do not apply to it: the sequencer executes the program
  without proving. On v0.4 its fees are metered per step (`v04_gas.rs`,
  `module/tests/vectors/lez-msig/v04-gas.json`).
