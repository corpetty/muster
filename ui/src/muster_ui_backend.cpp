#include "muster_ui_backend.h"

#include <QDebug>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QSet>
#include <memory>
#include <QDateTime>

// Generated umbrella: LogosModules (behind modules()) built from
// metadata.json#dependencies — the typed muster_module client the UI calls
// through the logos API (no hand-written invokeRemoteMethod, no keys, no net).
#include "logos_sdk.h"

// The seam the P4 spike proved: a QML view -> this C++ backend -> the generated
// muster_module client -> the Nim core, all through the logos API. Each call
// below returns the module's typed QString; it lands in a .rep PROP, which QtRO
// pushes to the QML replica. The backend keeps no state — the intent lives in
// the module; this is a conduit.

void MusterUiBackend::checkHealth()
{
    const QString h = modules().muster_module.health();
    qInfo() << "[muster_ui] muster_module.health() ->" << h;
    setHealth(h);
}

void MusterUiBackend::loadSettings()
{
    // settings() → {rpc, delivery, environment, identity}. The user-configurable
    // infrastructure (invariant 8) + who this module is.
    setSettingsJson(modules().muster_module.settings());
}

void MusterUiBackend::setSetting(const QString &key, const QString &value)
{
    // set_setting → repoint the RPC or delivery config; the module returns the
    // updated settings, which lands back on settingsJson.
    setSettingsJson(modules().muster_module.set_setting(key, value));
}

void MusterUiBackend::loadAccount()
{
    // The Safe account this walkthrough coordinates against. The view displays
    // the domain it is told here (chainId, safe, threshold), never one it
    // hardcodes — the safeTxHash commits to exactly this account.
    const QString a = modules().muster_module.describe();
    qInfo() << "[muster_ui] muster_module.describe() ->" << a;
    setAccountJson(a);
}

void MusterUiBackend::propose(const QString &effectJson)
{
    // propose -> the module canonicalizes the effect to the EIP-712 safeTxHash
    // and returns the intent id; txhash exposes those exact bytes; status is the
    // lifecycle state. The strip in QML shows the effect we sent (intentEffect)
    // against the hash the module re-derived from it (intentTxhash) — they agree
    // by construction here, which is the honest "matches" case. A genuine
    // mismatch is core's to refuse (F-4 / invariant 1) and only becomes
    // demonstrable with a divergent input source (the plugin runtime, P5); it is
    // never simulated.
    setLastError(QString());

    const QString id = modules().muster_module.propose(effectJson);
    if (id.isEmpty() || id.startsWith(QStringLiteral("unknown"))) {
        qWarning() << "[muster_ui] propose failed ->" << id;
        setLastError(QStringLiteral("propose failed: %1").arg(id));
        return;
    }

    setIntentId(id);
    setIntentEffect(effectJson);
    const QString state = modules().muster_module.status(id);
    setIntentTxhash(modules().muster_module.txhash(id));
    setIntentState(state);
    qInfo() << "[muster_ui] proposed" << id << "state" << state;
}

void MusterUiBackend::approve(const QString &signatureHex)
{
    // The owner signed this intent's safeTxHash on their own device; the 65-byte
    // hex is handed in here. The module verifies it recovers to a configured
    // owner before it counts, then returns the new lifecycle state (collecting
    // until the threshold is met, then executable). The client never holds keys.
    setLastError(QString());

    const QString id = intentId();
    if (id.isEmpty()) {
        setLastError(QStringLiteral("no intent to approve"));
        return;
    }

    const QString newState = modules().muster_module.approve(id, signatureHex);
    if (newState == QStringLiteral("rejected")) {
        // The module refused the signature: it did not recover to a configured
        // owner (or was already counted). Say so honestly; the intent is unchanged.
        setLastError(QStringLiteral("signature not counted — it did not recover to a configured owner (or was already collected)"));
        return;
    }
    if (newState.isEmpty() || newState.startsWith(QStringLiteral("unknown"))
        || newState.startsWith(QStringLiteral("error"))) {
        qWarning() << "[muster_ui] approve failed ->" << newState;
        setLastError(QStringLiteral("approve failed: %1").arg(newState));
        return;
    }

    setIntentState(newState);
    qInfo() << "[muster_ui] approve" << id << "->" << newState;
}

void MusterUiBackend::submit()
{
    // Submit the executable intent on-chain. The module assembles the Safe
    // execTransaction from the collected owner signatures, sends it through the
    // user's RPC, and reads finality from the receipt — no indexer, no service.
    // The client never holds keys; the sender only relays gas.
    setLastError(QString());

    const QString id = intentId();
    if (id.isEmpty()) {
        setLastError(QStringLiteral("no intent to submit"));
        return;
    }

    const QString newState = modules().muster_module.submit(id);
    if (newState.isEmpty() || newState.startsWith(QStringLiteral("unknown"))
        || newState.startsWith(QStringLiteral("error"))) {
        qWarning() << "[muster_ui] submit failed ->" << newState;
        setLastError(QStringLiteral("submit failed: %1").arg(newState));
        return;
    }

    setIntentState(newState);
    if (newState != QStringLiteral("final") && newState != QStringLiteral("submitted")) {
        // The module accepted the call but the intent did not move on-chain — most
        // often the RPC endpoint is unreachable. Say so rather than implying it landed.
        setLastError(QStringLiteral("submit did not land on-chain (state %1) — is the RPC reachable?").arg(newState));
    }
    qInfo() << "[muster_ui] submit" << id << "->" << newState;
}

void MusterUiBackend::reset()
{
    // UI-only: clear the current intent so the composer is fresh. The module keeps
    // its own log of every intent; this just stops the view pointing at one. The
    // account and health stay — they are module facts, not intent state.
    setIntentId(QString());
    setIntentEffect(QString());
    setIntentTxhash(QString());
    setIntentState(QString());
    setLastError(QString());
    qInfo() << "[muster_ui] reset — view cleared for a new proposal";
}

void MusterUiBackend::loadBalances()
{
    // The wallet's account-level view: balances across every configured chain,
    // each carrying its F-10 grade (attested vs verified-locally). Straight from
    // the module — the backend holds no keys, no net, no state.
    const QString b = modules().muster_module.wallet_balances();
    qInfo() << "[muster_ui] muster_module.wallet_balances() ->" << b;
    setBalancesJson(b);
}

void MusterUiBackend::loadWalletAccounts()
{
    // Every account across chains, with a LEZ account's shareable address (the `share`
    // field) — the addresses you hand out to be paid (Mode A request→share→send).
    setWalletAccountsJson(modules().muster_module.wallet_accounts());
}

void MusterUiBackend::previewLezSend(const QString &fromId, const QString &to, const QString &raw)
{
    // Preview the rail + disclosure without committing — the honesty before you send.
    Q_UNUSED(fromId);
    setLezPreviewJson(modules().muster_module.wallet_estimate_fee(
        QStringLiteral("lez:testnet"), to, QStringLiteral("LEZ"), raw));
}

void MusterUiBackend::sendLez(const QString &fromId, const QString &to, const QString &raw)
{
    // Send on the LEZ; the module picks the rail from (source form, destination kind)
    // and reports what it disclosed. Never a false receipt — a rejected send is {error}.
    const QString r = modules().muster_module.wallet_send(
        QStringLiteral("lez:testnet"), fromId, to, QStringLiteral("LEZ"), raw);
    qInfo() << "[muster_ui] wallet_send(lez) ->" << r;
    setLezSendJson(r);
    loadWalletAccounts();
    loadBalances();
}

void MusterUiBackend::joinRoom(const QString &topic)
{
    // coordinate_join → start/join the conversation on this topic over encrypted
    // transport (returns JSON {address, topic}). Key the view off the topic and
    // pull its messages + roster so the room opens on real state.
    if (topic.isEmpty()) {
        setLastError(QStringLiteral("cannot join an empty topic"));
        return;
    }
    const QString r = modules().muster_module.coordinate_join(topic);
    qInfo() << "[muster_ui] coordinate_join(" << topic << ") ->" << r;
    setRoomTopic(topic);
    setLastError(QString());
    loadPolicy();
    loadMessages();
    loadMembers();
    loadIntents();
    loadConnectivity();    // the delivery node + whatever this room's proposals introduced
    loadConversations();   // the room list — this join may have added a room
    loadDrivers();         // the room's admitted policy set (driver-as-proposal)
    loadAccounts();        // the accounts members have disclosed into this room (exo-a50.1.3)
    loadPending();         // anyone already asking to join this topic
}

void MusterUiBackend::postMessage(const QString &body)
{
    // coordinate_post_message → one channel for chat and cards. The module adds a
    // message event to the shared log; we re-read so the view reflects it (and any
    // that arrived from other participants) — reduce(log), no second record.
    if (body.isEmpty())
        return;
    const QString id = modules().muster_module.coordinate_post_message(body);
    qInfo() << "[muster_ui] coordinate_post_message ->" << id;
    loadMessages();
}

void MusterUiBackend::loadMessages()
{
    // coordinate_messages → the room's authored events, oldest-first, as JSON.
    // The view folds this into the thread; the module drives inbound delivery first.
    setMessagesJson(modules().muster_module.coordinate_messages());
}

void MusterUiBackend::loadConversations()
{
    // coordinate_conversations → every joined room as {topic, address, lastTs,
    // active}. The home surface lists them; opening one re-joins to re-activate.
    setConversationsJson(modules().muster_module.coordinate_conversations());
}

void MusterUiBackend::loadMembers()
{
    // coordinate_members → the admitted roster (who can read the room), each with its
    // address-book alias resolved by the module.
    setMembersJson(modules().muster_module.coordinate_members());
}

void MusterUiBackend::loadContacts()
{
    // contacts → the persisted address book [{identity, alias, address}].
    setContactsJson(modules().muster_module.contacts());
}

void MusterUiBackend::addContact(const QString &identityHex, const QString &alias)
{
    modules().muster_module.contact_add(identityHex, alias);
    setContactsJson(modules().muster_module.contacts());
}

void MusterUiBackend::setContactAlias(const QString &identityHex, const QString &alias)
{
    modules().muster_module.contact_set_alias(identityHex, alias);
    setContactsJson(modules().muster_module.contacts());
}

void MusterUiBackend::removeContact(const QString &identityHex)
{
    modules().muster_module.contact_remove(identityHex);
    setContactsJson(modules().muster_module.contacts());
}

void MusterUiBackend::startInbox()
{
    // coordinate_start_inbox → begin listening on THIS identity's inbox topic so room
    // invites arrive even before any room is joined. Idempotent; called once at startup.
    const QString r = modules().muster_module.coordinate_start_inbox();
    qInfo() << "[muster_ui] coordinate_start_inbox ->" << r;
    loadInvites();
}

void MusterUiBackend::sendInvite(const QString &peerChatId, const QString &roomTopic,
                                 const QString &note)
{
    // coordinate_invite → seal the room topic to the peer's chat id and drop it on their
    // inbox. This is how "Start something with someone" actually notifies them.
    const QString r = modules().muster_module.coordinate_invite(peerChatId, roomTopic, note);
    qInfo() << "[muster_ui] coordinate_invite(" << roomTopic << ") ->" << r;
}

void MusterUiBackend::loadInvites()
{
    // coordinate_invites → the invites received on our inbox, [{topic, from, fromAlias,
    // note, ts}]. The home surface lists them with Join / Dismiss.
    setInvitesJson(modules().muster_module.coordinate_invites());
}

void MusterUiBackend::dismissInvite(const QString &roomTopic)
{
    // coordinate_dismiss_invite → clear one invite so it stops showing; refresh the list.
    modules().muster_module.coordinate_dismiss_invite(roomTopic);
    loadInvites();
}

void MusterUiBackend::requestJoin()
{
    // coordinate_request_join → announce our encryption key on the topic. Carries no
    // authority (discovery, not entry) — an existing member still has to admit us.
    // Two instances that both joined one topic each founded their own epoch; this is
    // the first half of merging them into one readable room.
    const QString r = modules().muster_module.coordinate_request_join();
    qInfo() << "[muster_ui] coordinate_request_join ->" << r;
    setJoinStatus(r);
    loadPending();
    // Keep re-announcing until admitted. Delivery over the fleet is best-effort and
    // muster's shard can be sparse (no mesh peer at the instant of a one-shot send),
    // so a single request can fail to reach a store node and the other side never
    // sees it. Re-issue every few seconds until this peer is in a shared epoch (its
    // roster grows past just itself), then stop.
    if (!m_joinRetrying) {
        m_joinRetrying = true;
        m_joinAttempts = 0;
        scheduleJoinRetry();
    }
}

void MusterUiBackend::scheduleJoinRetry()
{
    // 3s: the common case is the first announce landing in the store and the admitter
    // seeing it within a catchup period (~1s). This re-announce only covers a send that
    // reached no store node; keep it brisk but not a flood (the request is a control
    // frame on the shared topic).
    QTimer::singleShot(3000, this, [this]() {
        loadMembers();
        const QJsonDocument d = QJsonDocument::fromJson(membersJson().toUtf8());
        const int members = d.isArray() ? d.array().size() : 0;
        if (members > 1 || roomTopic().isEmpty()) {   // admitted, or left the room
            m_joinRetrying = false;
            return;
        }
        // Bound the auto re-announce: after ~1min alone, an occupied room would have
        // admitted us by now, so stop rather than announce into an empty room forever.
        // The user can re-issue with the "Ask to join" button (which resets this).
        if (++m_joinAttempts >= 20) {
            m_joinRetrying = false;
            return;
        }
        setJoinStatus(modules().muster_module.coordinate_request_join());
        loadPending();
        scheduleJoinRetry();
    });
}

void MusterUiBackend::loadPending()
{
    // coordinate_pending → identities that asked to join but aren't admitted yet,
    // as [{identity, bindsOwner}]. A member reviews these and decides whom to admit.
    // Drives inbound delivery first, so a request from another host shows up here.
    setPendingJson(modules().muster_module.coordinate_pending());
}

void MusterUiBackend::admit(const QString &identityHex)
{
    // coordinate_admit → re-key the room forward and grant the joiner the new epoch
    // key (F-16: the admitted member reads from its epoch on, never earlier). Refresh
    // the roster, the pending list, and the folds so the newly shared room appears.
    if (identityHex.isEmpty())
        return;
    const QString r = modules().muster_module.coordinate_admit(identityHex);
    qInfo() << "[muster_ui] coordinate_admit(" << identityHex << ") ->" << r;
    loadMembers();
    loadPending();
    loadMessages();
    loadIntents();
}

void MusterUiBackend::proposeInRoom(const QString &effectJson)
{
    // coordinate_propose → put an effect to the room as a shared intent
    // (content-addressed id, so every participant derives the same one). Re-read
    // intents + messages so the proposal card and its folded state appear.
    const QString id = modules().muster_module.coordinate_propose(effectJson);
    qInfo() << "[muster_ui] coordinate_propose ->" << id;
    loadIntents();
    loadMessages();
}

void MusterUiBackend::contributeInRoom(const QString &intentId, const QString &signatureHex, const QString &keyRef)
{
    // coordinate_contribute → add an owner signature; the module verifies it
    // recovers to a configured owner before it counts (a non-owner is rejected).
    // keyRef (exo-45e K2b/K5) selects WHICH held key signs in-app — empty = the primary.
    const QString st = modules().muster_module.coordinate_contribute(intentId, signatureHex, keyRef);
    qInfo() << "[muster_ui] coordinate_contribute" << intentId << keyRef << "->" << st;
    // Surface the outcome: an approval that didn't count (your key isn't a recognized
    // signer for this policy) must SAY so, not vanish. ok iff st is a lifecycle state.
    // A vote-locus approval (a LEZ multisig, exo-3c9) answers "pending: …" while the
    // chain includes the member's vote (ok), or "refused: …" and the like (not ok).
    const bool ok = (st != "rejected" && st != "not-joined" && st != "unknown-intent" && st != "unknown-key"
                     && !st.startsWith("refused") && st != "not-a-vote-locus" && st != "expired"
                     && st != "unsupported-driver" && st != "no-context" && st != "unaccountable-input"
                     && st != "attestation-mismatch" && !st.startsWith("unconfirmed")
                     && !st.startsWith("keystore-"));   // keystore-busy / -unreachable / -refused: …
    QJsonObject r;
    r.insert("intentId", intentId);
    r.insert("state", st);
    r.insert("ok", ok);
    r.insert("reason", st);
    setContributeJson(QString::fromUtf8(QJsonDocument(r).toJson(QJsonDocument::Compact)));
    loadIntents();
    loadDrivers();   // an approval may have admitted a new driver kind (governance)
    // a keystore_module account approves in the platform's signer (exo-d4d.2): read the new
    // request now, so the view raises evm.signing.approve without waiting for its next poll
    if (st == "awaiting-approval") loadKeystoreRequests();
}

void MusterUiBackend::loadIntents()
{
    // coordinate_intents → the room's proposals folded from the shared log, as
    // [{id, state}]. Drives inbound delivery first (in the module).
    setIntentsJson(modules().muster_module.coordinate_intents());
    // the room's FROST ceremonies advance on the same tick (the module's pump)
    loadFrostCeremonies();
    // The activity feed folds from the SAME log, so refresh it whenever the
    // intents do — every join, propose, contribute, submit, and periodic tick.
    loadActivity();
}

void MusterUiBackend::reannounce()
{
    // coordinate_reannounce → re-publish open intents into the current epoch so a
    // just-admitted member sees proposals made before they joined (F-16). Refresh
    // the thread + intents after, so the re-announced cards appear.
    const QString r = modules().muster_module.coordinate_reannounce();
    qInfo() << "[muster_ui] coordinate_reannounce ->" << r;
    loadMessages();
    loadIntents();
}

void MusterUiBackend::loadActivity()
{
    // coordinate_activity → the room's coordination history (proposed / approved /
    // ready / submitted / settled) in causal order, folded from the shared log.
    setActivityJson(modules().muster_module.coordinate_activity());
}

void MusterUiBackend::submitInRoom(const QString &intentId)
{
    // coordinate_submit → settle a ready room intent on-chain FROM the room: the
    // module assembles the Safe execTransaction from the owner signatures folded on
    // the shared log, submits through the user's RPC, and observes finality. The
    // result ({state, onchain, txHash} or {error}) is surfaced so the card reports
    // honestly. Re-read the intents so the room converges on submitted.
    const QString r = modules().muster_module.coordinate_submit(intentId);
    qInfo() << "[muster_ui] coordinate_submit" << intentId << "->" << r;
    setRoomSubmitJson(r);
    loadIntents();
}

void MusterUiBackend::loadDrivers()
{
    // coordinate_drivers → every driver kind this client has (the module's one list),
    // each marked admitted or not for the joined room — folded from the shared log: the
    // founding set plus any kind an approved add-driver proposal admitted. Without a room
    // it is the founding set, so the composer can pick a policy before joining.
    setDriversJson(modules().muster_module.coordinate_drivers());
}

void MusterUiBackend::loadAvailableActions()
{
    // coordinate_available_actions → the module actions the room can coordinate
    // (P-D4): for each candidate module (the invoke allowlist + MUSTER_INVOKE_MODULES,
    // never a blind scan), its non-read methods as [{module, method, signature,
    // params, allowed}]. The composer renders these as the action menu.
    setAvailableActionsJson(modules().muster_module.coordinate_available_actions());
}

void MusterUiBackend::executeInRoom(const QString &intentId)
{
    // coordinate_execute → run a generic module-action intent that reached executable,
    // FROM the room: the core re-derives, gates (allowlist + capability), invokes
    // module.method(args), and publishes submit+final. The result is surfaced so the
    // invoke card reports honestly; re-read the intents so the room converges on final.
    const QString r = modules().muster_module.coordinate_execute(intentId);
    qInfo() << "[muster_ui] coordinate_execute" << intentId << "->" << r;
    setExecuteJson(r);
    loadIntents();
}

void MusterUiBackend::loadConnectivity()
{
    // connectivity → liveness of the infra the room relies on: its delivery node, plus
    // what its proposals' drivers introduced (the RPC only once a Safe proposal exists)
    // (invariant 8). The RPC probe blocks briefly, so the view calls this on a slower
    // cadence than the 1s message tick.
    setConnectivityJson(modules().muster_module.connectivity());
}

void MusterUiBackend::loadRlnStatus()
{
    // rln_status → this node's RLN membership (exo-eb6.3): on logos.test the payer and
    // what it holds, the membership's state, and what to send where; elsewhere "not
    // needed". The module never blocks on it (its chain reads are async), so Settings
    // polls it while open.
    setRlnStatusJson(modules().muster_module.rln_status());
}

void MusterUiBackend::loadKeystoreStatus()
{
    // keystore_status → the official EVM keystore (exo-149.1 K1): whether keystore_module
    // attributes our calls to muster_module, who approves, which accounts could sign. The
    // module's reads are async, so this never blocks; Settings polls it while open.
    setKeystoreStatusJson(modules().muster_module.keystore_status());
}

void MusterUiBackend::keystoreSelect(const QString &address)
{
    // keystore_select (exo-149.5 K5): from now on this member's Safe approvals go through
    // that keystore_module account; selecting asks keystore_module, once, for the
    // account's binding, which a person approves in the signer. Then re-read the row.
    const QString r = modules().muster_module.keystore_select(address);
    qInfo().noquote() << "[muster_ui] KEYSTORE-SELECT" << r;
    loadKeystoreStatus();
    loadKeystoreRequests();
}

void MusterUiBackend::loadKeystoreRequests()
{
    // keystore_requests (exo-149.2 K2): the approvals waiting on a person in the signer, and
    // the ones that just finished. Reading it also advances them (keystorePump), so the view
    // polls it while any is open; the view raises evm.signing.approve for each new one.
    setKeystoreRequestsJson(modules().muster_module.keystore_requests());
}

void MusterUiBackend::loadSecurityLevels()
{
    // security_levels → the room's active null-ladder level on the three axes (exo-1ec.5),
    // {axes:[{axis,rung,real,mechanism}]}. A pure fold (the driver + the log +
    // the room crypto), so it rides the slow tick beside connectivity/flow.
    setSecurityLevelsJson(modules().muster_module.security_levels());
}

void MusterUiBackend::loadRoomAccount()
{
    // coordinate_account → the composer's sending context: what's available to send
    // (the Safe's live balance) and who you act as (+ owner check). Reads the RPC, so
    // the view calls this when the composer opens, not on the message tick.
    setRoomAccountJson(modules().muster_module.coordinate_account());
}

void MusterUiBackend::loadReadiness(const QString &intentId)
{
    // coordinate_readiness → the card's five questions for ONE intent plus this
    // instance's readiness (docs/design/action-manifest.md, exo-002.3): every manifest
    // requirement graded met / missing / unknown with a remedy, the full disclosure
    // (baseline store-node rows included), touches, and the agreement policy. Kept
    // per intent in a JSON object so several open cards each read their own entry.
    // The module names remedies; performing them (install, configure) is the host's.
    const QString r = modules().muster_module.coordinate_readiness(intentId);
    QJsonObject all = QJsonDocument::fromJson(readinessJson().toUtf8()).object();
    const QJsonDocument one = QJsonDocument::fromJson(r.toUtf8());
    all.insert(intentId, one.isObject() ? QJsonValue(one.object())
                                        : QJsonValue(QJsonObject{{"error", r}}));
    qInfo() << "[muster_ui] coordinate_readiness" << intentId << "->" << r;
    setReadinessJson(QString::fromUtf8(QJsonDocument(all).toJson(QJsonDocument::Compact)));
}

void MusterUiBackend::loadOffers(const QString &intentId)
{
    // coordinate_offers → the card's "From you" section for ONE intent (exo-45e K6):
    // which of MY OWN holdings fill the slots it asks of me, each candidate the PUBLIC
    // face of a holding (never a handle, s1) + its grade + the rows choosing it discloses.
    // Graded about me only. Kept per intent so several open cards each read their own.
    const QString r = modules().muster_module.coordinate_offers(intentId);
    QJsonObject all = QJsonDocument::fromJson(offersJson().toUtf8()).object();
    const QJsonDocument one = QJsonDocument::fromJson(r.toUtf8());
    all.insert(intentId, one.isObject() ? QJsonValue(one.object())
                                        : QJsonValue(QJsonObject{{"error", r}}));
    qInfo() << "[muster_ui] coordinate_offers" << intentId << "->" << r;
    setOffersJson(QString::fromUtf8(QJsonDocument(all).toJson(QJsonDocument::Compact)));
}

void MusterUiBackend::loadComposeOffers(const QString &effectJson)
{
    // compose_offers → the composer's third step: for a DRAFT effect under the room's
    // compose policy, which of my holdings fill the proposer slots (the asset+amount).
    // Graded about me only. Not keyed — the composer holds one draft at a time.
    const QString r = modules().muster_module.compose_offers(effectJson);
    qInfo() << "[muster_ui] compose_offers" << effectJson << "->" << r;
    setComposeOffersJson(r);
}

void MusterUiBackend::shareMaterial(const QString &intentId, const QString &requirement, const QString &pub)
{
    // coordinate_share_material → publish a chosen holding's PUBLIC face into the intent
    // to fill a slot (the request-first path for counterparty material). Reload offers so
    // the picker reflects the filled slot, and intents so the effect updates.
    const QString r = modules().muster_module.coordinate_share_material(intentId, requirement, pub);
    qInfo() << "[muster_ui] coordinate_share_material" << intentId << requirement << "->" << r;
    loadOffers(intentId);
    loadIntents();
}

void MusterUiBackend::declineInRoom(const QString &intentId)
{
    // coordinate_decline → decline to take part: a decline event keyed by this member
    // folds into the intent view, naming who declined.
    // Informational — the threshold is unchanged. Re-read the intents so the room
    // converges on the decline count.
    const QString r = modules().muster_module.coordinate_decline(intentId);
    qInfo() << "[muster_ui] coordinate_decline" << intentId << "->" << r;
    setDeclineJson(r);
    loadIntents();
}

void MusterUiBackend::exportOutside(const QString &intentId)
{
    // coordinate_export_outside → the intent in its driver's outside-signer format (a
    // Bitcoin spend: a base64 PSBT). Nothing is signed or published (exo-a50.2.6).
    const QString r = modules().muster_module.coordinate_export_outside(intentId);
    qInfo() << "[muster_ui] coordinate_export_outside" << intentId << "->" << r.left(120);
    setOutsideJson(r);
}

void MusterUiBackend::importOutside(const QString &intentId, const QString &encoded)
{
    // coordinate_import_outside → the driver reads the outside signer's signatures and each
    // is published as a pasted approval: counted, graded unattested (signed outside muster).
    const QString r = modules().muster_module.coordinate_import_outside(intentId, encoded.trimmed());
    qInfo() << "[muster_ui] coordinate_import_outside" << intentId << "->" << r;
    setOutsideImportJson(r);
    loadIntents();
}

void MusterUiBackend::proposeBtcSpend(const QString &payTo, const QString &amountSat, const QString &feeRate)
{
    // coordinate_propose_btc_spend → a Bitcoin payment from the room's chosen Bitcoin
    // account, its coins read from the user's node. An id, or {error, detail}.
    const QString r = modules().muster_module.coordinate_propose_btc_spend(payTo, amountSat, feeRate);
    qInfo() << "[muster_ui] coordinate_propose_btc_spend" << payTo << amountSat << feeRate << "->" << r;
    QJsonObject o;
    if (r.startsWith("{")) {
        o = QJsonDocument::fromJson(r.toUtf8()).object();
    } else {
        o.insert("id", r);
    }
    setBtcProposeJson(QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
    loadIntents();
    loadMessages();
}

static QString asObjectJson(const QString &r, const char *key)
{
    // a module answer that is JSON stays as is; a bare string becomes {key: r}
    QJsonObject o;
    if (r.startsWith("{")) o = QJsonDocument::fromJson(r.toUtf8()).object();
    else o.insert(QString::fromLatin1(key), r);
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

// ── a split (exo-a90) ──────────────────────────────────────────────────────────
// Each outcome lands on splitJson, tagged with what was done and to which intent, so the
// room can say why a button did nothing — never a silent no-op.
// Self-test only (MUSTER_AUTOLEZFUND): true while this instance is still funding its
// private LEZ balance, so MUSTER_AUTOPAYSPLIT does not try to pay before it can.
static bool s_lezFunding = false;

static QString splitOutcome(const QString &op, const QString &intentId, const QString &r)
{
    QJsonObject o;
    if (r.startsWith("{")) o = QJsonDocument::fromJson(r.toUtf8()).object();
    else if (r.startsWith("0x")) o.insert("id", r);           // propose → the intent id
    else o.insert("error", r);
    o.insert("op", op);
    if (!intentId.isEmpty() && !o.contains("id")) o.insert("id", intentId);
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void MusterUiBackend::proposeSplit(const QString &chain, const QString &totalWei, const QString &sharesJson, const QString &memo)
{
    // coordinate_propose_split: you are the creditor, paid at your own address; every
    // person named agrees to their own share before anyone pays.
    const QString r = modules().muster_module.coordinate_propose_split(chain.trimmed(), totalWei.trimmed(),
                                                                       sharesJson, memo);
    qInfo() << "[muster_ui] coordinate_propose_split" << chain << totalWei << sharesJson << "->" << r;
    setSplitJson(splitOutcome("propose", "", r));
    loadIntents();
    loadMessages();
}

void MusterUiBackend::proposeSettleUp(const QString &chain, const QString &asset, const QString &memo)
{
    // coordinate_propose_settle_up: the room's open shares on this chain and asset, netted —
    // every party the covered shares name agrees before anything is paid.
    const QString r = modules().muster_module.coordinate_propose_settle_up(chain.trimmed(), asset.trimmed(), memo);
    qInfo() << "[muster_ui] coordinate_propose_settle_up" << chain << asset << "->" << r;
    setSplitJson(splitOutcome("settle-up", "", r));
    loadIntents();
    loadMessages();
}

void MusterUiBackend::settlePart(const QString &intentId)
{
    // coordinate_settle_part: MY share, from my own wallet — the module derives the
    // transfer from the agreed split; the report follows once it lands (the intents tick).
    const QString r = modules().muster_module.coordinate_settle_part(intentId);
    qInfo() << "[muster_ui] coordinate_settle_part" << intentId << "->" << r;
    setSplitJson(splitOutcome("pay", intentId, r));
    loadIntents();
}

void MusterUiBackend::renewSplit(const QString &intentId)
{
    // coordinate_renew_split: a split past its expiry, its unpaid shares renewed as a
    // settle-up of that one split — everyone they name agrees again (exo-a90.15).
    const QString r = modules().muster_module.coordinate_renew_split(intentId);
    qInfo() << "[muster_ui] coordinate_renew_split" << intentId << "->" << r;
    setSplitJson(splitOutcome("renew", intentId, r));
    loadIntents();
    loadMessages();
}

void MusterUiBackend::loadOpenAssets()
{
    // coordinate_open_assets: what a settle-up across assets could cover (exo-a90.17)
    const QString r = modules().muster_module.coordinate_open_assets();
    qInfo() << "[muster_ui] coordinate_open_assets ->" << r;
    setOpenAssetsJson(r);
}

void MusterUiBackend::proposeSettleUpAcross(const QString &chain, const QString &asset, const QString &ratesJson,
                                            const QString &memo)
{
    // coordinate_propose_settle_up_across: paid in one asset, every other priced at my rate —
    // a recorded read; every party agrees before anything is paid (exo-a90.17).
    const QString r = modules().muster_module.coordinate_propose_settle_up_across(chain.trimmed(), asset.trimmed(),
                                                                                   ratesJson, memo);
    qInfo() << "[muster_ui] coordinate_propose_settle_up_across" << chain << asset << ratesJson << "->" << r;
    setSplitJson(splitOutcome("settle-up", "", r));
    loadIntents();
    loadMessages();
}

void MusterUiBackend::shareAddress(const QString &chain)
{
    // coordinate_share_address: MY address for a chain, as an author-signed address-share card
    const QString r = modules().muster_module.coordinate_share_address(chain.trimmed());
    qInfo() << "[muster_ui] coordinate_share_address" << chain << "->" << r;
    loadMessages();
}

void MusterUiBackend::lookupToken(const QString &chain, const QString &token)
{
    // coordinate_token_info: what the token says about itself, through your own RPC —
    // display only (the split's amounts are base units; nothing here is signed).
    const QString r = modules().muster_module.coordinate_token_info(chain.trimmed(), token.trimmed());
    qInfo() << "[muster_ui] coordinate_token_info" << token << "->" << r;
    setTokenInfoJson(r);
}

void MusterUiBackend::confirmPart(const QString &intentId, const QString &part, const QString &tx)
{
    // coordinate_confirm_part: the creditor confirms a share — from her own read of tx,
    // or (tx empty) received outside muster.
    const QString r = modules().muster_module.coordinate_confirm_part(intentId, part, tx);
    qInfo() << "[muster_ui] coordinate_confirm_part" << intentId << part << tx << "->" << r;
    setSplitJson(splitOutcome("confirm", intentId, r));
    loadIntents();
}

void MusterUiBackend::reportPaid(const QString &intentId, const QString &tx)
{
    // coordinate_report_paid: "I paid" for MY share of a Monero request (exo-dcc.5) — my
    // author-signed claim, with the txid if I gave one. It never confirms the part.
    const QString r = modules().muster_module.coordinate_report_paid(intentId, tx.trimmed());
    qInfo() << "[muster_ui] coordinate_report_paid" << intentId << tx << "->" << r;
    setSplitJson(splitOutcome("report", intentId, r));
    loadIntents();
}

void MusterUiBackend::proposeLezTransfer(const QString &recipient, const QString &amount)
{
    // coordinate_propose_lez_transfer → the proposer's own Propose, sent (not awaited);
    // the room intent appears on a later intents tick once the chain holds it.
    const QString r = modules().muster_module.coordinate_propose_lez_transfer(recipient.trimmed(), amount.trimmed());
    qInfo() << "[muster_ui] coordinate_propose_lez_transfer" << recipient << amount << "->" << r;
    setLezProposeJson(asObjectJson(r, "id"));
    loadIntents();
}

void MusterUiBackend::proposeLezVaultInit(const QString &definition)
{
    const QString r = modules().muster_module.coordinate_propose_lez_vault_init(definition.trimmed());
    qInfo() << "[muster_ui] coordinate_propose_lez_vault_init" << definition << "->" << r;
    setLezProposeJson(asObjectJson(r, "id"));
    loadIntents();
}

void MusterUiBackend::lezMemberAccount(const QString &index)
{
    const QString r = modules().muster_module.lez_member_account(index.trimmed());
    qInfo() << "[muster_ui] lez_member_account" << index << "->" << r;
    setLezMemberJson(asObjectJson(r, "error"));
}

void MusterUiBackend::lezCreateMultisig(const QString &threshold, const QString &members)
{
    // lez_multisig_create → sent (not awaited); disclosed into the room by the module
    // once the chain holds the multisig's state.
    const QString r = modules().muster_module.lez_multisig_create(threshold.trimmed(), members.trimmed());
    qInfo() << "[muster_ui] lez_multisig_create" << threshold << members << "->" << r;
    setLezCreateJson(asObjectJson(r, "error"));
}

void MusterUiBackend::frostCeremonyOpen(const QString &ceremonyId, const QString &network, const QString &t, const QString &n)
{
    // frost_ceremony_open → open + join; the module advances this member's steps on the
    // intents tick, and discloses the account once the ceremony completes.
    const QString r = modules().muster_module.frost_ceremony_open(ceremonyId.trimmed(), network.trimmed(), t.trimmed(), n.trimmed());
    qInfo() << "[muster_ui] frost_ceremony_open" << ceremonyId << network << t << n << "->" << r;
    setFrostCeremonyJson(asObjectJson(r, "error"));
    loadFrostCeremonies();
}

void MusterUiBackend::frostCeremonyJoin(const QString &ceremonyId)
{
    const QString r = modules().muster_module.frost_ceremony_join(ceremonyId.trimmed());
    qInfo() << "[muster_ui] frost_ceremony_join" << ceremonyId << "->" << r;
    setFrostCeremonyJson(asObjectJson(r, "error"));
    loadFrostCeremonies();
}

void MusterUiBackend::loadFrostCeremonies()
{
    setFrostCeremoniesJson(modules().muster_module.frost_ceremonies());
}

void MusterUiBackend::downloadAudit(const QString &intentId)
{
    // coordinate_audit → the intent's signature-audit file (exo-403). The module
    // builds it (pure, from the log); the UI only saves it: the canonical bytes as
    // .cbor — what verifies — and the report rendered from them as .md.
    const QString r = modules().muster_module.coordinate_audit(intentId);
    const QJsonObject o = QJsonDocument::fromJson(r.toUtf8()).object();
    QJsonObject out;
    out["intentId"] = intentId;
    if (!o.value("ok").toBool()) {
        out["ok"] = false;
        out["reason"] = o.value("reason").toString(r);
    } else {
        QString dir = QString::fromUtf8(qgetenv("MUSTER_AUDIT_DIR"));
        if (dir.isEmpty()) dir = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
        if (dir.isEmpty()) dir = QDir::homePath();
        QDir().mkpath(dir);
        QString stem = intentId;
        stem.remove(QStringLiteral("0x"));
        const QString cborPath = QDir(dir).filePath(QStringLiteral("muster-audit-%1.cbor").arg(stem));
        const QString mdPath = QDir(dir).filePath(QStringLiteral("muster-audit-%1.md").arg(stem));
        QFile cbor(cborPath), md(mdPath);
        const bool wrote = cbor.open(QIODevice::WriteOnly) &&
            cbor.write(QByteArray::fromHex(o.value("file").toString().toUtf8())) >= 0 &&
            md.open(QIODevice::WriteOnly) &&
            md.write(o.value("report").toString().toUtf8()) >= 0;
        cbor.close(); md.close();
        out["ok"] = wrote;
        if (wrote) {
            out["cbor"] = cborPath;
            out["report"] = mdPath;
            out["digest"] = o.value("digest").toString();
        } else {
            out["reason"] = QStringLiteral("could not write to %1").arg(dir);
        }
    }
    const QString j = QString::fromUtf8(QJsonDocument(out).toJson(QJsonDocument::Compact));
    qInfo() << "[muster_ui] downloadAudit" << intentId << "->" << j;
    setAuditJson(j);
}

void MusterUiBackend::loadFlow()
{
    // coordinate_flow → who could see what, per action: the log × each action's
    // manifest disclosure × the membership at that point (exo-002.5). A pure fold;
    // no RPC — refreshed with connectivity on the slower tick.
    setFlowJson(modules().muster_module.coordinate_flow());
}

void MusterUiBackend::setPolicy(const QString &kind)
{
    // coordinate_set_policy → choose the room's driver (safe | threshold). The same
    // propose/contribute/fold path runs under whichever; the policy is a driver, not
    // hardcoded. Result is {policy, threshold, domain}.
    const QString r = modules().muster_module.coordinate_set_policy(kind);
    qInfo() << "[muster_ui] coordinate_set_policy(" << kind << ") ->" << r;
    // A refused choice (no-account, choose-account, not admitted) never overwrites the
    // policy actually in force: it lands on policyErrorJson, and the policy is re-read.
    const QJsonDocument d = QJsonDocument::fromJson(r.toUtf8());
    if (d.isObject() && d.object().contains(QStringLiteral("error"))) {
        setPolicyErrorJson(r);
        loadPolicy();
        return;
    }
    setPolicyErrorJson(QStringLiteral("{}"));
    setPolicyJson(r);
}

void MusterUiBackend::loadAccounts()
{
    // coordinate_accounts → the accounts members disclosed into the room, each with the
    // chain's verdict on the disclosure (a read through the user's RPC — so this runs on
    // join and after a disclose, not on the 1s tick).
    setAccountsJson(modules().muster_module.coordinate_accounts());
}

void MusterUiBackend::discloseAccount(const QString &accountJson)
{
    // coordinate_disclose_account → disclose an account into the room as this member.
    const QString r = modules().muster_module.coordinate_disclose_account(accountJson);
    qInfo() << "[muster_ui] coordinate_disclose_account ->" << r;
    setAccountDiscloseJson(r);
    loadAccounts();
    loadPolicy();
}

void MusterUiBackend::discloseSuggestedAccount()
{
    // The local test Safe describe() suggests (the anvil fixture), disclosed as-is with
    // its owners + threshold (the fixture exposes no getOwners() to read them from).
    const QJsonDocument d = QJsonDocument::fromJson(modules().muster_module.describe().toUtf8());
    if (!d.isObject()) { setAccountDiscloseJson(QStringLiteral("{\"error\":\"no suggestion\"}")); return; }
    const QJsonObject s = d.object();
    QJsonObject a;
    a.insert(QStringLiteral("family"), s.value(QStringLiteral("family")).toString(QStringLiteral("evm.safe")));
    a.insert(QStringLiteral("chain"), s.value(QStringLiteral("chain")));
    a.insert(QStringLiteral("address"), s.value(QStringLiteral("safe")));
    a.insert(QStringLiteral("label"), s.value(QStringLiteral("label")));
    a.insert(QStringLiteral("signers"), s.value(QStringLiteral("owners")));
    a.insert(QStringLiteral("threshold"), s.value(QStringLiteral("threshold")));
    discloseAccount(QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact)));
}

void MusterUiBackend::loadPolicy()
{
    // coordinate_policy → the room's current policy, described by its driver.
    setPolicyJson(modules().muster_module.coordinate_policy());
}

void MusterUiBackend::retryStartup(int attemptsLeft)
{
    // health() comes back empty while the module isn't answering yet; once it does,
    // redo the startup reads. Bounded (~30 s); the module also starts its inbox on the
    // first invite poll, so this is the first line of defence, not the only one.
    if (!health().isEmpty() || attemptsLeft <= 0) return;
    QTimer::singleShot(1500, this, [this, attemptsLeft]() {
        checkHealth();
        if (health().isEmpty()) { retryStartup(attemptsLeft - 1); return; }
        qInfo() << "[muster_ui] module answered — re-running the startup reads";
        loadAccount();
        loadSettings();
        loadDrivers();
        startInbox();
    });
}

void MusterUiBackend::onContextReady()
{
    // Fires once ui-host hands the plugin its wired modules(); read liveness, the
    // account context, and the settings so the view opens on real values. NOT the
    // wallet balances: those read the RPC, and nothing has introduced an RPC yet
    // (exo-428) — the Account tab and the LEZ send panel load them when opened.
    checkHealth();
    loadAccount();
    loadSettings();
    loadDrivers();   // the one kind list, so the composer picks a policy before any room
    // Begin listening on this identity's inbox so room invites (from "Start something
    // with someone") arrive even before any room is opened. Idempotent; safe on launch.
    startInbox();
    // These calls can land before muster_module answers, and are then simply lost —
    // found running the tour: the inbox never started, so Bob never saw an invitation.
    // If the module hasn't answered, run them again until it does.
    retryStartup(20);

    // Diagnostic/headless self-test hook (exo-149.1 K1): MUSTER_KEYSTORE_PROBE=1 reads
    // keystore_status every 2 s for a minute and logs each answer, so an offscreen runner
    // shows whether keystore_module attributes muster's calls to muster_module. The first
    // read only sends the async reads; the answers land on the next. Off unless set.
    if (!qgetenv("MUSTER_KEYSTORE_PROBE").isEmpty()) {
        auto *t = new QTimer(this);
        auto n = std::make_shared<int>(0);
        connect(t, &QTimer::timeout, this, [this, t, n]() {
            loadKeystoreStatus();
            qInfo().noquote() << "[muster_ui] KEYSTORE" << keystoreStatusJson();
            if (++*n >= 30) t->stop();
        });
        t->start(2000);
    }

    // Diagnostic/headless self-test hook: if MUSTER_AUTOJOIN_TOPIC is set, join that
    // room a few seconds after startup — no GUI click needed. Runs on the ui-host's
    // Qt main thread (so muster's lp client has an event loop) and drives the full
    // coordinate_join → delivery createNode path, so the runner can be exercised
    // offscreen. Off unless the env var is set; never affects a normal launch.
    const QByteArray autojoin = qgetenv("MUSTER_AUTOJOIN_TOPIC");
    if (!autojoin.isEmpty()) {
        const QString topic = QString::fromUtf8(autojoin);
        QTimer::singleShot(5000, this, [this, topic]() {
            qInfo() << "[muster_ui] AUTOJOIN ->" << topic;
            joinRoom(topic);
            QTimer::singleShot(3000, this, [this]() { requestJoin(); });
            // Invite self-test: MUSTER_AUTOINVITE=<contact alias> invites that contact to
            // this room once joined, exactly as the composer's "Open the room with them"
            // does (sendInvite with the contact's chat id). Seeded demo peers carry the
            // other roles as contacts, so "Bob" resolves with no setup.
            const QByteArray autoinvite = qgetenv("MUSTER_AUTOINVITE");
            if (!autoinvite.isEmpty()) {
                const QString who = QString::fromUtf8(autoinvite);
                QTimer::singleShot(2000, this, [this, who, topic]() {
                    loadContacts();
                    const QJsonDocument d = QJsonDocument::fromJson(contactsJson().toUtf8());
                    for (const auto &c : d.array()) {
                        const QJsonObject o = c.toObject();
                        if (o.value("alias").toString() == who) {
                            sendInvite(o.value("identity").toString(), topic, QStringLiteral("talk"));
                            return;
                        }
                    }
                    qInfo() << "[muster_ui] AUTOINVITE: no contact named" << who;
                });
            }
            // Card self-test (exo-002.3): MUSTER_AUTOPROPOSE=<effect json> proposes it
            // once joined, then asks the module for that intent's readiness (the card's
            // "What this needs" round trip) and, with MUSTER_AUTODECLINE set, declines
            // it — each result logged, so an offscreen run proves the host round trips.
            const QByteArray autopropose = qgetenv("MUSTER_AUTOPROPOSE");
            if (!autopropose.isEmpty()) {
                const QString effect = QString::fromUtf8(autopropose);
                QTimer::singleShot(4000, this, [this, effect]() {
                    // Audit self-test (exo-403): MUSTER_AUTOPOLICY picks the driver first,
                    // MUSTER_AUTOAPPROVE approves in-app, MUSTER_AUTOAUDIT then calls the
                    // SAME slot the card's "Download audit trail" button calls.
                    // MUSTER_AUTODISCLOSE discloses the local test Safe first, so an
                    // account-bound policy (safe) has an account to act from (exo-a50.1.3).
                    if (!qgetenv("MUSTER_AUTODISCLOSE").isEmpty()) discloseSuggestedAccount();
                    const QByteArray autopolicy = qgetenv("MUSTER_AUTOPOLICY");
                    if (!autopolicy.isEmpty()) setPolicy(QString::fromUtf8(autopolicy));
                    const QString id = modules().muster_module.coordinate_propose(effect);
                    qInfo() << "[muster_ui] AUTOPROPOSE ->" << id;
                    if (!qgetenv("MUSTER_AUTOAPPROVE").isEmpty()) contributeInRoom(id, QString(), QString());
                    if (!qgetenv("MUSTER_AUTOAUDIT").isEmpty()) downloadAudit(id);
                    loadIntents();
                    loadReadiness(id);
                    if (!qgetenv("MUSTER_AUTODECLINE").isEmpty()) declineInRoom(id);
                    loadFlow();
                    loadConnectivity();   // the proposal may have introduced infra (exo-428)
                    qInfo() << "[muster_ui] AUTOPROPOSE intents ->" << intentsJson();
                });
            }
            // XMR request self-test (exo-dcc.5): MUSTER_AUTOREPORTPAID=<intent id> says "I
            // paid" for it once joined — the card's "I paid" slot — so an offscreen run shows
            // the slot reaching coordinate_report_paid (the module logs the answer).
            const QByteArray autoreport = qgetenv("MUSTER_AUTOREPORTPAID");
            if (!autoreport.isEmpty()) {
                const QString id = QString::fromUtf8(autoreport);
                QTimer::singleShot(4000, this, [this, id]() {
                    reportPaid(id, QString());
                    qInfo() << "[muster_ui] AUTOREPORTPAID ->" << splitJson();
                });
            }
            // Poll pending/members so a two-instance self-test shows cross-host
            // delivery (another peer's join-request arriving) in the console.
            const bool founder = !qgetenv("MUSTER_AUTOADMIT").isEmpty();
            auto* t = new QTimer(this);
            // Mirror the real Room live-refresh cadence (Room.qml, 1s) so the offscreen
            // self-test measures the same felt latency a user sees — this tick is what
            // drives poll()/catchup here, exactly as the Room timer does in the GUI.
            t->setInterval(1000);
            connect(t, &QTimer::timeout, this, [this, founder]() {
                // requestJoin() fires ONCE (above) — the backend's own retry chain
                // re-announces until admitted, exactly as the UI button now does.
                loadPending(); loadMembers(); loadMessages(); loadIntents();
                // Split self-test, on someone's behalf (exo-770): MUSTER_AUTOSHARE shares
                // this member's address into the room once someone else is in — the
                // address-share card's "Share an address".
                static bool shared = false;
                if (!shared && !qgetenv("MUSTER_AUTOSHARE").isEmpty()
                    && membersJson().contains("\"self\":false")) {
                    const QString addr = QJsonDocument::fromJson(settingsJson().toUtf8()).object()
                                             .value("identity").toObject().value("address").toString();
                    if (!addr.isEmpty()) {
                        shared = true;
                        postMessage(QString::fromUtf8(QJsonDocument(QJsonObject{
                            {"kind", "address-share"}, {"asset", "ETH"}, {"address", addr}, {"form", 1}})
                            .toJson(QJsonDocument::Compact)));
                    }
                }
                // Founder-only: admit the first pending asker (one admitter keeps a
                // single shared epoch), then propose one intent so the other side's
                // convergence can be observed.
                if (founder) {
                    QJsonDocument d = QJsonDocument::fromJson(pendingJson().toUtf8());
                    if (d.isArray() && !d.array().isEmpty()) {
                        const QString id = d.array().first().toObject().value("identity").toString();
                        if (!id.isEmpty()) admit(id);
                    }
                    static bool proposed = false;
                    // MUSTER_AUTOSPLIT_FOR: propose the split on the OTHER member's behalf —
                    // they fronted it, this member owes — once they have shared an address
                    const bool forOther = !qgetenv("MUSTER_AUTOSPLIT_FOR").isEmpty();
                    if (!proposed && membersJson().contains("\"self\":false")
                        && (!forOther || messagesJson().contains("address-share"))) {
                        proposed = true;
                        // Split self-test (exo-a90.8): MUSTER_AUTOSPLIT=<total, base units>
                        // splits a bill this founder fronted with the other member, on the
                        // chain the configured RPC serves — or, with MUSTER_AUTOSPLIT_CHAIN
                        // (e.g. lez:testnet), privately on the LEZ — the same slot the room's
                        // Split composer calls.
                        const QByteArray autosplit = qgetenv("MUSTER_AUTOSPLIT");
                        if (!autosplit.isEmpty()) {
                            QJsonArray others;
                            QString me;
                            for (const auto &m : QJsonDocument::fromJson(membersJson().toUtf8()).array()) {
                                if (!m.toObject().value("self").toBool())
                                    others.append(m.toObject().value("identity").toString());
                                else
                                    me = m.toObject().value("identity").toString();
                            }
                            const QString shares = forOther && !others.isEmpty()
                                ? QString::fromUtf8(QJsonDocument(QJsonObject{
                                      {"parties", QJsonArray{me}}, {"creditor", others.first()}})
                                      .toJson(QJsonDocument::Compact))
                                : QString::fromUtf8(QJsonDocument(others).toJson(QJsonDocument::Compact));
                            proposeSplit(QString::fromUtf8(qgetenv("MUSTER_AUTOSPLIT_CHAIN")),
                                         QString::fromUtf8(autosplit), shares,
                                         QStringLiteral("split self-test"));
                        } else {
                            proposeInRoom(QStringLiteral("{\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":1000,\"nonce\":0}"));
                        }
                    }
                }
                // Split self-test, the debtor's side: MUSTER_AUTOPAYSPLIT agrees to MY share of
                // any split that names me, then pays it once everyone has agreed — the card's
                // "Agree to my share" and "Pay my share". A pay the module refuses (a LEZ
                // wallet still scanning the chain, say) is tried again after 10s, and none is
                // tried while MUSTER_AUTOLEZFUND is funding.
                //
                // An agreement the module refuses for a reason that can be transient is tried
                // again every 2s, for up to 60s (exo-ca3). A proposal reaches a member as
                // several log events: the propose, then its signing context
                // (intent/<id>/context) and any reads. Over the fleet's ~1s store poll these
                // can land in different ticks. Then the split is in this member's view before
                // its context is, and the module rightly refuses to sign ("no-context",
                // invariant 2). Agreeing once and never again stalled the test: 1 run in 5.
                if (!qgetenv("MUSTER_AUTOPAYSPLIT").isEmpty()) {
                    static QSet<QString> agreed, paid;
                    static QHash<QString, qint64> payAgainAt, agreeAgainAt, agreeGiveUpAt;
                    // Agree to `id`; if the refusal can be transient, try again in 2s (≤ 60s).
                    const auto agree = [this](const QString &id) {
                        const qint64 now = QDateTime::currentSecsSinceEpoch();
                        if (now < agreeAgainAt.value(id, 0)) return;
                        contributeInRoom(id, QString(), QString());
                        const QJsonObject r = QJsonDocument::fromJson(contributeJson().toUtf8()).object();
                        const QString why = r.value("reason").toString();
                        const bool transient = !r.value("ok").toBool()
                            && (why == "no-context" || why == "unknown-intent" || why == "unaccountable-input");
                        if (!agreeGiveUpAt.contains(id)) agreeGiveUpAt[id] = now + 60;
                        if (transient && now < agreeGiveUpAt.value(id)) {
                            agreeAgainAt[id] = now + 2;
                            qInfo() << "[muster_ui] SELFTEST agree" << id << "refused" << why << "- again in 2s";
                        } else {
                            agreed.insert(id);   // agreed, or refused for good: stop asking
                        }
                    };
                    for (const auto &v : QJsonDocument::fromJson(intentsJson().toUtf8()).array()) {
                        const QJsonObject it = v.toObject();
                        if (!it.contains("split")) continue;
                        const QString id = it.value("id").toString();
                        const QString st = it.value("state").toString();
                        QJsonObject mine;
                        for (const auto &p : it.value("parts").toArray())
                            if (p.toObject().value("mine").toBool()) mine = p.toObject();
                        // the creditor of a split proposed on their behalf (exo-770): agree
                        // that payTo is theirs — only when their own client holds it
                        const QJsonObject sp = it.value("split").toObject();
                        if (mine.isEmpty() && sp.value("iAmCreditor").toBool() && !sp.value("creditorAgreed").toBool()
                            && sp.value("payToMine").toBool() && (st == "proposed" || st == "collecting")
                            && !agreed.contains(id)) {
                            agree(id);
                        }
                        if (mine.isEmpty()) continue;
                        if ((st == "proposed" || st == "collecting") && !it.value("approvedByMe").toBool()
                            && !agreed.contains(id)) {
                            agree(id);
                        } else if (!s_lezFunding && (st == "executable" || st == "submitted" || st == "settling")
                                   && !mine.value("settled").toBool() && !mine.value("paying").toBool()
                                   && !paid.contains(id)
                                   && QDateTime::currentSecsSinceEpoch() >= payAgainAt.value(id, 0)) {
                            settlePart(id);
                            if (splitJson().contains("\"error\""))
                                payAgainAt[id] = QDateTime::currentSecsSinceEpoch() + 10;
                            else
                                paid.insert(id);
                        }
                    }
                }
                qInfo() << "[muster_ui] SELFTEST pending=" << pendingJson()
                        << "members=" << membersJson()
                        << "intents=" << intentsJson();
            });
            t->start();
        });
    }

    // LEZ testnet self-test (exo-14d): MUSTER_AUTOLEZFUND funds THIS instance's
    // private balance the way a person would, through the module's own wallet path:
    // make sure the public account exists (wallet_lez_setup) and log it, so whoever
    // holds native LEZ can send to it (LEZ v0.3 has no faucet, exo-eb6.4: a script's
    // funder, or a person); wait for those funds to land; then shield all that arrived
    // to MY OWN key node (wallet_send takes the shield rail) and wait for that proof.
    // The note lands at an account the scan discovers, which is what a debtor then pays
    // from. Needs MUSTER_LEZ_REAL. Runs on its own, not only inside an autojoin run, so
    // a person trying the tour can fund a wallet the same way (scripts/try-peer.sh
    // --lez-fund).
    QTimer::singleShot(5000, this, [this]() {
        if (!qgetenv("MUSTER_AUTOLEZFUND").isEmpty()) {
            s_lezFunding = true;
            auto *ft = new QTimer(this);
            ft->setInterval(5000);
            connect(ft, &QTimer::timeout, this, [this, ft]() {
                static int stage = 0;
                static QString pub, keyNode;
                static qint64 retryAt = 0, awaitingSince = 0;
                const qint64 now = QDateTime::currentSecsSinceEpoch();
                if (now < retryAt) return;
                const QString lez = QStringLiteral("lez:testnet");
                if (stage == 0) {                   // the accounts, and the one to fund
                    const QString r = modules().muster_module.wallet_lez_setup();
                    qInfo() << "[muster_ui] LEZFUND setup ->" << r;
                    if (r.contains("\"error\"")) { retryAt = now + 30; return; }
                    for (const auto &v : QJsonDocument::fromJson(
                             modules().muster_module.wallet_accounts().toUtf8()).array()) {
                        const QJsonObject a = v.toObject();
                        if (a.value("chain").toString() != lez) continue;
                        if (a.value("form").toString() == "public") pub = a.value("id").toString();
                        if (a.value("form").toString() == "shielded") keyNode = a.value("share").toString();
                    }
                    qInfo() << "[muster_ui] LEZFUND public" << pub << "key node" << keyNode.left(24);
                    if (pub.isEmpty() || keyNode.isEmpty()) return;
                    qInfo() << "[muster_ui] LEZFUND awaiting funds at" << pub;
                    awaitingSince = now;
                    stage = 1;
                } else if (stage == 1) {            // someone who holds native LEZ sends it
                    QString raw;
                    for (const auto &v : QJsonDocument::fromJson(
                             modules().muster_module.wallet_balances().toUtf8()).array()) {
                        const QJsonObject b = v.toObject();
                        if (b.value("chain").toString() == lez && b.value("account").toString() == pub)
                            raw = b.value("raw").toString();
                    }
                    qInfo() << "[muster_ui] LEZFUND public balance" << raw;
                    if (raw.isEmpty() || raw == "0") {
                        // nothing yet: say so now and then, so a funder can find the account
                        if (now - awaitingSince >= 60) {
                            qInfo() << "[muster_ui] LEZFUND awaiting funds at" << pub;
                            awaitingSince = now;
                        }
                        return;
                    }
                    const QString r = modules().muster_module.wallet_send(lez, pub, keyNode, QStringLiteral("LEZ"), raw);
                    qInfo() << "[muster_ui] LEZFUND shield" << raw << "->" << r;
                    if (r.contains("\"error\"")) { retryAt = now + 30; return; }
                    stage = 2;
                } else if (stage == 2) {            // the shield proves in the background
                    const QString f = modules().muster_module.wallet_finality(lez, QStringLiteral("pending"));
                    qInfo() << "[muster_ui] LEZFUND shield finality ->" << f;
                    if (f.contains("\"final\"")) {
                        qInfo() << "[muster_ui] LEZFUND funded";
                        s_lezFunding = false;
                        ft->stop();
                    } else if (f.contains("\"failed\"")) {
                        stage = 1;                  // shield what is public again
                    }
                }
            });
            ft->start();
        }
    });
}
