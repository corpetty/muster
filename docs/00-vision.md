# Muster — Vision

*Muster* (v.): to assemble, as people gathering for a common purpose. The name is the product: get people into a room, agree on what to do, and do it — without anyone outside the room watching.

## Two missions, one artifact

**First, education.** Muster's initial job is to walk people through the entire lifecycle of a multi-party transaction and make the invisible parts visible: who can see what, at every step, and why. Each stage of the lifecycle is a teaching surface — the client shows what the Logos stack protects at that stage, and names precisely where conventional stacks leak the same information.

**Then, utility.** The teaching client and the real client are the same client. Everything demonstrated is real: the log is really signed, the payloads really are domain-bound, the epochs really re-key. As the educational walkthrough matures, the same surfaces become a usable application for doing things together with people, securely and privately, on the Logos tech stack. There is no "demo mode" that behaves differently from the product — if a step can't be shown truthfully, that's a product bug.

## The lifecycle as curriculum

The intent lifecycle (`draft → proposed → collecting → executable → submitted → settling → final`, per F-3 in `01-furps.md`) is the spine of the walkthrough. At each stage, three questions get answered on-screen:

1. **What just happened?** — the mechanical step, in plain language.
2. **What does Logos protect here?** — what stays inside the conversation boundary, and which property guarantees it (encryption to the member set, replay binding, effect/materialization re-derivation, epoch re-keying…).
3. **Where do others leak?** — the concrete comparison at the same step in a conventional stack.

The comparison column writes itself from the status quo:

| Lifecycle stage | Logos/Muster | Conventional stacks |
|---|---|---|
| Compose & propose | Proposal lives in an E2E-encrypted conversation; store nodes see ciphertext | Proposals sit in a coordination service's database (e.g. a transaction service), visible to its operator, often behind an unauthenticated read API |
| Review | Participants review the semantic effect; the client re-derives the materialization and refuses on mismatch | Signers approve opaque calldata or a hash they cannot independently reconstruct; blind signing is the norm |
| Collect signatures | Contributions travel over the conversation transport, bound to environment/account/slot/expiry; useless anywhere else | Signatures pool in a centralized service; collection progress, signer identities, and timing are public or operator-visible |
| Submit | The submitted card names exactly what became public and what stayed inside | Whole coordination history often becomes linkable on-chain and in indexers; RPC providers see origin metadata |
| Settle & finality | Finality is driver-described; reorgs surface honestly as state transitions | Finality is assumed; reorgs silently rewrite history in UIs |
| Membership over time | Epoch re-keying: new members provably cannot read the past; removal rotates keys immediately | Chat and signing membership conflated or unmanaged; departed members retain full history |
| Infrastructure | No server-side state, no telemetry; store nodes and RPC are untrusted and user-chosen | Vendor servers hold application state; telemetry and phone-home are default |

This table is illustrative, not normative — the walkthrough's claims about *Logos* must trace to a FURPS requirement and its test, and claims about *others* must cite observable, current behavior of the named system.

## Honesty rules for the educational layer

- Every "Logos protects X" claim maps to a requirement ID in `01-furps.md` and at least one test that fails if it stops being true.
- Every "others leak X" claim is specific and verifiable — name the system, the step, and the observer. No strawmen: where a conventional stack does something well, say so.
- The walkthrough never simulates a guarantee the running code doesn't enforce. The prototype's re-materialization strip was theater; in Muster it is the check (F-4).

## Sequencing

Education does not add a phase — it rides the plan in `02-implementation-plan.md`. The headless phases (P0–P3) build the guarantees; the UI phase (P4) is where the walkthrough becomes tangible, since the six-step legend and the room surfaces are already its skeleton. Walkthrough copy and comparison content grow alongside each phase's accept tests, so the curriculum can never describe a property the code doesn't yet have.
