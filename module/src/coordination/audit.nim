## The signature-audit file — one downloadable, self-verifying record of everything an
## intent's approvals cover (spec: contracts/specs/derived-exo-403.spec.json, critical).
##
## STUB: the API the exo-403 probes name. Every call reports "not built yet", so the
## probes compile and fail on their assertions until the implementation lands.

import ../log/log
import ../crypto/keystore
import ./intent_events

type
  AuditResult* = object
    ok*: bool
    reason*: string          ## why the export was refused (when not ok)
    bytes*: seq[byte]        ## the canonical file (dCBOR)

  ApprovalReport* = object
    who*: string
    round*: int
    grade*: string           ## committed | unattested | rejected

  SettlementReport* = object
    kind*: string            ## submit | final
    chainRef*: string        ## the tx hash, or "" when the event predates chain refs
    grade*: string           ## always "external-read"

  AuditVerdict* = object
    ok*: bool
    reason*: string          ## the first discrepancy, when refused
    intentId*, stage*, issuer*, digest*: string
    firstEpoch*: int
    approvals*: seq[ApprovalReport]
    settlement*: seq[SettlementReport]

proc exportAudit*(events: seq[Event], driverFor: DriverFor, intentId: string,
                  issuer: Keystore): AuditResult =
  AuditResult(ok: false, reason: "not built yet")

proc verifyAudit*(bytes: seq[byte]): AuditVerdict =
  AuditVerdict(ok: false, reason: "not built yet")

proc auditDigest*(bytes: seq[byte]): string = ""

proc renderAuditReport*(bytes: seq[byte]): string = ""
