## The null ladder (exo-1ec.5, docs/design/null-ladder.md).
##
## The status quo is a null cipher: the system is built with the null in place, and the
## nulls are replaced one at a time — each real level the LIMITING CASE of the null at the
## SAME seam (the correspondence principle), never a different code path. An unencrypted
## channel is an encrypted channel with a transparent key; a local transport is a delivery
## node with no distance. So the level is a TYPED ATTRIBUTE a seam declares and a consumer
## READS — never inferred by branching on a concrete type — and the null carries the same
## metadata envelope as the real thing (a consumer reads a level, never a field's presence).
##
## Three INDEPENDENT axes. A level on one says nothing about another: a signed artifact is
## not a private one; an encrypted channel to an unknown peer is not an authenticated one.
## They do not substitute — keep them separate.
##
## The hazard this is designed against: TLS shipped NULL and export-grade cipher suites and
## got downgrade attacks (FREAK, Logjam). The lesson is in the type here, not just the
## surface: an upgrade that cannot be satisfied REFUSES (`require` raises `DowngradeRefused`)
## — it never silently proceeds at the null. The null is an explicit, displayed level, never
## a fallback the code slips to when the real option fails.
##
## Invariant guards:
##   10 — signing is already refused when an input's origin is unaccountable. The PROVENANCE
##        rung EXTENDS that refusal into a typed level; it does not duplicate the check.

type
  SecurityAxis* = enum
    axAuthentication  = "authentication"   ## who is speaking now
    axProvenance      = "provenance"       ## where this came from, what path it took
    axConfidentiality = "confidentiality"  ## who can read it

  Rung* = enum
    ## The ladder is ORDERED, and consumers compare with `>=`, never `== rungReal` — so a
    ## richer rung can be inserted between these two later without touching a call site.
    rungNull = 0     ## the transparent limiting case — explicit, displayed, legitimate
    rungReal = 1     ## the attested / bound / encrypted real thing

  AxisLevel* = object
    rung*: Rung
    mechanism*: string   ## the concrete mechanism at this rung, NAMED for display — so the
                         ## UI shows "bound secp256k1 identity" / "plaintext" /
                         ## "ECIES epoch", not a bare "null" / "real" the reader can't act on

  SecurityLevel* = object
    ## The metadata envelope every seam carries — the null carries it too, same shape as the
    ## real thing. There is no "absent" state: an axis a seam does not itself provide is
    ## `rungNull` with a mechanism that says so, never a missing field.
    axes*: array[SecurityAxis, AxisLevel]

  DowngradeRefused* = object of CatchableError
    ## Raised when a consumer requires a rung the seam cannot meet. It is REFUSAL, not a
    ## signal to retry at the null — there is deliberately no `orNull` variant of `require`.

proc axisLevel*(rung: Rung, mechanism: string): AxisLevel =
  AxisLevel(rung: rung, mechanism: mechanism)

proc securityLevel*(auth, prov, conf: AxisLevel): SecurityLevel =
  ## Build an envelope from its three axes. All three are always present (the null too).
  SecurityLevel(axes: [auth, prov, conf])

proc rungOf*(l: SecurityLevel, axis: SecurityAxis): Rung = l.axes[axis].rung
proc mechanismOf*(l: SecurityLevel, axis: SecurityAxis): string = l.axes[axis].mechanism

proc atLeast*(l: SecurityLevel, axis: SecurityAxis, want: Rung): bool =
  ## Does the seam meet `want` on `axis`? A pure predicate — the caller decides what to do.
  l.axes[axis].rung >= want

proc require*(l: SecurityLevel, axis: SecurityAxis, want: Rung) =
  ## The anti-downgrade gate. A consumer that NEEDS `want` on `axis` calls this; if the seam
  ## cannot meet it, this REFUSES (raises) — it never returns, never falls back to the null.
  ## Negotiation is not a silent downgrade (the honesty rule, in the type).
  if l.axes[axis].rung < want:
    raise newException(DowngradeRefused,
      "downgrade refused: " & $axis & " is at '" & l.axes[axis].mechanism &
      "' (" & $l.axes[axis].rung & "), the caller requires " & $want &
      " — the real level is unavailable, so this refuses rather than proceed at the null")

proc combine*(levels: varargs[SecurityLevel]): SecurityLevel =
  ## The ACTIVE level across several seams: per axis, the STRONGEST rung any of them
  ## provides, carrying that seam's mechanism. The seams govern DIFFERENT axes (a driver
  ## the authentication axis, the epoch layer confidentiality, the log provenance), so in
  ## practice one seam is non-null per axis and this just gathers them into one envelope —
  ## the "active level on all three axes" a UI shows. When two seams touch one axis, the
  ## stronger wins (this reports the capability present, not a weakest-link security claim;
  ## per-scope caveats — e.g. metadata visible to the store node, FS-9 — live in the
  ## mechanism strings, which is why the null still carries a mechanism). No input ⇒ all null.
  var best: array[SecurityAxis, AxisLevel]
  for a in SecurityAxis: best[a] = axisLevel(rungNull, "unset")
  for l in levels:
    for a in SecurityAxis:
      if l.axes[a].rung >= best[a].rung: best[a] = l.axes[a]
  SecurityLevel(axes: best)

proc `$`*(l: SecurityLevel): string =
  ## A one-line rendering of the whole envelope, for logs and the UI seam.
  result = ""
  for a in SecurityAxis:
    if result.len > 0: result.add "  ·  "
    result.add $a & "=" & l.axes[a].mechanism & " (" & (if l.axes[a].rung == rungReal: "real" else: "null") & ")"

import std/json

proc toJson*(l: SecurityLevel): JsonNode =
  ## What the surface returns and the UI renders: one row per axis, in the fixed order
  ## authentication · provenance · confidentiality, each with its rung and named mechanism.
  ## `real` is a boolean too, so a consumer never string-compares the rung to decide.
  result = newJObject()
  var axes = newJArray()
  for a in SecurityAxis:
    axes.add %*{"axis": $a, "rung": (if l.axes[a].rung == rungReal: "real" else: "null"),
                "real": l.axes[a].rung == rungReal, "mechanism": l.axes[a].mechanism}
  result["axes"] = axes
