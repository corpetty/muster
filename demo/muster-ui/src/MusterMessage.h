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

// Posted by the sender once the zone accepts the transfer. `tx` is whatever
// the zone returned; it is shown, not trusted — the receiver's balance is the
// thing that settles the question.
inline QString sendReceipt(const QString& amount, const QString& tx, bool privatePath)
{
    // "shielded", not "private": the reader is QML, and `private` is a reserved
    // word there — a field named that is a trap for anyone extending this.
    return wrap(QStringLiteral("send-receipt"),
                QJsonObject{{QStringLiteral("amount"), amount},
                            {QStringLiteral("denom"), QStringLiteral("LEZ")},
                            {QStringLiteral("tx"), tx},
                            {QStringLiteral("shielded"), privatePath}});
}

} // namespace MusterMessage

#endif // MUSTER_MESSAGE_H
