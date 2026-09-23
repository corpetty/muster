# Proposal: allowed *effects* — the host hook that makes muster the permissions protocol

**Status:** proposal to the Basecamp / logos-core side, 2026-09-16; **checked against the LIPs draft branch head the same day — see §"Against the LIPs branch head", which supersedes the bespoke hook below where they differ.** muster's half is built (`coordinate_authorization`, `coordinate_check_authorization`, `intents/authorization.nim`, `authorization_test`). Tracked as `exo-002.7` (M7 of the action-manifest epic, `docs/design/action-manifest.md`). Reads with `basecamp-capability-alignment.md`.

## The want, in one line

*What am I allowing to happen, before it is allowed to happen?* Today the host's access policy answers **who may call whom** (`infra/access-policy.json`: `allowedCallers`). It cannot answer *what they agreed to*. muster already produces that answer, the room's fold to `executable` over an exact materialization, but nothing in the host asks for it before a gated module call runs. This proposal is the hook.

## What muster provides (built)

For an intent the room has folded to **executable**, and only then, `coordinate_authorization(intent_id)` returns a signed grant:

```json
{
  "format": "muster.authorization.v1",
  "intentId": "0x1f23…",
  "capability": "lez_core.transfer_private",
  "materializationRoot": "0x…",          // the exact bytes the room agreed on (F-4)
  "environment": "chain:31337",          // replay binding, invariant 2
  "account": "safe:0x5fbd…",
  "slot": "0x1f23…",                     // = intentId
  "expiry": 1789544400,
  "issuer": "0x…",                       // this instance's secp256k1 authorization identity
  "signature": "0x…",                    // over the domain-separated digest muster.authorization.v1
  "digest": "0x…"
}
```

Properties the host can rely on:

- **Nothing is authorized before agreement.** A non-executable intent yields `{error: not-executable}`. The room's threshold, rounds, and finality came from the driver (invariant 6); the host does not re-implement any of it.
- **Bound to one call.** The root is the materialization the room reviewed and every client re-derived (invariant 1); the context is environment + account + slot + expiry (invariant 2). A grant for one call is worthless for any other.
- **Checkable without muster.** `checkAuthorization` is pure: recover the issuer from the signature over the digest, require `slot == intentId`, `now <= expiry`, and, supplied by the host, the root of the call about to be dispatched and the issuers the policy trusts. Refuse-on-mismatch with a named reason. The digest is a domain-separated dCBOR hash-input record (invariant 5), so any language can recompute it.
- **The plugin dispatches nothing** (invariant 3). It says what the room decided in a form the host can check.

## What the host would add

Extend the access policy from callers to **effects**. The policy names an authorization **format** and the **issuers** it trusts — not a module. muster is one *provider* of the `muster.authorization.v1` format (today the only one, said plainly); a different coordinator could issue the same format later without the host changing. Proposed shape (`infra/access-policy.effects.example.json` is a worked example):

```json
{
  "version": 2,
  "mode": "enforce",
  "restrictions": {
    "muster_module": { "allowedCallers": ["muster_ui"] }
  },
  "authorizationFormats": {
    "muster.authorization.v1": {
      "digest": "muster.authorization.v1 hash-input record (dCBOR, domain-separated)",
      "signature": "secp256k1 recoverable, 65 bytes, over the digest",
      "providers": ["muster_module"]
    }
  },
  "gatedEffects": {
    "lez_core.transfer_private": {
      "format": "muster.authorization.v1",
      "issuers": ["0x…alice", "0x…bob"],
      "maxAge": 600
    },
    "safe.execute": { "format": "muster.authorization.v1", "issuers": ["*"] }
  }
}
```

**What this does and does not impose.** Nothing changes for a call whose capability is not listed: `gatedEffects` is empty by default. Gating applies to *every* caller of a listed capability, muster's own execution path included — it presents the grant it issued like anyone else, no bypass. *Producing* a grant needs a provider of the format (muster, because only muster holds the room's fold). *Verifying* one does not: the check is pure (recompute the digest, recover the signer, compare slot / expiry / root), so the broker implements it in its own language and never loads or calls a provider at dispatch time. The one muster-shaped piece the broker needs is the canonical encoding of the call it is about to make, to compare roots — see "Merkleized module calls" below for why that piece disappears once the platform's own canonical encoding ships.

The hook, at the point the broker dispatches a call to a capability named in `gatedEffects`:

1. Require an authorization to accompany the call (a header on the `lp_*` invoke, or a preceding `coordinate_check_authorization`-style handshake, whichever the broker prefers).
2. Recompute the **materialization root of the call it is about to make** (for an invoke: the dCBOR encoding of `{module, method, args}` under `muster.invoke.<module>.<method>.v1`, which `lidl-gen driver` already emits byte-exact) and pass it as `expectedRoot`.
3. Check issuer ∈ `issuers`, `now <= expiry`, `slot == intentId`, signature recovers under the declared `format`.
4. Refuse the dispatch on any failure. A refusal is a refusal, never a false success (the same rule the invoke gate already follows).

## Why this is the right seam

- It is **core-to-core** (`muster_module → target`), the pattern the alignment doc already sanctions. The UI never carries authority.
- It composes with the existing capability policy rather than replacing it: `allowedCallers` still says who may call; `gatedEffects` says what must have been agreed first.
- The capability name is the one the driver manifest already carries (SDK #2), so a muster is addressable the same way from the compose menu, the readiness card, and the policy file.
- It is how muster becomes the permissions protocol *emergently*: which effects are gated falls out of which module actions a room can coordinate, not out of an ACL someone designs.

## Merkleized module calls, CDDL/CBOR, and what this needs from them

The platform's draft direction (LOGOS-MODULE-*, cdCDDLe — tracked, not targeted; ADR-009 / invariant 5b) is that every module-to-module message has a canonical CBOR encoding under a ratified CDDL schema, with a **schema root** identifying the type and a digest committing to the bytes, so any party can recompute and verify what was sent. Where that lands relative to this proposal:

- **Not a prerequisite for the gate.** A grant commits to a hash of the agreed call under muster's own deterministic encoding (invariant 5) and is checked by signature recovery. That works today, with no Merkleization anywhere.
- **It is what removes the last muster-shaped piece from the broker.** Step 2 above asks the broker to recompute the root of the call it is dispatching. Once the platform encodes every call canonically and the broker already computes that digest for its own verification, the grant's root simply *is* the platform's call digest — muster would commit to the platform's canonical bytes rather than its own `muster.invoke.*` encoding, and the broker compares two digests it already has. Until then the broker carries the dCBOR encoder (small, ours, deterministic) or asks muster to recompute (weaker: muster on the dispatch path).
- **Schema roots slot into the `format` and `capability` fields.** When cdCDDLe ratifies, the grant's schema id migrates from the hand-assigned `muster.authorization.v1` to the schema root, exactly as every muster signing payload is designed to (invariant 5b). The capability name stays stable across that migration; that is why the two are separate fields.
- **Inclusion proofs would shrink the evidence.** Today a log proof (`coordinate_proof`) is the whole slice — every event, recomputed. A Merkleized log yields a compact proof that the executable fold is in the room's history, which a grant could carry so a verifier checks membership without the whole log. Two cautions: the events themselves stay sealed to the epoch (a verifier outside the room checks *structure*, not content), and even structure is metadata — which events exist and when — so what a grant carries out of the room is a disclosure decision (FS-9), not a free upgrade.
- **"Verified" module inputs.** The bigger prize is upstream of the gate: provenance today grades what one module tells another as an *external read* — attested, trusted by name. With canonical encoding + proofs on every call, those inputs become *verified-locally* (F-10), the same grade a proof-checked chain read gets. That is the security half of "a permissions and security protocol"; the gate is the permissions half. The gate can ship first; the security half needs the platform's encoding to ratify.

What muster has today, stated plainly: deterministic dCBOR encoding and domain-separated digests on every signing path; content-addressed, hash-linked events (each id commits to its parents, a Merkle-DAG in the loose sense) and a state digest; whole-slice log proofs; and Merkle-Patricia proof checking for *chain* state reads (`verifyMptProof`, the Nimbus verified-proxy core). It does **not** yet have Merkle *inclusion* proofs over the log, a CDDL parser, or schema roots — those are deferred to ratification (ADR-009), and no module-to-module call in the platform carries a proof today as far as this repo can see.

## Against the LIPs branch head (2026-09-13, `logos-co/logos-lips` PR #317, all specs `raw`)

Checked at `draft/logos-core-module-specs` @ `e50463f`. The branch is still an open, early-WiP PR; every LOGOS-MODULE-* spec on it is **Status: raw**. Four findings, each of which moves this proposal.

**1. The hook already exists as a module contract: LOGOS-MODULE-CAPABILITY-AUTHORITY (slug 312).** A *Capability Authority* provider "evaluates authority policy and manages grants for consumers"; Runtime "supplies authenticated call context and remains responsible for … enforcement". Runtime MUST obtain an `allow` decision before a call, publication, or subscription on a route (§3.1), with the request carrying the route and "an `access` value containing the one method or event declaration being checked". Grants (§6) are durable policy state for one target instance, scoped by `provider_access_scope` (exact contract root + method/event roots + routes + providers), with `issued_at` / `expires_at` / `status` and revocation, and any consumer *authorized by policy* may call `issue_grant`. So the shape this proposal invents — `gatedEffects` beside `allowedCallers`, checked before dispatch — is the spec's shape, and the right ask is not "add a hook" but **"let muster be a consumer that policy permits to `issue_grant`"**: when a room folds to executable, muster issues a Capability Authority grant for `target = the module`, `scopes = [provider_access: that contract, that method, that route]`, `expires_at = the room's expiry`. Runtime then enforces with **zero muster-specific code**, and revocation, caching (§8), audit (§9) all come for free. The muster-shaped `format` + `issuers` policy in this doc becomes the *policy input* that authorizes muster's `issue_grant` — protected trust input (§4), never something the evaluate request supplies.

**2. What the Capability Authority scope cannot express — and the one extension to ask for.** Scopes narrow to contract, method, event, route, provider. They do **not** bind argument values: "Request and response value roots normally do not exist when an allow decision is made" (§4). Muster's grant commits to the exact **materialization root** (the agreed args). Under the spec, that binding lands in *audit*, not prevention: an allow decision may require `retain-root` and the Runtime-controlled invocation boundary retains the call's request root in the call audit record (§4, §9), where it can be compared to the intent's root after the fact. To get **prevention** — refuse a call whose args differ from what the room agreed — `provider_access_scope` needs one optional field: an **expected request value root** the enforcement boundary compares against the mandatory payload commitment before dispatch. That is the concrete spec ask. Until then, a muster-issued grant narrowed to method + route + short expiry, plus retained roots for audit, is what the platform can enforce.

**3. Payload commitments are mandatory and platform-computed — but under BLAKE3-256, not muster's SHA-256.** "Runtime and Transport compute and verify the mandatory payload commitments independently of authority policy" (§4); audit-retention policy "cannot disable commitment computation" (Security Considerations). Every call already has a request/response value root. The hash profile's mandatory suite is `logos.hash-suite.blake3-256` (Hash Profile §6.1; Transport §10.1 rejects any other suite, no negotiation). Muster's signing paths hash with SHA-256 (and keccak for EIP-712). For a muster grant's root to *equal* the platform's call root — the "broker never needs muster's encoder" outcome — muster must compute the platform's root: the canonical semantic value tree under the method's schema root, BLAKE3-256. That is an implementation of the hash profile + commitment model, not a flag. Until the specs ratify, the grant keeps its own root and the comparison is muster-side or audit-side.

**4. Verified views are exactly Merkle inclusion/absence proofs, and they are `raw`.** Hash Profile §8: "typed partial disclosures over a committed value root … conventional Merkle inclusion or absence proofs over the semantic value tree"; each view carries schema root, value root, profile, suite, path, disclosed value, proof material. This is the "auto-verified data" — and it is what would upgrade a module's answer from *attested* to *verified-locally* in muster's provenance (F-10). The transport spec notes a full message already carries its whole value, so views matter for *partial* disclosure and for third-party verification of retained roots. None of it is ratified: PR #317 is open, every spec is raw, and muster's ADR-009 deferral stands.

**What this changes in the plan.** M7's upstream half is re-targeted from "add a hook" to two asks against slug 312: (a) policy that authorizes muster to `issue_grant` narrowed to a method + route + expiry, and (b) the expected-request-root extension to `provider_access_scope` for argument-level prevention. muster's `coordinate_authorization` stays as the *interim* artifact (checkable by anyone, usable today by a broker that does not yet implement 312) and becomes the input muster translates into an `issue_grant` call once a Capability Authority provider exists. A follow-on epic — the hash-profile/commitment-model implementation (BLAKE3-256 semantic value tree) — is the prerequisite for equal roots and for verified module inputs; it is sized separately, not part of exo-002.

## What to confirm with the Basecamp side

Revised after reading the draft (the earlier four questions are answered or reframed by it):

1. **Is Basecamp implementing LOGOS-MODULE-CAPABILITY-AUTHORITY (312), and on what timeline?** If yes, the hook exists and the ask is policy: authorize `muster_module` to `issue_grant` for `provider_access` scopes narrowed to a method + route + expiry on the targets a room coordinates. If no, the interim path is this doc's `format` + `issuers` check in the broker.
2. **Would the editors accept an optional *expected request value root* on `provider_access_scope`** so the enforcement boundary can refuse a call whose args differ from what was agreed, rather than only retaining the root for audit? This is the one spec change muster needs for argument-level prevention.
3. **Who is the issuer of record** for a room's grant: the muster instance that submits, or a threshold signature the room produces over the same digest? The spec's `consumer` is an authenticated module-instance address, which names the instance either way; every muster driver is named (ADR-015), so that names nothing the room does not already know.
4. **Hash-suite timeline.** Commitments are BLAKE3-256 under the draft; muster signs under SHA-256/keccak. When the profile ratifies, muster implements it and grant roots become the platform's call roots; until then roots are compared muster-side or in audit.

## Open, muster-side

- Issuer set semantics: the grant is signed by *an* instance, which names it (fine inside a named room, ADR-015). A grant that speaks for the room as one signer would be a threshold signature over the same digest, which the FROST driver would produce once it is a real threshold scheme (see the claims registry's FROST gap).
- `expiry` is fixed at 600s. It should come from the driver descriptor once finality types carry a settlement horizon.
