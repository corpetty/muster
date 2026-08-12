#include "ChatBackend.h"
#include "ConversationListModel.h"
#include "MessageListModel.h"
#include "MemberListModel.h"
#include "Identity.h"
#include "ProcessLog.h"

// Generated umbrella: LogosModules (behind modules()) from
// metadata.json#dependencies — the Qt-typed chat_module wrapper.
#include "logos_sdk.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QFileInfo>
#include <QPointer>
#include <QVariantMap>
#include <utility>

namespace {

// Preview cap; mirrors chat_module's own 160-char truncation so a live preview
// matches the one a rehydrate reads back from the module.
constexpr int kPreviewMaxChars = 160;
constexpr const char* kDefaultDeliveryPreset = "logos.test";
// How much of the chat core's account of a run to keep.
// TODO: expose to the client through the UI in the future.
constexpr const char* kChatLogLevel = "info";

// How often the module is asked whether it is still there, and how long that
// question is worth waiting for. Acquiring the object blocks the caller, so the
// timeout is what a dead module costs this thread: short enough not to be felt,
// long enough that a loaded box does not look like a crash.
constexpr int kHealthIntervalMs = 10000;
constexpr int kHealthTimeoutMs = 2000;
// Probes that must go unanswered before the module is called gone. One is a
// hiccup; the announcement is not worth being wrong about.
constexpr int kHealthMissesBeforeGone = 2;

QDateTime msToDateTime(qint64 ms)
{
    return ms > 0 ? QDateTime::fromMSecsSinceEpoch(ms) : QDateTime::currentDateTime();
}

QString humanSize(qint64 bytes)
{
    static const char* const units[] = {"bytes", "KB", "MB", "GB"};
    double size = static_cast<double>(bytes);
    int unit = 0;
    while (size >= 1024.0 && unit < 3) {
        size /= 1024.0;
        ++unit;
    }
    return unit == 0 ? QStringLiteral("%1 bytes").arg(bytes)
                     : QStringLiteral("%1 %2").arg(size, 0, 'f', 1).arg(QLatin1String(units[unit]));
}

// The run's start time as a reader states it, or the stamp itself when the file
// name does not spell one.
QString runLabel(const QString& stamp)
{
    const QDateTime started = QDateTime::fromString(stamp, QStringLiteral("yyyyMMdd_HHmmss"));
    return started.isValid() ? started.toString(QStringLiteral("yyyy-MM-dd HH:mm:ss")) : stamp;
}

// One writer's runs, newest first, appended to `published` and tagged with the
// writer so the view can offer each on its own tab. The announced path fixes both
// the directory to read and the naming to group by, so the two writers sharing a
// directory never pick up each other's files.
void appendRuns(QVariantList& published, const QString& writer, const QString& announcedPath)
{
    const QList<SessionLogRun> runs = listSessionLogRuns(announcedPath);
    const QString currentStamp = runs.isEmpty() ? QString() : runs.first().stamp;
    for (const SessionLogRun& run : runs) {
        published.append(QVariantMap{
            {QStringLiteral("writer"), writer},
            {QStringLiteral("label"), runLabel(run.stamp)},
            {QStringLiteral("sizeLabel"), humanSize(run.bytes)},
            {QStringLiteral("fileCount"), run.paths.size()},
            {QStringLiteral("path"), run.paths.isEmpty() ? QString() : run.paths.last()},
            {QStringLiteral("paths"), run.paths.join(QLatin1Char('\n'))},
            {QStringLiteral("stamp"), run.stamp},
            {QStringLiteral("current"), run.stamp == currentStamp},
        });
    }
}

} // namespace

// QtCore Settings (QSettings) persists only when the application has an
// identity, and the module host does not always set one. Provide a fallback so
// UI preferences survive restarts, leaving a host-set identity untouched.
static void ensureApplicationIdentity()
{
    if (QCoreApplication::organizationName().isEmpty())
        QCoreApplication::setOrganizationName(QStringLiteral("Logos"));
    if (QCoreApplication::applicationName().isEmpty())
        QCoreApplication::setApplicationName(QStringLiteral("logos-chat-ui"));
}
Q_COREAPP_STARTUP_FUNCTION(ensureApplicationIdentity)

ChatBackend::ChatBackend(QObject* parent)
    : ChatBackendSimpleSource(parent)
    , m_conversationModel(new ConversationListModel(this))
    , m_conversationProxy(new QSortFilterProxyModel(this))
    , m_messageModel(new MessageListModel(this))
    , m_memberModel(new MemberListModel(this))
{
    // Present conversations newest-first without disturbing the source's
    // insertion order; the proxy re-sorts live as last_activity changes.
    m_conversationProxy->setSourceModel(m_conversationModel);
    m_conversationProxy->setSortRole(ConversationListModel::LastActivityRole);
    m_conversationProxy->setDynamicSortFilter(true);
    m_conversationProxy->sort(0, Qt::DescendingOrder);

    setChatStatus(ChatBackendSimpleSource::Stopped);
    setMyAddress(QString());
    setMyLabel(QString());
    setMyInitials(QString());
    setCurrentConversationId(QString());
    setLoadedConversationId(QString());
    setLogDir(QString());
    syncCurrentConversationMeta();

    // Built here, before any zone call and before the first fold, because the
    // catalogue is what names a rail. A proposal read off a thread with no
    // catalogue would report every rail as one this build has never heard of —
    // including its own. Nothing in it reaches the zone until something asks it
    // to, so building it this early costs a handful of strings.
    buildAssets();
    setAssets(holdingRows());
    setRails(railRows());

    // As early as this plugin can reach: the QML engine has not loaded the view
    // yet, so its warnings are caught too. The lines are held in memory until
    // openRunLogs finds somewhere to put them.
    ProcessLog::install();
}

void ChatBackend::onContextReady()
{
    // Fires after the framework has wired modules(), so the typed chat_module
    // surface is live and the QtRO source is registered — the right point to
    // initialise the module and arm event subscriptions.
    initialiseModule();
}

ChatBackend::~ChatBackend()
{
    if (isContextReady())
        modules().chat_module.shutdown();
}

QAbstractItemModel* ChatBackend::conversationModel() const
{
    return m_conversationProxy;
}

MessageListModel* ChatBackend::messageModel() const
{
    return m_messageModel;
}

MemberListModel* ChatBackend::memberModel() const
{
    return m_memberModel;
}

// ── lifecycle ───────────────────────────────────────────────────────────────

void ChatBackend::initialiseModule()
{
    setChatStatus(ChatBackendSimpleSource::Initialising);

    // The ChatConfig record, which reaches the module untyped: there is no
    // generated struct for a record in parameter position, so the wire shape is
    // the contract.
    const QVariantMap config{
        {QStringLiteral("delivery_preset"), QString::fromLatin1(kDefaultDeliveryPreset)},
        {QStringLiteral("log_level"), QString::fromLatin1(kChatLogLevel)},
    };
    const LogosResult res = modules().chat_module.init(config);
    if (!res.success) {
        const QString reason = res.getError<QString>();
        setChatStatus(ChatBackendSimpleSource::Error);
        reportFailure(QStringLiteral("Failed to initialise chat"), reason);
        return;
    }

    m_moduleInitialised = true;

    // After init, because that is when the module opens the file it names.
    openRunLogs();

    // Subscribe before the initial snapshot so no event fires in the gap
    // between snapshotting and registering the listeners.
    subscribeToEvents();

    // Take the initial snapshot and mark it done *before* seeding delivery
    // state. If status() already reports online (re-attaching to a still-running,
    // already-connected module), the seed's online transition then drives the
    // recovery refetch through applyDeliveryState instead of being dropped by
    // the m_initialSnapshotDone gate — which previously left history missing
    // until a reconnect that never came.
    rehydrateConversations();
    refreshActions();
    m_initialSnapshotDone = true;

    // Seed delivery state from the snapshot in case delivery_state_changed
    // fired during init(), before subscribeToEvents() registered the listener.
    const QVariantMap status = modules().chat_module.status().toMap();
    applyDeliveryState(status.value(QStringLiteral("delivery_state")).toString(),
                       status.value(QStringLiteral("detail")).toString());

    startHealthProbe();
}

void ChatBackend::startHealthProbe()
{
    m_healthProbe = new QTimer(this);
    m_healthProbe->setInterval(kHealthIntervalMs);
    connect(m_healthProbe, &QTimer::timeout, this, [this] {
        // Guarded rather than captured raw: the reply arrives on a later turn of
        // the event loop, by which time this backend may be gone.
        QPointer<ChatBackend> self(this);
        modules().chat_module.healthAsync([self](bool answered) {
            if (self)
                self->onHealthAnswer(answered);
        }, Timeout(kHealthTimeoutMs));
    });
    m_healthProbe->start();
}

void ChatBackend::onHealthAnswer(bool answered)
{
    if (answered) {
        m_healthMisses = 0;
        return;
    }
    if (++m_healthMisses < kHealthMissesBeforeGone)
        return;

    // Nothing brings the module back inside this process, so asking again would
    // only spend the acquire timeout on every tick for the rest of the run.
    m_healthProbe->stop();
    setChatStatus(ChatBackendSimpleSource::Error);
    report(QStringLiteral("The chat module stopped responding and has probably crashed. "
                          "Its log for this run is where the reason will be."));
}

void ChatBackend::openRunLogs()
{
    m_moduleLogPath = modules().chat_module.get_log_path();
    if (m_moduleLogPath.isEmpty()) {
        report(QStringLiteral("Failed to open this run's logs: the chat module opened none"));
        return;
    }

    // The chat module's instance directory, borrowed: the platform assigns a view
    // module none of its own, and picking one would mean two instances writing
    // into the same folder. The two writers' runs stay apart because each list is
    // grouped by the stem of the file its own writer announced.
    // TODO: write into this view's own instance directory once
    // LogosUiPluginContext hands one over.
    const QString directory = QFileInfo(m_moduleLogPath).absolutePath();
    setLogDir(directory);

    if (ProcessLog::openIn(directory))
        m_viewLogPath = ProcessLog::path();
    else
        report(QStringLiteral("Failed to open this view's log: cannot write to ") + directory);

    refreshSessionLogs();
}

void ChatBackend::report(const QString& message)
{
    m_errors.add(message, QDateTime::currentDateTime());
    setErrors(m_errors.published());
    // Through Qt's logging, so the line reaches this run's log by the same route
    // and in the same order as everything else the view writes.
    qWarning().noquote() << "chat_ui:" << message;
    emit error(message);
}

void ChatBackend::reportFailure(const QString& action, const QString& reason)
{
    report(reason.isEmpty() ? action + QStringLiteral(": the chat module gave no reason")
                            : action + QStringLiteral(": ") + reason);
}

void ChatBackend::subscribeToEvents()
{
    auto& chat = modules().chat_module;
    chat.on(QStringLiteral("message_received"),
            [this](const QVariantList& a) { applyMessageReceived(a); });
    chat.on(QStringLiteral("message_sent"),
            [this](const QVariantList& a) { applyMessageSent(a); });
    chat.on(QStringLiteral("conversation_created"),
            [this](const QVariantList& a) { applyConversationCreated(a); });
    chat.on(QStringLiteral("conversation_updated"),
            [this](const QVariantList& a) { applyConversationUpdated(a); });
    chat.on(QStringLiteral("members_changed"),
            [this](const QVariantList& a) { applyMembersChanged(a); });
    chat.on(QStringLiteral("conversation_deleted"),
            [this](const QVariantList& a) { applyConversationDeleted(a); });
    chat.on(QStringLiteral("delivery_state_changed"), [this](const QVariantList& a) {
        applyDeliveryState(a.value(0).toString(), a.value(1).toString());
    });
}

void ChatBackend::rehydrateConversations()
{
    if (!m_moduleInitialised) return;

    const QVariantList convos = modules().chat_module.list_conversations();
    // Unread counts live only here, so carry them across the rebuild.
    const QHash<QString, int> unread = m_conversationModel->unreadCounts();
    m_conversationModel->clear();
    for (const QVariant& v : convos) {
        const QVariantMap obj = v.toMap();
        const QString convoId = obj.value(QStringLiteral("convo_id")).toString();
        if (convoId.isEmpty()) continue;
        const QString nickname = obj.value(QStringLiteral("nickname")).toString();
        const QString name = obj.value(QStringLiteral("name")).toString();
        const QString description = obj.value(QStringLiteral("description")).toString();
        const QString preview = obj.value(QStringLiteral("preview")).toString();
        const qint64 lastActivity = obj.value(QStringLiteral("last_activity_ms")).toLongLong();
        const bool isGroup = obj.value(QStringLiteral("kind")).toString() == QStringLiteral("group");
        // Local nickname wins, then the group's shared name, else a generated label.
        const QString displayName = !nickname.isEmpty() ? nickname
            : !name.isEmpty()                           ? name
                                                        : fallbackDisplayName(convoId, QString(), isGroup);
        m_conversationModel->addConversation(convoId, displayName, description,
                                             msToDateTime(lastActivity), isGroup, preview);
    }
    m_conversationModel->restoreUnreadCounts(unread);
    // The rebuilt list may now know the current conversation's kind/name.
    syncCurrentConversationMeta();
}

void ChatBackend::refreshMyAddress()
{
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady())
        return;

    const QString address = modules().chat_module.get_address();
    if (address.isEmpty()) {
        report(QStringLiteral("Failed to get your address"));
        return;
    }
    setMyAddress(address);
    setMyLabel(Identity::shortLabel(address));
    setMyInitials(Identity::initials(address));
}

// Push the current conversation's derived view state (group flag, display name)
// as backend properties. The models reach QML as QtRO replicas that don't proxy
// ConversationListModel's isGroupFor/displayNameFor Q_INVOKABLE lookups, so the
// view binds these instead. Call whenever the selection or the list changes.
void ChatBackend::syncCurrentConversationMeta()
{
    const QString id = currentConversationId();
    setCurrentIsGroup(m_conversationModel->isGroupFor(id));
    setCurrentDisplayName(m_conversationModel->displayNameFor(id));
    setCurrentDescription(m_conversationModel->descriptionFor(id));
    setCurrentAvatarInitials(Identity::initials(id));
    setCurrentAvatarRamp(Identity::avatarRamp(Identity::shortLabel(id)));
}

bool ChatBackend::showConversationMessages(const QString& convoId)
{
    if (convoId.isEmpty()) {
        m_messageModel->clear();
        return true;
    }
    if (!m_moduleInitialised) {
        m_messageModel->clear();
        return false;
    }

    // A failed read comes back as an empty list, so ask for the error too: an
    // empty thread and an unreachable module must not look alike.
    logos::CallError err;
    const QVariantList msgs = modules().chat_module.get_messages(convoId, &err);
    if (!err.ok()) {
        const QString reason = QString::fromStdString(err.message);
        reportFailure(QStringLiteral("Could not load messages"), reason);
        return false;
    }

    QVector<MessageItem> rows;
    rows.reserve(msgs.size());
    for (const QVariant& v : msgs) {
        const QVariantMap obj = v.toMap();
        const bool fromSelf = obj.value(QStringLiteral("from_self")).toBool();
        const QString content = obj.value(QStringLiteral("content")).toString();
        const qint64 ts = obj.value(QStringLiteral("timestamp_ms")).toLongLong();
        const QString sender = obj.value(QStringLiteral("sender")).toString();
        rows.append({ fromSelf ? QStringLiteral("Me") : shortSenderLabel(sender),
                      content, msToDateTime(ts), fromSelf });
    }
    m_messageModel->setMessages(std::move(rows));
    // Re-read the journey off the thread we just loaded, so opening a
    // conversation shows how far it has got and what happened — including one
    // this instance did not start.
    rebuildJourney(msgs);
    // And its proposals, from the same read — opening a room shows what it is
    // currently deciding, not just what it has said.
    setIntents(intentsForMessages(msgs));
    setLiveIntent(liveIntentForMessages(msgs));
    return true;
}

void ChatBackend::deferToEventLoop(std::function<void()> work)
{
    QMetaObject::invokeMethod(this, std::move(work), Qt::QueuedConnection);
}

// ── .rep slot implementations ───────────────────────────────────────────────

void ChatBackend::createConversation(QString peerAddress)
{
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady()) {
        report(QStringLiteral("Failed to create DM: chat is not online"));
        return;
    }
    if (peerAddress.isEmpty()) {
        report(QStringLiteral("Failed to create DM: address cannot be empty"));
        return;
    }

    const LogosResult res = modules().chat_module.create_conversation(peerAddress);
    if (!res.success) {
        const QString reason = res.getError<QString>();
        reportFailure(QStringLiteral("Failed to create DM"), reason);
    }
    // The conversation_created event surfaces via the push subscription — the
    // appliers handle the UI side from there.
}

// Start something with someone. The verb is remembered, not sent: the room has
// to exist before anything can be said in it, so the activity acts on
// conversation_created. That is also what makes choosing it up front worth
// doing — "ask to be paid" opens a room that has already asked.
void ChatBackend::startActivity(QString verb, QString peerAddress)
{
    m_pendingVerb = verb;
    createConversation(peerAddress);
}

void ChatBackend::createGroupConversation(QString name, QString description)
{
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady()) {
        report(QStringLiteral("Failed to create group: chat is not online"));
        return;
    }

    const LogosResult res = modules().chat_module.create_group_conversation(name, description);
    if (!res.success) {
        const QString reason = res.getError<QString>();
        reportFailure(QStringLiteral("Failed to create group"), reason);
    }
    // The group starts with only this member; conversation_created selects it.
    // Members are added afterwards from the members panel.
}

void ChatBackend::addGroupMember(QString conversationId, QString peerAddress)
{
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady()) {
        report(QStringLiteral("Failed to add member: chat is not online"));
        return;
    }
    if (conversationId.isEmpty()) {
        report(QStringLiteral("Failed to add member: no conversation selected"));
        return;
    }
    if (peerAddress.isEmpty()) {
        report(QStringLiteral("Failed to add member: address cannot be empty"));
        return;
    }

    const LogosResult res = modules().chat_module.add_group_member(conversationId, peerAddress);
    if (!res.success) {
        const QString reason = res.getError<QString>();
        reportFailure(QStringLiteral("Failed to add member"), reason);
        return;
    }
    // The commit is async, so the peer joins the roster as a pending busy row;
    // the members_changed event reconciles it once committed.
    if (conversationId == currentConversationId())
        refreshMembers();
}

void ChatBackend::sendMessage(QString conversationId, QString content)
{
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady()) {
        report(QStringLiteral("Failed to send message: chat is not online"));
        return;
    }
    if (conversationId.isEmpty() || content.isEmpty()) return;

    const LogosResult res = modules().chat_module.send_message(conversationId, content);
    if (!res.success) {
        const QString reason = res.getError<QString>();
        reportFailure(QStringLiteral("Failed to send message"), reason);
        emit sendFailed(conversationId, content);
    }
    // On success the module emits a message_sent event, which applyMessageSent
    // appends to the model.
}

void ChatBackend::selectConversation(QString conversationId)
{
    // Re-selecting the conversation on screen is a no-op only once its messages
    // are in; while they are not, it is the user's retry.
    if (conversationId == currentConversationId() && conversationId == loadedConversationId())
        return;

    setLoadedConversationId(QString());
    setCurrentConversationId(conversationId);
    syncCurrentConversationMeta();
    m_conversationModel->clearUnread(conversationId);
    const bool loaded = showConversationMessages(conversationId);
    // Reset the roster on every switch: a conversation whose roster we can't
    // fetch right now (offline) must show empty, not the previous conversation's
    // members. refreshMembers then loads the new roster when it can, and keeps
    // the last-known one across a transient offline of the same conversation.
    // User-driven, so its synchronous read is safe here (not in an event callback).
    m_memberModel->clear();
    setMemberCount(0);
    setPendingMemberCount(0);
    setCurrentPeerAddress(QString());
    refreshMembers();
    if (loaded)
        setLoadedConversationId(conversationId);
}

void ChatBackend::refreshMembers()
{
    const QString convoId = currentConversationId();
    if (convoId.isEmpty()) {
        m_memberModel->clear();
        setMemberCount(0);
        setPendingMemberCount(0);
        setCurrentPeerAddress(QString());
        return;
    }
    if (chatStatus() != ChatBackendSimpleSource::Online || !isContextReady())
        return; // can't fetch now; keep the last-known roster

    // Telling our own entry from the others needs our address; recover it here
    // if the online transition could not.
    if (myAddress().isEmpty())
        refreshMyAddress();

    // list_group_members returns [GroupMember], so the typed wrapper is a
    // QVariantList (each element a QVariantMap), like the other record lists.
    const QVariantList members = modules().chat_module.list_group_members(convoId);
    QVector<MemberItem> rows;
    rows.reserve(members.size());
    int committed = 0;
    for (const QVariant& v : members) {
        const QVariantMap record = v.toMap();
        const QString address = record.value(QStringLiteral("address")).toString();
        const bool pending = record.value(QStringLiteral("pending")).toBool();
        // An empty address is the roster's "no confirmed account" signal; keep
        // it — the model renders it as "unknown_account". Only a real account
        // address can be self.
        rows.append({ address, !address.isEmpty() && address == myAddress(), pending });
        if (!pending)
            ++committed;
    }

    m_memberModel->setMembers(rows);
    // Committed roster size only; pending invites appear in the list and are
    // counted separately.
    setMemberCount(committed);
    setPendingMemberCount(static_cast<int>(members.size()) - committed);
    // With our own address unknown every entry looks like the peer, so leave it
    // unset rather than guess.
    setCurrentPeerAddress(myAddress().isEmpty()
                              ? QString()
                              : peerAddressOf(rows, m_conversationModel->isGroupFor(convoId)));
}

void ChatBackend::refreshSessionLogs()
{
    QVariantList published;
    appendRuns(published, QStringLiteral("chat_ui"), m_viewLogPath);
    appendRuns(published, QStringLiteral("chat_module"), m_moduleLogPath);
    setLogRuns(published);
}

// ── event handlers ────────────────────────────────────────────────────────────

void ChatBackend::applyDeliveryState(const QString& state, const QString& detail)
{
    ChatBackendSimpleSource::ChatStatus next = ChatBackendSimpleSource::Stopped;
    if (state == QStringLiteral("online")) {
        next = ChatBackendSimpleSource::Online;
    } else if (state == QStringLiteral("initialising")) {
        next = ChatBackendSimpleSource::Initialising;
    } else if (state == QStringLiteral("error")) {
        next = ChatBackendSimpleSource::Error;
    } else if (state == QStringLiteral("stopped")) {
        next = ChatBackendSimpleSource::Stopped;
    } else {
        return;
    }

    const bool becameOnline =
        next == ChatBackendSimpleSource::Online && chatStatus() != ChatBackendSimpleSource::Online;
    const bool becameError =
        next == ChatBackendSimpleSource::Error && chatStatus() != ChatBackendSimpleSource::Error;

    setChatStatus(next);

    // The connectivity label says only that delivery is in error; what went
    // wrong reaches the user here or not at all.
    if (becameError)
        report(detail.isEmpty() ? QStringLiteral("Delivery error")
                                : QStringLiteral("Delivery error: ") + detail);

    // Events are push-only, so a fresh online transition (reconnect) is our
    // cue to refetch the lists and recover anything missed while offline.
    // Deferred: this runs inside a module event callback and the refetch makes
    // synchronous module reads (see deferToEventLoop).
    if (becameOnline && m_initialSnapshotDone) {
        deferToEventLoop([this] {
            refreshMyAddress();
            rehydrateConversations();
            const QString convoId = currentConversationId();
            if (convoId.isEmpty())
                return;
            // The refetch replaces the thread, so the models stop holding it
            // until the reload lands.
            setLoadedConversationId(QString());
            const bool loaded = showConversationMessages(convoId);
            refreshMembers();
            if (loaded)
                setLoadedConversationId(convoId);
        });
    }
}

void ChatBackend::applyMessageReceived(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    if (convoId.isEmpty()) return;
    const QString content = args.value(1).toString();
    const qint64 ts = args.value(2).toLongLong();
    const QString sender = args.value(3).toString();
    const QDateTime when = msToDateTime(ts);
    const QString preview = content.left(kPreviewMaxChars);

    if (!m_conversationModel->contains(convoId)) {
        // Defensive: ConversationStarted normally lands first with the kind.
        // Add it now and backfill the kind by re-reading the list (deferred:
        // this runs inside a module event callback, see deferToEventLoop).
        m_conversationModel->addConversation(convoId, fallbackDisplayName(convoId), QString(), when, false, preview);
        deferToEventLoop([this] { rehydrateConversations(); });
    } else {
        m_conversationModel->updateLastActivity(convoId, when);
    }
    m_conversationModel->updatePreview(convoId, preview);

    if (convoId == currentConversationId()) {
        m_messageModel->addMessage(shortSenderLabel(sender), content, when, false);
        // Advance the journey with it: an arriving card is how the other side
        // moves this conversation forward.
        noteJourneyMessage(content, false, ts);
        // ...and it may have changed what this conversation is asking of you.
        // Deferred: refreshActions reads every thread (see deferToEventLoop).
        deferToEventLoop([this] { refreshActions(); refreshIntents(); });
        // A message from someone not yet on the roster means the group grew;
        // refetch (deferred: sync module read from inside an event callback).
        if (!sender.isEmpty() && !m_memberModel->contains(sender))
            deferToEventLoop([this] { refreshMembers(); });
    } else {
        m_conversationModel->incrementUnread(convoId);
    }
}

void ChatBackend::applyMessageSent(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    if (convoId.isEmpty()) return;
    const QString content = args.value(1).toString();
    const qint64 ts = args.value(2).toLongLong();
    const QDateTime when = msToDateTime(ts);
    const QString preview = content.left(kPreviewMaxChars);

    if (!m_conversationModel->contains(convoId)) {
        m_conversationModel->addConversation(convoId, fallbackDisplayName(convoId), QString(), when, false, preview);
    } else {
        m_conversationModel->updateLastActivity(convoId, when);
    }
    m_conversationModel->updatePreview(convoId, preview);

    if (convoId == currentConversationId()) {
        m_messageModel->addMessage(QStringLiteral("Me"), content, when, true);
        noteJourneyMessage(content, true, ts);
        deferToEventLoop([this] { refreshActions(); refreshIntents(); });
    }
}

void ChatBackend::applyConversationCreated(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    if (convoId.isEmpty()) return;
    const bool isOutgoing = args.value(1).toBool();
    const QString peerLabel = args.value(2).toString();
    const bool isGroup = args.value(3).toString() == QStringLiteral("group");
    const QString name = args.value(4).toString();
    const QString description = args.value(5).toString();
    const QString displayName =
        name.isEmpty() ? fallbackDisplayName(convoId, peerLabel, isGroup) : name;
    const QDateTime now = QDateTime::currentDateTime();

    // A new conversation is a new row on the home surface. Deferred: this runs
    // inside a module event callback and refreshActions reads every thread.
    deferToEventLoop([this] { refreshActions(); refreshIntents(); });

    if (!m_conversationModel->contains(convoId)) {
        m_conversationModel->addConversation(convoId, displayName, description, now, isGroup, QString());
    } else {
        m_conversationModel->updateDisplayName(convoId, displayName);
        m_conversationModel->updateDescription(convoId, description);
        m_conversationModel->updateLastActivity(convoId, now);
    }

    // Open a conversation we just created, so creating a chat or group lands
    // the user in it. Deferred: selectConversation makes a synchronous module
    // read and this runs inside a module event callback (see deferToEventLoop).
    // The activity the user picked, now that there is a room to do it in.
    // Deferred like the selection below: this runs inside an event callback.
    if (isOutgoing && !m_pendingVerb.isEmpty()) {
        const QString verb = m_pendingVerb;
        m_pendingVerb.clear();
        if (verb == QLatin1String("request"))
            deferToEventLoop([this, convoId] { requestAddress(convoId); });
        else if (verb == QLatin1String("pay"))
            // Paying needs somewhere to pay to, so the first move is the ask.
            deferToEventLoop([this, convoId] { requestAddress(convoId); });
    }

    if (isOutgoing) {
        deferToEventLoop([this, convoId] { selectConversation(convoId); });
    } else if (convoId != currentConversationId()) {
        // Being invited comes with no message of its own, so the unread badge is
        // the only thing marking the new row as unseen.
        m_conversationModel->incrementUnread(convoId);
    }
}

void ChatBackend::applyConversationUpdated(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    // Cheapest correct option: refresh the whole list (the read is cheap and
    // conversation counts are small). Deferred — this runs inside a module event
    // callback (see deferToEventLoop).
    deferToEventLoop([this, convoId] {
        rehydrateConversations();
        // A group update (e.g. a member added) may have grown the roster of the
        // conversation on screen; refetch it.
        if (convoId == currentConversationId() && m_conversationModel->isGroupFor(convoId))
            refreshMembers();
    });
}

void ChatBackend::applyMembersChanged(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    // A commit changed this group's roster; refetch it if it is on screen.
    deferToEventLoop([this, convoId] {
        if (convoId == currentConversationId() && m_conversationModel->isGroupFor(convoId))
            refreshMembers();
    });
}

void ChatBackend::applyConversationDeleted(const QVariantList& args)
{
    const QString convoId = args.value(0).toString();
    if (convoId.isEmpty()) return;

    m_conversationModel->removeConversation(convoId);
    if (convoId == currentConversationId()) {
        setCurrentConversationId(QString());
        setLoadedConversationId(QString());
        syncCurrentConversationMeta();
        m_messageModel->clear();
        // The roster goes with the conversation. Reached with no current
        // conversation, refreshMembers clears it without a module read.
        refreshMembers();
    }
}

QString ChatBackend::peerAddressOf(const QVector<MemberItem>& members, bool isGroup)
{
    if (isGroup)
        return {};
    for (const MemberItem& member : members) {
        if (!member.isSelf && !member.address.isEmpty())
            return member.address;
    }
    return {};
}

QString ChatBackend::fallbackDisplayName(const QString& convoId, const QString& peerLabel,
                                         bool isGroup)
{
    const QString label = peerLabel.isEmpty() ? Identity::shortLabel(convoId) : peerLabel;
    return (isGroup ? QStringLiteral("Group ") : QStringLiteral("DM ")) + label;
}

QString ChatBackend::shortSenderLabel(const QString& sender)
{
    return sender.isEmpty() ? QStringLiteral("Peer") : Identity::shortLabel(sender);
}
