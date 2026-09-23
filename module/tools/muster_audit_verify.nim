## muster-audit-verify — check a Muster signature-audit file with nothing but the file
## (exo-403). No log, no keys, no network, no running muster: it re-derives what the
## file claims and refuses on the first discrepancy.
##
##   muster_audit_verify <audit-file.cbor> [--report]
##
## Prints the verdict as JSON; exits 0 when the file verifies, 1 when it is refused,
## 2 on usage/IO errors. `--report` also prints the readable report rendered from the
## file. Build (links secp256k1 + libsodium, flags as tests/README.md):
##   nim c -d:release --threads:on $SECP $STINT --passL:"$SODIUM/lib/libsodium.so" \
##     -o:muster-audit-verify tools/muster_audit_verify.nim

import std/[os, json]
import ../src/coordination/audit

proc main(): int =
  var path = ""
  var report = false
  for a in commandLineParams():
    if a == "--report": report = true
    elif path.len == 0: path = a
  if path.len == 0:
    stderr.writeLine "usage: muster_audit_verify <audit-file.cbor> [--report]"
    return 2
  var bytes: seq[byte]
  try:
    for c in readFile(path): bytes.add byte(c)
  except IOError as e:
    stderr.writeLine "cannot read " & path & ": " & e.msg
    return 2
  let v = verifyAudit(bytes)
  var apps = newJArray()
  for a in v.approvals: apps.add %*{"who": a.who, "round": a.round, "grade": a.grade}
  var st = newJArray()
  for x in v.settlement: st.add %*{"kind": x.kind, "chainRef": x.chainRef, "grade": x.grade}
  echo $(%*{"ok": v.ok, "reason": v.reason, "intentId": v.intentId, "stage": v.stage,
            "issuer": v.issuer, "digest": v.digest, "firstEpoch": v.firstEpoch,
            "approvals": apps, "settlement": st})
  if report: echo renderAuditReport(bytes)
  if v.ok: 0 else: 1

quit(main())
