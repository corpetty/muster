// The catalogue: every balance this wallet can hold, and every way it can pay.
//
// **This is the file you add an asset to.** One entry in `buildAssets`, and the
// wallet card, the address cards, the send and propose dialogs, the intent
// fold, the receipt and the visibility panel all pick it up. If adding
// something here made you edit a view, the entry is not carrying enough — put
// the missing fact in Assets.h rather than a branch in the view.
//
// Why the behaviours are lambdas built here rather than a table of ids the
// wallet switches on: a switch is a second place to edit for every addition,
// and the two drift. A rail that knows how to send itself cannot be added
// without saying how.
//
// Everything in here runs on the blocking side of the wallet — see
// ChatBackendWallet.cpp for the deferral discipline. `readBalance` and
// `readReceiveAddress` are called on a refresh pass and cached; `send` and
// `claim` are called from an entry point that has already gone async.

#include "ChatBackend.h"
#include "Assets.h"
#include "Zone.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>

#include "logos_sdk.h"

using Assets::AddressForm;
using Assets::Disclosure;
using Assets::Done;
using Assets::Holding;
using Assets::Rail;

namespace {

// The unit every λ rail counts in. One string, so a rename cannot leave half
// the surfaces saying the old thing.
const QString kDenom = QStringLiteral("LEZ");

QString asDecimal(const QString& raw)
{
    const QString t = raw.trimmed();
    return t.isEmpty() ? QString() : t;
}

} // namespace

void ChatBackend::buildAssets()
{
    if (!m_holdings.isEmpty())
        return;

    // ── holdings ─────────────────────────────────────────────────────────

    Holding privateLez;
    privateLez.id = QStringLiteral("lez.private");
    privateLez.name = tr("Private λ");
    privateLez.denom = kDenom;
    privateLez.sourceNote = tr("shielded, in the zone");
    privateLez.addressForm = AddressForm::ShieldedKeys;
    privateLez.readBalance = [this] { return readPrivateBalance(); };
    privateLez.readReceiveAddress = [this]() -> QString {
        if (m_privateAccount.isEmpty())
            return {};
        logos::CallError err;
        const QString keys = modules().lez_core.get_private_account_keys(m_privateAccount, &err);
        return err.ok() ? keys : QString();
    };

    Holding publicLez;
    publicLez.id = QStringLiteral("lez.public");
    publicLez.name = tr("Public λ");
    publicLez.denom = kDenom;
    publicLez.sourceNote = tr("on the zone's public record");
    publicLez.addressForm = AddressForm::AccountId;
    publicLez.readBalance = [this] { return readPublicBalance(); };
    // The account id itself, not its base58 form: a peer's transfer_public
    // takes hex, and handing them something they have to convert is a step to
    // get wrong. The base58 is for showing a human, and no card shows one.
    publicLez.readReceiveAddress = [this]() -> QString { return m_publicAccount; };

    // A balance the zone is holding *for* this wallet rather than one it holds
    // itself — the second place money can arrive, and the reason the wallet
    // card is a list rather than a number. Nothing can be paid from here and
    // nothing can be paid to it: it is claimed into the private holding first,
    // which is a step the user should see rather than one done behind them.
    Holding vaultLez;
    vaultLez.id = QStringLiteral("lez.vault");
    vaultLez.name = tr("Vault λ");
    vaultLez.denom = kDenom;
    vaultLez.sourceNote = tr("held for you, not yet yours to spend");
    vaultLez.readBalance = [this]() -> QString {
        if (m_privateAccount.isEmpty())
            return {};
        logos::CallError err;
        const QString raw = modules().lez_core.get_vault_balance(m_privateAccount, &err);
        return err.ok() ? asDecimal(raw) : QString();
    };
    vaultLez.claimVerb = tr("Claim into private");
    vaultLez.claim = [this](quint64 amount, Done done) {
        // Claimed straight into the shielded account: a vault claim that landed
        // in public would quietly undo the privacy the rest of this is for.
        modules().lez_core.vault_claim_privateAsync(
            m_privateAccount, Zone::amountLe16Hex(amount),
            [done](QString raw) { done(Zone::parse(raw)); }, Timeout(Zone::kProveMs));
    };

    m_holdings = {privateLez, publicLez, vaultLez};

    // ── rails ────────────────────────────────────────────────────────────
    //
    // The four directions the zone supports, which are the same four every
    // stack has and only some of them admit to. Read as a square: the source
    // decides whether the payer is named, the destination decides whether the
    // payee is, and the amount is public unless both ends are shielded. Nothing
    // hides the *fact* of a transfer or its timing — that is the floor, and the
    // visibility panel says so once rather than each rail repeating it.

    Rail privateRail;
    privateRail.id = QStringLiteral("lez.private");
    privateRail.name = tr("Private → private");
    privateRail.promise = tr("The amount and both accounts stay off the public record. The zone "
                             "still learns that a transfer happened, and when.");
    privateRail.source = QStringLiteral("lez.private");
    privateRail.payTo = AddressForm::ShieldedKeys;
    privateRail.denom = kDenom;
    privateRail.discloses = Disclosure{false, false, false};
    privateRail.claimId = QStringLiteral("payment");
    privateRail.send = [this](const QString& to, quint64 amount, Done done) {
        // Not m_privateAccount: money received from someone else is held by a
        // different, discovered account (see readWalletState).
        modules().lez_core.transfer_privateAsync(
            spendFromAccount(), to, Zone::amountLe16Hex(amount),
            [done](QString raw) { done(Zone::parse(raw)); }, Timeout(Zone::kProveMs));
    };

    Rail shieldRail;
    shieldRail.id = QStringLiteral("lez.shield");
    shieldRail.name = tr("Public → private");
    shieldRail.promise = tr("You are named as the payer and the amount is public, because it "
                            "leaves a public account. Who you paid is not: it lands shielded.");
    shieldRail.source = QStringLiteral("lez.public");
    shieldRail.payTo = AddressForm::ShieldedKeys;
    shieldRail.denom = kDenom;
    shieldRail.discloses = Disclosure{true, true, false};
    shieldRail.claimId = QStringLiteral("payment-shield");
    shieldRail.send = [this](const QString& to, quint64 amount, Done done) {
        modules().lez_core.transfer_shieldedAsync(
            m_publicAccount, to, Zone::amountLe16Hex(amount),
            [done](QString raw) { done(Zone::parse(raw)); }, Timeout(Zone::kProveMs));
    };

    Rail deshieldRail;
    deshieldRail.id = QStringLiteral("lez.deshield");
    deshieldRail.name = tr("Private → public");
    deshieldRail.promise = tr("Who you paid is named and the amount is public, because it lands "
                              "in a public account. That you were the payer is not.");
    deshieldRail.source = QStringLiteral("lez.private");
    deshieldRail.payTo = AddressForm::AccountId;
    deshieldRail.denom = kDenom;
    deshieldRail.discloses = Disclosure{true, false, true};
    deshieldRail.claimId = QStringLiteral("payment-deshield");
    deshieldRail.send = [this](const QString& to, quint64 amount, Done done) {
        modules().lez_core.transfer_deshieldedAsync(
            spendFromAccount(), to, Zone::amountLe16Hex(amount),
            [done](QString raw) { done(Zone::parse(raw)); }, Timeout(Zone::kProveMs));
    };

    // The one that leaks everything, offered on purpose. A demo about privacy
    // that only ships the private path is asking to be taken on trust; this is
    // the control, it is fast because it proves nothing, and the difference
    // between its receipt and the shielded one is the lesson.
    Rail publicRail;
    publicRail.id = QStringLiteral("lez.public");
    publicRail.name = tr("Public → public");
    publicRail.promise = tr("Everything is on the public record: the amount, your account and "
                            "theirs. Anyone reading the zone can see all of it, for good.");
    publicRail.source = QStringLiteral("lez.public");
    publicRail.payTo = AddressForm::AccountId;
    publicRail.denom = kDenom;
    publicRail.discloses = Disclosure{true, true, true};
    publicRail.claimId = QStringLiteral("payment-public");
    publicRail.send = [this](const QString& to, quint64 amount, Done done) {
        modules().lez_core.transfer_publicAsync(
            m_publicAccount, to, Zone::amountLe16Hex(amount),
            [done](QString raw) { done(Zone::parse(raw)); }, Timeout(Zone::kProveMs));
    };

    m_rails = {privateRail, shieldRail, deshieldRail, publicRail};
}

// ── lookups ─────────────────────────────────────────────────────────────

const Assets::Holding* ChatBackend::holdingById(const QString& id) const
{
    for (const Holding& h : m_holdings) {
        if (h.id == id)
            return &h;
    }
    return nullptr;
}

const Assets::Rail* ChatBackend::railById(const QString& id) const
{
    for (const Rail& r : m_rails) {
        if (r.id == id)
            return &r;
    }
    return nullptr;
}

const Assets::Rail* ChatBackend::sendableRailById(const QString& id) const
{
    const Rail* rail = railById(id);
    if (!rail)
        return nullptr;
    // The honesty rule, enforced rather than remembered: a rail with no entry
    // in the visibility panel has nowhere to say what it leaks, so it cannot be
    // paid with. Adding a rail without a claim fails here, loudly, instead of
    // shipping a payment the app cannot account for.
    if (rail->claimId.isEmpty()) {
        qWarning() << "[muster] rail" << id << "has no visibility claim and will not be offered";
        return nullptr;
    }
    return rail->canSend() ? rail : nullptr;
}

QString ChatBackend::defaultRailFor(Assets::AddressForm form) const
{
    // The first rail that can pay this form of address, which is the order they
    // are declared in — most private first. A picker opens on the safest thing
    // that works rather than the last thing used.
    for (const Rail& r : m_rails) {
        if (r.payTo == form && r.canSend())
            return r.id;
    }
    return {};
}

// ── the rows the view binds ─────────────────────────────────────────────

QVariantList ChatBackend::holdingRows() const
{
    QVariantList rows;
    rows.reserve(m_holdings.size());
    for (const Holding& h : m_holdings) {
        const QString balance = m_balances.value(h.id);
        // Why this holding cannot be paid into yet, or empty. Per holding rather
        // than one wallet-wide state, so the private account's seven-minute
        // on-chain registration does not make the rest of the wallet look
        // broken — or, worse, make the app look hung on first launch.
        const QString blocker = m_blockers.value(h.id);
        rows.append(QVariantMap{
            {QStringLiteral("id"), h.id},
            {QStringLiteral("name"), h.name},
            {QStringLiteral("denom"), h.denom},
            {QStringLiteral("sourceNote"), h.sourceNote},
            {QStringLiteral("blocked"), !blocker.isEmpty()},
            {QStringLiteral("blockedNote"), blocker},
            // Empty until the first read lands, which the card draws as "—"
            // rather than as zero.
            {QStringLiteral("balance"), balance},
            {QStringLiteral("address"), m_addresses.value(h.id)},
            // Can be *shared*, which a blocker withholds: an address handed out
            // before its registration lands invites a payment that may vanish.
            // Spending from it is not gated — that is the zone's call, and it
            // will simply have no notes to spend.
            {QStringLiteral("canReceive"), h.canReceive() && blocker.isEmpty()},
            {QStringLiteral("canClaim"), h.canClaim() && balance.toULongLong() > 0},
            {QStringLiteral("claimVerb"), h.claimVerb},
            {QStringLiteral("addressForm"), int(h.addressForm)},
            // A holding worth nothing is still listed — the point of the card
            // is that these are the places money can be, not the places it is —
            // but the view dims one rather than leading with it.
            {QStringLiteral("empty"), balance.isEmpty() || balance.toULongLong() == 0}});
    }
    return rows;
}

QVariantList ChatBackend::railRows() const
{
    QVariantList rows;
    rows.reserve(m_rails.size());
    for (const Rail& r : m_rails) {
        if (!sendableRailById(r.id))
            continue;
        const Holding* source = holdingById(r.source);
        rows.append(QVariantMap{
            {QStringLiteral("id"), r.id},
            {QStringLiteral("name"), r.name},
            {QStringLiteral("promise"), r.promise},
            {QStringLiteral("denom"), r.denom},
            {QStringLiteral("source"), r.source},
            {QStringLiteral("sourceName"), source ? source->name : QString()},
            {QStringLiteral("balance"), m_balances.value(r.source)},
            {QStringLiteral("payTo"), int(r.payTo)},
            {QStringLiteral("claimId"), r.claimId},
            {QStringLiteral("discloses"), disclosureRow(r.discloses)}});
    }
    return rows;
}

QVariantMap ChatBackend::disclosureRow(const Assets::Disclosure& d)
{
    return QVariantMap{{QStringLiteral("amount"), d.amount},
                       {QStringLiteral("payer"), d.payer},
                       {QStringLiteral("payee"), d.payee},
                       {QStringLiteral("nothing"), d.nothing()},
                       {QStringLiteral("everything"), d.everything()}};
}
