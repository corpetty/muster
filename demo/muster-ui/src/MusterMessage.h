#ifndef MUSTER_MESSAGE_H
#define MUSTER_MESSAGE_H

#include <QJsonDocument>
#include <QJsonObject>
#include <QString>

// The structured cards Muster sends *inside* a chat message.
//
// chat_module's send_message carries an opaque tstr, so a card is JSON in that
// string and inherits the conversation's encryption exactly as plain text does.
// We add no transport and no crypto of our own — which is the point, and what
// the visibility panel claims on screen.
//
// A receiver that does not know a `type` renders the message as an ordinary
// bubble (see MessageDelegate.qml), so the vocabulary can grow without
// breaking a peer running an older build. `v` is the schema version; bump it
// only for a change that an old peer could misread rather than merely ignore.
namespace MusterMessage {

inline constexpr int kVersion = 1;
// Marks a message as ours. Present on every card and on nothing else.
inline const QString kTag = QStringLiteral("muster");

// The card in a message, or an empty object for ordinary text. Every reader
// goes through this, so there is one answer to "is this a card" rather than a
// parse per caller drifting apart. The QML side does the same check by hand in
// MessageDelegate, which is the one copy we cannot share.
inline QJsonObject cardOf(const QString& content)
{
    if (content.isEmpty() || !content.startsWith(QLatin1Char('{')))
        return {};
    const QJsonObject o = QJsonDocument::fromJson(content.toUtf8()).object();
    if (!o.contains(kTag))
        return {};
    return o;
}

inline QString wrap(const QString& type, QJsonObject body = {})
{
    body.insert(kTag, kVersion);
    body.insert(QStringLiteral("type"), type);
    return QString::fromUtf8(QJsonDocument(body).toJson(QJsonDocument::Compact));
}

// "Send me an address to pay." Carries nothing else: the chain is implied by
// the demo's single settlement path, and adding a field we don't branch on
// would be a claim the code doesn't keep.
inline QString addressRequest()
{
    return wrap(QStringLiteral("address-request"));
}

// The reply: a *shielded* receiving key set, produced by
// lez_core.get_private_account_keys. It names an account nobody but the sender
// and receiver can associate with a payment — the reason this is worth a card
// rather than a pasted string.
inline QString addressShare(const QString& keysJson, const QString& label)
{
    return wrap(QStringLiteral("address-share"),
                QJsonObject{{QStringLiteral("keys"), keysJson},
                            {QStringLiteral("label"), label}});
}

// ── the intent spine ─────────────────────────────────────────────────────
//
// A proposal, the approvals it collects, and the drop that abandons it. These
// three make a payment something a group agrees to before anyone moves money,
// which is the difference between a wallet and a room.
//
// What they are and are not: an approval is *authenticated* — chat_module
// binds every message to its author, so nobody in the room can forge or replay
// another member's approval. It is not *authorization*: the zone knows nothing
// about a threshold, and the account that finally pays is single-key. "2 of 3"
// is enforced by the room, and the thread is the only record that it was. The
// visibility panel says exactly this at the `authorization` step; do not let a
// label here imply more than that claim does.
//
// `intentId` ties the family together. It is minted by the proposer and echoed
// by every approval, drop and receipt, so state is a fold over the thread and
// nothing has to be kept in step separately.
inline QString intentPropose(const QString& intentId, const QString& amount,
                             const QString& keysJson, const QString& label,
                             int threshold, int members)
{
    return wrap(QStringLiteral("intent-propose"),
                QJsonObject{{QStringLiteral("intentId"), intentId},
                            {QStringLiteral("amount"), amount},
                            {QStringLiteral("denom"), QStringLiteral("LEZ")},
                            {QStringLiteral("keys"), keysJson},
                            {QStringLiteral("label"), label},
                            // Both are frozen at propose time so the card keeps
                            // reading "2 of 3" even after the roster changes.
                            {QStringLiteral("threshold"), threshold},
                            {QStringLiteral("members"), members}});
}

// Carries nothing but the id: *who* approved is the message's own author, which
// is the one part of this we don't have to take on trust.
inline QString intentApprove(const QString& intentId)
{
    return wrap(QStringLiteral("intent-approve"),
                QJsonObject{{QStringLiteral("intentId"), intentId}});
}

inline QString intentDrop(const QString& intentId, const QString& reason)
{
    return wrap(QStringLiteral("intent-drop"),
                QJsonObject{{QStringLiteral("intentId"), intentId},
                            {QStringLiteral("reason"), reason}});
}

// Posted by the sender once the zone accepts the transfer. `tx` is whatever
// the zone returned; it is shown, not trusted — the receiver's balance is the
// thing that settles the question.
//
// `intentId` is empty for a direct send and set when the payment closes a
// proposal, which is what moves that intent to `final` in the fold.
inline QString sendReceipt(const QString& amount, const QString& tx, bool privatePath,
                           const QString& intentId = QString())
{
    // "shielded", not "private": the reader is QML, and `private` is a reserved
    // word there — a field named that is a trap for anyone extending this.
    return wrap(QStringLiteral("send-receipt"),
                QJsonObject{{QStringLiteral("amount"), amount},
                            {QStringLiteral("denom"), QStringLiteral("LEZ")},
                            {QStringLiteral("tx"), tx},
                            {QStringLiteral("shielded"), privatePath},
                            {QStringLiteral("intentId"), intentId}});
}

} // namespace MusterMessage

#endif // MUSTER_MESSAGE_H
