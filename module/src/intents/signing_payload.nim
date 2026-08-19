## Replay-bound signing payloads (spec:
## contracts/specs/derived-exo-307.spec.json, invariant 2, catastrophic).
##
## Every signing payload commits to (environment, account, slot, expiry) — and to
## the materialization being signed — inside its deterministically encoded bytes.
## A signature is therefore worthless anywhere else: collected under one context
## it fails verification under every other, and a payload past its committed
## expiry is refused even when the other three fields still match (FS-3).
##
## The signer here is a documented P0/P1 stand-in — a keyed hash (MAC) over the
## domain-separated payload bytes. Real secp256k1 signing arrives at P2/P6; the
## replay-binding property is a property of what the PAYLOAD commits to, not of
## the signature primitive, so it holds under either.

import ../dcbor/dcbor
import ../hashing/hash_input

type
  SigningContext* = object
    environment*: string   ## environment id (chain / network)
    account*: string       ## account or membership commitment
    slot*: string          ## serialization slot
    expiry*: uint64        ## unix-time expiry (payload invalid at/after now > expiry)

  SigningPayload* = object
    context*: SigningContext
    materializationRoot*: seq[byte]   ## the materialization these bytes authorize

  Signature* = object
    bytes*: seq[byte]

proc encodePayload*(p: SigningPayload): seq[byte] =
  ## Deterministic, domain-separated encoding committing to all four context
  ## fields plus the materialization root. Every field is load-bearing in the
  ## signed bytes — change any one and these bytes change.
  encodeHashInput(hashInput("muster.signing-payload.v1", @[
    ("environment", cbText(p.context.environment)),
    ("account", cbText(p.context.account)),
    ("slot", cbText(p.context.slot)),
    ("expiry", cbUint(p.context.expiry)),
    ("materialization", cbBytes(p.materializationRoot)),
  ]))

proc sign*(p: SigningPayload, key: string): Signature =
  ## Stand-in signer: a keyed digest over the payload's domain-separated bytes.
  Signature(bytes: @(digest(hashInput("muster.sig.v1", @[
    ("key", cbText(key)),
    ("payload", cbBytes(encodePayload(p))),
  ]))))

proc verify*(sig: Signature, p: SigningPayload, key: string,
             verifyContext: SigningContext, now: uint64): bool =
  ## A signature verifies only at exactly the context it was bound to, and only
  ## before expiry. Order matters for none of it — all three must hold.
  if p.context != verifyContext: return false   # bound to one (env, account, slot, expiry)
  if now > p.context.expiry: return false        # expiry enforced independently
  sign(p, key).bytes == sig.bytes                # signature valid over the payload bytes
