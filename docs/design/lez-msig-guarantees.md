# lez-msig: who sees what, and which test holds each requirement

*Written 2026-11-26 for RFP-005 milestone M3 (issue exo-05d). It covers three of M3's documentation
items: the per-action public/private table (U.5), the cross-layer correlations (Privacy 3), and the
requirement-to-test map (S.7).*

Sources:
- The accepted proposal, [`RFP-005-lez-msig.md`](../proposals/RFP-005-lez-msig.md).
- The design and decision log, [`lez-msig.md`](lez-msig.md). Its §7 is the summary this page expands.
- The code under [`programs/lez-msig/`](../../programs/lez-msig/) and `module/src/`. Every claim
  names the file or test it was read from.

Where this page and the code disagree, the code wins. §4 lists the places where the code and
`lez-msig.md` already disagree.

**Not audited.** The program has not been audited (milestone M5, exo-a80). Nothing here is a
guarantee until it has been.

## 0. The observers

| Observer | Who it is | What it can read |
|---|---|---|
| **Chain** | anyone who reads the zone's blocks | every transaction as the zone stores it |
| **Sequencer / RPC** | the node a member's client talks to: Muster's `lez-rpc` setting, the prover's `rpc` field | what the chain sees, plus the network connection each request comes from, and every read the client makes before it sends (§2, C7) |
| **Store node / fleet** | the Logos delivery nodes that hold the room's content topic | sealed frames: their timing, size and kind tag, and the publishing peer unless `mix` is on. No member identity and no epoch number (`module/tests/store_node_view_test.nim`) |
| **Room member in the multisig** | a member of the room who holds an approval key in this multisig | everything the room carries, and (private posture) the group secret and every note |
| **Room member outside the multisig** | a member of the room who is not in this multisig | everything posted to the room in the clear, but not what is sealed to the multisig's members (the group secret, the notes) |
| **Removed member** | a member the multisig removed earlier, looking at an action that happens **after** the removal | what they still hold. Before removal they saw what any member sees |

The RFP names the first five observers. The sixth column is added because a Muster room can hold
people who are not in its multisig (`coordination/msig_room.nim`, `msigOpen`: the ceremony names
its members out of the room's members), and they see more than a store node does.

Lines: **v0.3** is LEZ v0.3 (`programs/lez-msig/`). **v0.4** is LEZ 0.4.0-rc3
(`programs/lez-msig/lez04/`). Both run the same rules (`msig_core`).

## 1. Per action (U.5)

### 1.1 The private posture

The private posture runs over a group-owned private PDA. Every execution is one
privacy-preserving transaction with no public signer (`lez-msig.md` §6). In the table, "frames" means
sealed room frames: one per published event (`coordination/session.nim`, `publish`).

| Action | Chain | Sequencer / RPC | Store node / fleet | Room member in the multisig | Room member outside | Removed member |
|---|---|---|---|---|---|---|
| **Create** | **v0.3:** one transaction with no signer, no fee and one new commitment. No member, threshold or setting appears.<br>**v0.4:** the same, plus: the fee is paid from the group's fee account to the zone's fee inbox (D17); no program is named (D18, `v04_undisclosed.rs`); and the vault's **recovery binding**, which shows the vault's address in the clear. The v0.4 executor always registers it at Create (`lez04/host/src/exec.rs`; LEE's `RecoveryBinding { address, note }`). | The sending connection.<br>**v0.4:** before proving, it reads the program's account and its mirror commitment (`exec.rs`, `undisclosed`), the fee note's proof and `getFeeState`. | Frames: the ceremony's open event, one join per member, one sealed group secret per member, then one note frame per member after inclusion (v0.4: also one fee-note frame per member), and the disclosure. | Everything: the settings, the group secret, the note, the address. | The open event, which names the members, threshold, time lock, program, zone, the private flag and the create key (`msigOpen`), and the disclosure. Not the group secret or the note, so not the address (it reads as unknown, `lez-msig.md` §8) and not the balance. | n/a |
| **Fund (a member's deposit)** | The member's **public account**, its nonce and the amount, debited into a private transaction. The vault's credit is private (`deposit_tx`).<br>**v0.3:** no fee.<br>**v0.4:** the fee comes from the fee account. | The member's account and connection, and the proof requests for the notes it spends (v0.4: and the program read). | One note frame per member (v0.4: and fee-note frames). | Who deposited, how much, the new balance. | The note events' transaction hash, which is outside the seal (C9). With the chain, that gives the depositor's account and the amount. | With the group secret they can scan the chain, so they see the new balance (§2, C6). |
| **Deposit from outside the group** | **v0.4 only.** A public transaction naming the payer's account, the amount and the **vault's address**. The next private transaction collects it and names the deposit's nullifier, which nobody can link to the deposit without the group's keys (`v04_private_inbound.rs`).<br>**v0.3:** not supported. | **The collector's RPC:** it pages the publications from the room's cursor, then asks `getMessagePath(position)` for each deposit it collects, so it learns which deposit that transaction collects (`exec.rs`). | The cursor rides in the clear inside the room's note events (`publishNote`), but the store node cannot open them. | The depositor's account and the amount (`inbound` lists `from` and `amount`). | The cursor and the transaction hash. | They can find it: `inbound` needs only the group's viewing key. |
| **Fee top-up** | **v0.4 only.** The member's public account, its nonce and the amount, into a private transaction whose only private account is the fee account. The fee account is not named. It is **229,025 bytes**, against about 237–238 KB for every other step (`BENCHMARKS.md`).<br>**v0.3:** private transactions are fee-exempt, so there is no fee account. | As for Fund. | Fee-note frames. | Who topped up, and how much. | The transaction hash. | They can **drain** the fee account, since anyone holding the group secret can (D17). |
| **Propose** | Nothing: proposals stay off-chain. | Nothing: a private multisig's state is read from its note. | A few frames: the intent, and the author-signed proposer claim. | The decoded action, the proposer, nonce, epoch and expiry (`effect_summary.nim`). | The same: a proposal is a room intent, and every room member reads it. | Nothing, once the room has re-keyed them out. Exception: a removed member who is still in another lez-msig of the room keeps the room (`msig_members_test` §5). |
| **Approve** | Nothing until execution. | Nothing: the approval is signed locally. | One frame per approval. | Who approved: each approval is named `msig:<key>` and author-signed. | The same. | As for Propose. |
| **Execute: transfer to a public payee** | A nullifier for the vault's old note, a commitment for its new one, and the **payee's account and amount** as a public credit (it may land a block later). The upper bound of the validity window is the proposal's expiry, to the millisecond (C2). No member key, no approval and no create key appear (`lez_msig_private_e2e` §5). The size is flat in M (`BENCHMARKS.md`).<br>**v0.3:** no fee.<br>**v0.4:** the fee comes from the fee account, flat in M (about 5.07M at base fee 8); no program is named (D18); and nullifiers appear for any outside deposits it collects. | The program read (v0.4), the proofs for the commitments of the notes it spends (which ties it to the transaction that made them, C7), the payee's account read, `getFeeState`, and the connection. | The settle and final frames, then one note frame per member (v0.4: plus fee-note frames), just after inclusion (C1). | Everything. | The action, approvals and status, and the transaction hash; not the balance. | With the group secret they see the new note: the balance, the spent nonce, and that this transaction is the multisig's. |
| **Execute: transfer to a private payee** | **v0.4 only.** As above, but the payee's address appears nowhere in the transaction. The credit is published sealed to the payee's `Recipient`, and only the payee can open and claim it (`v04_private_payee.rs`; `lez_msig_private_e2e` §10).<br>**v0.3:** not available. | As above, without a payee read. | As above. | Everything, including the recipient, which travels in the effect. | The proposal, which names the recipient, and the transaction hash. | The balance drops by the amount; they do not see the payee. |
| **Call** | As an execution, plus whatever public effects the called program has. `v04_private_call.rs` credits a public payee through the native program. Whether the called program's id appears in the transaction is **not checked by any test**. | As for Execute. | As for Execute. | The decoded call: program, rows and data. | The same. | The new note. |
| **Configuration change** (add, remove, threshold, roles, weights, time lock, limits) | An execution with no public credit. That a private config change looks like any other execution on chain is **inferred**: it has not been measured. | As for Execute. | As for Execute. An add also seals the group secret and the newest note to the new member (`msig_members_test` §6). A removal also publishes re-key grant frames (one per remaining room member), so the store node sees that the room re-keyed. | The decoded change. | The same. | See Removal. |
| **Queue, then ExecuteQueued** | Two executions. **Queue:** the window's upper bound is `at_ms + 1`, where `at_ms` is the send time plus 120 s (`settlement.nim`, `QueueSlackMs`). **ExecuteQueued:** the window runs from `eta = at_ms + time lock` to the expiry, and the payee (if any) is credited here. Both bounds are unrounded milliseconds, so the two transactions can be paired, and their difference is the time lock (C2). | As for Execute. | As for Execute, twice. | The queue and the ETA, on the card. | The same. | Queue entries (nonce, proposal id, ETA, expiry) in the note. |
| **Cancel** | An execution with no public credit. It is never time-locked. | As for Execute. | As for Execute. | Which nonces it cancels. | The same. | The new note. |
| **Spend under a limit** | One `Spend` execution. Its window is `[p·period, min((p+1)·period, expiry))`, so the lower bound is a multiple of the limit's period (C2), and the payee and amount are public. **No test runs a Spend over a private PDA** (§3). | As for Execute. | The spend intent's frame and one frame per signature, then the note frames. | The limit, the signers and the amount. | The same. | The new note. |
| **Recovery by scan** | Nothing: it only reads. | `getLastBlockId`, then `getBlockRange` over every block from `from` (default block 1), and on v0.4 the publications too (`exec.rs`, `scan`). The RPC sees a full scan, not which account it is for. | The recovered note, sealed to each member. | Who recovered it. | The transaction hash in the note event. | They can run the same scan, since it needs only the group's viewing key. |
| **Removal** | An execution, like any configuration change.<br>**v0.3, migration (D11):** after the removal, the remaining members create a new multisig under a new group secret and move the vault there with a `Transfer` the old quorum approves. Muster has **no flow and no test** for it. How the move to a private vault shows on chain is untested.<br>**v0.4, rotation (D19):** decided 2026-11-26 and **not built** (exo-3dc). Until it lands, a removal on v0.4 behaves as on v0.3. | As for Execute. | Re-key grant frames. | The room re-keys the removed member out (F-16, `msig_members_test` §4–5). | The same. | Keeps the group secret, so: reads the multisig's state from the chain until migration or rotation; can drain the fee account (v0.4, D17); can stall the multisig by consuming its note (`lez-msig.md` §7); can **never spend**, because the program checks current members (`rules.rs`). See C6 for the room window. |

### 1.2 The public posture

The public posture runs over a public PDA. Every operation is a public transaction from a member's
own funded account. In Muster, that is the member's `lez-member/0` account
(`module/tests/lez_msig_live_e2e.nim`).

| Action | Chain | Sequencer / RPC | Store node / fleet | Room member in the multisig | Room member outside | Removed member |
|---|---|---|---|---|---|---|
| **Create** | The whole configuration: every member's approval key, their roles and weights, the threshold, the time lock, open execution, and the limits. Also the multisig's address and the **creator's paying account**. | The transaction and its connection. | The ceremony's frames (no group secret). | Everything. | Everything the chain shows, plus the room's binding of each approval key to a room member (C10). | n/a |
| **Fund / deposit (from anyone)** | A public transfer naming the payer, the multisig's address and the amount. | The transaction and its connection. | Nothing. | The same as the chain. | The same as the chain. | The same as the chain. |
| **Fee top-up** | n/a: each sender pays its own fee. | n/a | n/a | n/a | n/a | n/a |
| **Propose / approve** | Nothing until execution. | `getAccount` of the multisig, read before proposing (`muster_module.nim`, `musterCoordinateProposeLezMsig`). | As in the private posture. | The decoded action, and who approved. | The same. | Nothing, once re-keyed out. |
| **Execute: public payee** | The whole proposal, every approval key and signature, the executor's signature if one is needed, the **executor's paying account**, the payee, the amount and the window. | As for Create. | As in the private posture, without note frames. | Everything. | Everything. | Everything the chain shows. |
| **Execute: private payee** | n/a: the module refuses it ("a private payee needs a private multisig", `muster_module.nim`). | | | | | |
| **Call** | The target program, its rows, its data, and the approvals. | As for Create. | Frames. | Everything. | Everything. | What the chain shows. |
| **Configuration change** | The full list of changes and the new epoch, which is readable in the state. | As for Create. | Frames, and re-key grants on a removal. | Everything. | Everything. | What the chain shows. |
| **Queue / ExecuteQueued / Cancel** | The queue entries are in the public state, and the windows as in §1.1. | As for Create. | Frames. | Everything. | Everything. | What the chain shows. |
| **Spend under a limit** | The limit id, its signers' keys and signatures, the payee and the amount. | As for Create. | Frames. | Everything. | Everything. | What the chain shows. |
| **Recovery by scan** | n/a: the state is public. | | | | | |
| **Removal** | The `RemoveMember` change. There is no secret to revoke. | As for Create. | Re-key grants. | The room re-keys the removed member out. | The same. | Everything the chain shows. They lose the room (C6). Their approvals stop counting, through the epoch. |

**Fees on the public posture.**
- **v0.3:** a public transaction pays up to its declared cap. A refused one is still included, so
  the state is read back to judge it (`programs/lez-msig/README.md`).
- **v0.4:** each step declares a gas limit fitted to what it meters (`v04_gas.rs`, held by
  `module/tests/msig_gas_test.nim`), because a refused transaction burns its whole limit.

### 1.3 What a disclosure shows (Privacy Architecture 2–3)

**The disclosure tiers are not built** (exo-4cd4). `lez-msig.md` §7 records the design:
- **A narrow audience gets the PDA's viewing key.** It reads everything the key decrypts, from then
  on. On v0.3 that key is `(nsk, vsk)`, so the auditor could also stall the multisig.
- **A wide audience gets the signature-audit export.** This is `coordination/audit.nim`, built and
  generic, held by `module/tests/audit_*_test.nim`. It carries the room's record of who approved
  what, verifiable from the file alone.
- **Ongoing assurance comes from re-disclosure,** checked against the chain's commitment set.

Today only the audit export exists. Muster has no flow that hands over a viewing key, and nothing
that checks a re-disclosure.

## 2. Cross-layer correlations (Privacy 3)

Each entry says what is observable, who observes it, what it reveals, and what mitigates it.
"Inferred" marks a consequence read from the code that has not been measured.

**C1. Room traffic timing against executions.**
- **What the store node sees:**
  - before an execution, a proposal frame and one frame per approval;
  - after a private transaction lands, a burst of frames from the member who settled it: one note
    per multisig member on v0.3, and a note plus a fee note per member on v0.4 (`publishNote`, one
    `publish` per member).
- **What it reveals:**
  - an observer of the store and the chain can line up a burst with a private transaction a block
    or two earlier;
  - the burst's size gives the multisig's member count (inferred);
  - frames are not padded (`session.nim`: `seal(encodeEvent(e))`), so sizes are visible too.
- **What mitigates it:**
  - `mix` (off by default) hides **which member sent** a frame, not who reads a room: reading is a
    store query from the reader's own address;
  - nothing batches, pads or delays note frames.

**C2. Public validity-window bounds.** A program reads no clock, so every time is a validity
window, and the window is public even in a private transaction (`lez-msig.md` §5).
- **Execute:** the upper bound is the proposal's expiry. Muster sets it to the propose time plus a
  default of 7 days, to the millisecond, and a spend's to the spend time plus 24 h
  (`muster_module.nim`). So an execution reveals **when its proposal was made**, to the
  millisecond. That lines up with the proposal frame the store node holds, and is the strongest
  link between a room and an execution.
- **Queue and ExecuteQueued:** they pair up, and their difference is the time lock (§1.1).
- **Spend:** the lower bound is a multiple of the limit's period, which suggests the period.
- **What mitigates it:** `lez-msig.md` §5 says "clients round them to the minute". **The code does
  not** (§4).

**C3. A public payee's credit.** The payee and amount are public. Anyone who knows the payee, and
the payee itself, learns that some private account paid them at that time. With C1 or C2 that
payment can be tied to a room. On v0.4 a private payee removes the payee and the amount from the
chain (§1.1).

**C4. Fee top-ups and deposits from a member's public account.** On v0.4 every private multisig
needs its fee account topped up. Muster's flow tops it up from a member's public account right
before Create (`scripts/lez-msig-private-self-test.sh`: "Create waits for it"), and again
whenever it runs low.
- **What it reveals:** a member's account appearing in a private transaction just before a new
  private account's first transaction, and again in the rhythm of its executions, links that
  account to the multisig (inferred). A top-up's size (229,025 B) sets it apart (C8). A member's
  deposit (Fund) shows the same.
- **What mitigates it:** any public account can top up or deposit, so a member can use one not
  otherwise theirs; topping up early and in larger amounts helps too. Muster does neither by
  itself.

**C5. A deposit from outside the group (v0.4).**
- **What is public:** the vault's address is published at Create (its recovery binding), and every
  outside deposit names it. So the Create and every outside deposit can be linked to one another,
  though not to the multisig's later executions on chain.
- **What the collector's RPC sees:** which deposit each transaction collects (C7).
- **What mitigates it:** none. The address has to be public for anyone to pay it.

**C6. The removed member's window.** Three windows, of different lengths:
- **The room:** from the chain including the removal until the room re-keys. The re-key is done
  once, by the removal's proposer's client (or, when a member removed themselves, the lowest
  remaining member's), when the room sees the change final (`msig_members.nim`). As a backup,
  every member's client re-keys out a removed member a minute after it notices, and the removed
  member's own frames are still accepted for five minutes (`docs/design/signed-room-wire.md`).
  Until then, the removed member reads everything sealed under the current epoch.
- **A removed member still in another lez-msig of the same room keeps the room.** They go on
  reading this multisig's proposals and approvals (`msig_members_test` §5).
- **The chain:** the group secret cannot be revoked. A removed member can read the multisig's
  state, drain the fee account (v0.4), and stall by consuming its note, until the group migrates
  (v0.3, D11, no flow) or rotates (v0.4, D19, not built, exo-3dc). They can never spend.

**C7. The RPC endpoint.** It sees one layer, but it sees more of it than the chain does:
- **v0.4 names the program to the RPC.** Before every private transaction, the executor reads the
  program's account and its mirror commitment (`undisclosed` in `exec.rs`), so D18 hides the
  program from the chain but not from the RPC.
- **The proof requests chain the multisig's transactions together.** Each private transaction
  first asks for the proofs of the notes it spends (`getProofsAndRoot`), and those notes are
  commitments some earlier transaction made. An RPC that serves every member can therefore link the
  multisig's whole history (inferred).
- **Deposit collection:** `getMessagePath(position)` names the deposit each transaction collects.
- **What mitigates it:** using one's own sequencer (invariant 8: user-configurable infrastructure).
  Nothing in the code does it.

**C8. Transaction size.** BENCHMARKS.md measured one size per step on v0.4:

| Step | Size |
|---|---|
| top-up | 229,025 B |
| Create | 237,441 B |
| execute | 237,905 B |
| deposit | 238,217 B |

That run named the program (it was not proved undisclosed). Whether the size alone tells the steps
apart under D18 has **not been measured**. The size does not reveal M: it is flat in M.

**C9. The transaction hash beside the seal.** Each note event carries the transaction's `hash` in
the clear inside the room envelope (`sealNoteTo`). So every room member, in the multisig or not,
can find each of the multisig's transactions on chain. The store node cannot read it.

**C10. The LEZ-to-chat identity binding.**
- **Which signal carries it:** each member's approval key is disclosed in the room, signed by the
  key itself over the room and the member, and author-signed by their room identity (`msigJoin`).
- **Who can read it:**
  - every room member, including those outside the multisig, and a removed member up to their
    removal;
  - nobody else: nothing on chain names the room or a room identity.
- **In the public posture,** the approval keys are on chain (at Create, and in every execution),
  so someone who also holds the room can tie each on-chain key to a room identity.
- **Why it remains:** the program verifies approval keys, and the room needs to know whose key is
  whose to show who approved.
- **The deliberation group** runs on `chat_module`. Its conversation id is announced in the room
  (`lmsig/<ck>/chat`). Whether a store node can read the group's conversation id or roster has not
  been measured (`docs/upstream/chat-module-field-report.md` §5). `lez-msig.md` §8 notes that chat
  0.3.0 sends the room id in the clear and registers key packages with a central HTTP service.

**C11. A shared account used as an approval key** (exo-1f9). In the public posture, one account
used in several multisigs links them on chain (`lez-msig.md` §8). The fresh per-multisig key is the
default.

## 3. Requirement to test (S.7)

**Where the tests live**, and whether CI runs them:

| Shorthand | File | Runs in CI? |
|---|---|---|
| `rules.rs` | `programs/lez-msig/core/tests/rules.rs` | yes, `checks.yml` (`rust-cores`) |
| `v03_state.rs`, `live_public.rs`, `live_private.rs` | `programs/lez-msig/host/tests/` | `live_public` and `live_private` in `lez-e2e.yml` on a v0.3 zone; `v03_state` is **not** in CI |
| `v04_*.rs`, `live_*04.rs` | `programs/lez-msig/lez04/host/tests/` | **not** in CI (exo-7610). The live ones passed by hand on the 0.4.0-rc3 devnet (`lez04/host/tests/CLAUDE.md`) |
| `module.rs` | `programs/lez-msig/module/tests/` and `lez04/module/tests/` | no |
| `*_test.nim` | `module/tests/` | yes, `checks.yml` (`run-suite.sh`) |
| `lez_msig_live_e2e` | `module/tests/` | yes, `lez-e2e.yml` on a v0.3 zone; passed 7/7 on the 0.4 devnet by hand |
| `lez_msig_private_e2e` | `module/tests/` | no (by hand, v0.3 and v0.4) |

**How tests are named.** Rust tests are named by their function. Nim tests are named by the
numbered sections in each file's header (`§n`).

| Req | What it asks | Held by | Not held / gap |
|---|---|---|---|
| **F.1** | M-of-N; members, threshold and action set configurable at creation | `rules.rs`: `create_writes_state_once`, `invalid_configs_refused`, `below_threshold_refused`, `action_set_and_targets`, `runs_iff_weight_reaches_threshold` (proptest); `v03_state.rs`: `public_create_then_pay_two_of_three`; `v04_state.rs`: `create_on_a_fresh_pda_then_pay_two_of_three` | — |
| **F.2** | Lifecycle; async approve or reject; expiry; off-chain collection stated; under the private posture, no payload on chain | `rules.rs`: `expiry`; `lez_msig_driver_test` §2–3 (the effect is the proposal's bytes; an approval counts only for this proposal); `lez_msig_live_e2e` §3, §6; `lez_msig_private_e2e` §5 (the payment's transaction names no member key, approval or create key), §7; **reject:** `decline_final_test` (a decline is final; generic, stub driver) | No lez-msig-specific decline test. Nothing checks the store node's view of a lez-msig room in particular: `store_node_view_test` checks the room in general |
| **F.3** | Execute actions on any program | `rules.rs`: `action_set_and_targets`; `v03_state.rs`: `a_state_anywhere_but_its_pda_is_refused`, `rows_must_be_the_outflows_own`; `v04_private_call.rs`: `a_private_call_runs_with_the_vaults_seed`, `a_call_outside_the_targets_list_is_refused_while_proving` | No test executes a **public** Call on LEZ state; the core rules only. The private Call from the room is exo-0db |
| **F.4** | Target-program registry | **none** | exo-ac1 |
| **F.5** | Configuration changes through the quorum | `rules.rs`: `r2_approvals_before_a_change_stop_counting`, `r2_the_cutoff_is_the_queue`, `config_change_refused_whole_when_invalid`; `v03_state.rs`: `r2_on_chain`; `lez_msig_live_e2e` §4; `msig_members_test` §1–7 | No test runs a config change over a **private** PDA on chain; only `msig_members_test` §6 covers the room side |
| **F.6** | Role separation, and what each role guarantees | `rules.rs`: `the_proposer_must_sign_and_counts_only_if_an_approver`, `a_signer_without_approve_is_refused`, `executor_role_when_execution_is_closed`; `lez_msig_driver_test` §4 | The guarantees are stated in `lez-msig.md` §5 |
| **F.7** | Optional time lock, enforced by the program | `rules.rs`: `timelock_queue_then_execute_at_eta`, `queue_is_bounded`, `cancel_is_immediate_and_unqueues`; `v03_state.rs`: `time_lock_lands_from_its_eta_and_never_after_expiry`; `v04_state.rs`: `a_time_locked_action_lands_from_its_eta`; `lez_msig_live_e2e` §5 | Not over a private PDA |
| **F.8** | Spending limits | `rules.rs`: `spending_limit_skips_quorum_and_lock_up_to_its_amount`, `spend_signatures_are_not_proposal_approvals`; `v03_state.rs`: `spending_limit_on_chain`; `v04_state.rs`: `a_spend_under_a_limit_skips_the_quorum`; `lez_msig_driver_test` §6; `lez_msig_live_e2e` §8; `live_public.rs`: `public_multisig_through_the_module_only` | No Spend over a private PDA |
| **F.9** | An E2EE room per multisig on the chat module, with a defined binding | `lez_msig_live_e2e` §1 (each approval key proved by itself and author-signed), §7; `member_accounts_test` §1–5; `msig_members_test` §4–5 (the room follows removals); `msig_chat_test` §1–7 (the chat group follows the members, on a fake `chat_module`); `membership_handshake_test` (F-16 forward re-keying) | Deliberate deviation: proposals and approvals ride Muster's room, not `chat_module` (S.2, exo-13f) |
| **F.10** | Private by default; a public posture; selective disclosure | **Private:** `v03_state.rs`: `private_create_fund_and_pay`; `v04_private.rs`: `the_private_vault_end_to_end_each_step_paying_its_fee`; `lez_msig_private_e2e` §1–11; `live_private.rs`, `live_private04.rs`, `live_exec04.rs`. **Public:** `live_public.rs`, `live_public04.rs`, `lez_msig_live_e2e` | **Disclosure tiers: none** (exo-4cd4). **"By default": none, and the code defaults to public** (§4) |
| **U.1** | A module other modules call | `module.rs`: `health_derive_and_a_private_create_as_a_job` (v0.3), `health_derive_and_a_fee_top_up_as_a_job` (v0.4); `live_public.rs` (the module's `exec_request`, public posture); `live_exec04.rs` (the v0.4 executor's JSON surface) | The full API (create, propose, approve, reject, execute, configuration and limits, both postures and lines): exo-dbd3 |
| **U.2** | A QML mini-app with the room beside the proposal list | `scripts/lez-msig-self-test.sh`, `scripts/lez-msig-private-self-test.sh` (the real runner, offscreen) | The multisig view: exo-93b. Offscreen, the QML is never instantiated (the self-test says so) |
| **U.3** | A CLI on the headless core | `msig_exec` / `msig_exec04`, driven by `live_public.rs`, `live_exec04.rs`, `lez_msig_private_e2e` (`CliMsigProver`) | A CLI over `logoscore`: exo-c3b |
| **U.4** | An IDL through SPEL | **none** | exo-7610 |
| **U.5** | Per-action public/private documentation | this page, §1 | **none**: nothing checks this page against the code |
| **U.6** | Decode from the exact bytes before signing | `lez_msig_bytes_test` §1–5 (every encoding, held to the program's vectors); `lez_msig_driver_test` §2 (the card's line read from the same bytes; bytes that do not decode are named "unknown"); `lez_msig_recipient_test` §3 (the card names a private payee) | No test checks the card's words for a Call, a Config, a Cancel or a Spend. Arbitrary targets and the registry: exo-ac1 |
| **U.7** | Clear, actionable errors | `rules.rs` (every refusal matched by its `MsigError` code; `r2_approvals_before_a_change_stop_counting` checks the message names the epoch); `live_public.rs` (`below-threshold`); `live_exec04.rs` (1 of 2 answered `refused` with its code); `lez_msig_private_e2e` §6–7; `lez_msig_live_e2e` §4, §6 | The UI pass: exo-93b |
| **R.1** | M distinct current members, exactly this action, no double count, no replay | `rules.rs`: `approvals_must_be_distinct_members_signing_exactly_this`, `below_threshold_refused`, `proposal_bound_to_account_zone_and_create_key`, `nonces_any_order_once_inside_the_window`, `nonce_window_any_order` (proptest), `weights_count`; `v03_state.rs`, `v04_state.rs` (the same on LEZ state); `v04_private.rs` (below threshold and a spent nonce refused while proving) | — |
| **R.2** | A config change voids old approvals; the cutoff is defined | `rules.rs`: `r2_approvals_before_a_change_stop_counting`, `r2_the_cutoff_is_the_queue`, `r2_a_removal_with_a_cancel_stops_the_queued_action`; `v03_state.rs`: `r2_on_chain`; `lez_msig_live_e2e` §4; `msig_members_test` §7 (a queued proposal by a removed member is flagged for cancel) | No R.2 test on v0.4 state (`v04_state.rs` has none); `lez_msig_live_e2e` §4 ran on the 0.4 devnet by hand |
| **S.7 minimums** | Below threshold; R.2; no drain before initialisation | Below threshold: `rules.rs`: `below_threshold_refused`; `lez_msig_live_e2e` §6. R.2: above. Before initialisation: `rules.rs`: `nothing_before_create`; `v03_state.rs`: `nothing_moves_before_create`; `v04_state.rs`: `nothing_moves_before_create` | — |
| **P.1** | Cost, size and proving time, with real proving | Harnesses: `host/src/bin/msig_bench.rs`, `lez04/host/src/bin/msig_bench04.rs` (both refuse dev mode), results in `BENCHMARKS.md`; per-step gas: `v04_gas.rs`: `every_step_metered`, `msig_gas_test` §1–3 | A laptop-class figure: exo-0d3.15 |
| **P.2** | Cost as a function of M; M ≥ 5 viable | the same harnesses, at M = 1, 3, 5, 10 (`BENCHMARKS.md`) | — |
| **S.1** | LEZ private accounts | as F.10 (private) | — |
| **S.2** | The room on the chat module | `msig_chat_test` §1–7 (deliberation, on a fake module) | The full binding: exo-13f |
| **S.3, S.4** | Compatible with, and deployed on, testnet 0.4 | `live_public04.rs`, `live_private04.rs` passed on the 0.4.0-rc3 devnet (`docs/labbook/lez-v04-port.md`) | Run by hand, not in CI |
| **S.5, S.6** | End-to-end tests against a standalone sequencer, in CI, green | `.github/workflows/lez-e2e.yml`: `live_public`, `live_private`, `lez_msig_live_e2e` on a v0.3 zone; green on `main` 2026-11-26 | v0.4 in CI: exo-7610 |
| **S.7** | A test per hard requirement | this section | The rows marked none |
| **S.8** | A README | `programs/lez-msig/README.md` | Documentation, not tested |
| **S.9, S.10** | API and CLI docs | `docs/design/lez-msig-signing.md`; the README's "Use it without Muster" | The full guides: exo-c3b |
| **S.11** | Designs for the mini-app | **none** | exo-05d (M3) |
| **S.12** | The team's own catalogue | `catalog/index.json` lists `lez_msig_module` and `lez_msig_v04_module` | No test |
| **S.13** | Audit | **none** | exo-a80 |
| **S.14** | Decision log | `lez-msig.md` §9, D1–D19 | Documentation |
| **Privacy 1** | No transaction identifies a member's account or role | `lez_msig_private_e2e` §5, §10 (no member key, approval, create key or private payee in the chain's copy); `v04_undisclosed.rs`: `an_undisclosed_execution_names_no_program_and_lands`, `an_undisclosed_claim_against_no_deployed_header_is_refused`; `v04_private_payee.rs`: `a_private_payee_is_paid_by_a_sealed_message_it_alone_claims` | Top-ups and deposits name a member's public account by design (C4); no test measures what timing links |
| **Privacy 2** | No room message identifies a chat identity or its role | `store_node_view_test` §1–3 (no member key or address in any frame, no epoch tag) | The chat-module group's view is unmeasured (C10). Frame counts and timing are visible (C1) |
| **Privacy 3** | Every cross-layer correlation documented | §2 of this page | **none**: documentation |
| Soft: weighted approvals | | `rules.rs`: `weights_count`, `runs_iff_weight_reaches_threshold`; `lez_msig_driver_test` §4 | — |

**Requirements with no test at all:** F.4, U.4, U.5, S.11, S.13 and Privacy 3. **F.10 and U.1–U.3
are partial:** F.10 lacks the disclosure tiers and "by default"; U.1–U.3 lack the full module, the
mini-app view and the `logoscore` CLI.

**Gaps in the private posture.** The private posture has no on-chain test for a configuration
change, a Queue/ExecuteQueued, a Cancel or a Spend. The rules are the shared `msig_core`, so they
hold, but no test proves that these actions' private transactions build and land.

## 4. Where the code and the design doc disagree

These were found while writing this page. Each is left as it is, for a decision.

1. **"Clients round [windows] to the minute"** (`lez-msig.md` §5). They do not:
   - `musterCoordinateProposeLezMsig` and `musterLezMsigSpend` set the expiry as
     `epochTime() * 1000 + ttlMs`;
   - settlement sets Queue's `at_ms` as `now + QueueSlackMs`;
   - `msig_core::claims` passes both through unchanged.

   C2 follows from this.
2. **"Private by default"** (proposal; `lez-msig.md` §1: "the private posture, the default"). In
   the code the default is public:
   - `lez_msig_open` reads `private` with a default of `false` (`muster_module.nim`);
   - the room panel's first button, "Create a k-of-n LEZ multisig", opens a public one, and the
     private one is offered below it as "Or keep it private" (`ui/src/qml/RoomAccounts.qml`).
3. **§7's removal rows** say a removed member loses pending proposals "immediately". Two things
   qualify that:
   - a removed member still in another lez-msig of the room keeps the room (`msig_members.nim`,
     `msigExecutedRemovals`; `msig_members_test` §5). §8 says so; §7 does not;
   - the re-key waits for the room to see the change final, and the removed member's frames are
     still accepted for five minutes (C6).
4. **§7's "existence: no" on chain.** On v0.4 a private Create publishes the vault's address as a
   recovery binding, and outside deposits name it (C5). The chain cannot tell it is a multisig, but
   it can tell that this private account exists and receives deposits.
5. **D18 against the RPC.** D18 hides the program from the chain. The v0.4 executor reads the
   program's account and its mirror commitment from the RPC before every private transaction, so
   the RPC learns it (C7). `lez-msig.md` has no RPC column.
6. **An issue id.** `programs/lez-msig/lez04/CLAUDE.md` cites "exo-0d3.36" for the private Call
   from the room. No such issue exists. The roadmap names it exo-0db.
