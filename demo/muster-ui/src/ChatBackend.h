#ifndef CHAT_BACKEND_H
#define CHAT_BACKEND_H

#include <QObject>
#include <QSortFilterProxyModel>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVector>
#include <functional>
#include "Assets.h"
#include "rep_ChatBackend_source.h"
#include "logos_ui_plugin_context.h"
#include "ConversationListModel.h"
#include "MessageListModel.h"
#include "MemberListModel.h"
#include "ErrorLog.h"
#include "SessionLogFiles.h"

class ChatBackend : public ChatBackendSimpleSource,
                    public LogosUiPluginContext
{
    Q_OBJECT
    // The conversation model reaches QML through a recency proxy, so the list is
    // sorted newest-first; the base type is what the host remotes to the replica.
    Q_PROPERTY(QAbstractItemModel* conversationModel READ conversationModel CONSTANT)
    Q_PROPERTY(MessageListModel* messageModel READ messageModel CONSTANT)
    Q_PROPERTY(MemberListModel* memberModel READ memberModel CONSTANT)

public:
    explicit ChatBackend(QObject* parent = nullptr);
    ~ChatBackend() override;

    QAbstractItemModel* conversationModel() const;
    MessageListModel* messageModel() const;
    MemberListModel* memberModel() const;

    // Fires once the generated plugin glue has wired modules(); the typed
    // chat_module surface is live, so init + event subscriptions happen here.
    void onContextReady() override;

public slots:
    // Wallet slots. Implemented in ChatBackendWallet.cpp — the zone is a
    // separate concern from the conversation and reads more clearly apart from
    // it, but it shares this object because both surfaces answer to one view.
    void openWallet() override;
    void fundWallet() override;
    void refreshBalances() override;
    void requestAddress(QString conversationId) override;
    void shareAddress(QString conversationId, QString assetId) override;
    void sendPayment(QString conversationId, QString railId, QString toAddress,
                     QString amount) override;
    // Move a holding that is owed into one that can be spent. Only offered for
    // a holding whose entry declares how (Assets::Holding::claim).
    void claimHolding(QString assetId, QString amount) override;

    // The intent spine. Implemented in ChatBackendIntent.cpp — these are pure
    // conversation moves; only submitIntent reaches the wallet, and it does so
    // through the same sendPayment path a direct payment takes.
    void proposePayment(QString conversationId, QString railId, QString toAddress, QString label,
                        QString amount, int threshold) override;
    void approveIntent(QString conversationId, QString intentId) override;
    void dropIntent(QString conversationId, QString intentId, QString reason) override;
    void submitIntent(QString conversationId, QString intentId) override;

    void createConversation(QString peerAddress) override;
    void startActivity(QString verb, QString peerAddress) override;
    void createGroupConversation(QString name, QString description) override;
    void addGroupMember(QString conversationId, QString peerAddress) override;
    void sendMessage(QString conversationId, QString content) override;
    void selectConversation(QString conversationId) override;
    // Reloads the current conversation's roster into memberModel. A synchronous
    // module read, so never call it from inside a module event callback without
    // deferToEventLoop.
    void refreshMembers() override;
    void refreshSessionLogs() override;

private:
    void initialiseModule();
    // Opens this run's logs: the chat module names the file it is writing, and
    // its directory is where this view writes beside it, for want of one of its
    // own. Reports rather than falls back when there is nowhere to write.
    void openRunLogs();
    // The one way a failure reaches anyone: it joins the retained list, goes into
    // this view's log, and reaches the strip. Every failing path calls this and
    // none of them classifies what it is reporting.
    void report(const QString& message);
    // A failed action and the module's account of it. An empty reason gets words
    // of its own rather than a dangling separator: it is what a call that never
    // reached the module leaves behind, which is the worst moment to say least.
    void reportFailure(const QString& action, const QString& reason);
    // Starts asking the module whether it is still there. Until something asks,
    // a module that died is indistinguishable from an idle one, and the app goes
    // on looking connected until the next thing the user does times out.
    void startHealthProbe();
    // One probe's answer. False is the call failing, not the module saying so:
    // health() has no other return.
    void onHealthAnswer(bool answered);
    void subscribeToEvents();
    void rehydrateConversations();
    // Reads this account's own address into the myAddress property. A
    // synchronous module read, so never call it from inside a module event
    // callback without deferToEventLoop.
    void refreshMyAddress();
    // Pushes the current conversation's group flag, display name, and description
    // as backend properties for the QML view to bind — see the .cpp for why the
    // view can't read them off the model directly.
    void syncCurrentConversationMeta();
    // Loads a conversation's messages into messageModel. False when the module
    // could not be read, leaving the model as it was.
    bool showConversationMessages(const QString& convoId);

    // Runs `work` on the next event-loop turn. A module read (list_conversations/
    // get_messages) is a synchronous QtRO call; issuing one from inside a module
    // event callback re-enters the replica's socket-read handler while its read
    // notifier is disabled, so the reply only lands after the call's ~20s timeout
    // and the UI thread stalls. Deferring lets the callback return first.
    void deferToEventLoop(std::function<void()> work);

    // Event handlers. Each receives the event's positional argument list, in
    // the order declared in chat_module.lidl.
    void applyDeliveryState(const QString& state, const QString& detail);
    void applyMessageReceived(const QVariantList& args);
    void applyMessageSent(const QVariantList& args);
    void applyConversationCreated(const QVariantList& args);
    void applyConversationUpdated(const QVariantList& args);
    void applyMembersChanged(const QVariantList& args);
    void applyConversationDeleted(const QVariantList& args);

    // The other participant in a direct conversation's roster; empty for a group
    // or when no other account is on it.
    static QString peerAddressOf(const QVector<MemberItem>& members, bool isGroup);

    static QString fallbackDisplayName(const QString& convoId, const QString& peerLabel = QString(),
                                       bool isGroup = false);

    // Short display form of a message sender; "Peer" when the sender is empty.
    static QString shortSenderLabel(const QString& sender);

    ConversationListModel* m_conversationModel;
    // Sorts m_conversationModel newest-first for the view; the source keeps
    // insertion order and every internal edit stays on the source.
    QSortFilterProxyModel* m_conversationProxy;
    MessageListModel* m_messageModel;
    MemberListModel* m_memberModel;

    bool m_moduleInitialised = false;
    // Set once the initial snapshot has loaded; gates the reconnect resync in
    // applyDeliveryState so it doesn't fire during initial setup.
    bool m_initialSnapshotDone = false;

    ErrorLog m_errors;
    // The file each writer announced it is writing. Each fixes the naming its own
    // runs are grouped by, and they share one directory.
    QString m_moduleLogPath;
    QString m_viewLogPath;

    QTimer* m_healthProbe = nullptr;
    // Consecutive unanswered probes. Reset by any answer, so what it counts is a
    // module that has stopped answering rather than one slow reply.
    int m_healthMisses = 0;

    // ── wallet (ChatBackendWallet.cpp) ───────────────────────────────────
    // The directory this instance's wallet lives in, derived from the chat
    // module's instance directory so two peers under different --user-dir
    // never share one. A wallet in a shared path would silently merge the two
    // demo identities, which is the one failure that would make the recording
    // a lie.
    QString walletDir() const;
    // Sync the wallet forward to the zone's tip, in chunks. Returns false and
    // fills `error` if it could not reach the tip; the caller decides whether
    // that is fatal, because a stale read is not the same as a failed send.
    bool syncToTip(QString* error);
    // Create-or-open, plus the private account this wallet receives into.
    // Idempotent; safe to call from any entry point that needs a live wallet.
    bool ensureWalletOpen();
    // The registered public account, created and registered on first use.
    // Empty string means the zone would not give us one.
    QString ensurePublicAccount();
    // Block until this wallet can actually see `atLeast` in `account`, and
    // return what it sees (0 if it never arrives in time). The chain reporting
    // a balance is not the same as this wallet being able to spend it, and
    // spending too early fails as InsufficientFunds.
    quint64 waitForPublicFunds(const QString& account, quint64 atLeast, int timeoutMs);
    // Wait until this wallet can actually see the effect of a transfer it just
    // made, re-reading balances as it goes. Every path that moves value ends
    // here: the zone accepting a transfer and this wallet being able to see it
    // are different moments, and reading once between them shows the balances
    // from before — which looks exactly like the transfer having failed.
    void settleAfterTransfer(int timeoutMs);
    // Every mutating zone call must be followed by this: the wallet-ffi holds
    // state in memory and without save() nothing reaches disk, so the next
    // open() gets a wallet that has forgotten the transfer it just made.
    void walletSave();
    // Marks the wallet busy and names the stage, so the view can say what the
    // pause is for. Pairs with endStage().
    void beginStage(const QString& stage);
    void endStage();
    void failWallet(const QString& action, const QString& reason);
    // Reads both balances and this account's receiving keys. A synchronous run
    // of zone calls — never call it from inside a module event callback.
    void readWalletState();

    // The verb chosen for a conversation being opened, acted on once the
    // module reports it created. Cleared as soon as it is used.
    QString m_pendingVerb;

    // ── the join handshake (see MusterMessage::conversationReady) ────────
    // The conversation whose opening card is waiting for the peer to announce
    // itself, or empty. At most one: it only ever applies to a conversation
    // this instance just created, and creating a second replaces the first.
    QString m_heldAsk;
    // How long to wait before giving up and telling the user to ask by hand.
    // Generous, because the peer may be starting up — a shielded wallet's own
    // first launch is slower than this — and the cost of waiting is a line on
    // screen, while the cost of giving up early is a silent non-ask.
    static constexpr int kPeerJoinWaitMs = 120000;
    void holdAskUntilPeerJoins(const QString& conversationId);
    void onPeerJoined(const QString& conversationId);

    // Sync to the tip, publish the balances, and declare the wallet Ready.
    void finishWalletOpen();

    // True when this message is a payment receipt from somebody else. Used
    // only to decide whether to go and look at our own wallet — never to
    // decide what to show. See scanForIncomingPayment.
    bool isIncomingReceipt(const QString& content) const;
    // Look for money that has arrived, because a receipt in the room says some
    // may have. Safe to call on any receipt, addressed to us or not.
    void scanForIncomingPayment();

    bool m_walletOpen = false;
    // The account this wallet minted for itself. It names the key node we
    // publish — not an address anyone pays. Nothing registers it: see
    // ensureWalletOpen for why registering would break it.
    QString m_privateAccount;
    // Every private account this wallet can see that holds a balance, largest
    // first, found by scanning with our viewing key. A payment to us mints a
    // fresh account under our key node at an identifier the sender chose, so
    // the account we minted is usually not the one holding the money — and not
    // the one a payment can be spent from. See readPrivateBalance.
    QStringList m_fundedPrivateAccounts;
    // The account to spend from: the largest funded one, or the account we
    // created when nothing has been received yet.
    QString spendFromAccount() const;
    QString m_publicAccount;

    // ── journey (ChatBackendJourney.cpp) ─────────────────────────────────
    // Back to the start: no conversation, so nothing but discovery has
    // happened yet.
    void resetJourney();
    // Fold one message into the journey, advancing the step if it is evidence
    // of a later one and appending what happened to the trail.
    void noteJourneyMessage(const QString& content, bool fromSelf, qint64 timestampMs);
    // Re-read the whole thread. Called when a conversation is loaded, so the
    // journey is correct for one this instance did not start.
    void rebuildJourney(const QVariantList& messages);
    // What one conversation is asking of the user, read from its messages:
    // {state, action, detail}. State is needs-you | waiting | settled | idle.
    QVariantMap actionForMessages(const QVariantList& messages) const;
    // Which of this wallet's holdings a thread has put in play, and why:
    // [{id, why}], in the catalogue's order. Call buildAssets() first — the
    // fold reads the rail table to learn which holding a payment was drawn
    // from.
    QVariantList conversationAssetsForMessages(const QVariantList& messages) const;
    // Rebuild the whole home list, one entry per conversation, needs-you first.
    // Makes synchronous module reads for every conversation, so never call it
    // straight from an event callback — defer it.
    void refreshActions();

    QVariantList m_journeyTrail;

    // ── intents (ChatBackendIntent.cpp) ──────────────────────────────────
    // Fold a thread into its intents, newest proposal last. Every field the UI
    // shows comes from here: there is no intent state kept anywhere else, so a
    // peer that was offline for the whole exchange reads the same result as one
    // that watched it happen. Approvals are attributed by each message's own
    // author and deduplicated per address, so approving twice is not two.
    QVariantList intentsForMessages(const QVariantList& messages) const;
    // Where a payee address came from, read off the thread: the address-share
    // card a peer posted it in, as {sender, atMs, assetName}. Empty when this
    // conversation never carried it from anyone but us — which is the answer
    // payForIntent refuses on.
    QVariantMap addressOriginForMessages(const QVariantList& messages,
                                         const QString& address) const;
    // The one intent a room is currently about — the last that is neither
    // final nor dropped — or an empty map. Drives the pinned banner (U-3).
    QVariantMap liveIntentForMessages(const QVariantList& messages) const;
    // Re-read the current thread and publish both. Synchronous module reads:
    // defer it out of event callbacks like refreshActions.
    void refreshIntents();
    // Post the receipt that closes `intentId`, and pay it. Shares every step
    // with a direct send; the id is what ties the receipt back to the proposal.
    // The rail is named rather than assumed — a proposal is agreed on one, and
    // paying it on another would settle terms the room did not approve.
    void payForIntent(const QString& conversationId, const QString& railId,
                      const QString& toAddress, quint64 amount, const QString& intentId);

    // ── assets (ChatBackendAssets.cpp) ───────────────────────────────────
    // Builds the catalogue of holdings and rails, once. See that file: it is
    // the single place an asset or a way to pay is added.
    void buildAssets();
    const Assets::Holding* holdingById(const QString& id) const;
    const Assets::Rail* railById(const QString& id) const;
    // The rail, or null if it cannot be paid with — unknown, unsendable, or
    // carrying no visibility claim. Every payment path goes through this rather
    // than railById, so a rail that cannot account for what it leaks cannot be
    // used by any of them.
    const Assets::Rail* sendableRailById(const QString& id) const;
    // The rail a picker should open on for a destination of this form: the
    // most private one that can pay it.
    QString defaultRailFor(Assets::AddressForm form) const;
    // What the view binds: one row per holding, one per sendable rail.
    QVariantList holdingRows() const;
    QVariantList railRows() const;
    static QVariantMap disclosureRow(const Assets::Disclosure& d);

    // The catalogue, and the last answers the zone gave for it. Balances and
    // addresses are cached rather than read on demand: some are a sequencer
    // round trip, and a property read must not block a frame.
    QVector<Assets::Holding> m_holdings;
    QVector<Assets::Rail> m_rails;
    QHash<QString, QString> m_balances;
    QHash<QString, QString> m_addresses;
    // Why a holding cannot be used yet, keyed by holding id; absent when it can.
    // A blocked holding is still listed and still shows its balance — it is the
    // *reason* that is the information, and hiding the row would turn a wait
    // into an unexplained absence. Nothing sets one at present.
    QHash<QString, QString> m_blockers;

    // The two reads with enough going on to be worth their own functions —
    // the private one scans and sums, the public one is the only balance that
    // comes from the sequencer instead of the wallet.
    QString readPrivateBalance();
    QString readPublicBalance();
};

#endif
