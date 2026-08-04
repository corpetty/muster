# Muster — Vision

*Muster* (v.): to assemble, as people gathering for a common purpose. The name is the product: get people into a room, agree on what to do, and do it — without anyone outside the room watching.

## Two missions, one artifact

**First, education.** Muster's initial job is to walk people through the entire lifecycle of a multi-party transaction and make the invisible parts visible: who can see what, at every step, and why. Each stage of the lifecycle is a teaching surface — the client shows what the Logos stack protects at that stage, and names precisely where conventional stacks leak the same information.

**Then, utility.** The teaching client and the real client are the same client. Everything demonstrated is real: the log is really signed, the payloads really are domain-bound, the epochs really re-key. As the educational walkthrough matures, the same surfaces become a usable application for doing things together with people, securely and privately, on the Logos tech stack. There is no "demo mode" that behaves differently from the product — if a step can't be shown truthfully, that's a product bug.

**What we build today does not have to be the ideal.** It has to deliver something real, be honest about exactly what that is, place it against what the rest of the ecosystem does at the same step, and point at what would close the remaining gap. A client that ships a genuine improvement and names its residual leak teaches more than one that waits for a perfect stack, and far more than one that claims the perfect stack already exists. The gaps are curriculum, not embarrassment: knowing *why* a protection is hard, and what specifically would fix it, is the part of this that transfers.

## The lifecycle as curriculum

The intent lifecycle (`draft → proposed → collecting → executable → submitted → settling → final`, per F-3 in `01-furps.md`) is the spine of the walkthrough. At each stage, four questions get answered on-screen:

1. **What just happened?** — the mechanical step, in plain language.
2. **What does Logos protect here?** — what stays inside the conversation boundary, and which property guarantees it (encryption to the member set, replay binding, effect/materialization re-derivation, epoch re-keying…).
3. **Where do others leak?** — the concrete comparison at the same step in a conventional stack.
4. **What's still open, and what would close it?** — the residual gap at this step, named plainly, with the specific thing that would fix it and its honest status: shipped, specified, or neither.

The fourth question is not a disclaimer appended to the third. It is the one that makes the walkthrough a curriculum rather than a pitch, and it is the one a reader can act on — by choosing differently, by contributing, or by knowing what to wait for.

The comparison column writes itself from the status quo:

| Lifecycle stage | Logos/Muster | Conventional stacks |
|---|---|---|
| Compose & propose | Proposal lives in an E2E-encrypted conversation; store nodes see ciphertext | Proposals sit in a coordination service's database (e.g. a transaction service), visible to its operator, often behind an unauthenticated read API |
| Review | Participants review the semantic effect; the client re-derives the materialization and refuses on mismatch | Signers approve opaque calldata or a hash they cannot independently reconstruct; blind signing is the norm |
| Collect signatures | Contributions travel over the conversation transport, bound to environment/account/slot/expiry; useless anywhere else. *What* is being signed and *by whom* stays inside; that this conversation is active, and when, does not (FS-9) | Signatures pool in a centralized service; collection progress, signer identities, and timing are public or operator-visible |
| Submit | The submitted card names exactly what became public and what stayed inside | Whole coordination history often becomes linkable on-chain and in indexers; RPC providers see origin metadata |
| Settle & finality | Finality is driver-described; reorgs surface honestly as state transitions | Finality is assumed; reorgs silently rewrite history in UIs |
| Membership over time | Epoch re-keying: new members provably cannot read the past; removal rotates keys immediately | Chat and signing membership conflated or unmanaged; departed members retain full history |
| Infrastructure | No server-side state, no telemetry; store nodes and RPC are untrusted and user-chosen — but untrusted is not blind: a store node still learns the conversation graph from subscription shape and timing (FS-9). Closing that needs a mixnet, not an app change | Vendor servers hold application state; telemetry and phone-home are default |

This table is illustrative, not normative — the walkthrough's claims about *Logos* must trace to a FURPS requirement and its test, and claims about *others* must cite observable, current behavior of the named system.

## The fourth question, worked: the conversation graph

Our largest open gap is the worked example for how question 4 should read, and its answer is usefully complicated.

**The gap.** Under F-15, each conversation gets its own content topic and the client subscribes to the topics of every conversation it is in. A store node therefore sees a client's subscription set and its publish/fetch timing — the conversation graph, pseudonymously. End-to-end encryption does not touch this, and neither does running your own node: self-hosting protects the operator's own metadata, not that of the people they talk to, and a node operator can invert the threat by serving content from their own node to learn when a target fetches it.

**What would close it.** A mixnet at the transport layer. Not an application change, and not Tor — Tor hides *who by IP*, not *what links to what* or *when*.

**Its honest status, as of 2026-08.** Specified but early, implemented but partial, and not near-term on the roadmap:

- `LOGOS-MIXNET` exists as a specification (`logos-lips`, branch `anoncomms/logos-mixnet-lip`, added 2026-07-30) alongside a real supporting body of work — `LIBP2P-MIX`, cover traffic, DoS protection, LIONESS, RLN spam protection. But its status field reads **`raw`**, the earliest lifecycle stage, and its own rationale section says *"To be defined."*
- The implementation is a testnet proof-of-concept: IPv4-only, and integrated into **send only** — receive over mix is not there.
- The published Messaging roadmap's near-term milestones are RLN, QUIC, the Reliable Channel API, and Status integration. Mix is not among them.

That three-part answer — specified, partially built, not scheduled — is more useful to a reader than either "solved soon" or "broken." It tells them what to watch, what to contribute to, and what to assume in the meantime. Every question-4 answer should land somewhere on that same scale and say which rung it is on.

## Honesty rules for the educational layer

- Every "Logos protects X" claim maps to a requirement ID in `01-furps.md` and at least one test that fails if it stops being true.
- Every "others leak X" claim is specific and verifiable — name the system, the step, and the observer. No strawmen: where a conventional stack does something well, say so.
- The walkthrough never simulates a guarantee the running code doesn't enforce. The prototype's re-materialization strip was theater; in Muster it is the check (F-4).
- **Separate content from metadata, and say where the line is (FS-9).** Muster protects message and effect *content* strongly. It does not hide the conversation graph: with one content topic per conversation, a store node sees which topics a client subscribes to and when it publishes and fetches. A curriculum that teaches "who can see what at every step" and then quietly omits the observer who sees the most is not teaching, it is marketing. Name the gap at the step where it applies, name what would close it (a mixnet, not an app change), and do not let "untrusted infrastructure" stand in for "blind infrastructure."
- Where a comparison is *unfavourable* at a given step, keep it in. The teaching value of a stack is what it makes visible, including about itself.
- **Every gap points at a fix, and the fix carries its real status.** Name the specific mechanism that would close it, then say where it actually stands — *shipped*, *specified* (with its LIP status and how early that is), *partially implemented* (with what the partial covers), or *neither*. A roadmap link is evidence, not a promise: cite it where it exists and say plainly when it doesn't. "Coming soon" is not a status and never appears in the walkthrough.

## Sequencing

Education does not add a phase — it rides the plan in `02-implementation-plan.md`. The headless phases (P0–P3) build the guarantees; the UI phase (P4) is where the walkthrough becomes tangible, since the six-step legend and the room surfaces are already its skeleton. Walkthrough copy and comparison content grow alongside each phase's accept tests, so the curriculum can never describe a property the code doesn't yet have.

The rules above are enforceable, not aspirational: claims are structured data with resolvable evidence, validated in CI (ADR-012). A protection claim whose test is deleted fails the build; a gap claim must carry a fix and a status from a closed vocabulary. CI cannot check that a claim is *true* — that stays the author's obligation — but it can make a silently vanishing caveat impossible, and that is the failure mode honest documentation actually has.
