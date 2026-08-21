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

    const QString prev = intentState();
    const QString newState = modules().muster_module.approve(id, signatureHex);
    if (newState.isEmpty() || newState.startsWith(QStringLiteral("unknown"))
        || newState.startsWith(QStringLiteral("error"))) {
        qWarning() << "[muster_ui] approve failed ->" << newState;
        setLastError(QStringLiteral("approve failed: %1").arg(newState));
        return;
    }

    setIntentState(newState);
    if (newState == prev) {
        // The module accepted the call but the state did not advance — the
        // signature did not recover to an owner (or was already counted). Say so
        // honestly rather than implying progress.
        setLastError(QStringLiteral("signature not counted — it did not recover to an owner"));
    }
    qInfo() << "[muster_ui] approve" << id << ":" << prev << "->" << newState;
}

void MusterUiBackend::onContextReady()
{
    // Fires once ui-host hands the plugin its wired modules(); read liveness and
    // the account context immediately so the view opens on real values.
    checkHealth();
    loadAccount();
}
