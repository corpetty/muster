#pragma once

#include "rep_muster_ui_source.h"
#include "logos_ui_plugin_context.h"

/**
 * @brief The muster-ui backend (universal authoring model).
 *
 * You write only this class + the `.rep` view contract; the `*Plugin` /
 * `*Interface` glue (Q_PLUGIN_METADATA, initLogos wiring, QtRO registration)
 * is generated around it.
 *
 * Derives:
 *   - `MusterUiSimpleSource` — generated from muster_ui.rep; implement its
 *     SLOTs and feed its PROPs (`setHealth(...)`, `setIntentTxhash(...)`, …),
 *     which auto-sync to QML.
 *   - `LogosUiPluginContext` — supplies `onContextReady()` + `modules()`, the
 *     Qt-typed callers for the declared `dependencies` (here: muster_module).
 *
 * The backend holds no keys and no state of its own: every value it feeds a PROP
 * comes back from a muster_module call through the logos API. The intent lives in
 * the module; this class is a thin conduit.
 */
class MusterUiBackend : public MusterUiSimpleSource,
                        public LogosUiPluginContext
{
public:
    void checkHealth() override;
    void loadAccount() override;
    void loadSettings() override;
    void setSetting(const QString &key, const QString &value) override;
    void propose(const QString &effectJson) override;
    void approve(const QString &signatureHex) override;
    void submit() override;
    void reset() override;
    void loadBalances() override;

    // The room / conversation surface (see muster_ui.rep).
    void joinRoom(const QString &topic) override;
    void postMessage(const QString &body) override;
    void loadMessages() override;
    void loadMembers() override;
    void loadConversations() override;
    void requestJoin() override;
    void loadPending() override;
    void admit(const QString &identityHex) override;
    void proposeInRoom(const QString &effectJson) override;
    void contributeInRoom(const QString &intentId, const QString &signatureHex) override;
    void loadIntents() override;
    void submitInRoom(const QString &intentId) override;
    void loadDrivers() override;
    void setPolicy(const QString &kind) override;
    void loadPolicy() override;

    void onContextReady() override;

private:
    // Re-announce a pending join request until admitted (best-effort delivery over
    // the fleet). Guarded so only one retry chain runs at a time.
    void scheduleJoinRetry();
    bool m_joinRetrying = false;
};
