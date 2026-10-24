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
    void loadWalletAccounts() override;
    void loadWalletSummary() override;

    // FileShare (exo-4d0): the room's shared files, through muster_module's fileshare_*.
    void loadFileShare() override;
    void shareFile(const QString &path) override;
    void fetchFile(const QString &fileId, const QString &folder, const QString &privately) override;
    void seedFile(const QString &fileId, const QString &on) override;
    void retractFile(const QString &fileId) override;

    // Voice notes (docs/design/voice-notes.md §8): muster_module's voice_*; no audio here.
    void loadVoice() override;
    void startVoiceRecording() override;
    void stopVoiceRecording() override;
    void sendVoiceDraft() override;
    void discardVoiceDraft() override;
    void playVoiceNote(const QString &noteId) override;
    void stopVoicePlayback() override;
    void previewLezSend(const QString &fromId, const QString &to, const QString &raw) override;
    void sendLez(const QString &fromId, const QString &to, const QString &raw) override;

    // The room / conversation surface (see muster_ui.rep).
    void joinRoom(const QString &topic) override;
    void postMessage(const QString &body) override;
    void loadMessages() override;
    void loadMembers() override;
    void loadConversations() override;
    void requestJoin() override;
    void loadPending() override;
    void admit(const QString &identityHex) override;
    void loadContacts() override;
    void addContact(const QString &identityHex, const QString &alias) override;
    void setContactAlias(const QString &identityHex, const QString &alias) override;
    void removeContact(const QString &identityHex) override;
    void startInbox() override;
    void sendInvite(const QString &peerChatId, const QString &roomTopic, const QString &note) override;
    void loadInvites() override;
    void dismissInvite(const QString &roomTopic) override;
    void leaveRoom(const QString &roomTopic) override;
    void setRoomTitle(const QString &roomTopic, const QString &title) override;
    void proposeInRoom(const QString &effectJson) override;
    void contributeInRoom(const QString &intentId, const QString &signatureHex, const QString &keyRef) override;
    void loadIntents() override;
    void reannounce() override;
    void loadActivity() override;
    void submitInRoom(const QString &intentId) override;
    void loadDrivers() override;
    void loadAccounts() override;
    void discloseAccount(const QString &accountJson) override;
    void discloseSuggestedAccount() override;
    void loadAvailableActions() override;
    void executeInRoom(const QString &intentId) override;
    void loadConnectivity() override;
    void loadRlnStatus() override;
    void loadKeystoreStatus() override;
    void keystoreSelect(const QString &address) override;
    void loadKeystoreRequests() override;
    void loadSecurityLevels() override;
    void loadRoomAccount() override;
    void loadReadiness(const QString &intentId) override;
    void loadOffers(const QString &intentId) override;
    void loadComposeOffers(const QString &effectJson) override;
    void shareMaterial(const QString &intentId, const QString &requirement, const QString &pub) override;
    void declineInRoom(const QString &intentId) override;
    void downloadAudit(const QString &intentId) override;
    void exportOutside(const QString &intentId) override;
    void importOutside(const QString &intentId, const QString &encoded) override;
    void proposeBtcSpend(const QString &payTo, const QString &amountSat, const QString &feeRate) override;
    void proposeSplit(const QString &chain, const QString &totalWei, const QString &sharesJson, const QString &memo) override;
    void proposeSettleUp(const QString &chain, const QString &asset, const QString &memo) override;
    void loadOpenAssets() override;
    void proposeSettleUpAcross(const QString &chain, const QString &asset, const QString &ratesJson,
                               const QString &memo) override;
    void shareAddress(const QString &chain) override;
    void settlePart(const QString &intentId) override;
    void renewSplit(const QString &intentId) override;
    void lookupToken(const QString &chain, const QString &token) override;
    void confirmPart(const QString &intentId, const QString &part, const QString &tx) override;
    void reportPaid(const QString &intentId, const QString &tx) override;
    void proposeLezTransfer(const QString &recipient, const QString &amount) override;
    void proposeLezVaultInit(const QString &definition) override;
    void lezMemberAccount(const QString &index) override;
    void lezCreateMultisig(const QString &threshold, const QString &members) override;
    void frostCeremonyOpen(const QString &ceremonyId, const QString &network, const QString &t, const QString &n) override;
    void frostCeremonyJoin(const QString &ceremonyId) override;
    void loadFrostCeremonies() override;
    void xmrMsigSetupOpen(const QString &ceremonyId, const QString &chain, const QString &k, const QString &membersJson) override;
    void xmrMsigSetupJoin(const QString &ceremonyId) override;
    void xmrMsigPropose(const QString &account, const QString &recipientsJson, const QString &feeCap, const QString &memo) override;
    void loadXmrMsig() override;
    void loadFlow() override;
    void loadGraph(const QString &roomTopic) override;
    void setPolicy(const QString &kind) override;
    void loadPolicy() override;

    void onContextReady() override;

private:
    // Re-run the startup reads (health, account, settings, drivers, inbox) until the
    // module answers — onContextReady can fire before it does, and those calls are lost.
    void retryStartup(int attemptsLeft);
    // Re-announce a pending join request until admitted (best-effort delivery over
    // the fleet). Guarded so only one retry chain runs at a time.
    void scheduleJoinRetry();
    bool m_joinRetrying = false;
    int  m_joinAttempts = 0;   // bounds the re-announce so an empty room doesn't loop forever
    // A voice call's answer: voiceResultJson, then voiceResultSeq one more (§8 of
    // docs/design/voice-notes.md), so the view can tell a new answer from the last one.
    void voiceAnswer(const QString &answer);
    qint64 m_voiceAnswers = 0;
};
