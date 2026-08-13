// A payment the room agrees to before anyone moves money.
//
// The three cards — propose, approve, drop — plus the receipt that closes one
// are folded into intents here. As with the journey, there is no intent state
// kept beside the thread: `state = reduce(messages)`, so a peer that was
// offline for the whole exchange reads the same result as one that watched it,
// a restart costs nothing, and nothing can drift out of step with what is on
// screen. The real client makes that a signed, hash-linked log (root
// CLAUDE.md, invariant 4); here it is a fold over chat_module's transcript,
// which is a weaker thing and is claimed as one.
//
// What an approval is: chat_module binds every message to its author, so an
// approval cannot be forged or replayed by anyone else in the room, and the
// count on the card is a real count of real members. What it is not: a
// signature the zone will check. The account that finally pays is single-key,
// so the threshold is enforced by the room and the thread is the only record
// that it was honoured. The `authorization` step in VisibilityClaims says so
// on screen; keep any wording here inside that claim.
//
// Two passes, not one, because a store-node catchup can deliver an approval
// before the proposal it belongs to. The first pass finds proposals; the
// second applies everything that references one. Out-of-order delivery then
// converges on the same state as in-order, which is the property that makes
// the fold safe to run on every message.

#include "ChatBackend.h"
#include "Identity.h"
#include "MusterMessage.h"

#include <QJsonObject>
#include <QSet>
#include <QUuid>
#include <QVector>

#include "logos_sdk.h"

namespace {

// One proposal, mid-fold. `approvers` keeps insertion order so the slots fill
// left to right in the order people actually approved; `seen` is what makes a
// second approval from the same member not a second approval.
struct Intent {
    QString intentId;
    QString amount;
    QString denom;
    // The rail the room agreed to, off the card. Not resolved to this build's
    // catalogue here: a proposal may name a rail we have never heard of, and
    // the honest reading of that is "they proposed something we cannot describe",
    // not silently substituting one we do know.
    QString rail;
    QString keys;
    QString label;
    int threshold = 1;
    int members = 1;
    QString proposer;
    bool proposedByMe = false;
    QVector<QString> approvers;
    QSet<QString> seen;
    bool dropped = false;
    QString reason;
    QString tx;
    bool paid = false;
    qint64 atMs = 0;
};

// Who wrote a message. `from_self` is authoritative for our own — a message we
// sent may come back without the sender field filled in — and the sender
// address is what names anyone else.
QString authorOf(const QVariantMap& msg, const QString& self)
{
    const bool fromSelf = msg.value(QStringLiteral("from_self")).toBool();
    const QString sender = msg.value(QStringLiteral("sender")).toString();
    if (fromSelf && !self.isEmpty())
        return self;
    return fromSelf ? QStringLiteral("self") : sender;
}

} // namespace

// ── where a payee address came from ──────────────────────────────────────
//
// The room is the only thing here that can vouch for an address. `chat_module`
// binds every message to its author, so an address that arrived in an
// address-share card in this conversation is one a named peer put here — and
// an address that did not is a string some view handed down, which is not a
// provenance however plausible it looks.
//
// Our own shares are deliberately not an answer. Paying an address back to
// ourselves because we once published it is not a payee the room named, and
// counting it would let a view route a payment to us and still pass the check.
//
// First occurrence wins: the question is when the address entered the room, and
// a peer re-sharing the same one later does not change that.
QVariantMap ChatBackend::addressOriginForMessages(const QVariantList& messages,
                                                  const QString& address) const
{
    if (address.isEmpty())
        return {};

    const QString self = myAddress();
    for (const QVariant& v : messages) {
        const QVariantMap msg = v.toMap();
        const QJsonObject card =
            MusterMessage::cardOf(msg.value(QStringLiteral("content")).toString());
        if (card.value(QStringLiteral("type")).toString() != QLatin1String("address-share"))
            continue;
        if (msg.value(QStringLiteral("from_self")).toBool())
            continue;
        if (card.value(QStringLiteral("keys")).toString() != address)
            continue;

        return QVariantMap{
            {QStringLiteral("sender"), authorOf(msg, self)},
            {QStringLiteral("atMs"), msg.value(QStringLiteral("timestamp_ms")).toLongLong()},
            {QStringLiteral("assetName"), card.value(QStringLiteral("assetName")).toString()},
        };
    }
    return {};
}

QVariantList ChatBackend::intentsForMessages(const QVariantList& messages) const
{
    const QString self = myAddress();

    QVector<QString> order;
    QHash<QString, Intent> byId;

    // Pass one: the proposals. A repeated id is ignored rather than replacing
    // the first, so a duplicated delivery cannot rewrite an intent's terms.
    for (const QVariant& v : messages) {
        const QVariantMap msg = v.toMap();
        const QJsonObject card = MusterMessage::cardOf(msg.value(QStringLiteral("content")).toString());
        if (card.value(QStringLiteral("type")).toString() != QLatin1String("intent-propose"))
            continue;
        const QString id = card.value(QStringLiteral("intentId")).toString();
        if (id.isEmpty() || byId.contains(id))
            continue;

        Intent in;
        in.intentId = id;
        in.amount = card.value(QStringLiteral("amount")).toString();
        in.denom = card.value(QStringLiteral("denom")).toString();
        // A v1 card has no rail, and v1 had exactly one — so that is the only
        // thing a missing field can honestly mean.
        in.rail = card.value(QStringLiteral("rail")).toString();
        if (in.rail.isEmpty())
            in.rail = QStringLiteral("lez.private");
        in.keys = card.value(QStringLiteral("keys")).toString();
        in.label = card.value(QStringLiteral("label")).toString();
        in.threshold = qMax(1, card.value(QStringLiteral("threshold")).toInt(1));
        in.members = qMax(1, card.value(QStringLiteral("members")).toInt(1));
        in.proposer = authorOf(msg, self);
        in.proposedByMe = msg.value(QStringLiteral("from_self")).toBool();
        in.atMs = msg.value(QStringLiteral("timestamp_ms")).toLongLong();
        // Proposing is approving: you do not ask the room for something you
        // are not for. It also makes a 1-of-N proposal ready on arrival, which
        // is the honest reading of a threshold of one.
        in.approvers.append(in.proposer);
        in.seen.insert(in.proposer);

        byId.insert(id, in);
        order.append(id);
    }

    // Pass two: everything that refers to a proposal. Anything naming an id we
    // never saw is dropped on the floor — it will apply on the next fold, once
    // catchup has delivered the proposal too.
    for (const QVariant& v : messages) {
        const QVariantMap msg = v.toMap();
        const QJsonObject card = MusterMessage::cardOf(msg.value(QStringLiteral("content")).toString());
        const QString type = card.value(QStringLiteral("type")).toString();
        const QString id = card.value(QStringLiteral("intentId")).toString();
        if (id.isEmpty() || !byId.contains(id))
            continue;
        Intent& in = byId[id];

        if (type == QLatin1String("intent-approve")) {
            const QString who = authorOf(msg, self);
            if (who.isEmpty() || in.seen.contains(who))
                continue;
            in.seen.insert(who);
            in.approvers.append(who);
        } else if (type == QLatin1String("intent-drop")) {
            in.dropped = true;
            in.reason = card.value(QStringLiteral("reason")).toString();
        } else if (type == QLatin1String("send-receipt")) {
            in.paid = true;
            in.tx = card.value(QStringLiteral("tx")).toString();
        }
    }

    QVariantList rows;
    rows.reserve(order.size());
    for (const QString& id : order) {
        const Intent& in = byId.value(id);

        // Dropped beats paid: if both appear, someone abandoned a proposal that
        // was paid anyway, and the room should see the contradiction rather
        // than have it resolved quietly in its favour.
        QString state;
        if (in.dropped)
            state = QStringLiteral("dropped");
        else if (in.paid)
            state = QStringLiteral("final");
        else if (in.approvers.size() >= in.threshold)
            state = QStringLiteral("ready");
        else if (in.approvers.size() > 0)
            state = QStringLiteral("collecting");
        else
            state = QStringLiteral("proposed");

        QVariantList approvers;
        approvers.reserve(in.approvers.size());
        for (const QString& who : in.approvers) {
            const bool isMe = !self.isEmpty() && who == self;
            const QString label = isMe ? tr("You") : shortSenderLabel(who);
            approvers.append(QVariantMap{
                {QStringLiteral("label"), label},
                {QStringLiteral("initials"), Identity::initials(label)},
                {QStringLiteral("ramp"), Identity::avatarRamp(who)},
                {QStringLiteral("isMe"), isMe}});
        }

        // This build's words for the rail, or nothing. A card whose rail we do
        // not know still renders — amount, destination, approvals, all of it —
        // it just does not get a privacy claim attached, because we have no
        // grounds to make one. The view says so rather than leaving the gap to
        // be read as "nothing disclosed".
        const Assets::Rail* rail = railById(in.rail);

        rows.append(QVariantMap{
            {QStringLiteral("intentId"), in.intentId},
            {QStringLiteral("amount"), in.amount},
            {QStringLiteral("denom"), in.denom.isEmpty() ? QStringLiteral("LEZ") : in.denom},
            {QStringLiteral("rail"), in.rail},
            {QStringLiteral("railName"), rail ? rail->name : QString()},
            {QStringLiteral("railPromise"), rail ? rail->promise : QString()},
            {QStringLiteral("discloses"), rail ? disclosureRow(rail->discloses) : QVariantMap{}},
            {QStringLiteral("railKnown"), rail != nullptr},
            {QStringLiteral("keys"), in.keys},
            {QStringLiteral("label"), in.label},
            {QStringLiteral("threshold"), in.threshold},
            {QStringLiteral("members"), in.members},
            {QStringLiteral("proposer"), in.proposer},
            {QStringLiteral("proposedByMe"), in.proposedByMe},
            {QStringLiteral("approvals"), in.approvers.size()},
            {QStringLiteral("approvedByMe"), !self.isEmpty() && in.seen.contains(self)},
            {QStringLiteral("approvers"), approvers},
            {QStringLiteral("state"), state},
            {QStringLiteral("reason"), in.reason},
            {QStringLiteral("tx"), in.tx},
            {QStringLiteral("atMs"), in.atMs}});
    }
    return rows;
}

QVariantMap ChatBackend::liveIntentForMessages(const QVariantList& messages) const
{
    const QVariantList rows = intentsForMessages(messages);
    // The last one still in play. Later proposals win the banner, because the
    // thing a room is about is the thing it most recently decided to be about.
    for (auto it = rows.crbegin(); it != rows.crend(); ++it) {
        const QVariantMap row = it->toMap();
        const QString state = row.value(QStringLiteral("state")).toString();
        if (state != QLatin1String("final") && state != QLatin1String("dropped"))
            return row;
    }
    return {};
}

void ChatBackend::refreshIntents()
{
    const QString convoId = currentConversationId();
    if (!m_moduleInitialised || convoId.isEmpty()) {
        setIntents({});
        setLiveIntent({});
        setConversationAssets({});
        return;
    }

    logos::CallError err;
    const QVariantList msgs = modules().chat_module.get_messages(convoId, &err);
    if (!err.ok())
        return; // keep the last-known set rather than blanking the room

    setIntents(intentsForMessages(msgs));
    setLiveIntent(liveIntentForMessages(msgs));
    // Folded from the same read: a payment made here changes both what the room
    // is deciding and which holding the room has reached into.
    buildAssets();
    setConversationAssets(conversationAssetsForMessages(msgs));
}

void ChatBackend::proposePayment(QString conversationId, QString railId, QString toAddress,
                                 QString label, QString amount, int threshold)
{
    if (conversationId.isEmpty())
        return;
    if (toAddress.isEmpty()) {
        report(QStringLiteral("No address to propose paying — share one first."));
        return;
    }
    buildAssets();
    // Refused at propose time, not at pay time. A room should not spend a round
    // of approvals on terms the proposer's own build cannot settle.
    const Assets::Rail* rail = sendableRailById(railId);
    if (!rail) {
        report(tr("This build cannot pay on that rail%1, so it will not propose it.")
                   .arg(railId.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(railId)));
        return;
    }
    bool ok = false;
    const quint64 value = amount.trimmed().toULongLong(&ok);
    if (!ok || value == 0) {
        report(QStringLiteral("Amount must be a whole number above zero."));
        return;
    }

    // The roster is the honest denominator: a threshold larger than the room
    // could never be met, and one below 1 would make a proposal a send.
    const int members = qMax(1, memberCount());
    const int wanted = qBound(1, threshold, members);
    if (wanted != threshold) {
        report(tr("Threshold adjusted to %1 — the room has %2 members.")
                   .arg(wanted)
                   .arg(members));
    }

    const QString intentId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    sendMessage(conversationId,
                MusterMessage::intentPropose(intentId, QString::number(value), rail->denom,
                                             rail->id, toAddress, label, wanted, members));
}

void ChatBackend::approveIntent(QString conversationId, QString intentId)
{
    if (conversationId.isEmpty() || intentId.isEmpty())
        return;
    sendMessage(conversationId, MusterMessage::intentApprove(intentId));
}

void ChatBackend::dropIntent(QString conversationId, QString intentId, QString reason)
{
    if (conversationId.isEmpty() || intentId.isEmpty())
        return;
    sendMessage(conversationId, MusterMessage::intentDrop(intentId, reason));
}

void ChatBackend::submitIntent(QString conversationId, QString intentId)
{
    if (conversationId.isEmpty() || intentId.isEmpty())
        return;

    logos::CallError err;
    const QVariantList msgs = modules().chat_module.get_messages(conversationId, &err);
    if (!err.ok()) {
        reportFailure(QStringLiteral("Could not read the proposal"),
                      QString::fromStdString(err.message));
        return;
    }

    // Re-read the terms off the thread rather than trusting what the view
    // passed down. The view renders a fold; the payment should be made from
    // one, so a stale card cannot pay the wrong amount to the wrong place.
    for (const QVariant& v : intentsForMessages(msgs)) {
        const QVariantMap in = v.toMap();
        if (in.value(QStringLiteral("intentId")).toString() != intentId)
            continue;

        const QString state = in.value(QStringLiteral("state")).toString();
        if (state != QLatin1String("ready")) {
            report(tr("That proposal is not ready — it is %1.").arg(state));
            return;
        }
        // Only the proposer pays: the money comes out of their account, so no
        // one else's approval can spend it. This is a fact about the account,
        // not a permission we are enforcing on their behalf.
        if (!in.value(QStringLiteral("proposedByMe")).toBool()) {
            report(QStringLiteral("Only whoever proposed this can pay it — "
                                  "it comes out of their account."));
            return;
        }

        // The rail off the thread, like every other term. Paying an agreed
        // proposal on a rail the room did not agree to would disclose things
        // nobody approved disclosing, so it comes from the fold and not from
        // whatever the view or the wallet would otherwise prefer.
        payForIntent(conversationId, in.value(QStringLiteral("rail")).toString(),
                     in.value(QStringLiteral("keys")).toString(),
                     in.value(QStringLiteral("amount")).toString().toULongLong(), intentId);
        return;
    }

    report(QStringLiteral("That proposal is no longer in this conversation."));
}
