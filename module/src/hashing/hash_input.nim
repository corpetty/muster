## Domain-separated hash-input records — the only way the module hashes on the
## signing path (spec: contracts/specs/derived-exo-449.spec.json, invariant 5,
## criticality catastrophic).
##
## Every signing-path hash goes through this typed record rather than ad-hoc
## byte concatenation. The domain tag is committed *inside* the deterministically
## encoded bytes, so the same underlying content under a different domain encodes
## differently and therefore hashes differently — domain separation is
## load-bearing, not decorative (mirrors FS-3).

import ../dcbor/dcbor
import sha256

export sha256.Sha256Digest, sha256.toHex

type
  HashInput* = object
    domain*: string                    ## e.g. "muster.event.transfer.v1"
    fields*: seq[(string, CborValue)]  ## typed, named content fields

proc hashInput*(domain: string, fields: seq[(string, CborValue)] = @[]): HashInput =
  HashInput(domain: domain, fields: fields)

proc encodeHashInput*(hi: HashInput): seq[byte] =
  ## The structured framing every signing-path hash commits to: the dCBOR
  ## encoding of the 2-element array [domain, {fields}]. Deterministic by
  ## construction (dcbor), domain-separated by construction (domain is element 0).
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in hi.fields:
    pairs.add (cbText(k), v)
  encode(cbArray(@[cbText(hi.domain), cbMap(pairs)]))

proc digest*(hi: HashInput): Sha256Digest =
  ## The one hash call site: sha256 over the domain-separated framing. Nothing
  ## on the signing path hashes raw concatenated bytes; it hashes this.
  sha256(encodeHashInput(hi))
