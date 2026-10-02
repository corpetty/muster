## The official keystore_module, as one status row (exo-149.1 K1). Pure: it reads the
## replies muster_module gathers from keystore_module and says what stands and what to
## do next. Never a false green: an unread or failed reply is never ok.
##
## keystore_module (logos-co/logos-evm-keystore-module, 0.1.0 in Basecamp 0.3.1's
## catalog) is the only module that holds EVM key material. Another module may READ
## its accounts (list_accounts / get_labels / get_account_wallets are ungated) and
## REQUEST signatures, which a human approves in an approver's UI; it can never sign
## for itself or create a key. A request is admitted only from a caller the runtime
## attributes as a plain module (LogosCaller::Module{name}); the host, a derived or
## operator identity, and an unknown caller are refused with "not authorized". So the
## question this row answers first is the one everything else in exo-149 rests on:
## does keystore_module see muster's calls as muster_module's? It answers through
## caller_identity, which reports {ok, kind, identity, approvers, custodians}
## (glue.rs, KeystoreModuleImpl::caller_identity, @2318c679).

import std/[json, strutils]

const
  KeystoreModule* = "keystore_module"
  Ours* = "muster_module"
    ## the name keystore_module must attribute our calls to
  SignerUi = "evm_signer_ui"
  KeystoreUi = "evm_keystore_ui"

type
  KeystoreInputs* = object
    reached*: bool          ## lp_client_create("keystore_module") gave a client
    identity*: JsonNode     ## caller_identity; nil = unread
    accounts*: JsonNode     ## list_accounts {ok, accounts:[address]}; nil = unread
    labels*: JsonNode       ## get_labels {ok, labels:{address: name}}; nil = unread
    wallets*: JsonNode      ## get_account_wallets {ok, wallets:{address:{wallet,index?}}}; nil = unread

proc ksReply*(raw: string): JsonNode =
  ## A keystore reply, however it arrives over lp_*: the JSON object itself, that object
  ## as a JSON string (a tstr result), or either inside the lp envelope {success, value}.
  ## nil when it carries no object or the envelope says it failed.
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return nil
  for _ in 0 .. 3:
    case j.kind
    of JString:
      let s = j.getStr()
      if s.len == 0: return nil
      try: j = parseJson(s)
      except CatchableError: return nil
    of JObject:
      if j.hasKey("success") and j.hasKey("value"):
        if not j["success"].getBool(false): return nil
        j = j["value"]
      else: return j
    else: return nil
  nil

proc okReply(j: JsonNode): bool =
  ## A reply that parsed and says ok: true. Anything else is unread, never a pass.
  j != nil and j.kind == JObject and j{"ok"}.getBool(false)

proc row(level, detail: string, remedy = ""): JsonNode =
  result = %*{"key": "keystore", "name": "EVM keystore", "level": level, "detail": detail,
              "approvers": [], "accounts": []}
  if remedy.len > 0: result["remedy"] = %remedy

proc strs(j: JsonNode): seq[string] =
  if j != nil and j.kind == JArray:
    for e in j:
      if e.kind == JString: result.add e.getStr()

proc byAddress(j: JsonNode, field: string): JsonNode =
  ## {lowercase address: value} from a {field: {address: value}} reply; {} when unread.
  result = newJObject()
  if okReply(j) and j{field} != nil and j[field].kind == JObject:
    for k, v in j[field]: result[k.toLowerAscii()] = v

proc accountRows(i: KeystoreInputs): JsonNode =
  result = newJArray()
  let labels = byAddress(i.labels, "labels")
  let wallets = byAddress(i.wallets, "wallets")
  for a in strs(i.accounts{"accounts"}):
    let k = a.toLowerAscii()
    let w = wallets{k}
    result.add %*{"address": a,
                  "label": labels{k}.getStr(),
                  "wallet": (if w != nil and w.kind == JObject: w{"wallet"}.getStr() else: "")}

proc keystoreRow*(i: KeystoreInputs): JsonNode =
  ## The row: {key:"keystore", name, level: ok|warn|down, detail, remedy?,
  ## identity?:{kind, identity}, approvers:[…], accounts:[{address, label, wallet}]}.
  if not i.reached:
    return row("down", "keystore_module not loaded",
               "Install keystore_module (Basecamp: Package Manager, catalog Logos Official) — " &
               "muster requests EVM signatures through it.")
  if not okReply(i.identity) or i.identity{"kind"} == nil:
    return row("down", "keystore_module did not answer caller_identity",
               "Check that keystore_module is loaded and initialized.")
  let kind = i.identity{"kind"}.getStr()
  let ident = i.identity{"identity"}.getStr()
  let approvers = strs(i.identity{"approvers"})
  var r: JsonNode
  if kind != "module" or ident != Ours:
    let seen = (if ident.len > 0: kind & " " & ident else: kind)
    r = row("down", "keystore_module sees muster's calls as " & seen & ", not " & Ours &
                    ": every signing request would be refused",
            "The runtime must attribute muster_module's calls to it as a plain module; " &
            "check the origin muster passes to lp_client_create and the host's caller attestation.")
  elif approvers.len == 0:
    r = row("warn", "attested as " & Ours & ", but no approver is named: no request could settle",
            "Name an approver for keystore_module (its default is " & SignerUi & ").")
  elif not okReply(i.accounts):
    r = row("warn", "attested as " & Ours & "; its accounts could not be read")
  else:
    let n = strs(i.accounts{"accounts"}).len
    if n == 0:
      r = row("warn", "attested as " & Ours & "; no accounts yet",
              "Create or import an account in " & KeystoreUi & " (intent evm.accounts.manage).")
    else:
      r = row("ok", "attested as " & Ours & "; " & $n & (if n == 1: " account" else: " accounts") &
                    "; approvals by " & approvers.join(", "))
  r["identity"] = %*{"kind": kind, "identity": ident}
  r["approvers"] = %approvers
  r["accounts"] = accountRows(i)
  r
