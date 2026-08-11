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
#include "MusterMessage.h"

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
