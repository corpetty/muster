// Where the user is in the transaction, and what happened to get them there.
//
// The app's argument is that a transaction is a thing you do *inside* a
// conversation, so the conversation is the record of it. That means the
// journey is not separate state to maintain — it is a reading of the messages
// that are already there. Rebuilding it from the thread rather than tracking
// it alongside means it cannot drift, survives a restart for free, and is
// correct for a conversation this instance did not start.
//
// The steps are the transaction's stages, not the app's screens:
//   discovery    — no conversation yet; how you reach anyone at all
//   conversation — a private thread exists
//   address      — somewhere to pay has been agreed
//   payment      — value has moved
//
// A step is reached when its evidence appears in the thread, and never
// un-reached, because the thread is append-only.

#include "ChatBackend.h"
#include "Identity.h"
#include "MusterMessage.h"

#include <algorithm>

#include <QJsonDocument>
#include <QJsonObject>

#include "logos_sdk.h"

namespace {

// Rank so a later step is never overwritten by an earlier one arriving out of
// order — a store-node catchup can deliver history in any order.
int rankOf(const QString& step)
{
    if (step == QLatin1String("payment"))
        return 3;
    if (step == QLatin1String("address"))
        return 2;
    if (step == QLatin1String("conversation"))
        return 1;
    return 0; // discovery
}

// The card type in a message, or empty for ordinary text. Mirrors the parse
// MessageDelegate does for rendering; kept in sync by both reading the same
// `muster` tag.
QString cardType(const QString& content)
{
    if (content.isEmpty() || !content.startsWith(QLatin1Char('{')))
        return {};
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    if (!o.contains(MusterMessage::kTag))
        return {};
    return o.value(QStringLiteral("type")).toString();
}

QString amountOf(const QString& content)
{
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    return o.value(QStringLiteral("amount")).toString();
}

} // namespace

void ChatBackend::resetJourney()
{
    m_journeyTrail.clear();
    setJourneyTrail({});
    setJourneyStep(QStringLiteral("discovery"));
}

void ChatBackend::noteJourneyMessage(const QString& content, bool fromSelf, qint64 timestampMs)
{
    const QString type = cardType(content);

    // Any message at all means a private conversation exists, which is the
    // thing discovery was for.
    QString step = QStringLiteral("conversation");
    QString what;

    if (type.isEmpty()) {
        // Ordinary text only establishes the conversation, and only the first
        // one is worth a line in the trail.
        if (rankOf(journeyStep()) >= rankOf(step))
            return;
        what = tr("A private conversation opened");
    } else if (type == QLatin1String("address-request")) {
        what = fromSelf ? tr("You asked where to pay") : tr("They asked where to pay");
    } else if (type == QLatin1String("address-share")) {
        step = QStringLiteral("address");
        what = fromSelf ? tr("You shared a private address")
                        : tr("They shared a private address");
    } else if (type == QLatin1String("send-receipt")) {
        step = QStringLiteral("payment");
        const QString amount = amountOf(content);
        what = fromSelf ? tr("You sent %1 LEZ").arg(amount) : tr("They sent %1 LEZ").arg(amount);
    } else {
        // A card type this build does not know. It still proves a conversation.
        if (rankOf(journeyStep()) >= rankOf(step))
            return;
        what = tr("A private conversation opened");
    }

    m_journeyTrail.append(QVariantMap{{QStringLiteral("step"), step},
                                      {QStringLiteral("what"), what},
                                      {QStringLiteral("atMs"), timestampMs}});
    setJourneyTrail(m_journeyTrail);

    if (rankOf(step) > rankOf(journeyStep()))
        setJourneyStep(step);
}

// ── what each conversation is asking of you ─────────────────────────────
//
// The home surface is a list of actions, not a list of people. What you are
// doing comes first; who you are doing it with is the context for it. That is
// the whole reason to open this app, so it is what the app opens on.
//
// Each conversation's state is read from its own thread, the same way the
// journey is — no second record to keep in step, and correct for a
// conversation this instance did not start.
QVariantMap ChatBackend::actionForMessages(const QVariantList& messages) const
{
    bool peerAsked = false;     // they want somewhere to pay
    bool selfAsked = false;     // we want somewhere to pay
    bool peerShared = false;    // we can pay them
    bool selfShared = false;    // they can pay us
    bool paid = false;          // value has moved, either way
    bool paidBySelf = false;

    for (const QVariant& v : messages) {
        const QVariantMap obj = v.toMap();
        const QString content = obj.value(QStringLiteral("content")).toString();
        const bool fromSelf = obj.value(QStringLiteral("from_self")).toBool();
        const QString type = cardType(content);

        if (type == QLatin1String("address-request")) {
            (fromSelf ? selfAsked : peerAsked) = true;
        } else if (type == QLatin1String("address-share")) {
            if (fromSelf) {
                selfShared = true;
                peerAsked = false;   // answered
            } else {
                peerShared = true;
                selfAsked = false;   // answered
            }
        } else if (type == QLatin1String("send-receipt")) {
            paid = true;
            paidBySelf = fromSelf;
        }
    }

    // Ordered by what the user should do about it. A thing waiting on *you* is
    // the only kind that should pull someone back into an app, so it wins.
    QString state, action, detail;
    if (peerAsked) {
        state = QStringLiteral("needs-you");
        action = tr("They need an address");
        detail = tr("Share yours to be paid");
    } else if (peerShared && !paid) {
        state = QStringLiteral("needs-you");
        action = tr("Ready to pay");
        detail = tr("They shared a private address");
    } else if (paid) {
        state = QStringLiteral("settled");
        action = paidBySelf ? tr("Paid") : tr("Got paid");
        detail = tr("Private, both ends");
    } else if (selfAsked) {
        state = QStringLiteral("waiting");
        action = tr("Waiting for an address");
        detail = tr("You asked where to pay");
    } else if (selfShared) {
        state = QStringLiteral("waiting");
        action = tr("Waiting to be paid");
        detail = tr("You shared an address");
    } else {
        state = QStringLiteral("idle");
        action = tr("Talking");
        detail = QString();
    }

    return QVariantMap{{QStringLiteral("state"), state},
                       {QStringLiteral("action"), action},
                       {QStringLiteral("detail"), detail}};
}

void ChatBackend::refreshActions()
{
    if (!m_moduleInitialised)
        return;

    logos::CallError err;
    const QVariantList convos = modules().chat_module.list_conversations(&err);
    if (!err.ok())
        return;

    QVariantList rows;
    for (const QVariant& v : convos) {
        const QVariantMap c = v.toMap();
        const QString convoId = c.value(QStringLiteral("convo_id")).toString();
        if (convoId.isEmpty())
            continue;

        logos::CallError readErr;
        const QVariantList msgs = modules().chat_module.get_messages(convoId, &readErr);
        // A conversation we cannot read is still one the user has; show it as
        // itself rather than dropping it off the list.
        QVariantMap row = readErr.ok() ? actionForMessages(msgs)
                                       : QVariantMap{{QStringLiteral("state"), QStringLiteral("idle")},
                                                     {QStringLiteral("action"), tr("Talking")},
                                                     {QStringLiteral("detail"), QString()}};

        const bool isGroup = c.value(QStringLiteral("kind")).toString() == QLatin1String("group");
        const QString name = c.value(QStringLiteral("name")).toString().isEmpty()
            ? (c.value(QStringLiteral("nickname")).toString().isEmpty()
                   ? fallbackDisplayName(convoId, QString(), isGroup)
                   : c.value(QStringLiteral("nickname")).toString())
            : c.value(QStringLiteral("name")).toString();

        row.insert(QStringLiteral("conversationId"), convoId);
        row.insert(QStringLiteral("displayName"), name);
        row.insert(QStringLiteral("avatarInitials"), Identity::initials(convoId));
        row.insert(QStringLiteral("avatarRamp"), Identity::avatarRamp(convoId));
        row.insert(QStringLiteral("lastActivityMs"),
                   c.value(QStringLiteral("last_activity_ms")).toLongLong());
        rows.append(row);
    }

    // needs-you, then in flight, then done, then idle chatter — and most
    // recent first inside each band.
    const auto rank = [](const QString& s) {
        if (s == QLatin1String("needs-you")) return 0;
        if (s == QLatin1String("waiting")) return 1;
        if (s == QLatin1String("settled")) return 2;
        return 3;
    };
    std::sort(rows.begin(), rows.end(), [&rank](const QVariant& a, const QVariant& b) {
        const QVariantMap ma = a.toMap(), mb = b.toMap();
        const int ra = rank(ma.value(QStringLiteral("state")).toString());
        const int rb = rank(mb.value(QStringLiteral("state")).toString());
        if (ra != rb)
            return ra < rb;
        return ma.value(QStringLiteral("lastActivityMs")).toLongLong()
             > mb.value(QStringLiteral("lastActivityMs")).toLongLong();
    });

    setActions(rows);
}

void ChatBackend::rebuildJourney(const QVariantList& messages)
{
    resetJourney();
    for (const QVariant& v : messages) {
        const QVariantMap obj = v.toMap();
        noteJourneyMessage(obj.value(QStringLiteral("content")).toString(),
                           obj.value(QStringLiteral("from_self")).toBool(),
                           obj.value(QStringLiteral("timestamp_ms")).toLongLong());
    }
}
