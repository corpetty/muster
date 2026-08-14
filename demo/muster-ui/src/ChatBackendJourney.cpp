// Where the user is in the transaction, and what happened to get them there.
//
// The app's argument is that a transaction is a thing you do *inside* a
// conversation, so the conversation is the record of it. That means the
// journey is not separate state to maintain — it is a reading of the messages
// that are already there. Rebuilding it from the thread rather than tracking
// it alongside means it cannot drift, costs nothing to rebuild, and is
// correct for a conversation this instance did not start.
//
// It does *not* survive a restart, though this comment used to say so:
// chat_module holds conversations in memory only, so after a restart there is
// no thread to read and the peer has a new address entirely. That is upstream
// (logos-messaging/libchat#28) — see poc/BUG-chat-module-state-not-persisted.md.
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

#include <QCoreApplication>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>

#include "logos_sdk.h"

namespace {

// Rank so a later step is never overwritten by an earlier one arriving out of
// order — a store-node catchup can deliver history in any order.
int rankOf(const QString& step)
{
    if (step == QLatin1String("payment"))
        return 4;
    // Agreeing *who must agree* sits between having somewhere to pay and
    // paying. A room that never proposes anything skips it, which is why the
    // rank is a floor and not a sequence to walk.
    if (step == QLatin1String("authorization"))
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

// "100 LEZ", off the card. The denom is the card's own, not this build's idea
// of one: the trail is a record of what happened, and an asset we do not
// recognise is still a thing that was proposed and should read as what its
// proposer called it. A card with no denom is a v1 card, when there was one.
QString amountOf(const QString& content)
{
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    const QString amount = o.value(QStringLiteral("amount")).toString();
    const QString denom = o.value(QStringLiteral("denom")).toString();
    return QStringLiteral("%1 %2").arg(amount, denom.isEmpty() ? QStringLiteral("LEZ") : denom);
}

// What the sharer called the holding they shared. Their words, because they are
// the ones who know what it is; "private" for a v1 card, which is what v1 meant.
QString assetNameOf(const QString& content)
{
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    const QString name = o.value(QStringLiteral("assetName")).toString();
    return name.isEmpty() ? QCoreApplication::translate("ChatBackend", "private") : name;
}

// How the payment discloses itself, in the few words a trail line can hold, or
// empty for a rail this build does not know. The journey is the honest summary
// of the lifecycle, so the step that crossed the boundary should say which
// crossing it was rather than implying the private one throughout.
QString railNoteOf(const QString& content, const QString& fallback)
{
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    const QJsonObject d = o.value(QStringLiteral("discloses")).toObject();
    if (d.isEmpty())
        return fallback;
    const bool amount = d.value(QStringLiteral("amount")).toBool();
    const bool payer = d.value(QStringLiteral("payer")).toBool();
    const bool payee = d.value(QStringLiteral("payee")).toBool();
    if (!amount && !payer && !payee)
        return QCoreApplication::translate("ChatBackend", "nothing disclosed");
    if (amount && payer && payee)
        return QCoreApplication::translate("ChatBackend", "all of it on the public record");
    if (payer)
        return QCoreApplication::translate("ChatBackend", "you named, they were not");
    return QCoreApplication::translate("ChatBackend", "they named, you were not");
}

} // namespace

// A payment receipt from somebody else.
//
// Deliberately the whole of what we read off it. A receipt is authenticated in
// the room — chat_module binds it to its author — but the zone checks none of
// it, so its amount, its rail and its transaction id are all claims by the
// sender. Believing any of them would let a peer make this wallet display a
// payment nobody made, which is the one thing this app must never do.
//
// So the only question asked here is "did somebody say a payment happened",
// and the only thing done with the answer is to go and look at our own wallet.
// See ChatBackend::scanForIncomingPayment.
bool ChatBackend::isIncomingReceipt(const QString& content) const
{
    return cardType(content) == QLatin1String("send-receipt");
}

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
    } else if (type == QLatin1String("conversation-ready")) {
        // Both ends exist, which is what "conversation" means here. Worth a
        // line because it is the moment the room became usable, and because the
        // card that follows it was waiting on this one.
        if (rankOf(journeyStep()) >= rankOf(step))
            return;
        what = fromSelf ? tr("You joined") : tr("They joined");
    } else if (type == QLatin1String("address-request")) {
        what = fromSelf ? tr("You asked where to pay") : tr("They asked where to pay");
    } else if (type == QLatin1String("address-share")) {
        step = QStringLiteral("address");
        // Which address, because there is more than one kind now and "a private
        // address" was only true while there was one.
        const QString assetName = assetNameOf(content);
        what = fromSelf ? tr("You shared a %1 address").arg(assetName)
                        : tr("They shared a %1 address").arg(assetName);
    } else if (type == QLatin1String("intent-propose")) {
        step = QStringLiteral("authorization");
        const QString amount = amountOf(content);
        what = fromSelf ? tr("You proposed paying %1").arg(amount)
                        : tr("They proposed paying %1").arg(amount);
    } else if (type == QLatin1String("intent-approve")) {
        step = QStringLiteral("authorization");
        what = fromSelf ? tr("You approved it") : tr("They approved it");
    } else if (type == QLatin1String("intent-drop")) {
        step = QStringLiteral("authorization");
        what = fromSelf ? tr("You dropped the proposal") : tr("They dropped the proposal");
    } else if (type == QLatin1String("send-receipt")) {
        step = QStringLiteral("payment");
        const QString amount = amountOf(content);
        const QString note = railNoteOf(content, tr("nothing disclosed"));
        what = fromSelf ? tr("You sent %1 — %2").arg(amount, note)
                        : tr("They sent %1 — %2").arg(amount, note);
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

// ── what of this wallet is in play in one conversation ──────────────────
//
// A muster is a slice of the wallet, not the whole of it, and which slice is
// not a setting anyone picks — it is what this thread has already done. So it
// is read off the thread, like the journey and the home row: correct for a
// conversation this instance did not start, and unable to drift from the
// messages that are the record of it.
//
// Only what *we* put in. A peer's shared address is their holding; listing it
// among ours would describe their wallet in our wallet's words, which is the
// kind of quiet lie this build exists not to tell.
//
// A v1 card names no rail, so a payment made by an older peer's build cannot
// be attributed to one of our holdings and is left out rather than guessed at.
// The two peers in this demo are built from one tree, so that case is a
// statement about the fold's honesty rather than one anybody will hit.
QVariantList ChatBackend::conversationAssetsForMessages(const QVariantList& messages) const
{
    // Holding id → why it is here. A holding can be both shared and paid from;
    // the strongest reason wins, so the row says the most this thread did with
    // it rather than the most recent.
    QHash<QString, int> rank;
    QHash<QString, QString> why;

    const auto note = [&rank, &why](const QString& holdingId, int r, const QString& text) {
        if (holdingId.isEmpty() || rank.value(holdingId, 0) >= r)
            return;
        rank.insert(holdingId, r);
        why.insert(holdingId, text);
    };

    for (const QVariant& v : messages) {
        const QVariantMap obj = v.toMap();
        if (!obj.value(QStringLiteral("from_self")).toBool())
            continue;
        const QJsonObject card =
            MusterMessage::cardOf(obj.value(QStringLiteral("content")).toString());
        if (card.isEmpty())
            continue;
        const QString type = card.value(QStringLiteral("type")).toString();

        if (type == QLatin1String("address-share")) {
            note(card.value(QStringLiteral("asset")).toString(), 1,
                 tr("You shared this address here"));
            continue;
        }
        if (type != QLatin1String("intent-propose") && type != QLatin1String("send-receipt"))
            continue;

        // The rail names the holding it spends, which is how a payment says
        // which part of the wallet this room reached into.
        const Assets::Rail* rail = railById(card.value(QStringLiteral("rail")).toString());
        if (!rail)
            continue;
        if (type == QLatin1String("send-receipt"))
            note(rail->source, 3, tr("You paid from this here"));
        else
            note(rail->source, 2, tr("You proposed paying from this"));
    }

    // The catalogue's order, so the slice reads as a subset of the wallet
    // rather than as its own differently-sorted list.
    QVariantList rows;
    for (const Assets::Holding& h : m_holdings) {
        if (!why.contains(h.id))
            continue;
        rows.append(QVariantMap{{QStringLiteral("id"), h.id},
                                {QStringLiteral("why"), why.value(h.id)}});
    }
    return rows;
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

    // A live proposal outranks the address dance: once a room is deciding
    // something, that is what the room is about, and the ask that led to it is
    // answered by definition.
    const QVariantMap live = liveIntentForMessages(messages);
    if (!live.isEmpty()) {
        const QString intentState = live.value(QStringLiteral("state")).toString();
        const int approvals = live.value(QStringLiteral("approvals")).toInt();
        const int threshold = live.value(QStringLiteral("threshold")).toInt();
        const bool mine = live.value(QStringLiteral("proposedByMe")).toBool();
        const bool approved = live.value(QStringLiteral("approvedByMe")).toBool();
        const QString count = tr("%1 of %2 approved").arg(approvals).arg(threshold);

        QString s, a, d;
        if (intentState == QLatin1String("ready") && mine) {
            s = QStringLiteral("needs-you");
            a = tr("Ready to pay");
            d = count;
        } else if (intentState == QLatin1String("ready")) {
            s = QStringLiteral("waiting");
            a = tr("Waiting to be paid");
            d = count;
        } else if (!approved) {
            // The only row that is genuinely an ask of this person.
            s = QStringLiteral("needs-you");
            a = tr("Needs your approval");
            d = count;
        } else {
            s = QStringLiteral("waiting");
            a = tr("Waiting on approvals");
            d = count;
        }
        return QVariantMap{{QStringLiteral("state"), s},
                           {QStringLiteral("action"), a},
                           {QStringLiteral("detail"), d}};
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
