#ifndef ASSETS_H
#define ASSETS_H

// What this wallet can hold, and the ways it can pay.
//
// These are two tables, not one, and keeping them apart is the whole point.
// The first build had a single hardcoded path — shielded λ to shielded λ — and
// every surface downstream was written against it: a card that said "private
// account", a dialog titled "Send LEZ", a receipt that assumed nothing was
// disclosed. Adding a second way to pay meant editing all of them. So:
//
//   Holding — a balance this wallet has. Where it lives, how to read it, and
//             what address a peer would pay it at. One entry per place money
//             can sit.
//   Rail    — a way to move value. Which holding it spends, what form of
//             address it needs at the other end, and *what the chain learns*.
//             One entry per (source, destination) pair the zone supports.
//
// A new asset is a Holding. A new way to pay it is a Rail. Everything else —
// the wallet card, the address cards, the send and propose dialogs, the intent
// fold, the receipt, the visibility panel — reads these tables and needs no
// edit. That is the test for whether an addition here is finished: if a
// surface had to change, this file is not carrying enough.
//
// Both tables are built in ChatBackendAssets.cpp, where the behaviours can be
// lambdas over the backend that owns the zone client.

#include <QString>
#include <functional>

#include "Zone.h"

namespace Assets {

// The shape of a destination. A rail can only pay an address of the form it
// names, which is what stops a shielded key set being handed to a public
// transfer — and what lets the send dialog offer exactly the rails that can
// actually pay the card in front of it.
enum class AddressForm {
    // A JSON key set from get_private_account_keys. Names a shielded account;
    // the only thing on-chain that can be paid without naming who.
    ShieldedKeys,
    // A hex account id. A public account, visible to anyone reading the zone.
    AccountId,
};

// What a payment on a rail puts on the public record. Three facts, because
// these are the three the receipt and the visibility panel both ask about, and
// they must give the same answer — so they read the same struct rather than
// each carrying its own prose.
//
// "That it happened, and when" is disclosed by every rail there is, so it is
// not a field: it is the floor, and the panel says so once.
struct Disclosure {
    bool amount = true;
    bool payer = true;
    bool payee = true;

    // For the card that has to say this in three words.
    bool nothing() const { return !amount && !payer && !payee; }
    bool everything() const { return amount && payer && payee; }
};

// Reports the outcome of something that moves value. Every rail's send and
// every holding's claim answers through this, so a caller never has to know
// which zone method ran.
using Done = std::function<void(Zone::Result)>;

// ── a balance ────────────────────────────────────────────────────────────
struct Holding {
    // Stable, and it goes on the wire in an address-share card. Never rename
    // one: a peer on an older build reads it.
    QString id;
    // What it is called on screen, and the unit its balance is counted in.
    QString name;
    QString denom;
    // Where the money actually is, in the fewest words that are true —
    // "shielded, in the zone" / "on the zone's public record". Shown under the
    // balance, because a number with no location is the thing that made the
    // first build confusing.
    QString sourceNote;

    // Asks the zone what this holding is worth, as the decimal string the zone
    // returns. Slow — some of these are a sequencer round trip — so it is run
    // by a refresh and cached, never called to paint a frame. An empty answer
    // means not read yet, which is not the same as zero and must not be
    // rendered as one.
    std::function<QString()> readBalance;
    // The payload a peer needs to pay this holding, or null when there is
    // nothing to share. Cached on the same pass as the balance. `canReceive` is
    // derived from this rather than declared beside it, so a holding cannot
    // claim an address it does not have.
    std::function<QString()> readReceiveAddress;
    AddressForm addressForm = AddressForm::ShieldedKeys;
    // Moves this holding's balance somewhere spendable, for a balance that is
    // owed rather than held. Null for a holding that needs no such step.
    std::function<void(quint64, Done)> claim;
    // What the button for that claim says. Only read when `claim` is set.
    QString claimVerb;

    bool canReceive() const { return bool(readReceiveAddress); }
    bool canClaim() const { return bool(claim); }
};

// ── a way to pay ─────────────────────────────────────────────────────────
struct Rail {
    // Stable, and it goes on the wire in a proposal and a receipt.
    QString id;
    // Named for what it does to the money, not for the method it calls:
    // "Private → private", "Into the open".
    QString name;
    // One sentence at the moment of payment. This is the claim the send dialog
    // makes, so it has to be true of `discloses` — the two sit together here
    // for exactly that reason.
    QString promise;

    // The Holding::id this rail spends. The dialog shows its balance, because
    // what you can afford depends on which rail you pick.
    QString source;
    // The form of address it can pay.
    AddressForm payTo = AddressForm::ShieldedKeys;
    QString denom;

    Disclosure discloses;
    // The key into VisibilityClaims.qml. A rail with no claim is not offered —
    // enforced where the table is read, not by remembering to. The demo's rule
    // is that every claim on screen is true of the code that ran; a rail with
    // nowhere to say what it leaks cannot keep that rule, so it does not ship.
    QString claimId;

    // Null makes the rail unsendable, which is how a rail can exist in the
    // catalogue — named, with its disclosure honest — before it can be used.
    std::function<void(const QString& to, quint64 amount, Done)> send;

    bool canSend() const { return bool(send) && !claimId.isEmpty(); }
};

} // namespace Assets

#endif // ASSETS_H
