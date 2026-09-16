# Proposal: allowed *effects* — the host hook that makes muster the permissions protocol

**Status:** proposal to the Basecamp / logos-core side, 2026-09-16. muster's half is built (`coordinate_authorization`, `coordinate_check_authorization`, `intents/authorization.nim`, `authorization_test`). Tracked as `exo-002.7` (M7 of the action-manifest epic, `docs/design/action-manifest.md`). Reads with `basecamp-capability-alignment.md`.

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

- **Nothing is authorized before agreement.** A non-executable intent yields `{error: not-executable}`. The room's threshold, rounds, and membership model came from the driver (invariant 6); the host does not re-implement any of it.
- **Bound to one call.** The root is the materialization the room reviewed and every client re-derived (invariant 1); the context is environment + account + slot + expiry (invariant 2). A grant for one call is worthless for any other.
- **Checkable without muster.** `checkAuthorization` is pure: recover the issuer from the signature over the digest, require `slot == intentId`, `now <= expiry`, and, supplied by the host, the root of the call about to be dispatched and the issuers the policy trusts. Refuse-on-mismatch with a named reason. The digest is a domain-separated dCBOR hash-input record (invariant 5), so any language can recompute it.
- **The plugin dispatches nothing** (invariant 3). It says what the room decided in a form the host can check.

## What the host would add

Extend the access policy from callers to **effects**. Proposed shape (`infra/access-policy.effects.example.json` is a worked example):

```json
{
  "version": 2,
  "mode": "enforce",
  "restrictions": {
    "muster_module": { "allowedCallers": ["muster_ui"] }
  },
  "gatedEffects": {
    "lez_core.transfer_private": {
      "requires": "muster.authorization.v1",
      "trustedIssuers": ["0x…alice", "0x…bob"],
      "maxAge": 600
    },
    "safe.execute": { "requires": "muster.authorization.v1", "trustedIssuers": ["*"] }
  }
}
```

The hook, at the point the broker dispatches a call to a capability named in `gatedEffects`:

1. Require an authorization to accompany the call (a header on the `lp_*` invoke, or a preceding `coordinate_check_authorization`-style handshake, whichever the broker prefers).
2. Recompute the **materialization root of the call it is about to make** (for an invoke: the dCBOR encoding of `{module, method, args}` under `muster.invoke.<module>.<method>.v1`, which `lidl-gen driver` already emits byte-exact) and pass it as `expectedRoot`.
3. Check issuer ∈ `trustedIssuers`, `now <= expiry`, `slot == intentId`, signature recovers.
4. Refuse the dispatch on any failure. A refusal is a refusal, never a false success (the same rule the invoke gate already follows).

## Why this is the right seam

- It is **core-to-core** (`muster_module → target`), the pattern the alignment doc already sanctions. The UI never carries authority.
- It composes with the existing capability policy rather than replacing it: `allowedCallers` still says who may call; `gatedEffects` says what must have been agreed first.
- The capability name is the one the driver manifest already carries (SDK #2), so a muster is addressable the same way from the compose menu, the readiness card, and the policy file.
- It is how muster becomes the permissions protocol *emergently*: which effects are gated falls out of which module actions a room can coordinate, not out of an ACL someone designs.

## What to confirm with the Basecamp side

1. Can the broker consult an external module, or a supplied header, **before** dispatch at all? This is the single question everything else depends on.
2. Where does the root recomputation live: broker-side (preferred, trust-minimal) or muster-side with the broker trusting muster's answer (weaker, but a start)?
3. Is the policy file the right home for `trustedIssuers`, or should issuers be the room's own roster, published by muster? (The latter keeps the policy static and the roster dynamic.)

## Open, muster-side

- Issuer set semantics under an **anonymous** driver: the grant is signed by *an* instance, which names it. For an anonymous room the grant should be a threshold signature over the same digest, which the FROST driver would produce once it is a real threshold scheme (see the claims registry's FROST gap).
- `expiry` is fixed at 600s. It should come from the driver descriptor once finality types carry a settlement horizon.
