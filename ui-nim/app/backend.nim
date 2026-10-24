## muster's UI backend in Nim (exo-607 T5): every SLOT of `ui/src/muster_ui.rep`, and
## the MUSTER_AUTO* autopilot the offscreen self-tests drive. The port of
## `ui/src/muster_ui_backend.cpp`, slot for slot. Included into muster_app.nim, because
## nimside wants each slot's Impl in the module that declares the contract.
##
## The backend holds no keys and no state of its own, as in C++: every PROP it feeds
## comes back from a muster_module call through the logos API. The difference is the
## thread. The C++ backend ran in ui-host, a process of its own, so its blocking calls
## never touched the view. This one shares the Qt main thread with the view, so every
## call is the generated client's async twin (`mm.<method>Async(…, done)`), and its
## result lands back on this thread. Each step here takes an optional `Done`
## continuation and runs it once its PROPs are set: that is how a caller that needs
## an answer (the autopilot, mostly) sequences what the C++ did line by line.
##
## Needs, from the including module: `mm: MusterClient`, `coreUp: bool`, and the
## `MusterUi` contract type.

import std/[json, os, strutils, sets, tables, times]
import seaqt/[qstandardpaths]
import ./sched

type
  Done = proc (r: string) {.closure.}
  Step = proc (next: proc () {.closure.}) {.closure.}

proc fin(d: Done, r = "") =
  if d != nil: d(r)

proc info(msg: string) =
  ## The C++ backend's qInfo lines, under the same prefix, on stderr.
  try: stderr.writeLine "[muster_ui] " & msg
  except IOError: discard

proc qs(s: string): string = escapeJson(s)   ## a value quoted as qInfo quotes a QString

template ask(call: untyped) =
  ## Dispatch a module call; without a core (the view-only self-test) nothing is sent.
  if coreUp: discard call

proc obj(s: string): JsonNode =
  ## QJsonDocument::fromJson(s).object(): the object, or an empty one.
  try:
    let n = parseJson(s)
    if n.kind == JObject: n else: newJObject()
  except CatchableError: newJObject()

proc arr(s: string): JsonNode =
  ## QJsonDocument::fromJson(s).array(): the array, or an empty one.
  try:
    let n = parseJson(s)
    if n.kind == JArray: n else: newJArray()
  except CatchableError: newJArray()

proc objectOr(r: string, key: string): JsonNode =
  ## A module answer that is a JSON object, or `{key: r}`.
  try:
    let n = parseJson(r)
    if n.kind == JObject: return n
  except CatchableError: discard
  %*{key: r}

proc asObjectJson(r: string, key: string): string =
  ## A module answer that is JSON stays as is; a bare string becomes {key: r}.
  if r.startsWith("{"): $obj(r) else: $(%*{key: r})

proc splitOutcome(op, intentId, r: string): string =
  ## Each split outcome lands on splitJson, tagged with what was done and to which
  ## intent, so the room can say why a button did nothing.
  var o: JsonNode
  if r.startsWith("{"): o = obj(r)
  elif r.startsWith("0x"): o = %*{"id": r}             # propose → the intent id
  else: o = %*{"error": r}
  o["op"] = %op
  if intentId.len > 0 and not o.hasKey("id"): o["id"] = %intentId
  $o

proc chain(steps: seq[Step], last: proc () {.closure.} = nil) =
  ## Run async steps one after another.
  if steps.len == 0:
    if last != nil: last()
    return
  let rest = steps[1 .. ^1]
  steps[0](proc () = chain(rest, last))

proc then(next: proc () {.closure.}): Done = (proc (r: string) = next())

proc nowS(): int64 = getTime().toUnix()

# State the C++ kept in members or function statics.
var
  joinRetrying = false
  joinAttempts = 0
  inviteAccepted = false
  lezFunding = false    ## MUSTER_AUTOLEZFUND is still funding: MUSTER_AUTOPAYSPLIT waits
  voiceAnswers = 0      ## the voice answers so far, fed to voiceResultSeq

# ── reads: each sets one PROP ───────────────────────────────────────────────────

proc checkHealthDo(o: MusterUi, d: Done = nil) =
  ask mm.healthAsync(proc (r: string) =
    info "muster_module.health() -> " & qs(r)
    o.setHealth(r)
    fin(d, r))

proc loadSettingsDo(o: MusterUi, d: Done = nil) =
  # settings() → {rpc, delivery, environment, identity}: the user-configurable
  # infrastructure (invariant 8) and who this module is.
  ask mm.settingsAsync(proc (r: string) = o.setSettingsJson(r); fin(d, r))

proc loadAccountDo(o: MusterUi, d: Done = nil) =
  # The Safe account the walkthrough coordinates against: the view shows the domain it
  # is told here, never one it hardcodes.
  ask mm.describeAsync(proc (r: string) =
    info "muster_module.describe() -> " & qs(r)
    o.setAccountJson(r)
    fin(d, r))

proc loadBalancesDo(o: MusterUi, d: Done = nil) =
  # Balances across every configured chain, each with its F-10 grade.
  ask mm.wallet_balancesAsync(proc (r: string) =
    info "muster_module.wallet_balances() -> " & qs(r)
    o.setBalancesJson(r)
    fin(d, r))

proc loadWalletAccountsDo(o: MusterUi, d: Done = nil) =
  ask mm.wallet_accountsAsync(proc (r: string) = o.setWalletAccountsJson(r); fin(d, r))

proc loadMessagesDo(o: MusterUi, d: Done = nil) =
  # The room's authored events, oldest first; the module drives inbound delivery first.
  ask mm.coordinate_messagesAsync(proc (r: string) = o.setMessagesJson(r); fin(d, r))

proc loadConversationsDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_conversationsAsync(proc (r: string) = o.setConversationsJson(r); fin(d, r))

proc loadMembersDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_membersAsync(proc (r: string) = o.setMembersJson(r); fin(d, r))

proc loadContactsDo(o: MusterUi, d: Done = nil) =
  ask mm.contactsAsync(proc (r: string) = o.setContactsJson(r); fin(d, r))

proc loadFileShareDo(o: MusterUi, d: Done = nil) =
  # FileShare (exo-4d0): the room's files and this instance's operations.
  ask mm.fileshare_filesAsync(proc (r: string) = o.setFileShareJson(r); fin(d, r))

proc fileShareDone(o: MusterUi, r: string) =
  # A FileShare operation's answer: fileShareResultJson, then the list re-reads.
  o.setFileShareResultJson(r)
  o.loadFileShareDo()

proc loadVoiceDo(o: MusterUi, d: Done = nil) =
  # Voice notes (docs/design/voice-notes.md §8): voice_status, which also drives the
  # module's voice pump. No audio crosses this backend in either direction.
  ask mm.voice_statusAsync(proc (r: string) = o.setVoiceJson(r); fin(d, r))

proc voiceDone(o: MusterUi, r: string, d: Done = nil) =
  # A voice call's answer: voiceResultJson, then voiceResultSeq one more (an answer
  # identical to the last changes only the count), then voice_status re-reads.
  o.setVoiceResultJson(r)
  inc voiceAnswers
  o.setVoiceResultSeq($voiceAnswers)
  o.loadVoiceDo(d)

proc startVoiceRecordingDo(o: MusterUi, d: Done = nil) =
  ask mm.voice_record_startAsync(proc (r: string) = o.voiceDone(r, d))

proc stopVoiceRecordingDo(o: MusterUi, d: Done = nil) =
  ask mm.voice_record_stopAsync(proc (r: string) = o.voiceDone(r, d))

proc sendVoiceDraftDo(o: MusterUi, d: Done = nil) =
  ask mm.voice_draft_sendAsync(proc (r: string) =
    info "muster_module.voice_draft_send() -> " & qs(r)
    o.voiceDone(r, d)
    o.loadMessagesDo())      # the note's row, at once

proc playVoiceNoteDo(o: MusterUi, noteId: string, d: Done = nil) =
  ask mm.voice_playAsync(noteId, proc (r: string) = o.voiceDone(r, d))

proc loadPendingDo(o: MusterUi, d: Done = nil) =
  # Identities that asked to join and are not admitted yet.
  ask mm.coordinate_pendingAsync(proc (r: string) = o.setPendingJson(r); fin(d, r))

proc loadActivityDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_activityAsync(proc (r: string) = o.setActivityJson(r); fin(d, r))

proc loadFrostCeremoniesDo(o: MusterUi, d: Done = nil) =
  ask mm.frost_ceremoniesAsync(proc (r: string) = o.setFrostCeremoniesJson(r); fin(d, r))

proc loadWalletSummaryDo(o: MusterUi, d: Done = nil) =
  # The Wallet page: only the wallets this instance was given (exo-f37). The module
  # decides; the backend holds nothing.
  ask mm.wallet_summaryAsync(proc (r: string) = o.setWalletSummaryJson(r); fin(d, r))

proc loadXmrMsigDo(o: MusterUi, d: Done = nil) =
  ask mm.xmr_msig_setupsAsync(proc (r: string) = o.setXmrMsigSetupsJson(r))
  ask mm.xmr_msig_spendsAsync(proc (r: string) = o.setXmrMsigSpendsJson(r); fin(d, r))

proc loadIntentsDo(o: MusterUi, d: Done = nil) =
  # The room's proposals folded from the shared log. The FROST ceremonies advance on
  # the same tick, and the activity feed folds from the same log.
  ask mm.coordinate_intentsAsync(proc (r: string) =
    o.setIntentsJson(r)
    o.loadFrostCeremoniesDo()
    o.loadXmrMsigDo()
    o.loadActivityDo()
    fin(d, r))

proc loadDriversDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_driversAsync(proc (r: string) = o.setDriversJson(r); fin(d, r))

proc loadAvailableActionsDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_available_actionsAsync(proc (r: string) = o.setAvailableActionsJson(r); fin(d, r))

proc loadConnectivityDo(o: MusterUi, d: Done = nil) =
  # The delivery node, plus what the room's proposals introduced (invariant 8).
  ask mm.connectivityAsync(proc (r: string) = o.setConnectivityJson(r); fin(d, r))

proc loadRlnStatusDo(o: MusterUi, d: Done = nil) =
  ask mm.rln_statusAsync(proc (r: string) = o.setRlnStatusJson(r); fin(d, r))

proc loadKeystoreStatusDo(o: MusterUi, d: Done = nil) =
  ask mm.keystore_statusAsync(proc (r: string) = o.setKeystoreStatusJson(r); fin(d, r))

proc loadKeystoreRequestsDo(o: MusterUi, d: Done = nil) =
  ask mm.keystore_requestsAsync(proc (r: string) = o.setKeystoreRequestsJson(r); fin(d, r))

proc loadSecurityLevelsDo(o: MusterUi, d: Done = nil) =
  ask mm.security_levelsAsync(proc (r: string) = o.setSecurityLevelsJson(r); fin(d, r))

proc loadRoomAccountDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_accountAsync(proc (r: string) = o.setRoomAccountJson(r); fin(d, r))

proc loadOpenAssetsDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_open_assetsAsync(proc (r: string) =
    info "coordinate_open_assets -> " & qs(r)
    o.setOpenAssetsJson(r)
    fin(d, r))

proc loadFlowDo(o: MusterUi, d: Done = nil) =
  # Who could see what, per action (exo-002.5). A pure fold.
  ask mm.coordinate_flowAsync(proc (r: string) = o.setFlowJson(r); fin(d, r))

proc loadGraphDo(o: MusterUi, roomTopic: string, d: Done = nil) =
  ask mm.coordinate_graphAsync(roomTopic, proc (r: string) = o.setGraphJson(r); fin(d, r))

proc loadPolicyDo(o: MusterUi, d: Done = nil) =
  ask mm.coordinate_policyAsync(proc (r: string) = o.setPolicyJson(r); fin(d, r))

proc loadAccountsDo(o: MusterUi, d: Done = nil) =
  # The accounts members disclosed, each with the chain's verdict (an RPC read).
  ask mm.coordinate_accountsAsync(proc (r: string) = o.setAccountsJson(r); fin(d, r))

proc loadInvitesDo(o: MusterUi, d: Done = nil)

proc loadReadinessDo(o: MusterUi, intentId: string, d: Done = nil) =
  # The card's five questions for ONE intent, kept per intent so several open cards
  # each read their own entry.
  ask mm.coordinate_readinessAsync(intentId, proc (r: string) =
    let all = obj(o.readinessJson)
    all[intentId] = objectOr(r, "error")
    info "coordinate_readiness " & qs(intentId) & " -> " & qs(r)
    o.setReadinessJson($all)
    fin(d, r))

proc loadOffersDo(o: MusterUi, intentId: string, d: Done = nil) =
  # The card's "From you" section for ONE intent: my own holdings only.
  ask mm.coordinate_offersAsync(intentId, proc (r: string) =
    let all = obj(o.offersJson)
    all[intentId] = objectOr(r, "error")
    info "coordinate_offers " & qs(intentId) & " -> " & qs(r)
    o.setOffersJson($all)
    fin(d, r))

proc loadComposeOffersDo(o: MusterUi, effectJson: string, d: Done = nil) =
  ask mm.compose_offersAsync(effectJson, proc (r: string) =
    info "compose_offers " & qs(effectJson) & " -> " & qs(r)
    o.setComposeOffersJson(r)
    fin(d, r))

# ── the walkthrough's local intent ──────────────────────────────────────────────

proc proposeDo(o: MusterUi, effectJson: string, d: Done = nil) =
  # The module canonicalizes the effect and returns the intent id; txhash is the exact
  # bytes it re-derived. A mismatch is the core's to refuse (F-4), never simulated.
  o.setLastError("")
  ask mm.proposeAsync(effectJson, proc (id: string) =
    if id.len == 0 or id.startsWith("unknown"):
      info "propose failed -> " & qs(id)
      o.setLastError("propose failed: " & id)
      fin(d, id)
      return
    o.setIntentId(id)
    o.setIntentEffect(effectJson)
    discard mm.statusAsync(id, proc (state: string) =
      discard mm.txhashAsync(id, proc (tx: string) =
        o.setIntentTxhash(tx)
        o.setIntentState(state)
        info "proposed " & qs(id) & " state " & qs(state)
        fin(d, id))))

proc approveDo(o: MusterUi, signatureHex: string, d: Done = nil) =
  # An owner's signature over this intent's safeTxHash; the module counts it only if it
  # recovers to a configured owner. The client never holds keys.
  o.setLastError("")
  let id = o.intentId
  if id.len == 0:
    o.setLastError("no intent to approve")
    return
  ask mm.approveAsync(id, signatureHex, proc (st: string) =
    if st == "rejected":
      o.setLastError("signature not counted — it did not recover to a configured owner (or was already collected)")
    elif st.len == 0 or st.startsWith("unknown") or st.startsWith("error"):
      info "approve failed -> " & qs(st)
      o.setLastError("approve failed: " & st)
    else:
      o.setIntentState(st)
      info "approve " & qs(id) & " -> " & qs(st)
    fin(d, st))

proc submitDo(o: MusterUi, d: Done = nil) =
  # Submit the executable intent on chain through the user's RPC; finality is read from
  # the receipt, never asserted.
  o.setLastError("")
  let id = o.intentId
  if id.len == 0:
    o.setLastError("no intent to submit")
    return
  ask mm.submitAsync(id, proc (st: string) =
    if st.len == 0 or st.startsWith("unknown") or st.startsWith("error"):
      info "submit failed -> " & qs(st)
      o.setLastError("submit failed: " & st)
      fin(d, st)
      return
    o.setIntentState(st)
    if st != "final" and st != "submitted":
      # accepted, but it did not move on chain: most often the RPC is unreachable
      o.setLastError("submit did not land on-chain (state " & st & ") — is the RPC reachable?")
    info "submit " & qs(id) & " -> " & qs(st)
    fin(d, st))

proc resetDo(o: MusterUi) =
  # UI-only: clear the current intent so the composer is fresh. The module keeps its log.
  o.setIntentId("")
  o.setIntentEffect("")
  o.setIntentTxhash("")
  o.setIntentState("")
  o.setLastError("")
  info "reset — view cleared for a new proposal"

# ── the wallet ──────────────────────────────────────────────────────────────────

proc previewLezSendDo(o: MusterUi, fromId, to, raw: string) =
  # The rail and disclosure, before anything is sent, from the account the send will
  # spend: its form picks the rail (exo-408 item 14), as the C++ backend's preview does.
  ask mm.wallet_estimate_feeAsync("lez:testnet", fromId, to, "LEZ", raw,
    proc (r: string) = o.setLezPreviewJson(r))

proc sendLezDo(o: MusterUi, fromId, to, raw: string) =
  # The module picks the rail and reports what it disclosed; a refused send is {error}.
  ask mm.wallet_sendAsync("lez:testnet", fromId, to, "LEZ", raw, proc (r: string) =
    info "wallet_send(lez) -> " & qs(r)
    o.setLezSendJson(r)
    o.loadWalletAccountsDo()
    o.loadBalancesDo())

# ── the room ────────────────────────────────────────────────────────────────────

proc joinRoomDo(o: MusterUi, topic: string, d: Done = nil) =
  # Join or start the conversation over encrypted transport, then pull its state so the
  # room opens on it.
  if topic.len == 0:
    o.setLastError("cannot join an empty topic")
    return
  ask mm.coordinate_joinAsync(topic, proc (r: string) =
    info "coordinate_join( " & qs(topic) & " ) -> " & qs(r)
    # Key the view by the room's content topic, the name the module gives it, however
    # it was typed (exo-dcc.25).
    let ctopic = obj(r){"topic"}.getStr("")
    o.setRoomTopic(if ctopic.len == 0: topic else: ctopic)
    o.setLastError("")
    o.loadPolicyDo()
    o.loadMessagesDo()
    o.loadMembersDo()
    o.loadIntentsDo()
    o.loadConnectivityDo()
    o.loadConversationsDo()
    o.loadDriversDo()
    o.loadAccountsDo()
    o.loadPendingDo()
    fin(d, r))

proc postMessageDo(o: MusterUi, body: string, d: Done = nil) =
  # One channel for chat and cards; re-read so the view reflects it, reduce(log).
  if body.len == 0: return
  ask mm.coordinate_post_messageAsync(body, proc (id: string) =
    info "coordinate_post_message -> " & qs(id)
    o.loadMessagesDo(d))

proc addContactDo(o: MusterUi, identityHex, alias: string) =
  ask mm.contact_addAsync(identityHex, alias, proc (r: string) = o.loadContactsDo())

proc setContactAliasDo(o: MusterUi, identityHex, alias: string) =
  ask mm.contact_set_aliasAsync(identityHex, alias, proc (r: string) = o.loadContactsDo())

proc removeContactDo(o: MusterUi, identityHex: string) =
  ask mm.contact_removeAsync(identityHex, proc (r: string) = o.loadContactsDo())

proc startInboxDo(o: MusterUi) =
  # Listen on THIS identity's inbox, so invites arrive before any room is joined.
  ask mm.coordinate_start_inboxAsync(proc (r: string) =
    info "coordinate_start_inbox -> " & qs(r)
    o.loadInvitesDo())

proc sendInviteDo(o: MusterUi, peerChatId, roomTopic, note: string) =
  # Seal the room topic to the peer's chat id and drop it on their inbox.
  ask mm.coordinate_inviteAsync(peerChatId, roomTopic, note, proc (r: string) =
    info "coordinate_invite( " & qs(roomTopic) & " ) -> " & qs(r))

proc leaveRoomDo(o: MusterUi, roomTopic: string, d: Done = nil) =
  # Stop following the room and forget it (exo-dcc.28); leaving the open room clears it.
  ask mm.coordinate_leaveAsync(roomTopic, proc (r: string) =
    info "coordinate_leave( " & qs(roomTopic) & " ) -> " & qs(r)
    if roomTopic.len > 0 and roomTopic == o.roomTopic:
      o.setRoomTopic("")
      o.setMessagesJson("[]")
      o.setMembersJson("[]")
      o.setPendingJson("[]")
      o.setIntentsJson("[]")
      o.setAccountsJson("[]")
    o.loadConversationsDo(d))

proc setRoomTitleDo(o: MusterUi, roomTopic, title: string, d: Done = nil) =
  # This member's own name for the room (exo-dcc.25).
  ask mm.coordinate_set_room_titleAsync(roomTopic, title, proc (r: string) =
    o.loadConversationsDo(d))

proc loadInvitesDo(o: MusterUi, d: Done = nil) =
  # The invites received on our inbox. Invite self-test (exo-dcc.29):
  # MUSTER_AUTOACCEPT_INVITE=<room> joins that room's invite as Home's Join does, and
  # sends NO join request, so a run shows the invite alone made this identity a member.
  ask mm.coordinate_invitesAsync(proc (r: string) =
    o.setInvitesJson(r)
    let want = getEnv("MUSTER_AUTOACCEPT_INVITE")
    if not inviteAccepted and want.len > 0:
      var topic = ""
      for v in arr(r):
        if v{"topic"}.getStr("") == want: topic = want
      if topic.len > 0:
        inviteAccepted = true
        info "AUTOACCEPT_INVITE -> " & qs(topic)
        o.joinRoomDo(topic)
        # drive the room as its open view would, so the module logs its roster
        var n = 0
        every(1000, proc (): bool =
          o.loadPendingDo()
          inc n
          n < 60)
    fin(d, r))

proc dismissInviteDo(o: MusterUi, roomTopic: string) =
  ask mm.coordinate_dismiss_inviteAsync(roomTopic, proc (r: string) = o.loadInvitesDo())

proc scheduleJoinRetry(o: MusterUi) =
  # Re-announce every 3 s until this peer shares an epoch (its roster grows past itself)
  # or has left the room; stop after ~1 min alone. A one-shot request can reach no store
  # node on a sparse shard.
  after(3000, proc () =
    o.loadMembersDo(proc (r: string) =
      if arr(o.membersJson).len > 1 or o.roomTopic.len == 0:
        joinRetrying = false
        return
      inc joinAttempts
      if joinAttempts >= 20:
        joinRetrying = false
        return
      discard mm.coordinate_request_joinAsync(proc (r: string) =
        o.setJoinStatus(r)
        o.loadPendingDo()
        o.scheduleJoinRetry())))

proc requestJoinDo(o: MusterUi) =
  # Announce our encryption key on the topic: discovery, not entry. A member still
  # decides to admit us.
  ask mm.coordinate_request_joinAsync(proc (r: string) =
    info "coordinate_request_join -> " & qs(r)
    o.setJoinStatus(r)
    o.loadPendingDo()
    if not joinRetrying:
      joinRetrying = true
      joinAttempts = 0
      o.scheduleJoinRetry())

proc admitDo(o: MusterUi, identityHex: string, d: Done = nil) =
  # Re-key the room forward and grant the joiner the new epoch (F-16), then refresh.
  if identityHex.len == 0: return
  ask mm.coordinate_admitAsync(identityHex, proc (r: string) =
    info "coordinate_admit( " & qs(identityHex) & " ) -> " & qs(r)
    o.loadMembersDo()
    o.loadPendingDo()
    o.loadMessagesDo()
    o.loadIntentsDo()
    fin(d, r))

proc proposeInRoomDo(o: MusterUi, effectJson: string, d: Done = nil) =
  # A content-addressed shared intent: every participant derives the same id.
  ask mm.coordinate_proposeAsync(effectJson, proc (id: string) =
    info "coordinate_propose -> " & qs(id)
    o.loadIntentsDo()
    o.loadMessagesDo()
    fin(d, id))

const notCounted = ["rejected", "not-joined", "unknown-intent", "unknown-key",
  "not-a-vote-locus", "expired", "unsupported-driver", "no-context",
  "unaccountable-input", "attestation-mismatch"]

proc contributeInRoomDo(o: MusterUi, intentId, signatureHex, keyRef: string, d: Done = nil) =
  # An owner signature (or, empty, one signed in-app by keyRef's key). An approval that
  # did not count must SAY so: ok iff the answer is a lifecycle state. A vote-locus
  # approval answers "pending: …" while the chain includes the vote (ok).
  ask mm.coordinate_contributeAsync(intentId, signatureHex, keyRef, proc (st: string) =
    info "coordinate_contribute " & qs(intentId) & " " & qs(keyRef) & " -> " & qs(st)
    let ok = st notin notCounted and not st.startsWith("refused") and
             not st.startsWith("unconfirmed") and not st.startsWith("keystore-")
    let r = $(%*{"intentId": intentId, "state": st, "ok": ok, "reason": st})
    o.setContributeJson(r)
    o.loadIntentsDo()
    o.loadDriversDo()   # an approval may have admitted a new driver kind
    # a keystore_module account approves in the platform's signer (exo-d4d.2)
    if st == "awaiting-approval": o.loadKeystoreRequestsDo()
    fin(d, r))

proc reannounceDo(o: MusterUi) =
  # Re-publish open intents into the current epoch, so a just-admitted member sees them.
  ask mm.coordinate_reannounceAsync(proc (r: string) =
    info "coordinate_reannounce -> " & qs(r)
    o.loadMessagesDo()
    o.loadIntentsDo())

proc submitInRoomDo(o: MusterUi, intentId: string) =
  # Settle a ready room intent on chain, from the room.
  ask mm.coordinate_submitAsync(intentId, proc (r: string) =
    info "coordinate_submit " & qs(intentId) & " -> " & qs(r)
    o.setRoomSubmitJson(r)
    o.loadIntentsDo())

proc executeInRoomDo(o: MusterUi, intentId: string) =
  # Run a module-action intent that reached executable: re-derived, gated, invoked.
  ask mm.coordinate_executeAsync(intentId, proc (r: string) =
    info "coordinate_execute " & qs(intentId) & " -> " & qs(r)
    o.setExecuteJson(r)
    o.loadIntentsDo())

proc keystoreSelectDo(o: MusterUi, address: string) =
  # From now on this member's Safe approvals go through that keystore_module account.
  ask mm.keystore_selectAsync(address, proc (r: string) =
    info "KEYSTORE-SELECT " & r
    o.loadKeystoreStatusDo()
    o.loadKeystoreRequestsDo())

proc shareMaterialDo(o: MusterUi, intentId, requirement, pub: string) =
  # A chosen holding's PUBLIC face, published into the intent to fill a slot.
  ask mm.coordinate_share_materialAsync(intentId, requirement, pub, proc (r: string) =
    info "coordinate_share_material " & qs(intentId) & " " & qs(requirement) & " -> " & qs(r)
    o.loadOffersDo(intentId)
    o.loadIntentsDo())

proc declineInRoomDo(o: MusterUi, intentId: string, d: Done = nil) =
  # A decline names who declined; the room converges on it.
  ask mm.coordinate_declineAsync(intentId, proc (r: string) =
    info "coordinate_decline " & qs(intentId) & " -> " & qs(r)
    o.setDeclineJson(r)
    o.loadIntentsDo()
    fin(d, r))

proc exportOutsideDo(o: MusterUi, intentId: string) =
  # The intent in its driver's outside-signer form (a Bitcoin PSBT). Nothing is signed.
  ask mm.coordinate_export_outsideAsync(intentId, proc (r: string) =
    info "coordinate_export_outside " & qs(intentId) & " -> " & qs(r[0 ..< min(120, r.len)])
    o.setOutsideJson(r))

proc importOutsideDo(o: MusterUi, intentId, encoded: string) =
  # An outside signer's signatures, each published as a pasted, unattested approval.
  ask mm.coordinate_import_outsideAsync(intentId, encoded.strip(), proc (r: string) =
    info "coordinate_import_outside " & qs(intentId) & " -> " & qs(r)
    o.setOutsideImportJson(r)
    o.loadIntentsDo())

proc proposeBtcSpendDo(o: MusterUi, payTo, amountSat, feeRate: string) =
  # A Bitcoin payment from the room's chosen Bitcoin account: an id, or {error, detail}.
  ask mm.coordinate_propose_btc_spendAsync(payTo, amountSat, feeRate, proc (r: string) =
    info "coordinate_propose_btc_spend " & qs(payTo) & " " & qs(amountSat) & " " &
      qs(feeRate) & " -> " & qs(r)
    o.setBtcProposeJson(if r.startsWith("{"): $obj(r) else: $(%*{"id": r}))
    o.loadIntentsDo()
    o.loadMessagesDo())

# ── a split (exo-a90) ───────────────────────────────────────────────────────────

proc proposeSplitDo(o: MusterUi, chain, totalWei, sharesJson, memo: string, d: Done = nil) =
  # You are the creditor; every person named agrees to their own share first.
  ask mm.coordinate_propose_splitAsync(chain.strip(), totalWei.strip(), sharesJson, memo,
    proc (r: string) =
      info "coordinate_propose_split " & qs(chain) & " " & qs(totalWei) & " " &
        qs(sharesJson) & " -> " & qs(r)
      o.setSplitJson(splitOutcome("propose", "", r))
      o.loadIntentsDo()
      o.loadMessagesDo()
      fin(d, r))

proc proposeSettleUpDo(o: MusterUi, chain, asset, memo: string) =
  # The room's open shares on this chain and asset, netted.
  ask mm.coordinate_propose_settle_upAsync(chain.strip(), asset.strip(), memo, proc (r: string) =
    info "coordinate_propose_settle_up " & qs(chain) & " " & qs(asset) & " -> " & qs(r)
    o.setSplitJson(splitOutcome("settle-up", "", r))
    o.loadIntentsDo()
    o.loadMessagesDo())

proc settlePartDo(o: MusterUi, intentId: string, d: Done = nil) =
  # MY share, from my own wallet; the report follows once it lands.
  ask mm.coordinate_settle_partAsync(intentId, proc (r: string) =
    info "coordinate_settle_part " & qs(intentId) & " -> " & qs(r)
    let outcome = splitOutcome("pay", intentId, r)
    o.setSplitJson(outcome)
    o.loadIntentsDo()
    fin(d, outcome))

proc renewSplitDo(o: MusterUi, intentId: string) =
  # A split past its expiry, renewed as a settle-up of its unpaid shares (exo-a90.15).
  ask mm.coordinate_renew_splitAsync(intentId, proc (r: string) =
    info "coordinate_renew_split " & qs(intentId) & " -> " & qs(r)
    o.setSplitJson(splitOutcome("renew", intentId, r))
    o.loadIntentsDo()
    o.loadMessagesDo())

proc proposeSettleUpAcrossDo(o: MusterUi, chain, asset, ratesJson, memo: string) =
  # Paid in one asset, every other priced at my rate, a recorded read (exo-a90.17).
  ask mm.coordinate_propose_settle_up_acrossAsync(chain.strip(), asset.strip(), ratesJson, memo,
    proc (r: string) =
      info "coordinate_propose_settle_up_across " & qs(chain) & " " & qs(asset) & " " &
        qs(ratesJson) & " -> " & qs(r)
      o.setSplitJson(splitOutcome("settle-up", "", r))
      o.loadIntentsDo()
      o.loadMessagesDo())

proc shareAddressDo(o: MusterUi, chain: string) =
  # MY address for a chain, as an author-signed address-share card. A Monero address can
  # be refused (no wallet open): the answer lands in splitJson {op: "share"}.
  ask mm.coordinate_share_addressAsync(chain.strip(), proc (r: string) =
    info "coordinate_share_address " & qs(chain) & " -> " & qs(r)
    o.setSplitJson(splitOutcome("share", "", r))
    o.loadMessagesDo())

proc lookupTokenDo(o: MusterUi, chain, token: string) =
  # What the token says about itself, through your own RPC: display only.
  ask mm.coordinate_token_infoAsync(chain.strip(), token.strip(), proc (r: string) =
    info "coordinate_token_info " & qs(token) & " -> " & qs(r)
    o.setTokenInfoJson(r))

proc confirmPartDo(o: MusterUi, intentId, part, tx: string) =
  # The creditor confirms a share, from her own read of tx (or received outside muster).
  ask mm.coordinate_confirm_partAsync(intentId, part, tx, proc (r: string) =
    info "coordinate_confirm_part " & qs(intentId) & " " & qs(part) & " " & qs(tx) & " -> " & qs(r)
    o.setSplitJson(splitOutcome("confirm", intentId, r))
    o.loadIntentsDo())

proc reportPaidDo(o: MusterUi, intentId, tx: string, d: Done = nil) =
  # "I paid" for MY share of a Monero request: a claim, never a confirmation.
  ask mm.coordinate_report_paidAsync(intentId, tx.strip(), proc (r: string) =
    info "coordinate_report_paid " & qs(intentId) & " " & qs(tx) & " -> " & qs(r)
    let outcome = splitOutcome("report", intentId, r)
    o.setSplitJson(outcome)
    o.loadIntentsDo()
    fin(d, outcome))

# ── the LEZ multisig and FROST ──────────────────────────────────────────────────

proc proposeLezTransferDo(o: MusterUi, recipient, amount: string) =
  # The proposer's own Propose, sent, not awaited; the intent appears once the chain holds it.
  ask mm.coordinate_propose_lez_transferAsync(recipient.strip(), amount.strip(), proc (r: string) =
    info "coordinate_propose_lez_transfer " & qs(recipient) & " " & qs(amount) & " -> " & qs(r)
    o.setLezProposeJson(asObjectJson(r, "id"))
    o.loadIntentsDo())

proc proposeLezVaultInitDo(o: MusterUi, definition: string) =
  ask mm.coordinate_propose_lez_vault_initAsync(definition.strip(), proc (r: string) =
    info "coordinate_propose_lez_vault_init " & qs(definition) & " -> " & qs(r)
    o.setLezProposeJson(asObjectJson(r, "id"))
    o.loadIntentsDo())

proc lezMemberAccountDo(o: MusterUi, index: string) =
  ask mm.lez_member_accountAsync(index.strip(), proc (r: string) =
    info "lez_member_account " & qs(index) & " -> " & qs(r)
    o.setLezMemberJson(asObjectJson(r, "error")))

proc lezCreateMultisigDo(o: MusterUi, threshold, members: string) =
  # Sent, not awaited; disclosed into the room once the chain holds the multisig.
  ask mm.lez_multisig_createAsync(threshold.strip(), members.strip(), proc (r: string) =
    info "lez_multisig_create " & qs(threshold) & " " & qs(members) & " -> " & qs(r)
    o.setLezCreateJson(asObjectJson(r, "error")))

proc frostCeremonyOpenDo(o: MusterUi, ceremonyId, network, t, n: string) =
  # Open and join; the module advances this member's steps on the intents tick.
  ask mm.frost_ceremony_openAsync(ceremonyId.strip(), network.strip(), t.strip(), n.strip(),
    proc (r: string) =
      info "frost_ceremony_open " & qs(ceremonyId) & " " & qs(network) & " " & qs(t) & " " &
        qs(n) & " -> " & qs(r)
      o.setFrostCeremonyJson(asObjectJson(r, "error"))
      o.loadFrostCeremoniesDo())

proc frostCeremonyJoinDo(o: MusterUi, ceremonyId: string) =
  ask mm.frost_ceremony_joinAsync(ceremonyId.strip(), proc (r: string) =
    info "frost_ceremony_join " & qs(ceremonyId) & " -> " & qs(r)
    o.setFrostCeremonyJson(asObjectJson(r, "error"))
    o.loadFrostCeremoniesDo())

proc xmrMsigSetupOpenDo(o: MusterUi, ceremonyId, chain, k, membersJson: string) =
  # Open and join; each member's own wallet runs its rounds on the intents tick.
  ask mm.xmr_msig_setup_openAsync(ceremonyId.strip(), chain.strip(), k.strip(), membersJson.strip(),
    proc (r: string) =
      info "xmr_msig_setup_open " & qs(ceremonyId) & " " & qs(chain) & " " & qs(k) & " -> " & qs(r)
      o.setXmrMsigSetupJson(asObjectJson(r, "error"))
      o.loadXmrMsigDo())

proc xmrMsigSetupJoinDo(o: MusterUi, ceremonyId: string) =
  ask mm.xmr_msig_setup_joinAsync(ceremonyId.strip(), proc (r: string) =
    info "xmr_msig_setup_join " & qs(ceremonyId) & " -> " & qs(r)
    o.setXmrMsigSetupJson(asObjectJson(r, "error"))
    o.loadXmrMsigDo())

proc xmrMsigProposeDo(o: MusterUi, account, recipientsJson, feeCap, memo: string) =
  ask mm.coordinate_propose_xmr_msigAsync(account.strip(), recipientsJson.strip(), feeCap.strip(), memo,
    proc (r: string) =
      info "coordinate_propose_xmr_msig " & qs(account) & " -> " & qs(r)
      o.setXmrMsigProposeJson(asObjectJson(r, "intentId"))
      o.loadIntentsDo())

# ── the audit file ──────────────────────────────────────────────────────────────

const DownloadLocation = 14   ## QStandardPaths::DownloadLocation

proc downloadAuditDo(o: MusterUi, intentId: string, d: Done = nil) =
  # The module builds the signature-audit file (exo-403); the UI only saves it: the
  # canonical bytes as .cbor, what verifies, and the report rendered from them as .md.
  ask mm.coordinate_auditAsync(intentId, proc (r: string) =
    let a = obj(r)
    var res = %*{"intentId": intentId}
    if not a{"ok"}.getBool(false):
      res["ok"] = %false
      res["reason"] = %(a{"reason"}.getStr(r))
    else:
      var dir = getEnv("MUSTER_AUDIT_DIR")
      if dir.len == 0: dir = QStandardPaths.writableLocation(DownloadLocation.cint)
      if dir.len == 0: dir = getHomeDir()
      let stem = intentId.replace("0x", "")
      let cborPath = dir / ("muster-audit-" & stem & ".cbor")
      let mdPath = dir / ("muster-audit-" & stem & ".md")
      var wrote = false
      try:
        createDir(dir)
        writeFile(cborPath, parseHexStr(a{"file"}.getStr("")))
        writeFile(mdPath, a{"report"}.getStr(""))
        wrote = true
      except CatchableError: discard
      res["ok"] = %wrote
      if wrote:
        res["cbor"] = %cborPath
        res["report"] = %mdPath
        res["digest"] = %(a{"digest"}.getStr(""))
      else:
        res["reason"] = %("could not write to " & dir)
    let j = $res
    info "downloadAudit " & qs(intentId) & " -> " & qs(j)
    o.setAuditJson(j)
    fin(d, j))

# ── policy and accounts ─────────────────────────────────────────────────────────

proc setPolicyDo(o: MusterUi, kind: string, d: Done = nil) =
  # Choose the room's driver. A refused choice never overwrites the policy in force: it
  # lands on policyErrorJson, and the policy is re-read.
  ask mm.coordinate_set_policyAsync(kind, proc (r: string) =
    info "coordinate_set_policy( " & qs(kind) & " ) -> " & qs(r)
    if obj(r).hasKey("error"):
      o.setPolicyErrorJson(r)
      o.loadPolicyDo(d)
      return
    o.setPolicyErrorJson("{}")
    o.setPolicyJson(r)
    fin(d, r))

proc discloseAccountDo(o: MusterUi, accountJson: string, d: Done = nil) =
  # Disclose an account into the room as this member.
  ask mm.coordinate_disclose_accountAsync(accountJson, proc (r: string) =
    info "coordinate_disclose_account -> " & qs(r)
    o.setAccountDiscloseJson(r)
    o.loadAccountsDo()
    o.loadPolicyDo(d))

proc discloseSuggestedAccountDo(o: MusterUi, d: Done = nil) =
  # The local test Safe describe() suggests (the anvil fixture), disclosed as is, with
  # its owners and threshold.
  ask mm.describeAsync(proc (r: string) =
    var s: JsonNode
    try: s = parseJson(r)
    except CatchableError: s = nil
    if s == nil or s.kind != JObject:
      o.setAccountDiscloseJson("{\"error\":\"no suggestion\"}")
      fin(d, r)
      return
    let a = %*{"family": s{"family"}.getStr("evm.safe")}
    for (dst, src) in [("chain", "chain"), ("address", "safe"), ("label", "label"),
                       ("signers", "owners"), ("threshold", "threshold")]:
      if s.hasKey(src): a[dst] = s[src]   # a missing value is left out, as QJsonObject does
    o.discloseAccountDo($a, d))

# ── startup and the autopilot ───────────────────────────────────────────────────

proc retryStartup(o: MusterUi, attemptsLeft: int) =
  # health() is empty while the module is not answering; once it does, redo the startup
  # reads, which were lost. Bounded (~30 s).
  if o.health.len > 0 or attemptsLeft <= 0: return
  after(1500, proc () =
    o.checkHealthDo(proc (r: string) =
      if r.len == 0:
        o.retryStartup(attemptsLeft - 1)
        return
      info "module answered — re-running the startup reads"
      o.loadAccountDo()
      o.loadSettingsDo()
      o.loadDriversDo()
      o.startInboxDo()))

proc autopayTick(o: MusterUi)
proc autovoiceTick(o: MusterUi)
proc autoLezFund(o: MusterUi)

proc autojoin(o: MusterUi, topic: string) =
  # The headless self-tests' hook: join MUSTER_AUTOJOIN_TOPIC through the same calls a
  # person's clicks make, then do what the other MUSTER_AUTO* variables ask.
  info "AUTOJOIN -> " & qs(topic)
  o.joinRoomDo(topic, proc (r: string) =
    let autotitle = getEnv("MUSTER_AUTOTITLE")
    if autotitle.len > 0:
      o.setRoomTitleDo(topic, autotitle, proc (r: string) =
        info "AUTOTITLE conversations -> " & o.conversationsJson)
    after(3000, proc () = o.requestJoinDo())

    # MUSTER_AUTOCHAT=<n>: n chat lines through the composer's own call (exo-dde.8); the
    # thread is re-read once at the end.
    let autochat = try: parseInt(getEnv("MUSTER_AUTOCHAT", "0")) except ValueError: 0
    if autochat > 0:
      after(2000, proc () =
        let done = barrier(autochat, proc () =
          o.loadMessagesDo()
          info "AUTOCHAT posted " & $autochat)
        for i in 0 ..< autochat:
          ask mm.coordinate_post_messageAsync("scale line " & $(i + 1) & " of " & $autochat,
            proc (r: string) = done()))

    # MUSTER_AUTOINVITE=<contact alias>: invite that contact, as "Open the room with
    # them" does.
    let who = getEnv("MUSTER_AUTOINVITE")
    if who.len > 0:
      after(2000, proc () =
        o.loadContactsDo(proc (r: string) =
          for c in arr(o.contactsJson):
            if c{"alias"}.getStr("") == who:
              o.sendInviteDo(c{"identity"}.getStr(""), topic, "talk")
              return
          info "AUTOINVITE: no contact named " & qs(who)))

    # MUSTER_AUTOPROPOSE=<effect json>: propose it, then the card's round trips: the
    # readiness, and with the other variables a disclosure, a policy, an in-app
    # approval, the audit file and a decline (exo-002.3, exo-403, exo-a50.1.3).
    let effect = getEnv("MUSTER_AUTOPROPOSE")
    if effect.len > 0:
      after(4000, proc () =
        var id = ""
        var steps: seq[Step]
        if existsEnv("MUSTER_AUTODISCLOSE") and getEnv("MUSTER_AUTODISCLOSE").len > 0:
          steps.add proc (next: proc ()) = o.discloseSuggestedAccountDo(then(next))
        let autopolicy = getEnv("MUSTER_AUTOPOLICY")
        if autopolicy.len > 0:
          steps.add proc (next: proc ()) = o.setPolicyDo(autopolicy, then(next))
        steps.add proc (next: proc ()) =
          ask mm.coordinate_proposeAsync(effect, proc (r: string) =
            id = r
            info "AUTOPROPOSE -> " & qs(id)
            next())
        if getEnv("MUSTER_AUTOAPPROVE").len > 0:
          steps.add proc (next: proc ()) = o.contributeInRoomDo(id, "", "", then(next))
        if getEnv("MUSTER_AUTOAUDIT").len > 0:
          steps.add proc (next: proc ()) = o.downloadAuditDo(id, then(next))
        steps.add proc (next: proc ()) = o.loadIntentsDo(then(next))
        steps.add proc (next: proc ()) = o.loadReadinessDo(id, then(next))
        if getEnv("MUSTER_AUTODECLINE").len > 0:
          steps.add proc (next: proc ()) = o.declineInRoomDo(id, then(next))
        steps.add proc (next: proc ()) = o.loadFlowDo(then(next))
        steps.add proc (next: proc ()) = o.loadConnectivityDo(then(next))
        chain(steps, proc () = info "AUTOPROPOSE intents -> " & qs(o.intentsJson)))

    # MUSTER_AUTOREPORTPAID=<intent id>: the card's "I paid" (exo-dcc.5).
    let autoreport = getEnv("MUSTER_AUTOREPORTPAID")
    if autoreport.len > 0:
      after(4000, proc () =
        o.reportPaidDo(autoreport, "", proc (r: string) =
          info "AUTOREPORTPAID -> " & qs(o.splitJson)))

    # The room's live refresh, at the Room view's own 1 s cadence, so the self-tests
    # measure the latency a person feels. A tick whose reads are still in flight is
    # skipped: the C++ ticks could not overlap, because their calls blocked.
    var busy = false
    every(1000, proc (): bool =
      if busy: return true
      busy = true
      let loaded = barrier(4, proc () =
        o.autopayTick()
        o.autovoiceTick()
        busy = false)
      o.loadPendingDo(then(loaded))
      o.loadMembersDo(then(loaded))
      o.loadMessagesDo(then(loaded))
      o.loadIntentsDo(then(loaded))
      true))

var
  shared, proposed: bool
  admitting: HashSet[string]
  agreed, agreeing, paid, paying: HashSet[string]
  payAgainAt, agreeAgainAt, agreeGiveUpAt: Table[string, int64]

proc agree(o: MusterUi, id: string) =
  # Agree to `id`. A refusal that can be transient (a proposal's context or reads not yet
  # in this member's view, exo-ca3) is tried again every 2 s, for up to 60 s.
  let now = nowS()
  if now < agreeAgainAt.getOrDefault(id, 0) or id in agreeing: return
  agreeing.incl id
  o.contributeInRoomDo(id, "", "", proc (rj: string) =
    agreeing.excl id
    let r = obj(rj)
    let why = r{"reason"}.getStr("")
    let transient = not r{"ok"}.getBool(false) and
      why in ["no-context", "unknown-intent", "unaccountable-input"]
    if id notin agreeGiveUpAt: agreeGiveUpAt[id] = now + 60
    if transient and now < agreeGiveUpAt[id]:
      agreeAgainAt[id] = now + 2
      info "SELFTEST agree " & qs(id) & " refused " & qs(why) & " - again in 2s"
    else:
      agreed.incl id)   # agreed, or refused for good: stop asking

proc autopayTick(o: MusterUi) =
  let founder = getEnv("MUSTER_AUTOADMIT").len > 0
  # MUSTER_AUTOSHARE: share this member's address once someone else is in. For a Bitcoin
  # or Monero chain the module makes the address (exo-dcc.20).
  let shareOn = getEnv("MUSTER_AUTOSHARE")
  let othersIn = o.membersJson.contains("\"self\":false")
  if not shared and (shareOn.startsWith("monero:") or shareOn.startsWith("bip122:")) and othersIn:
    shared = true
    o.shareAddressDo(shareOn)
  if not shared and shareOn.len > 0 and othersIn:
    let address = obj(o.settingsJson){"identity"}{"address"}.getStr("")
    if address.len > 0:
      shared = true
      o.postMessageDo($(%*{"kind": "address-share", "asset": "ETH", "address": address, "form": 1}))
  # Founder only: admit the first pending asker (one admitter keeps one shared epoch),
  # then propose one intent so the other side's convergence can be observed.
  if founder:
    let pending = arr(o.pendingJson)
    if pending.len > 0:
      let id = pending[0]{"identity"}.getStr("")
      if id.len > 0 and id notin admitting:
        admitting.incl id
        o.admitDo(id, proc (r: string) = admitting.excl id)
    # MUSTER_AUTOSPLIT_FOR: propose the split on the OTHER member's behalf, once they
    # have shared an address (exo-770)
    let forOther = getEnv("MUSTER_AUTOSPLIT_FOR").len > 0
    if not proposed and othersIn and (not forOther or o.messagesJson.contains("address-share")):
      proposed = true
      let autosplit = getEnv("MUSTER_AUTOSPLIT")
      if autosplit.len > 0:
        # MUSTER_AUTOSPLIT=<total, base units> splits a bill this founder fronted with the
        # other member, through the Split composer's own slot (exo-a90.8)
        var others = newJArray()
        var me = ""
        for m in arr(o.membersJson):
          if not m{"self"}.getBool(false): others.add %(m{"identity"}.getStr(""))
          else: me = m{"identity"}.getStr("")
        let shares =
          if forOther and others.len > 0: $(%*{"parties": [me], "creditor": others[0]})
          else: $others
        let doSplit = proc () =
          o.proposeSplitDo(getEnv("MUSTER_AUTOSPLIT_CHAIN"), autosplit, shares, "split self-test")
        # MUSTER_AUTOPOLICY: choose the split's kind first, bare, so chain "" takes the
        # kind's own default (a Monero request: stagenet, exo-dcc.5)
        let splitPolicy = getEnv("MUSTER_AUTOPOLICY")
        if splitPolicy.len > 0:
          o.setPolicyDo(splitPolicy, proc (r: string) =
            info "AUTOPOLICY -> " & qs(o.policyJson) & " " & qs(o.policyErrorJson)
            doSplit())
        else:
          doSplit()
      else:
        o.proposeInRoomDo("{\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":1000,\"nonce\":0}")
  # MUSTER_AUTOPAYSPLIT, the debtor's side: agree to MY share of any split that names
  # me, then pay it once everyone has agreed. A refused pay is tried again after 10 s,
  # and none is tried while MUSTER_AUTOLEZFUND is funding.
  if getEnv("MUSTER_AUTOPAYSPLIT").len > 0:
    for it in arr(o.intentsJson):
      if not it.hasKey("split"): continue
      let id = it{"id"}.getStr("")
      let st = it{"state"}.getStr("")
      var mine = newJObject()
      for p in it{"parts"}.getElems():
        if p{"mine"}.getBool(false): mine = p
      # the creditor of a split proposed on their behalf (exo-770) agrees that payTo is
      # theirs, only when their own client holds it
      let sp = it{"split"}
      if mine.len == 0 and sp{"iAmCreditor"}.getBool(false) and
         not sp{"creditorAgreed"}.getBool(false) and sp{"payToMine"}.getBool(false) and
         st in ["proposed", "collecting"] and id notin agreed:
        o.agree(id)
      if mine.len == 0: continue
      if st in ["proposed", "collecting"] and not it{"approvedByMe"}.getBool(false) and
         id notin agreed:
        o.agree(id)
      elif not lezFunding and st in ["executable", "submitted", "settling"] and
           not mine{"settled"}.getBool(false) and not mine{"paying"}.getBool(false) and
           id notin paid and id notin paying and nowS() >= payAgainAt.getOrDefault(id, 0):
        paying.incl id
        o.settlePartDo(id, proc (outcome: string) =
          paying.excl id
          if outcome.contains("\"error\""): payAgainAt[id] = nowS() + 10
          else: paid.incl id)
  info "SELFTEST pending= " & qs(o.pendingJson) & " members= " & qs(o.membersJson) &
    " intents= " & qs(o.intentsJson)

var
  voiceStarted, voiceTimed, voiceAsking: bool
  voicePlayed: HashSet[string]
  voiceTries: Table[string, int]

proc autovoicePlay(o: MusterUi, id: string) =
  # The card's Play, for the voice self-test; no voice read or other Play overlaps it.
  voiceTries[id] = voiceTries.getOrDefault(id, 0) + 1
  voiceAsking = true
  o.playVoiceNoteDo(id, proc (r: string) =
    voiceAsking = false
    info "VOICE-RESULT play " & id & " " & o.voiceResultJson
    if not o.voiceResultJson.contains("\"error\""): voicePlayed.incl id)

proc autovoiceTick(o: MusterUi) =
  # Voice self-test (docs/design/voice-notes.md S9): MUSTER_AUTOVOICE=<seconds> records that
  # long once someone else is in the room, then sends the draft: the mic's Start, Stop and
  # Send. The module answers Start at once and starts the device on a thread of its own
  # (§9), so the seconds count from the first voice_status that says recording, not from
  # the call. MUSTER_AUTOVOICEPLAY=1 plays a complete note another member sent, while nothing
  # plays, as the card's Play does; a refused Play is tried again on the next tick, up to
  # five times. Each tick logs voice_status as VOICE and the thread's notes as VOICE-NOTES,
  # and each call's answer as VOICE-RESULT <call>.
  let secs = try: parseInt(getEnv("MUSTER_AUTOVOICE", "0")) except ValueError: 0
  let play = getEnv("MUSTER_AUTOVOICEPLAY").len > 0
  if (secs <= 0 and not play) or voiceAsking: return
  voiceAsking = true
  o.loadVoiceDo(proc (r: string) =
    voiceAsking = false
    info "VOICE " & o.voiceJson
    var notes = newJArray()
    for row in arr(o.messagesJson):
      let v = row{"voice"}
      if v == nil or v.kind != JObject: continue
      let n = v.copy()
      n["self"] = %row{"self"}.getBool(false)
      notes.add n
    info "VOICE-NOTES " & $notes
    if secs > 0 and not voiceStarted and o.membersJson.contains("\"self\":false"):
      voiceStarted = true
      o.startVoiceRecordingDo(proc (r: string) =
        info "VOICE-RESULT start " & o.voiceResultJson)
    let recState = obj(o.voiceJson){"recording"}{"state"}.getStr("")
    if secs > 0 and voiceStarted and not voiceTimed and recState == "recording":
      voiceTimed = true
      after(secs * 1000, proc () =
        o.stopVoiceRecordingDo(proc (r: string) =
          info "VOICE-RESULT stop " & o.voiceResultJson
          o.sendVoiceDraftDo(proc (r: string) =
            info "VOICE-RESULT send " & o.voiceResultJson)))
    let playing = obj(o.voiceJson){"playing"}
    if play and playing != nil and playing.kind == JNull:
      for n in notes:
        let id = n{"note"}.getStr("")
        if id.len == 0 or n{"self"}.getBool(false) or id in voicePlayed or
           n{"state"}.getStr("") != "complete" or voiceTries.getOrDefault(id, 0) >= 5: continue
        o.autovoicePlay(id)
        break)

proc autoLezFund(o: MusterUi) =
  # LEZ self-test (exo-14d): MUSTER_AUTOLEZFUND funds THIS instance's private balance as
  # a person would, through the module's own wallet path: make sure the public account
  # exists and log it, so whoever holds native LEZ can send to it (v0.3 has no faucet);
  # wait for the funds; shield them all to MY OWN key node; wait for that proof.
  lezFunding = true
  const lez = "lez:testnet"
  var
    stage = 0
    pub, keyNode: string
    retryAt, awaitingSince: int64
    busy = false
  every(5000, proc (): bool =
    if stage == 3: return false
    let now = nowS()
    if busy or now < retryAt: return true
    busy = true
    case stage
    of 0:                                  # the accounts, and the one to fund
      ask mm.wallet_lez_setupAsync(proc (r: string) =
        info "LEZFUND setup -> " & qs(r)
        if r.contains("\"error\""):
          retryAt = now + 30
          busy = false
          return
        discard mm.wallet_accountsAsync(proc (ra: string) =
          for a in arr(ra):
            if a{"chain"}.getStr("") != lez: continue
            if a{"form"}.getStr("") == "public": pub = a{"id"}.getStr("")
            if a{"form"}.getStr("") == "shielded": keyNode = a{"share"}.getStr("")
          info "LEZFUND public " & qs(pub) & " key node " & qs(keyNode[0 ..< min(24, keyNode.len)])
          if pub.len > 0 and keyNode.len > 0:
            info "LEZFUND awaiting funds at " & qs(pub)
            awaitingSince = now
            stage = 1
          busy = false))
    of 1:                                  # someone who holds native LEZ sends it
      ask mm.wallet_balancesAsync(proc (rb: string) =
        var raw = ""
        for b in arr(rb):
          if b{"chain"}.getStr("") == lez and b{"account"}.getStr("") == pub:
            raw = b{"raw"}.getStr("")
        info "LEZFUND public balance " & qs(raw)
        if raw.len == 0 or raw == "0":
          # nothing yet: say so now and then, so a funder can find the account
          if now - awaitingSince >= 60:
            info "LEZFUND awaiting funds at " & qs(pub)
            awaitingSince = now
          busy = false
          return
        discard mm.wallet_sendAsync(lez, pub, keyNode, "LEZ", raw, proc (rs: string) =
          info "LEZFUND shield " & qs(raw) & " -> " & qs(rs)
          if rs.contains("\"error\""): retryAt = now + 30
          else: stage = 2
          busy = false))
    else:                                  # the shield proves in the background
      ask mm.wallet_finalityAsync(lez, "pending", proc (f: string) =
        info "LEZFUND shield finality -> " & qs(f)
        if f.contains("\"final\""):
          info "LEZFUND funded"
          lezFunding = false
          stage = 3
        elif f.contains("\"failed\""):
          stage = 1                        # shield what is public again
        busy = false)
    true)

proc contextReady*(o: MusterUi) =
  ## What the C++ backend did in onContextReady, once the core answers: read liveness,
  ## the account, the settings and the kind list; start the inbox, so invites arrive
  ## before any room is opened; then the MUSTER_AUTO* autopilot. NOT the wallet
  ## balances: those read the RPC, and nothing has introduced one yet (exo-428).
  o.checkHealthDo(proc (r: string) = o.retryStartup(20))
  o.loadAccountDo()
  o.loadSettingsDo()
  o.loadDriversDo()
  o.startInboxDo()

  # MUSTER_KEYSTORE_PROBE=1: keystore_status every 2 s for a minute, each answer logged
  # (exo-149.1 K1). The first read only sends the async reads; the answers land later.
  if getEnv("MUSTER_KEYSTORE_PROBE").len > 0:
    var n = 0
    every(2000, proc (): bool =
      o.loadKeystoreStatusDo(proc (r: string) = info "KEYSTORE " & r)
      inc n
      n < 30)

  # MUSTER_AUTOLEAVE=<topic> leaves that room 10 s after startup, once the module has
  # re-entered the rooms it remembers (exo-dcc.28).
  let autoleave = getEnv("MUSTER_AUTOLEAVE")
  if autoleave.len > 0:
    after(10000, proc () =
      info "AUTOLEAVE -> " & qs(autoleave)
      o.leaveRoomDo(autoleave, proc (r: string) =
        info "AUTOLEAVE conversations -> " & o.conversationsJson))

  let autojoin = getEnv("MUSTER_AUTOJOIN_TOPIC")
  if autojoin.len > 0:
    after(5000, proc () = o.autojoin(autojoin))

  # MUSTER_AUTOLEZFUND runs on its own, not only inside an autojoin run, so a person
  # trying the tour can fund a wallet the same way (scripts/try-peer.sh --lez-fund).
  if getEnv("MUSTER_AUTOLEZFUND").len > 0:
    after(5000, proc () = o.autoLezFund())

# ── the SLOTs ───────────────────────────────────────────────────────────────────

proc checkHealthImpl(o: MusterUi) = o.checkHealthDo()
proc loadAccountImpl(o: MusterUi) = o.loadAccountDo()
proc loadSettingsImpl(o: MusterUi) = o.loadSettingsDo()
proc setSettingImpl(o: MusterUi, key, value: string) =
  # Repoint the RPC or delivery config; the updated settings land back on settingsJson.
  ask mm.set_settingAsync(key, value, proc (r: string) = o.setSettingsJson(r))
proc proposeImpl(o: MusterUi, effectJson: string) = o.proposeDo(effectJson)
proc approveImpl(o: MusterUi, signatureHex: string) = o.approveDo(signatureHex)
proc submitImpl(o: MusterUi) = o.submitDo()
proc resetImpl(o: MusterUi) = o.resetDo()
proc loadBalancesImpl(o: MusterUi) = o.loadBalancesDo()
proc loadWalletAccountsImpl(o: MusterUi) = o.loadWalletAccountsDo()
proc previewLezSendImpl(o: MusterUi, fromId, to, raw: string) = o.previewLezSendDo(fromId, to, raw)
proc sendLezImpl(o: MusterUi, fromId, to, raw: string) = o.sendLezDo(fromId, to, raw)
proc joinRoomImpl(o: MusterUi, topic: string) = o.joinRoomDo(topic)
proc postMessageImpl(o: MusterUi, body: string) = o.postMessageDo(body)
proc loadMessagesImpl(o: MusterUi) = o.loadMessagesDo()
proc loadMembersImpl(o: MusterUi) = o.loadMembersDo()
proc loadConversationsImpl(o: MusterUi) = o.loadConversationsDo()
proc requestJoinImpl(o: MusterUi) = o.requestJoinDo()
proc loadPendingImpl(o: MusterUi) = o.loadPendingDo()
proc admitImpl(o: MusterUi, identityHex: string) = o.admitDo(identityHex)
proc loadContactsImpl(o: MusterUi) = o.loadContactsDo()
proc loadFileShareImpl(o: MusterUi) = o.loadFileShareDo()
proc shareFileImpl(o: MusterUi, path: string) =
  ask mm.fileshare_shareAsync(path, proc (r: string) = o.fileShareDone(r))
proc fetchFileImpl(o: MusterUi, fileId, folder, privately: string) =
  ask mm.fileshare_fetchAsync(fileId, folder, privately, proc (r: string) = o.fileShareDone(r))
proc seedFileImpl(o: MusterUi, fileId, on: string) =
  ask mm.fileshare_seedAsync(fileId, on, proc (r: string) = o.fileShareDone(r))
proc retractFileImpl(o: MusterUi, fileId: string) =
  ask mm.fileshare_retractAsync(fileId, proc (r: string) = o.fileShareDone(r))
proc loadVoiceImpl(o: MusterUi) = o.loadVoiceDo()
proc startVoiceRecordingImpl(o: MusterUi) = o.startVoiceRecordingDo()
proc stopVoiceRecordingImpl(o: MusterUi) = o.stopVoiceRecordingDo()
proc sendVoiceDraftImpl(o: MusterUi) = o.sendVoiceDraftDo()
proc discardVoiceDraftImpl(o: MusterUi) =
  ask mm.voice_draft_discardAsync(proc (r: string) = o.voiceDone(r))
proc playVoiceNoteImpl(o: MusterUi, noteId: string) = o.playVoiceNoteDo(noteId)
proc stopVoicePlaybackImpl(o: MusterUi) =
  ask mm.voice_play_stopAsync(proc (r: string) = o.voiceDone(r))
proc addContactImpl(o: MusterUi, identityHex, alias: string) = o.addContactDo(identityHex, alias)
proc setContactAliasImpl(o: MusterUi, identityHex, alias: string) = o.setContactAliasDo(identityHex, alias)
proc removeContactImpl(o: MusterUi, identityHex: string) = o.removeContactDo(identityHex)
proc startInboxImpl(o: MusterUi) = o.startInboxDo()
proc sendInviteImpl(o: MusterUi, peerChatId, roomTopic, note: string) = o.sendInviteDo(peerChatId, roomTopic, note)
proc loadInvitesImpl(o: MusterUi) = o.loadInvitesDo()
proc dismissInviteImpl(o: MusterUi, roomTopic: string) = o.dismissInviteDo(roomTopic)
proc leaveRoomImpl(o: MusterUi, roomTopic: string) = o.leaveRoomDo(roomTopic)
proc setRoomTitleImpl(o: MusterUi, roomTopic, title: string) = o.setRoomTitleDo(roomTopic, title)
proc proposeInRoomImpl(o: MusterUi, effectJson: string) = o.proposeInRoomDo(effectJson)
proc contributeInRoomImpl(o: MusterUi, intentId, signatureHex, keyRef: string) =
  o.contributeInRoomDo(intentId, signatureHex, keyRef)
proc loadIntentsImpl(o: MusterUi) = o.loadIntentsDo()
proc reannounceImpl(o: MusterUi) = o.reannounceDo()
proc loadActivityImpl(o: MusterUi) = o.loadActivityDo()
proc submitInRoomImpl(o: MusterUi, intentId: string) = o.submitInRoomDo(intentId)
proc setPolicyImpl(o: MusterUi, kind: string) = o.setPolicyDo(kind)
proc loadPolicyImpl(o: MusterUi) = o.loadPolicyDo()
proc loadDriversImpl(o: MusterUi) = o.loadDriversDo()
proc loadAccountsImpl(o: MusterUi) = o.loadAccountsDo()
proc discloseAccountImpl(o: MusterUi, accountJson: string) = o.discloseAccountDo(accountJson)
proc discloseSuggestedAccountImpl(o: MusterUi) = o.discloseSuggestedAccountDo()
proc loadAvailableActionsImpl(o: MusterUi) = o.loadAvailableActionsDo()
proc executeInRoomImpl(o: MusterUi, intentId: string) = o.executeInRoomDo(intentId)
proc loadConnectivityImpl(o: MusterUi) = o.loadConnectivityDo()
proc loadSecurityLevelsImpl(o: MusterUi) = o.loadSecurityLevelsDo()
proc loadRoomAccountImpl(o: MusterUi) = o.loadRoomAccountDo()
proc loadReadinessImpl(o: MusterUi, intentId: string) = o.loadReadinessDo(intentId)
proc loadOffersImpl(o: MusterUi, intentId: string) = o.loadOffersDo(intentId)
proc loadComposeOffersImpl(o: MusterUi, effectJson: string) = o.loadComposeOffersDo(effectJson)
proc shareMaterialImpl(o: MusterUi, intentId, requirement, pub: string) =
  o.shareMaterialDo(intentId, requirement, pub)
proc declineInRoomImpl(o: MusterUi, intentId: string) = o.declineInRoomDo(intentId)
proc downloadAuditImpl(o: MusterUi, intentId: string) = o.downloadAuditDo(intentId)
proc exportOutsideImpl(o: MusterUi, intentId: string) = o.exportOutsideDo(intentId)
proc importOutsideImpl(o: MusterUi, intentId, encoded: string) = o.importOutsideDo(intentId, encoded)
proc proposeBtcSpendImpl(o: MusterUi, payTo, amountSat, feeRate: string) =
  o.proposeBtcSpendDo(payTo, amountSat, feeRate)
proc proposeSplitImpl(o: MusterUi, chain, totalWei, sharesJson, memo: string) =
  o.proposeSplitDo(chain, totalWei, sharesJson, memo)
proc proposeSettleUpImpl(o: MusterUi, chain, asset, memo: string) = o.proposeSettleUpDo(chain, asset, memo)
proc settlePartImpl(o: MusterUi, intentId: string) = o.settlePartDo(intentId)
proc renewSplitImpl(o: MusterUi, intentId: string) = o.renewSplitDo(intentId)
proc lookupTokenImpl(o: MusterUi, chain, token: string) = o.lookupTokenDo(chain, token)
proc loadOpenAssetsImpl(o: MusterUi) = o.loadOpenAssetsDo()
proc proposeSettleUpAcrossImpl(o: MusterUi, chain, asset, ratesJson, memo: string) =
  o.proposeSettleUpAcrossDo(chain, asset, ratesJson, memo)
proc shareAddressImpl(o: MusterUi, chain: string) = o.shareAddressDo(chain)
proc confirmPartImpl(o: MusterUi, intentId, part, tx: string) = o.confirmPartDo(intentId, part, tx)
proc reportPaidImpl(o: MusterUi, intentId, tx: string) = o.reportPaidDo(intentId, tx)
proc proposeLezTransferImpl(o: MusterUi, recipient, amount: string) = o.proposeLezTransferDo(recipient, amount)
proc proposeLezVaultInitImpl(o: MusterUi, definition: string) = o.proposeLezVaultInitDo(definition)
proc lezMemberAccountImpl(o: MusterUi, index: string) = o.lezMemberAccountDo(index)
proc lezCreateMultisigImpl(o: MusterUi, threshold, members: string) = o.lezCreateMultisigDo(threshold, members)
proc frostCeremonyOpenImpl(o: MusterUi, ceremonyId, network, t, n: string) =
  o.frostCeremonyOpenDo(ceremonyId, network, t, n)
proc frostCeremonyJoinImpl(o: MusterUi, ceremonyId: string) = o.frostCeremonyJoinDo(ceremonyId)
proc loadFrostCeremoniesImpl(o: MusterUi) = o.loadFrostCeremoniesDo()
proc xmrMsigSetupOpenImpl(o: MusterUi, ceremonyId, chain, k, membersJson: string) =
  o.xmrMsigSetupOpenDo(ceremonyId, chain, k, membersJson)
proc xmrMsigSetupJoinImpl(o: MusterUi, ceremonyId: string) = o.xmrMsigSetupJoinDo(ceremonyId)
proc xmrMsigProposeImpl(o: MusterUi, account, recipientsJson, feeCap, memo: string) =
  o.xmrMsigProposeDo(account, recipientsJson, feeCap, memo)
proc loadXmrMsigImpl(o: MusterUi) = o.loadXmrMsigDo()
proc loadWalletSummaryImpl(o: MusterUi) = o.loadWalletSummaryDo()
proc loadFlowImpl(o: MusterUi) = o.loadFlowDo()
proc loadGraphImpl(o: MusterUi, roomTopic: string) = o.loadGraphDo(roomTopic)
proc loadRlnStatusImpl(o: MusterUi) = o.loadRlnStatusDo()
proc loadKeystoreStatusImpl(o: MusterUi) = o.loadKeystoreStatusDo()
proc keystoreSelectImpl(o: MusterUi, address: string) = o.keystoreSelectDo(address)
proc loadKeystoreRequestsImpl(o: MusterUi) = o.loadKeystoreRequestsDo()
