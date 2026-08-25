#include "muster_ui_backend.h"

#include <QDebug>

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
}

void MusterUiBackend::loadIntents()
{
    // coordinate_intents → the room's proposals folded from the shared log, as
    // [{id, state}]. Drives inbound delivery first (in the module).
    setIntentsJson(modules().muster_module.coordinate_intents());
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
}
