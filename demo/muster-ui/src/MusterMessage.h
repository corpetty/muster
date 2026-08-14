#ifndef MUSTER_MESSAGE_H
#define MUSTER_MESSAGE_H

#include <QJsonDocument>
#include <QJsonObject>
#include <QString>
#include <QVariantMap>

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

// 2 since assets: a card now names the asset or rail it is about, and a v1
// reader has no field to read it from. That reader does not merely miss
// something — it assumes the one rail v1 had, so it would label a public
// account "shielded" and a public payment's receipt "not disclosed". Both are
// lies of exactly the kind this demo exists not to tell, which is what makes
// this a version bump rather than an added field.
//
// Nothing here refuses a v1 card: an older peer's shielded address and receipt
// still read correctly, because the defaults a missing field falls back to are
// v1's single rail. It is the other direction that cannot be made safe, and the
// two peers in this demo are built from one tree.
inline constexpr int kVersion = 2;
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

// "I am in the room." Sent by the side that was *invited*, the moment its
// conversation exists.
//
// It carries nothing, because its arrival is the entire content: it is the
// only evidence the inviter can get that the conversation now has two ends.
//
// Why it has to exist. create_conversation sends a cryptographic invite and
// returns; the peer joins some time later, and nothing tells the inviter when.
// A direct conversation's roster reports both participants from the instant it
// is created and never a pending one (chat_module.lidl), there is no
// per-message delivery state, and members_changed does not fire on the inviter
// when the peer joins -- measured 2026-08-14, no roster read on the inviter for
// the two and a half hours after one did. So a card sent on the inviter's first
// impulse goes to an MLS group of one and is encrypted to an epoch the peer
// will never be in. Not delayed: unreadable, permanently.
//
// Hence a handshake at this layer rather than a guess at that one. The inviter
// holds its first card until this arrives. A peer too old to send one is not
// broken by it -- an unknown type renders as an ordinary bubble, and the
// inviter's wait is bounded, falling back to the ask-by-hand button that has
// always been there.
inline QString conversationReady()
{
    return wrap(QStringLiteral("conversation-ready"));
}

// "Send me an address to pay." Still carries nothing: the ask does not need to
// name an asset, because the answer does, and a request that pinned one down
// would make the payer choose before they know what the payee has.
inline QString addressRequest()
{
    return wrap(QStringLiteral("address-request"));
}

// The reply: somewhere to be paid, and enough about it for the payer to know
// which rails could pay it.
//
//   asset      the payee's holding id ("lez.private", "lez.public")
//   keys       the address itself. Named `keys` because that is what it was
//              when the only address was a shielded key set, and a v1 peer
//              still reads that field; it now carries whatever form the asset
//              uses, and `form` says which.
//   form       Assets::AddressForm — 0 shielded key set, 1 public account id.
//              This is the field a payer filters rails on, so it is what makes
//              a new kind of address payable without the payer being taught
//              about it.
//   assetName  the payee's *own* words for the holding. A payer whose build has
//              never heard of `asset` shows this, attributed — "they called it
//              X" — rather than describing an address it cannot identify.
inline QString addressShare(const QString& asset, const QString& address, int form,
                            const QString& assetName, const QString& label)
{
    return wrap(QStringLiteral("address-share"),
                QJsonObject{{QStringLiteral("asset"), asset},
                            {QStringLiteral("keys"), address},
                            {QStringLiteral("form"), form},
                            {QStringLiteral("assetName"), assetName},
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
// The rail is part of the terms, not a detail of how they get carried out. A
// room agreeing to 100 λ has agreed to a payment that discloses a particular
// set of things about them, and settling it on another rail would settle
// something they did not approve — which is why submitIntent reads this back
// off the thread rather than trusting the view, and pays on the rail named
// here.
inline QString intentPropose(const QString& intentId, const QString& amount,
                             const QString& denom, const QString& rail,
                             const QString& address, const QString& label,
                             int threshold, int members)
{
    return wrap(QStringLiteral("intent-propose"),
                QJsonObject{{QStringLiteral("intentId"), intentId},
                            {QStringLiteral("amount"), amount},
                            {QStringLiteral("denom"), denom},
                            {QStringLiteral("rail"), rail},
                            {QStringLiteral("keys"), address},
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
//
// `discloses` is the rail's own account of what this payment put on the public
// record — `{amount, payer, payee}` — and the receipt carries it rather than a
// flag the reader interprets. The v1 card had a single `shielded` bool, which
// could only describe two of the four rails and described the other two wrongly:
// a shield discloses the payer but not the payee, and neither answer is "all" or
// "none". The bool is still written, as `!payer && !payee`, so a v1 peer reads
// the nearest true thing rather than nothing at all.
inline QString sendReceipt(const QString& amount, const QString& denom, const QString& rail,
                           const QVariantMap& discloses, const QString& tx,
                           const QString& intentId = QString())
{
    const bool nothingDisclosed = !discloses.value(QStringLiteral("payer")).toBool()
        && !discloses.value(QStringLiteral("payee")).toBool()
        && !discloses.value(QStringLiteral("amount")).toBool();
    // "shielded", not "private": the reader is QML, and `private` is a reserved
    // word there — a field named that is a trap for anyone extending this.
    return wrap(QStringLiteral("send-receipt"),
                QJsonObject{{QStringLiteral("amount"), amount},
                            {QStringLiteral("denom"), denom},
                            {QStringLiteral("rail"), rail},
                            {QStringLiteral("discloses"),
                             QJsonObject::fromVariantMap(discloses)},
                            {QStringLiteral("tx"), tx},
                            {QStringLiteral("shielded"), nothingDisclosed},
                            {QStringLiteral("intentId"), intentId}});
}

} // namespace MusterMessage

#endif // MUSTER_MESSAGE_H
