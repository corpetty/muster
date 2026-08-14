// The execution-zone half of the backend: open a wallet, fund it, and pay an
// address that arrived in a conversation.
//
// Everything here talks to lez_core, the zone module, through the generated
// typed client. The patterns — amount encoding, the faucet's proof of work,
// save-after-every-mutation, sync-before-spend — are taken from
// hackyguru/persona (core/src/logos_wallet_plugin.cpp), which is the worked
// example for driving this module and cost someone a lot of trial and error.
//
// **What is not here: which assets exist, or how any of them is paid.** That is
// ChatBackendAssets.cpp, and it is deliberately somewhere else. This file used
// to name transfer_private in the one place a payment happened, which made
// every surface downstream an assumption about that one rail. It now runs a
// rail the caller chose and knows nothing about which one it is — so adding an
// asset is an entry in a table, not an edit here.
//
// Two rules this file exists to keep:
//   1. Zone calls are synchronous and slow (zk proving runs for minutes). Each
//      entry point defers its work with a zero-timer so the caller's slot
//      returns immediately, and sets walletBusy/walletStage so the view can
//      say what the wait is for.
//   2. The wallet-ffi is in-memory. save() after every mutation, or the next
//      open() silently loses it.

#include "ChatBackend.h"
#include "Assets.h"
#include "MusterMessage.h"
#include "Zone.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QThread>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRandomGenerator>
#include <QTimer>

#include "logos_sdk.h"

namespace {

// The zone's genesis proof-of-work faucet, and its base58 form for the
// sequencer's account RPC. Both are testnet constants.
const QString kPinataId =
    QStringLiteral("cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe");
const QString kPinataB58 = QStringLiteral("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7");

// What the faucet pays per claim.
constexpr quint64 kPrize = 150;
// Blocks per sync_to_block call. The zone rejects a jump much larger than this.
constexpr int kSyncChunk = 250;

QJsonObject readJsonFile(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}

void writeJsonFile(const QString& path, const QJsonObject& o)
{
    QFile f(path);
    if (f.open(QIODevice::WriteOnly))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

} // namespace

// ── paths ───────────────────────────────────────────────────────────────

QString ChatBackend::walletDir() const
{
    // The chat module names the log file it is writing, and that file sits in
    // the instance directory the host assigned *this* instance. Deriving from
    // it is what keeps two --user-dir peers on two wallets. With no log path
    // there is no instance directory we can name, and a shared fallback would
    // be worse than refusing.
    if (m_moduleLogPath.isEmpty())
        return {};
    return QFileInfo(m_moduleLogPath).absolutePath() + QStringLiteral("/muster-wallet");
}

// ── plumbing ────────────────────────────────────────────────────────────

void ChatBackend::beginStage(const QString& stage)
{
    setWalletStage(stage);
    setWalletBusy(true);
}

void ChatBackend::endStage()
{
    setWalletStage(QString());
    setWalletJob(QString());
    setWalletBusy(false);
}

void ChatBackend::failWallet(const QString& action, const QString& reason)
{
    endStage();
    const QString message = reason.isEmpty() ? action : action + QStringLiteral(": ") + reason;
    setWalletError(message);
    report(message);
}

void ChatBackend::walletSave()
{
    logos::CallError err;
    modules().lez_core.save(&err);
    if (!err.ok())
        report(QStringLiteral("Wallet did not save: ") + QString::fromStdString(err.message));
}

bool ChatBackend::syncToTip(QString* error)
{
    logos::CallError err;
    const int height = modules().lez_core.get_current_block_height(&err);
    if (!err.ok()) {
        if (error)
            *error = QString::fromStdString(err.message);
        return false;
    }
    int last = modules().lez_core.get_last_synced_block(&err);
    if (!err.ok())
        last = 0;

    // Walk forward in chunks; the zone will not accept an arbitrarily large
    // jump. Each chunk is a separate call so a long catch-up reports progress
    // rather than looking hung.
    while (last < height) {
        const int next = qMin(last + kSyncChunk, height);
        modules().lez_core.sync_to_block(next, &err);
        if (!err.ok()) {
            if (error)
                *error = QString::fromStdString(err.message);
            return false;
        }
        last = next;
        setWalletStage(QStringLiteral("syncing %1/%2").arg(last).arg(height));
    }
    walletSave();
    return true;
}

quint64 ChatBackend::waitForPublicFunds(const QString& account, quint64 atLeast, int timeoutMs)
{
    // Poll the wallet's own view, not the sequencer's: what matters is whether
    // *this wallet* can spend the note, and those two answers differ for a
    // while after a claim. The chain showing the balance is exactly the case
    // that misled us.
    QElapsedTimer clock;
    clock.start();
    while (clock.elapsed() < timeoutMs) {
        QString ignored;
        syncToTip(&ignored);

        logos::CallError err;
        const QString raw = modules().lez_core.get_balance(account, true, &err);
        if (err.ok()) {
            const quint64 balance = raw.trimmed().toULongLong();
            if (balance >= atLeast)
                return balance;
        }

        setWalletStage(QStringLiteral("waiting for the claim to land (%1s)")
                           .arg(clock.elapsed() / 1000));
        // Blocking, like every other call on this path — the zone's work is
        // synchronous and the view is already showing a named stage for it.
        QThread::msleep(1500);
    }
    return 0;
}

void ChatBackend::settleAfterTransfer(int timeoutMs)
{
    // A transfer the zone accepted is not yet a balance this wallet can see.
    // The block carrying it may not exist yet, and syncToTip does nothing when
    // the height has not moved — so reading once, immediately, reports the
    // balances from *before* the transfer and leaves them there.
    //
    // That is not a cosmetic lag: it is indistinguishable from the payment
    // having failed. It is the same fact the faucet path already waits on (see
    // waitForPublicFunds) — a claim that is on-chain is not yet a note this
    // wallet can spend — and it applies to every rail, not just the faucet.
    // Measured 2026-08-12: after a 7-minute shield completed, the wallet still
    // showed 150 public / 0 private, and only a manual Refresh corrected it.
    //
    // So poll until this wallet's own view actually moves. Any change is enough
    // — a rail's payer loses funds while its payee gains them, and this has to
    // serve both — and the first poll usually has it.
    const QHash<QString, QString> before = m_balances;

    QElapsedTimer clock;
    clock.start();
    for (;;) {
        QString ignored;
        syncToTip(&ignored);
        readWalletState();
        if (m_balances != before)
            return;
        if (clock.elapsed() >= timeoutMs)
            break;
        setWalletStage(QStringLiteral("settling (%1s)").arg(clock.elapsed() / 1000));
        // Blocking, like every other wait on this path — the zone's work is
        // synchronous and the view is already showing a named stage for it.
        QThread::msleep(2000);
    }

    // Say so rather than leaving a stale number looking authoritative. The
    // transfer is not lost; this wallet just cannot see it yet.
    report(tr("The transfer went through, but this wallet cannot see the new balance yet. "
              "Press Refresh in a moment."));
}

bool ChatBackend::ensureWalletOpen()
{
    if (m_walletOpen)
        return true;

    const QString dir = walletDir();
    if (dir.isEmpty()) {
        failWallet(QStringLiteral("No wallet"),
                   QStringLiteral("this instance has no directory of its own yet"));
        return false;
    }
    QDir().mkpath(dir);

    const QString cfg = dir + QStringLiteral("/config.json");
    const QString storage = dir + QStringLiteral("/storage.json");
    const QString stats = dir + QStringLiteral("/statistics.json");
    const QString metaPath = dir + QStringLiteral("/meta.json");

    // We deliberately do NOT write this config. The wallet writes its own
    // default when the file is absent, already pointing at the testnet
    // sequencer, and that default is by construction the schema this build of
    // wallet-ffi expects. Writing our own is how the first attempt failed:
    // the shape published by older clients (a flat `sequencer_addr`) is not
    // the shape v0.2.2 deserializes (a `sequencers` array), and a config it
    // cannot parse makes create_new return null.
    //
    // Self-heal a config left behind by that earlier build, so a peer created
    // with it recovers instead of failing the same way forever.
    if (QFile::exists(cfg) && readJsonFile(cfg).contains(QStringLiteral("sequencer_addr"))) {
        QFile::remove(cfg);
        report(QStringLiteral("Replaced an unreadable wallet config; the wallet will write its own."));
    }

    QJsonObject meta = readJsonFile(metaPath);
    logos::CallError err;

    // The storage file is the truth. Creating over an existing wallet would
    // orphan whatever it holds, so an existing file is always opened.
    if (QFile::exists(storage)) {
        // Zero is success. The zone reports failure in the return value, not
        // through CallError, so both have to be checked.
        const int rc = modules().lez_core.open(cfg, storage, stats, &err);
        if (!err.ok() || rc != 0) {
            failWallet(QStringLiteral("Could not open the wallet"),
                       err.ok() ? QStringLiteral("the zone refused it (code %1)").arg(rc)
                                : QString::fromStdString(err.message));
            return false;
        }
    } else {
        QString password = meta.value(QStringLiteral("password")).toString();
        if (password.isEmpty()) {
            password = QString::number(QRandomGenerator::global()->generate64(), 16)
                + QString::number(QRandomGenerator::global()->generate64(), 16);
            meta.insert(QStringLiteral("password"), password);
        }
        const QString mnemonic = modules().lez_core.create_new(cfg, storage, stats, password, &err);
        // An empty return is how this call fails: it logs its own reason and
        // hands back nothing, with CallError still clear. Treating that as
        // success is what let a wallet that was never created look open.
        if (!err.ok() || mnemonic.isEmpty()) {
            failWallet(QStringLiteral("Could not create a wallet"),
                       err.ok() ? QStringLiteral("the zone returned no wallet — see the lez_core "
                                                 "lines in this run's log")
                                : QString::fromStdString(err.message));
            return false;
        }
        walletSave();
        // Surfaced once, for the demo to show that a real wallet was minted.
        // Never read back from storage afterwards.
        setNewWalletMnemonic(mnemonic);
        writeJsonFile(metaPath, meta);
    }

    m_walletOpen = true;
    m_privateAccount = meta.value(QStringLiteral("privateAccount")).toString();
    m_publicAccount = meta.value(QStringLiteral("publicAccount")).toString();

    if (m_privateAccount.isEmpty()) {
        m_privateAccount = modules().lez_core.create_account_private(&err);
        if (!err.ok() || m_privateAccount.isEmpty()) {
            failWallet(QStringLiteral("Could not create a private account"),
                       err.ok() ? QStringLiteral("the wallet is not open")
                                : QString::fromStdString(err.message));
            m_walletOpen = false;
            return false;
        }
        walletSave();
        meta.insert(QStringLiteral("privateAccount"), m_privateAccount);
        writeJsonFile(metaPath, meta);
    }

    // DO NOT register it. A private account is nothing like a public one here,
    // and this cost us a week of wrong conclusions.
    //
    // A public account has to exist on-chain before the faucet will pay it, so
    // `ensurePublicAccount` registers. The instinct to do the same for the
    // private one is not merely unnecessary — it is destructive.
    // `register_private_account` *initializes* the account, and the zone's
    // initialization nullifier is a hash of the account id alone. Any given
    // account id can therefore be foreign-initialized exactly once, ever. An
    // account we registered ourselves is permanently uncreditable by anyone
    // else: their transfer would be rejected on chain, forever, for that id.
    //
    // Nothing needs registering to receive. A sender's transfer is what creates
    // the account, at an identifier the sender picks. What we publish is the
    // *key node* — the (nullifier, viewing) public key pair that
    // get_private_account_keys returns — and every payment made to it mints a
    // fresh account underneath it, which we find by scanning with our viewing
    // key. That is `readPrivateBalance`, and it is the design rather than a
    // patch over one.
    //
    // Confirmed by the zone's team, 2026-08-13, in response to our report in
    // demo/poc/. This code called register_private_account for two days on the
    // belief that an unregistered account could not be credited; that belief
    // was wrong, and acting on it was what actually killed the advertised
    // account id. It is the clearest case in this build of a fix aimed at a
    // misdiagnosis doing the damage it was meant to prevent.
    return true;
}

QString ChatBackend::ensurePublicAccount()
{
    if (!m_publicAccount.isEmpty())
        return m_publicAccount;

    logos::CallError err;
    const QString id = modules().lez_core.create_account_public(&err);
    if (!err.ok() || id.isEmpty())
        return {};

    // A public account only exists on-chain once it is registered; the faucet
    // will not pay one that isn't. Unlike the private registration this one
    // completes well inside the sync client's 20s, but it returns the same
    // envelope — so it gets the same check rather than being discarded.
    const Zone::Result reg = Zone::parse(modules().lez_core.register_public_account(id, &err));
    if (!err.ok() || !reg.ok) {
        report(tr("Could not register the public account on-chain%1 — the faucet will "
                  "refuse to pay it.")
                   .arg(reg.error.isEmpty() ? QString()
                                            : QStringLiteral(": %1").arg(reg.error)));
    }
    walletSave();

    m_publicAccount = id;
    const QString metaPath = walletDir() + QStringLiteral("/meta.json");
    QJsonObject meta = readJsonFile(metaPath);
    meta.insert(QStringLiteral("publicAccount"), id);
    writeJsonFile(metaPath, meta);
    return id;
}

QString ChatBackend::spendFromAccount() const
{
    // The other half of readPrivateBalance: spend from an account that actually
    // holds a note. Money paid to us lands at an account the *sender* named, so
    // the one we created is usually not the one holding anything. A single
    // transfer cannot draw on several notes, so this picks the largest rather
    // than the sum — which means a balance can be displayed that no single
    // payment can spend. That is inherent to a note-based shielded pool rather
    // than a defect, and it is why the wallet card says where the money is.
    return m_fundedPrivateAccounts.isEmpty() ? m_privateAccount : m_fundedPrivateAccounts.first();
}

QString ChatBackend::readPrivateBalance()
{
    logos::CallError err;

    // ── THE MODEL, not a workaround ──────────────────────────────────────
    //
    // The private balance is the sum over *every* private account this wallet
    // knows, not the balance of the one account we created and published. That
    // is what a shielded balance is, and this loop is a scan, not a patch.
    //
    // A private account id is sha256(prefix || npk || vpk || identifier). What
    // a recipient publishes is the *key node* — the (npk, vpk) pair, which is
    // exactly what get_private_account_keys returns. The sender picks the
    // identifier, so every payment made to us mints a fresh account under our
    // key node, and we find our money by scanning with our viewing key. A
    // shielded wallet has no single address whose balance is the answer; it
    // has a key node and a set of notes that only it can see.
    //
    // This code stood here for two days labelled a workaround for an upstream
    // bug, with a comment saying to delete it once the zone "addressed the
    // account whose keys were shared". That was wrong twice over: the zone is
    // behaving as designed, and a fixed published identifier could never work —
    // the initialization nullifier is a hash of the account id alone, so any
    // one id can be foreign-initialized exactly once and would be dead after a
    // single payment. Confirmed by the zone's team, 2026-08-13.
    //
    // The one real cost survives and is still disclosed: a single transfer can
    // only draw on one note, so the sum shown can exceed what one send can
    // spend. See the `payment` claim in VisibilityClaims.qml and spendFromAccount.
    //
    // Full history, and where the misreading came from: demo/poc/.
    QStringList spendable;
    quint64 total = 0;
    bool sawAny = false;
    const QVariantList accounts = modules().lez_core.list_accounts(&err);
    if (err.ok()) {
        for (const QVariant& v : accounts) {
            const QVariantMap a = v.toMap();
            if (a.value(QStringLiteral("is_public")).toBool())
                continue;
            const QString id = a.value(QStringLiteral("account_id")).toString();
            if (id.isEmpty())
                continue;
            logos::CallError balErr;
            const QString b = modules().lez_core.get_balance(id, false, &balErr).trimmed();
            if (!balErr.ok() || b.isEmpty())
                continue;
            sawAny = true;
            const quint64 n = b.toULongLong();
            total += n;
            if (n > 0)
                spendable.append(id);
        }
    }
    // Keep the discovered accounts in balance order, largest first: a payment
    // has to be spent from an account that actually holds the note, and the
    // one we created is usually not it.
    std::sort(spendable.begin(), spendable.end(), [this](const QString& a, const QString& b) {
        logos::CallError e;
        return modules().lez_core.get_balance(a, false, &e).trimmed().toULongLong()
             > modules().lez_core.get_balance(b, false, &e).trimmed().toULongLong();
    });
    m_fundedPrivateAccounts = spendable;

    // Money is held somewhere we did not publish — which is what has to be
    // said on screen beside the number.
    bool elsewhere = false;
    for (const QString& id : spendable) {
        if (id != m_privateAccount) {
            elsewhere = true;
            break;
        }
    }
    setReceivedElsewhere(elsewhere);

    if (sawAny)
        return QString::number(total);

    // Fall back to the account we know about rather than reporting zero for a
    // listing that failed.
    const QString priv = modules().lez_core.get_balance(m_privateAccount, false, &err);
    if (!err.ok())
        return {};
    return priv.trimmed().isEmpty() ? QStringLiteral("0") : priv.trimmed();
}

QString ChatBackend::readPublicBalance()
{
    if (m_publicAccount.isEmpty())
        return {};

    // A public balance lives on-chain, not in the wallet, so it comes from the
    // sequencer rather than from lez_core. Which is itself the lesson this
    // holding teaches: anyone can ask that question about anyone's account, and
    // nobody has to be the account's owner to get an answer.
    logos::CallError err;
    const QString b58 = modules().lez_core.account_id_to_base58(m_publicAccount, &err);
    if (!err.ok())
        return {};

    QByteArray reply;
    if (!Zone::sequencerPost("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\","
                             "\"params\":[\""
                                 + b58.toUtf8() + "\"]}",
                             reply))
        return {};

    const QJsonValue r = QJsonDocument::fromJson(reply).object().value("result");
    return r.isDouble() ? QString::number(quint64(r.toDouble())) : QString();
}

void ChatBackend::readWalletState()
{
    if (!m_walletOpen)
        return;
    buildAssets();

    // One pass over the catalogue rather than a hardcoded read per balance. A
    // holding added to ChatBackendAssets.cpp is read here without this loop
    // changing, which is the whole point of the table — and an entry that
    // cannot answer keeps its last answer rather than being blanked, because a
    // failed read is not a balance of zero.
    for (const Assets::Holding& h : m_holdings) {
        if (h.readBalance) {
            const QString balance = h.readBalance();
            if (!balance.isEmpty())
                m_balances.insert(h.id, balance);
        }
        if (h.readReceiveAddress) {
            const QString address = h.readReceiveAddress();
            if (!address.isEmpty())
                m_addresses.insert(h.id, address);
        }
    }

    setAssets(holdingRows());
    // Republished with the balances: a rail carries its source's balance, so
    // the send dialog can say what this way of paying can afford.
    setRails(railRows());
}

// ── slots ───────────────────────────────────────────────────────────────

void ChatBackend::openWallet()
{
    if (walletBusy() || m_walletOpen)
        return;
    setWalletStatus(ChatBackendSimpleSource::WalletOpening);
    setWalletError(QString());
    beginStage(QStringLiteral("opening"));

    // Deferred so the slot returns to the view immediately: everything below
    // is a blocking run of zone calls.
    QTimer::singleShot(0, this, [this] {
        if (!ensureWalletOpen()) {
            setWalletStatus(ChatBackendSimpleSource::WalletError);
            return;
        }

        // Ready as soon as the wallet is open, with nothing owed afterwards.
        //
        // Two earlier shapes lived here, and both were paying for a diagnosis
        // that turned out to be wrong. The first blocked the whole wallet for
        // the seven minutes a private registration proves for — on first launch,
        // inert, including for public balances the registration had no bearing
        // on. The second narrowed the gate to the private holding alone, which
        // was the right instinct applied to a fiction: it marked the holding
        // unshareable "until registration lands", because an address shared
        // before then was believed to invite a payment that would vanish.
        //
        // Neither is needed, because the registration is not needed. See
        // ensureWalletOpen: a private account is created by the sender who pays
        // it, and the key node we publish is credit-worthy the moment it exists.
        // The private address is shareable immediately, and first launch has no
        // seven-minute hole in it.
        finishWalletOpen();
    });
}

void ChatBackend::finishWalletOpen()
{
    // The public account is created and registered here, not at first funding.
    // It used to be lazy because the faucet was the only thing that wanted one;
    // now it backs a holding a peer can be asked to pay and two rails that
    // spend it, and a wallet that says Ready with half its rails unusable would
    // be lying about what it can do. Registration is a public-account one, which
    // completes well inside the sync client's 20s — unlike the private one.
    beginStage(QStringLiteral("opening the public account"));
    if (ensurePublicAccount().isEmpty()) {
        report(tr("No public account — the two rails that spend one, and the faucet, will "
                  "be unavailable."));
    }

    beginStage(QStringLiteral("syncing"));
    QString error;
    if (!syncToTip(&error)) {
        // A wallet that opened but could not reach the tip is still usable
        // for reading; say so rather than calling the whole thing failed.
        report(QStringLiteral("Wallet opened but could not sync: ") + error);
    }
    readWalletState();
    endStage();
    setWalletStatus(ChatBackendSimpleSource::WalletReady);
}

void ChatBackend::fundWallet()
{
    // Say so rather than returning silently — the same rule payForIntent
    // already keeps, and for the same reason: a press that produces nothing at
    // all reads as a broken button. This one is worse than most, because a
    // wallet that has never been funded shows all zeros, which is exactly what
    // a Fund that did nothing also looks like.
    if (walletBusy()) {
        report(tr("The wallet is busy (%1) — wait for that to finish, then Fund.")
                   .arg(walletStage().isEmpty() ? tr("working") : walletStage()));
        return;
    }
    setWalletError(QString());
    setWalletJob(tr("Funding this wallet"));
    beginStage(QStringLiteral("syncing"));

    QTimer::singleShot(0, this, [this] {
        if (!ensureWalletOpen())
            return;

        QString error;
        if (!syncToTip(&error)) {
            failWallet(QStringLiteral("Could not sync before funding"), error);
            return;
        }

        // The faucet's difficulty and seed rotate per claim, so they are read
        // fresh every time rather than cached.
        beginStage(QStringLiteral("reading the faucet"));
        QByteArray rpc;
        if (!Zone::sequencerPost("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccount\",\"params\":[\""
                               + kPinataB58.toUtf8() + "\"]}",
                           rpc)) {
            failWallet(QStringLiteral("Could not reach the faucet"), QString());
            return;
        }
        const QJsonArray data = QJsonDocument::fromJson(rpc)
                                    .object()
                                    .value("result")
                                    .toObject()
                                    .value("data")
                                    .toArray();
        QByteArray raw;
        for (const QJsonValue& v : data)
            raw.append(char(v.toInt()));
        if (raw.size() != 33) {
            failWallet(QStringLiteral("The faucet did not answer with a puzzle"), QString());
            return;
        }

        // Proof of work: find a nonce whose sha256, prefixed by the seed, has
        // `difficulty` leading zero bytes. Seconds on testnet difficulty.
        beginStage(QStringLiteral("mining"));
        const int difficulty = quint8(raw[0]);
        QByteArray buf = raw.mid(1) + QByteArray(16, '\0');
        quint64 solution = 0;
        bool found = false;
        for (; solution < Q_UINT64_C(0xFFFFFFFFFF); ++solution) {
            quint64 v = solution;
            for (int i = 0; i < 8; ++i) {
                buf[32 + i] = char(v & 0xff);
                v >>= 8;
            }
            const QByteArray digest = QCryptographicHash::hash(buf, QCryptographicHash::Sha256);
            bool zero = true;
            for (int i = 0; i < difficulty; ++i) {
                if (digest[i] != 0) {
                    zero = false;
                    break;
                }
            }
            if (zero) {
                found = true;
                break;
            }
        }
        if (!found) {
            failWallet(QStringLiteral("Could not solve the faucet puzzle"), QString());
            return;
        }

        const QString publicAccount = ensurePublicAccount();
        if (publicAccount.isEmpty()) {
            failWallet(QStringLiteral("Could not create an account to be paid into"), QString());
            return;
        }

        beginStage(QStringLiteral("claiming"));
        logos::CallError err;
        const Zone::Result claim = Zone::parse(
            modules().lez_core.claim_pinata(kPinataId, publicAccount, Zone::amountLe16Hex(solution), &err));
        if (!err.ok() || !claim.ok) {
            failWallet(QStringLiteral("The faucet refused the claim"),
                       !err.ok()      ? QString::fromStdString(err.message)
                       : claim.error.isEmpty()
                           ? QStringLiteral("the zone returned nothing — the puzzle may have "
                                            "been solved by someone else first")
                           : claim.error);
            return;
        }
        walletSave();

        // Wait for the claim to actually land before spending it. Syncing to
        // the tip is not enough on its own: the claim's block may not exist
        // yet, and syncToTip does nothing when the height has not moved, so
        // shielding immediately spends a note the wallet cannot see and fails
        // with InsufficientFunds while the chain plainly shows the balance.
        beginStage(QStringLiteral("waiting for the claim to land"));
        const quint64 funded = waitForPublicFunds(publicAccount, kPrize, 60000);
        if (funded == 0) {
            // The prize is on-chain regardless; this is a visibility problem,
            // not a lost claim, and Refresh then Fund again recovers it.
            report(QStringLiteral("Claimed, but the funds have not reached this wallet yet. "
                                  "Refresh in a moment, then shield with Fund."));
            readWalletState();
            endStage();
            return;
        }

        // Do not shield into a holding that says it cannot be paid into. No
        // blocker is set on the private holding any more — the registration
        // that used to set one is gone — so this cannot currently fire; it
        // stays because the invariant is the point: value never moves into a
        // holding whose own row says it is not ready to receive.
        //
        // The prize is safe in the public account either way, so this is a
        // pause rather than a loss: press Fund again once the row clears.
        const QString blocker = m_blockers.value(QStringLiteral("lez.private"));
        if (!blocker.isEmpty()) {
            report(tr("Claimed %1 into your public account, and stopped there: %2 Press Fund "
                      "again once that finishes and it will shield.")
                       .arg(funded)
                       .arg(blocker));
            readWalletState();
            endStage();
            return;
        }

        // Shield what is actually there into the private account, so the
        // balance a payment draws on is already private.
        beginStage(QStringLiteral("shielding"));
        // Asynchronously, with a proving-length budget. The generated *sync*
        // wrapper takes no timeout and hardcodes 20s, which a zk proof does not
        // fit inside: it returned an error while the zone kept proving, and the
        // next blocking call then sat behind that work with a stale stage on
        // screen. The async form is the only one that accepts a Timeout, and it
        // leaves the view responsive while the zone works.
        modules().lez_core.transfer_shielded_ownedAsync(
            publicAccount, m_privateAccount, Zone::amountLe16Hex(funded),
            [this](QString raw) {
                // The envelope, not emptiness: a failed shield comes back as
                // well-formed JSON carrying success:false, and treating that as
                // a transaction id is what silently left the prize public.
                const Zone::Result res = Zone::parse(raw);
                if (!res.ok) {
                    report(tr("Funded, but shielding did not complete%1. The prize is safe in "
                              "the public account — press Fund again to retry shielding it.")
                               .arg(res.error.isEmpty()
                                        ? QString()
                                        : QStringLiteral(" (%1)").arg(res.error)));
                } else {
                    walletSave();
                }
                // Never make module calls straight out of a callback: that
                // re-enters the transport while its notifier is disabled.
                deferToEventLoop([this] {
                    // Not a bare read: the shielded note is not visible the
                    // instant the proof lands, and reading once here is what
                    // left 150 sitting in "public" until the user pressed
                    // Refresh by hand.
                    settleAfterTransfer(45000);
                    endStage();
                });
            },
            Timeout(Zone::kProveMs));
    });
}

void ChatBackend::scanForIncomingPayment()
{
    // A shielded payee has no address to watch. Money paid to us mints a fresh
    // account under our key node at an identifier the sender chose, so there is
    // nothing to subscribe to and nothing that can notify us — the only way to
    // learn we were paid is to scan with our viewing key. See
    // readPrivateBalance for the model.
    //
    // Which left the payee pressing Refresh and hoping. Measured 2026-08-13:
    // after a successful payment the recipient's app did nothing at all — its
    // log is health probes and nothing else — until a human refreshed by hand.
    // Someone who has just been told "I sent it" and sees an unchanged balance
    // cannot tell that from the payment having failed, and that confusion is
    // what produced a withdrawn bug report against the zone.
    //
    // The conversation is where the news arrives, so the conversation is what
    // triggers the look. Note carefully what is and is not taken from it: the
    // receipt is a *hint to go and look*, never a fact to display. Nothing the
    // sender wrote is read beyond "somebody said a payment happened" (see
    // isIncomingReceipt), and what the user sees afterwards is only what our
    // own scan found. A receipt for a payment that was never made therefore
    // moves no number here — it costs a sync and finds nothing.
    //
    // That is also why this does not check whether the payment was addressed to
    // us. It cannot know, and it does not need to: the scan either turns up
    // money or it does not.
    if (!m_walletOpen || walletBusy())
        return;
    beginStage(QStringLiteral("checking for a payment"));
    // The same poll the payer's own path uses. A receipt is sent once the zone
    // accepts the transfer, which is before the block carrying it necessarily
    // exists, so a single read here would be the stale-balance trap again.
    settleAfterTransfer(45000);
    endStage();
}

void ChatBackend::refreshBalances()
{
    if (!m_walletOpen) {
        report(tr("No wallet open yet — open one first."));
        return;
    }
    if (walletBusy()) {
        report(tr("The wallet is busy (%1) — the balances will be re-read when it finishes.")
                   .arg(walletStage().isEmpty() ? tr("working") : walletStage()));
        return;
    }
    beginStage(QStringLiteral("syncing"));
    QTimer::singleShot(0, this, [this] {
        QString error;
        syncToTip(&error);
        readWalletState();
        endStage();
    });
}

void ChatBackend::requestAddress(QString conversationId)
{
    if (conversationId.isEmpty())
        return;
    // A card is an ordinary message as far as the conversation is concerned,
    // so this is the same send path text takes — and inherits its encryption.
    sendMessage(conversationId, MusterMessage::addressRequest());
}

void ChatBackend::shareAddress(QString conversationId, QString assetId)
{
    if (conversationId.isEmpty())
        return;
    buildAssets();

    const Assets::Holding* holding = holdingById(assetId);
    if (!holding || !holding->canReceive()) {
        report(tr("There is nothing to share for %1.")
                   .arg(assetId.isEmpty() ? tr("that asset") : assetId));
        return;
    }
    // Never hand out an address for a holding that says it cannot be paid into:
    // that is an invitation to a payment that goes nowhere. Nothing sets a
    // blocker today — the private account's on-chain registration used to, and
    // that turned out to be a step that should never have existed — but the
    // refusal belongs here rather than at the moment a holding first needs one.
    const QString blocker = m_blockers.value(holding->id);
    if (!blocker.isEmpty()) {
        report(tr("%1 cannot be shared yet: %2").arg(holding->name, blocker));
        return;
    }
    const QString address = m_addresses.value(holding->id);
    if (address.isEmpty()) {
        report(tr("No %1 address yet — open the wallet first.").arg(holding->name));
        return;
    }

    // The card names the asset and the form of address it carries, so the payer
    // can work out which rails could pay it instead of assuming the one this
    // build happens to prefer. It also carries our words for the holding, which
    // is what lets a peer on a build that has never heard of this asset say
    // "they called it X" rather than describe it as something it is not.
    sendMessage(conversationId,
                MusterMessage::addressShare(holding->id, address, int(holding->addressForm),
                                            holding->name, myLabel()));
}

void ChatBackend::sendPayment(QString conversationId, QString railId, QString toAddress,
                              QString amount)
{
    if (walletBusy())
        return;
    if (conversationId.isEmpty() || toAddress.isEmpty()) {
        report(QStringLiteral("Nothing to pay to."));
        return;
    }
    bool ok = false;
    const quint64 value = amount.trimmed().toULongLong(&ok);
    if (!ok || value == 0) {
        report(QStringLiteral("Amount must be a whole number above zero."));
        return;
    }
    // A direct send is a payment with no proposal behind it, which is the only
    // difference between the two paths — so it is the only thing that differs
    // in the call.
    payForIntent(conversationId, railId, toAddress, value, QString());
}

void ChatBackend::claimHolding(QString assetId, QString amount)
{
    if (walletBusy()) {
        report(tr("The wallet is busy (%1) — wait for that to finish, then claim.")
                   .arg(walletStage().isEmpty() ? tr("working") : walletStage()));
        return;
    }
    buildAssets();

    const Assets::Holding* holding = holdingById(assetId);
    if (!holding || !holding->canClaim()) {
        report(tr("There is nothing to claim there."));
        return;
    }
    bool ok = false;
    quint64 value = amount.trimmed().toULongLong(&ok);
    // No amount means all of it, which is what the button on the card asks for.
    if (!ok || value == 0)
        value = m_balances.value(holding->id).toULongLong();
    if (value == 0) {
        report(tr("%1 is empty.").arg(holding->name));
        return;
    }

    const QString name = holding->name;
    const auto claim = holding->claim;
    setWalletError(QString());
    setWalletJob(tr("Claiming %1 from %2").arg(value).arg(name));
    beginStage(QStringLiteral("claiming"));

    QTimer::singleShot(0, this, [this, claim, name, value] {
        if (!ensureWalletOpen())
            return;
        QString error;
        if (!syncToTip(&error)) {
            failWallet(tr("Could not sync before claiming"), error);
            return;
        }
        beginStage(QStringLiteral("claiming"));
        claim(value, [this, name](Zone::Result res) {
            if (!res.ok) {
                failWallet(tr("The claim from %1 failed").arg(name),
                           res.error.isEmpty() ? tr("the zone did not accept it") : res.error);
                return;
            }
            walletSave();
            deferToEventLoop([this] {
                settleAfterTransfer(45000);
                endStage();
            });
        });
    });
}

void ChatBackend::payForIntent(const QString& conversationId, const QString& railId,
                               const QString& toAddress, quint64 value, const QString& intentId)
{
    // Say so rather than returning silently. A press that produces nothing at
    // all reads as a broken button, and the wallet is busy for *minutes* here —
    // long enough that someone will press it, see nothing, and press again.
    if (walletBusy()) {
        report(tr("The wallet is busy (%1) — wait for that to finish, then pay.")
                   .arg(walletStage().isEmpty() ? tr("working") : walletStage()));
        return;
    }
    if (conversationId.isEmpty() || toAddress.isEmpty() || value == 0) {
        report(QStringLiteral("Nothing to pay to."));
        return;
    }

    buildAssets();
    // Through sendableRailById, never railById: a rail with no visibility claim
    // is refused here, at the only place value moves, rather than being caught
    // by whichever view remembered to check. A payment this app cannot account
    // for on screen is one it does not make.
    const Assets::Rail* rail = sendableRailById(railId);
    if (!rail) {
        report(tr("This build cannot pay on that rail%1.")
                   .arg(railId.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(railId)));
        return;
    }
    // The same rule as the rail above, turned on the payee. A rail with nothing
    // to say about what it leaks cannot be paid with; an address this room
    // never named cannot be paid *to*. Both are refused here, at the one place
    // value moves, rather than in whichever dialog remembered to check — the
    // view that forgot is exactly the view an attacker would reach for.
    //
    // What this does and does not establish. It establishes that a named peer
    // put this address in this conversation, which `chat_module` makes
    // unforgeable in the room. It does not establish that they meant it now,
    // and nothing signed here commits to the answer: a receipt cannot prove
    // afterwards which message the address came from. That is F-20's job and
    // this build has no signing payload to do it with.
    logos::CallError msgErr;
    const QVariantList payeeMsgs = modules().chat_module.get_messages(conversationId, &msgErr);
    if (!msgErr.ok()) {
        reportFailure(tr("Could not read this conversation to check where that address came from"),
                      QString::fromStdString(msgErr.message));
        return;
    }
    const QVariantMap payeeOrigin = addressOriginForMessages(payeeMsgs, toAddress);
    if (payeeOrigin.isEmpty()) {
        report(tr("Nobody in this conversation shared that address, so this build will not pay "
                  "it. An address it cannot account for is a refusal, not a warning."));
        return;
    }

    // Copied, not held: the catalogue outlives the call, but a pointer into a
    // QVector does not survive it being rebuilt.
    const QString railName = rail->name;
    const QString denom = rail->denom;
    const auto send = rail->send;
    const QVariantMap discloses = disclosureRow(rail->discloses);

    setWalletError(QString());
    // The rail is in the job line because it is the part that decides what this
    // costs in privacy, and a job that runs for minutes should say which of the
    // four is running rather than just how much.
    setWalletJob(tr("Paying %1 %2 · %3").arg(value).arg(denom).arg(railName));
    beginStage(QStringLiteral("syncing"));

    QTimer::singleShot(0, this, [this, conversationId, railId, toAddress, value, intentId, send,
                                 denom, discloses] {
        if (!ensureWalletOpen())
            return;

        // Spend from what the wallet can actually see; an unsynced note is an
        // InsufficientFunds error rather than a wait.
        QString error;
        if (!syncToTip(&error)) {
            failWallet(QStringLiteral("Could not sync before paying"), error);
            return;
        }

        // The rail does the transfer; this knows only that it takes an address,
        // an amount and a callback. Three of the four prove, which takes
        // minutes — async is the only form that accepts a timeout long enough
        // for that, and it keeps the window responsive meanwhile. The public
        // rail returns in seconds, and the difference is the lesson.
        beginStage(QStringLiteral("sending"));
        send(toAddress, value, [this, conversationId, railId, value, intentId, denom,
                                discloses](Zone::Result res) {
            // The envelope decides, not emptiness. This is the most important
            // of the three sites: a failed transfer returns well-formed JSON,
            // so the old check posted a receipt for a payment the zone had
            // rejected — a card asserting that money moved when it had not,
            // which is the one thing this demo must never do.
            if (!res.ok) {
                failWallet(QStringLiteral("The payment failed"),
                           res.error.isEmpty()
                               ? QStringLiteral("the zone did not accept it — your balance "
                                                "is unchanged")
                               : res.error);
                return;
            }
            walletSave();

            // The receipt goes back into the same conversation, so both sides
            // see the payment where they agreed it. Carrying the intent id is
            // what closes the proposal it settles.
            //
            // It also carries the rail and what that rail disclosed, so the
            // receipt's account of what left the room is the rail's own — not
            // the reader's guess from a single "shielded" flag, which is what
            // it used to be and which had exactly one right answer.
            sendMessage(conversationId,
                        MusterMessage::sendReceipt(QString::number(value), denom, railId,
                                                   discloses, res.tx, intentId));

            deferToEventLoop([this] {
                // Same wait as the shield: a payment the zone accepted is not
                // yet a balance either end can see, and a receipt beside an
                // unchanged balance reads as a payment that did not happen.
                settleAfterTransfer(45000);
                endStage();
                refreshIntents();
            });
        });
    });
}
