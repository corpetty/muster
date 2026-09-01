#include "muster_ui_backend.h"

#include <QDebug>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>

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
    loadConversations();   // the room list — this join may have added a room
    loadDrivers();         // the room's admitted policy set (driver-as-proposal)
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
    // coordinate_members → the admitted roster (who can read the room).
    setMembersJson(modules().muster_module.coordinate_members());
}

void MusterUiBackend::requestJoin()
{
    // coordinate_request_join → announce our encryption key on the topic. Carries no
    // authority (discovery, not entry) — an existing member still has to admit us.
    // Two instances that both joined one topic each founded their own epoch; this is
    // the first half of merging them into one readable room.
    const QString r = modules().muster_module.coordinate_request_join();
    qInfo() << "[muster_ui] coordinate_request_join ->" << r;
    loadPending();
    // Keep re-announcing until admitted. Delivery over the fleet is best-effort and
    // muster's shard can be sparse (no mesh peer at the instant of a one-shot send),
    // so a single request can fail to reach a store node and the other side never
    // sees it. Re-issue every few seconds until this peer is in a shared epoch (its
    // roster grows past just itself), then stop.
    if (!m_joinRetrying) {
        m_joinRetrying = true;
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
        modules().muster_module.coordinate_request_join();
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

void MusterUiBackend::contributeInRoom(const QString &intentId, const QString &signatureHex)
{
    // coordinate_contribute → add an owner signature; the module verifies it
    // recovers to a configured owner before it counts (a non-owner is rejected).
    const QString st = modules().muster_module.coordinate_contribute(intentId, signatureHex);
    qInfo() << "[muster_ui] coordinate_contribute" << intentId << "->" << st;
    loadIntents();
    loadDrivers();   // an approval may have admitted a new driver kind (governance)
}

void MusterUiBackend::loadIntents()
{
    // coordinate_intents → the room's proposals folded from the shared log, as
    // [{id, state}]. Drives inbound delivery first (in the module).
    setIntentsJson(modules().muster_module.coordinate_intents());
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
    // coordinate_drivers → the driver kinds this room may use (driver-as-proposal).
    // Folded from the shared log: the founding set plus any kind an approved
    // add-driver proposal admitted. The policy pickers offer only these.
    setDriversJson(modules().muster_module.coordinate_drivers());
}

void MusterUiBackend::setPolicy(const QString &kind)
{
    // coordinate_set_policy → choose the room's driver (safe | threshold). The same
    // propose/contribute/fold path runs under whichever; the policy is a driver, not
    // hardcoded. Result is {policy, threshold, domain, membership}.
    const QString r = modules().muster_module.coordinate_set_policy(kind);
    qInfo() << "[muster_ui] coordinate_set_policy(" << kind << ") ->" << r;
    setPolicyJson(r);
}

void MusterUiBackend::loadPolicy()
{
    // coordinate_policy → the room's current policy, described by its driver.
    setPolicyJson(modules().muster_module.coordinate_policy());
}

void MusterUiBackend::onContextReady()
{
    // Fires once ui-host hands the plugin its wired modules(); read liveness, the
    // account context, and the wallet balances so the view opens on real values.
    checkHealth();
    loadAccount();
    loadBalances();
    loadSettings();

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
                    if (!proposed && membersJson().contains("\"self\":false")) {
                        proposed = true;
                        proposeInRoom(QStringLiteral("{\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":1000,\"nonce\":0}"));
                    }
                }
                qInfo() << "[muster_ui] SELFTEST pending=" << pendingJson()
                        << "members=" << membersJson()
                        << "intents=" << intentsJson();
            });
            t->start();
        });
    }
}
