// The execution-zone half of the backend: open a wallet, fund it, and pay a
// shielded address that arrived in a conversation.
//
// Everything here talks to lez_core, the zone module, through the generated
// typed client. The patterns — amount encoding, the faucet's proof of work,
// save-after-every-mutation, sync-before-spend — are taken from
// hackyguru/persona (core/src/logos_wallet_plugin.cpp), which is the worked
// example for driving this module and cost someone a lot of trial and error.
//
// Two rules this file exists to keep:
//   1. Zone calls are synchronous and slow (zk proving runs for minutes). Each
//      entry point defers its work with a zero-timer so the caller's slot
//      returns immediately, and sets walletBusy/walletStage so the view can
//      say what the wait is for.
//   2. The wallet-ffi is in-memory. save() after every mutation, or the next
//      open() silently loses it.

#include "ChatBackend.h"
#include "MusterMessage.h"

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

// The zone the demo settles on. A testnet sequencer, not a local node: the
// wallet is a client of it, which is why this demo needs no chain to sync.
const QString kSequencer = QStringLiteral("https://testnet.lez.logos.co");

// The zone's genesis proof-of-work faucet, and its base58 form for the
// sequencer's account RPC. Both are testnet constants.
const QString kPinataId =
    QStringLiteral("cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe");
const QString kPinataB58 = QStringLiteral("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7");

// What the faucet pays per claim.
constexpr quint64 kPrize = 150;
// Blocks per sync_to_block call. The zone rejects a jump much larger than this.
constexpr int kSyncChunk = 250;

// Zone calls that prove are slow; ones that only read are not. Two timeouts
// rather than one so a dead module surfaces quickly on a read instead of
// hanging the view for the proving budget.
//
// The proving budget is set from a measurement, not a guess: one shielded
// transfer on a 13-core desktop took **6m41s** at full CPU (2026-08-11,
// testnet). Persona's 300s — which is what this was first set to — expires
// mid-proof, and the client then discards a result the zone goes on to
// produce, so the work is done and thrown away. 15 minutes leaves headroom on
// slower hardware. If this ever needs raising again, the honest fix is not a
// bigger number: it is that a payment this slow does not belong behind a
// button the user is waiting on.
constexpr int kReadMs = 15000;
constexpr int kProveMs = 900000;

// u64 -> the 16-byte little-endian hex the zone takes for every amount.
QString amountLe16Hex(quint64 v)
{
    QByteArray le(16, '\0');
    for (int i = 0; i < 8; ++i) {
        le[i] = char(v & 0xff);
        v >>= 8;
    }
    return QString::fromLatin1(le.toHex());
}

// One JSON-RPC POST to the sequencer. Used only for public-account reads the
// wallet cannot answer from its own state.
bool sequencerPost(const QByteArray& json, QByteArray& out, int seconds = 8)
{
    QProcess p;
    p.start(QStringLiteral("curl"),
            {QStringLiteral("-s"), QStringLiteral("-m"), QString::number(seconds),
             QStringLiteral("-X"), QStringLiteral("POST"), QStringLiteral("-H"),
             QStringLiteral("Content-Type: application/json"), QStringLiteral("--data-binary"),
             QString::fromUtf8(json), kSequencer});
    if (!p.waitForFinished((seconds + 2) * 1000))
        return false;
    out = p.readAllStandardOutput().trimmed();
    return !out.isEmpty();
}

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

// The result of a zone call that moves value or registers an account.
//
// `lez_core` has three failure conventions, not the two the labbook first
// recorded. Seventeen of its methods — every `transfer_*`, `claim_pinata`,
// both `register_*`, the vault and generic-transaction calls — return a *JSON
// envelope* rather than a bare transaction id:
//
//     {"success": false, "tx_hash": "", "error": "…: wallet FFI error 99"}
//
// A failure is therefore non-empty, well-formed and truthy, so the obvious
// `if (tx.isEmpty())` reads it as success. That is not hypothetical: it is why
// a shielding step that had hard-failed took the success branch, left the
// prize sitting in the public account, and reported nothing (measured
// 2026-08-11). Every call site here goes through this.
struct ZoneResult {
    bool ok = false;
    QString tx;
    QString error;
};

ZoneResult zoneResult(const QString& raw)
{
    const QJsonObject o = QJsonDocument::fromJson(raw.toUtf8()).object();
    // Empty or unparseable is the *older* convention — a bare empty string on
    // failure — so it is a failure here too rather than a parse bug to ignore.
    if (o.isEmpty())
        return {};
    return { o.value(QStringLiteral("success")).toBool(),
             o.value(QStringLiteral("tx_hash")).toString(),
             o.value(QStringLiteral("error")).toString() };
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

    bool freshAccount = false;
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
        freshAccount = true;
    }

    // Register it on-chain, the same way a public account is registered before
    // the faucet will pay it.
    //
    // HYPOTHESIS, not yet confirmed: an unregistered private account can be
    // *sent* to — the sender's transfer succeeds and their balance drops — but
    // the note is never credited to the recipient, which is exactly the symptom
    // the first two-peer payment hit (2026-08-11: Alice 150 -> 50, Bob stayed
    // at 0, with Bob synced past the transfer and the account ids verified to
    // match). If this turns out not to be the cause, the next suspects are note
    // detection needing a scan this code does not perform, or the shielded keys
    // from get_private_account_keys not being what transfer_private credits.
    //
    // Registration is only ever possible here, at creation, and there is no
    // repair path for an account that missed it. `wallet_ffi` rejects a second
    // attempt with `Guest panicked: Account must be uninitialized` — measured
    // 2026-08-11 on both demo peers, whose accounts were minted before this
    // call existed. So a peer created by an older build cannot be fixed in
    // place; it has to be re-minted, which costs its identity.
    //
    // Attempting it on every open is worse than useless: the call runs a
    // *prover* before it fails, which blocks the wallet long enough for every
    // other lez_core call to hit the generated client's 20s timeout. An
    // earlier draft of this did exactly that and wedged the other peer.
    //
    // And because it proves, it cannot be called here at all: this function is
    // synchronous, and the generated sync client hardcodes 20s. That is why
    // the first attempt never worked even on a fresh account — it timed out
    // before the zone had finished, every time, and the empty `error` field
    // that came back said nothing about why. Registration is therefore a step
    // openWallet performs asynchronously; this only records that it is owed.
    // `freshAccount` only, never "not yet flagged": an account minted in an
    // earlier run is already initialized, so a retry is a guaranteed prover
    // run followed by a guaranteed panic. If registration failed the first
    // time, the peer is unfixable and has to be re-minted — which is worth
    // knowing loudly rather than retrying quietly.
    m_privateAccountNeedsRegistration = freshAccount;
    if (!freshAccount && !meta.value(QStringLiteral("privateAccountRegistered")).toBool()) {
        report(tr("This peer's private account was never registered on-chain, and cannot be "
                  "now — payments to it may not be credited. Re-mint the peer "
                  "(make clean-peer) to fix it."));
    }
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
    const ZoneResult reg = zoneResult(modules().lez_core.register_public_account(id, &err));
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

void ChatBackend::readWalletState()
{
    if (!m_walletOpen)
        return;
    logos::CallError err;

    const QString priv = modules().lez_core.get_balance(m_privateAccount, false, &err);
    if (err.ok())
        setPrivateBalance(priv.trimmed().isEmpty() ? QStringLiteral("0") : priv.trimmed());

    // A public balance lives on-chain, not in the wallet, so it comes from the
    // sequencer rather than from lez_core.
    if (!m_publicAccount.isEmpty()) {
        const QString b58 = modules().lez_core.account_id_to_base58(m_publicAccount, &err);
        QByteArray reply;
        if (err.ok()
            && sequencerPost("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\","
                             "\"params\":[\""
                                 + b58.toUtf8() + "\"]}",
                             reply)) {
            const QJsonValue r = QJsonDocument::fromJson(reply).object().value("result");
            if (r.isDouble())
                setPublicBalance(QString::number(quint64(r.toDouble())));
        }
    }

    // The keys a peer pays into. Shared by shareAddress; held here so the view
    // can show that this instance has something to be paid at.
    const QString keys = modules().lez_core.get_private_account_keys(m_privateAccount, &err);
    if (err.ok())
        setMyReceiveKeys(keys);
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

        // A newly minted private account has to be registered on-chain before
        // anything can be credited to it, and registering *proves*, so it takes
        // minutes and only the async client will wait that long. The wallet is
        // deliberately not Ready until this settles: Ready is what ungates
        // sharing an address, and an address shared before registration lands
        // is an invitation to a payment that may vanish.
        if (m_privateAccountNeedsRegistration) {
            m_privateAccountNeedsRegistration = false;
            beginStage(QStringLiteral("registering"));
            modules().lez_core.register_private_accountAsync(
                m_privateAccount,
                [this](QString raw) {
                    const ZoneResult res = zoneResult(raw);
                    if (!res.ok) {
                        report(tr("Could not register the private account on-chain%1 — "
                                  "payments to it may not be credited. The zone logs the "
                                  "real reason to the app's stdout as [wallet-ffi].")
                                   .arg(res.error.isEmpty()
                                            ? QString()
                                            : QStringLiteral(": %1").arg(res.error)));
                    } else {
                        const QString metaPath = walletDir() + QStringLiteral("/meta.json");
                        QJsonObject meta = readJsonFile(metaPath);
                        meta.insert(QStringLiteral("privateAccountRegistered"), true);
                        writeJsonFile(metaPath, meta);
                        // Positive signal, in the log rather than the error
                        // strip: an absent failure is not evidence this ran.
                        qInfo() << "[muster] registered private account" << m_privateAccount
                                << "tx" << res.tx;
                    }
                    walletSave();
                    deferToEventLoop([this] { finishWalletOpen(); });
                },
                Timeout(kProveMs));
            return;
        }

        finishWalletOpen();
    });
}

void ChatBackend::finishWalletOpen()
{
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
    if (walletBusy())
        return;
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
        if (!sequencerPost("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccount\",\"params\":[\""
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
        const ZoneResult claim = zoneResult(
            modules().lez_core.claim_pinata(kPinataId, publicAccount, amountLe16Hex(solution), &err));
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
            publicAccount, m_privateAccount, amountLe16Hex(funded),
            [this](QString raw) {
                // The envelope, not emptiness: a failed shield comes back as
                // well-formed JSON carrying success:false, and treating that as
                // a transaction id is what silently left the prize public.
                const ZoneResult res = zoneResult(raw);
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
                    QString e;
                    syncToTip(&e);
                    readWalletState();
                    endStage();
                });
            },
            Timeout(kProveMs));
    });
}

void ChatBackend::refreshBalances()
{
    if (walletBusy() || !m_walletOpen)
        return;
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

void ChatBackend::shareAddress(QString conversationId)
{
    if (conversationId.isEmpty())
        return;
    if (myReceiveKeys().isEmpty()) {
        report(QStringLiteral("No receiving address yet — open the wallet first."));
        return;
    }
    sendMessage(conversationId, MusterMessage::addressShare(myReceiveKeys(), myLabel()));
}

void ChatBackend::sendPrivate(QString conversationId, QString toKeysJson, QString amount)
{
    if (walletBusy())
        return;
    if (conversationId.isEmpty() || toKeysJson.isEmpty()) {
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
    payForIntent(conversationId, toKeysJson, value, QString());
}

void ChatBackend::payForIntent(const QString& conversationId, const QString& toKeysJson,
                               quint64 value, const QString& intentId)
{
    // Say so rather than returning silently. A press that produces nothing at
    // all reads as a broken button, and the wallet is busy for *minutes* here —
    // long enough that someone will press it, see nothing, and press again.
    if (walletBusy()) {
        report(tr("The wallet is busy (%1) — wait for that to finish, then pay.")
                   .arg(walletStage().isEmpty() ? tr("working") : walletStage()));
        return;
    }
    if (conversationId.isEmpty() || toKeysJson.isEmpty() || value == 0) {
        report(QStringLiteral("Nothing to pay to."));
        return;
    }

    setWalletError(QString());
    setWalletJob(tr("Paying %1 LEZ").arg(value));
    beginStage(QStringLiteral("syncing"));

    QTimer::singleShot(0, this, [this, conversationId, toKeysJson, value, intentId] {
        if (!ensureWalletOpen())
            return;

        // Spend from what the wallet can actually see; an unsynced note is an
        // InsufficientFunds error rather than a wait.
        QString error;
        if (!syncToTip(&error)) {
            failWallet(QStringLiteral("Could not sync before paying"), error);
            return;
        }

        // Private → private: both ends shielded. This is the step the whole
        // demo exists to show, and the slow one — the zone is proving, which
        // takes minutes. Async is the only form that accepts a timeout long
        // enough for that, and it keeps the window responsive meanwhile.
        beginStage(QStringLiteral("sending"));
        modules().lez_core.transfer_privateAsync(
            m_privateAccount, toKeysJson, amountLe16Hex(value),
            [this, conversationId, value, intentId](QString raw) {
                // The envelope decides, not emptiness. This is the most
                // important of the three sites: a failed transfer returns
                // well-formed JSON, so the old check posted a receipt for a
                // payment the zone had rejected — a card asserting that money
                // moved when it had not, which is the one thing this demo
                // must never do.
                const ZoneResult res = zoneResult(raw);
                if (!res.ok) {
                    failWallet(QStringLiteral("The payment failed"),
                               res.error.isEmpty()
                                   ? QStringLiteral("the zone did not accept it — your balance "
                                                    "is unchanged")
                                   : res.error);
                    return;
                }
                walletSave();

                // The receipt goes back into the same conversation, so both
                // sides see the payment where they agreed it. Carrying the
                // intent id is what closes the proposal it settles.
                sendMessage(conversationId,
                            MusterMessage::sendReceipt(QString::number(value), res.tx, true,
                                                       intentId));

                deferToEventLoop([this] {
                    QString e;
                    syncToTip(&e);
                    readWalletState();
                    endStage();
                    refreshIntents();
                });
            },
            Timeout(kProveMs));
    });
}
