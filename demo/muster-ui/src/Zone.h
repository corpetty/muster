#ifndef ZONE_H
#define ZONE_H

// The bits of talking to lez_core that every caller needs and nobody should
// re-derive: how an amount is encoded, how a failure is spelled, and the one
// read that has to go to the sequencer instead of the wallet.
//
// These lived in an anonymous namespace inside ChatBackendWallet.cpp while
// there was one rail. There are several now, and a second copy of the failure
// convention is a second place to get it wrong.

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QString>

namespace Zone {

// The zone the demo settles on. A testnet sequencer, not a local node: the
// wallet is a client of it, which is why this demo needs no chain to sync.
inline const QString kSequencer = QStringLiteral("https://testnet.lez.logos.co");

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
inline QString amountLe16Hex(quint64 v)
{
    QByteArray le(16, '\0');
    for (int i = 0; i < 8; ++i) {
        le[i] = char(v & 0xff);
        v >>= 8;
    }
    return QString::fromLatin1(le.toHex());
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
// 2026-08-11). Every call site goes through this.
struct Result {
    bool ok = false;
    QString tx;
    QString error;
};

inline Result parse(const QString& raw)
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

// One JSON-RPC POST to the sequencer. Used only for public-account reads the
// wallet cannot answer from its own state.
inline bool sequencerPost(const QByteArray& json, QByteArray& out, int seconds = 8)
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

} // namespace Zone

#endif // ZONE_H
