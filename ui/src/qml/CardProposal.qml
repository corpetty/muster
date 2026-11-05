import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A proposal card's body (exo-720.3, moved verbatim out of MusterCard.qml): what it
// does, its status rail, approvals, the verify box, provenance and every kind's parts.
// Compact by default (exo-720.10): the effect, its parts, the approvals and anything to
// heed stay on the face; the explanations wait behind the card's Details.
// `cardRoot` is the MusterCard, as before the move.
// ── intent-propose (the heart) ─────────────────────────────────────
// The room deciding something before anyone acts on it. The effect
// leads (amount → destination), a status rail shows how far it has
// got, and approvals are drawn as filled slots — because "who is still
// to weigh in" is the question people actually have.
ColumnLayout {
    required property var cardRoot

    visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
    Layout.fillWidth: true
    spacing: Theme.spacing.tiny

    // header: label · M of N  (· round R of N for multi-round)
    LogosText {
        objectName: "cardHeader"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: {
            var label = cardRoot.card && cardRoot.card.label
                ? String(cardRoot.card.label) : qsTr("Proposal");
            var head = cardRoot.threshold > 0
                ? label + "  ·  " + qsTr("%1 of %2").arg(cardRoot.threshold)
                                                    .arg(cardRoot.signerCount)
                : label;
            // FROST-style multi-round: name the round being collected and the
            // distinct approvals in it — the honest "M of k this round".
            if (cardRoot.rounds > 1 && !cardRoot.ready)
                head += "  ·  " + qsTr("round %1 of %2 (%3 of %4 this round)")
                            .arg(cardRoot.roundNo).arg(cardRoot.rounds)
                            .arg(cardRoot.roundApprovals).arg(cardRoot.threshold);
            else if (cardRoot.rounds > 1)
                head += "  ·  " + qsTr("%1 rounds complete").arg(cardRoot.rounds);
            return head;
        }
        color: Theme.palette.text
        font.family: Theme.typography.publicSans
        font.pixelSize: MusterStyle.cardBody
        font.weight: Theme.typography.weightBold
    }

    // the effect. A statement shows its text (quoted); a payment shows
    // amount denom → to. A statement carries no destination — it is a group
    // endorsement, not a transfer.
    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        visible: text.length > 0
        text: {
            // a generic module action (P-D4): "call module.method(N args)" — the
            // action lives in the effect, not the driver, so the card reads it off
            // the effect the same way it reads a payment's amount → destination.
            var act = String((cardRoot.card && cardRoot.card.action) || "");
            if (act.length > 0) {
                var args = (cardRoot.card && cardRoot.card.actionArgs)
                         ? cardRoot.card.actionArgs : [];
                var n = args.length;
                return qsTr("call %1(%2)").arg(act)
                    .arg(n === 0 ? "" : qsTr("%1 %2").arg(n)
                         .arg(n === 1 ? qsTr("arg") : qsTr("args")));
            }
            var stmt = String((cardRoot.card && cardRoot.card.statement) || "");
            if (stmt.length > 0)
                return "“" + stmt + "”";
            var amt = String((cardRoot.card && cardRoot.card.amount) || "");
            var den = String((cardRoot.card && cardRoot.card.denom) || "");
            var to = String((cardRoot.card && cardRoot.card.to) || "");
            var lead = cardRoot.amountText(amt, den);
            return to.length > 0 ? lead + "  →  " + to : lead;
        }
        color: Theme.palette.text
        font.family: Theme.typography.publicSans
        font.pixelSize: Theme.typography.subtitleText
        font.weight: Theme.typography.weightMedium
    }

    // ── a settle-up (exo-3c6): the net payments instead, and where each stands ──
    ColumnLayout {
        objectName: "cardSettleUp"
        visible: cardRoot.isSettleUp
        Layout.fillWidth: true
        spacing: 2

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.settleUp
                  // fewer payments than shares: netting ("instead of"); as many: a renewal,
                  // each share paid again as it was (exo-a90.15) — "for"
                  ? ((cardRoot.settleUp.transfers || []).length < Number(cardRoot.settleUp.covers || 0)
                     ? qsTr("Settle up%1 — %2 instead of %3 from %4") : qsTr("Settle up%1 — %2 for %3 from %4"))
                        .arg(String(cardRoot.settleUp.memo || "").length > 0 ? " · " + String(cardRoot.settleUp.memo) : "")
                        .arg((cardRoot.settleUp.transfers || []).length === 1 ? qsTr("1 payment")
                             : qsTr("%1 payments").arg((cardRoot.settleUp.transfers || []).length))
                        .arg(Number(cardRoot.settleUp.covers || 0) === 1 ? qsTr("1 share")
                             : qsTr("%1 shares").arg(Number(cardRoot.settleUp.covers || 0)))
                        .arg(Number(cardRoot.settleUp.splits || 0) === 1 ? qsTr("1 split")
                             : qsTr("%1 splits").arg(Number(cardRoot.settleUp.splits || 0)))
                  : ""
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightMedium
        }
        // across assets and chains (exo-a90.17): what it covers, and each rate — the
        // proposer's quote, named before anyone agrees, like a fiat bill's
        LogosText {
            objectName: "cardSettleUpAcross"
            visible: !!(cardRoot.settleUp && cardRoot.settleUp.across)
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: {
                if (!cardRoot.settleUp || !cardRoot.settleUp.across) return "";
                var as = (cardRoot.settleUp.coverAssets || []).map(function (a) {
                    return qsTr("%1 on %2").arg(String(a.symbol || a.asset)).arg(String(a.chainLabel || a.chain));
                });
                return qsTr("Covers shares in %1; every payment is %2 on %3.")
                       .arg(as.join(", ")).arg(cardRoot.unit)
                       .arg(String(cardRoot.settleUp.chainLabel || cardRoot.settleUp.chain || ""));
            }
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }
        Repeater {
            model: (cardRoot.settleUp && cardRoot.settleUp.across) ? (cardRoot.settleUp.rates || []) : []
            delegate: LogosText {
                required property var modelData
                objectName: "cardSettleUpRate"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: String(modelData.perUnit || "").length > 0
                      ? qsTr("1 %1 = %2 %3 — %4, from “%5”, %6")
                            .arg(String(modelData.symbol || modelData.asset)).arg(cardRoot.eth(modelData.perUnit))
                            .arg(cardRoot.unit).arg(cardRoot.rateOwner).arg(String(modelData.source || ""))
                            .arg(new Date(Number(modelData.at) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat))
                      : qsTr("%1 %2 base units per %3 base units of %4 — %5, from “%6” (this client could not read %4's decimals)")
                            .arg(String(modelData.rate)).arg(cardRoot.unit).arg(String(modelData.per))
                            .arg(String(modelData.symbol || modelData.asset)).arg(cardRoot.rateOwner)
                            .arg(String(modelData.source || ""))
                color: Theme.palette.text
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.cardCaption
            }
        }
        LogosText {
            visible: !!(cardRoot.settleUp && cardRoot.settleUp.across)
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Agreeing means trusting these rates: check them first. Each share is converted at its rate, rounded down; nothing in muster makes a rate fair.")
            color: Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }
        Repeater {
            model: cardRoot.settleUp ? (cardRoot.settleUp.transfers || []) : []
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    Layout.preferredWidth: 220
                    elide: Text.ElideRight
                    text: (String(modelData.fromName || "") || String(modelData.from).slice(0, 10) + "…") + "  →  "
                          + (String(modelData.toName || "") || String(modelData.to).slice(0, 10) + "…")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.cardCaption
                }
                LogosText {
                    text: qsTr("%1 %2").arg(cardRoot.eth(modelData.amount)).arg(cardRoot.unit)
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.cardCaption
                }
                LogosText {
                    Layout.fillWidth: true
                    text: modelData.confirmed ? qsTr("received ✓") : modelData.settled ? qsTr("paid — awaiting the recipient's read")
                          : modelData.unresolved ? qsTr("sent — not landed yet, still watched")
                          : modelData.paying ? qsTr("paying…") : cardRoot.settleUp.expired ? qsTr("expired")
                          : cardRoot.ready ? qsTr("to pay") : qsTr("once everyone agrees")
                    color: modelData.confirmed ? Theme.palette.success : Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.cardCaption
                }
            }
        }
        // a recipient owed only on other chains is paid at an address they vouch for
        Repeater {
            model: cardRoot.settleUp ? (cardRoot.settleUp.transfers || []).filter(function (t) { return t.vouched; }) : []
            delegate: LogosText {
                required property var modelData
                objectName: "cardSettleUpVouched"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: modelData.toMe && !modelData.payToMine
                      ? qsTr("⚠ You would be paid at %1, which this client does not hold — so it will not agree for you.")
                            .arg(String(modelData.payTo))
                      : modelData.toMe
                      ? qsTr("You are paid at %1 — the address you shared for this chain; your agreement vouches for it.")
                            .arg(String(modelData.payTo))
                      : qsTr("%1 is paid at %2 — an address %1 shared for this chain; their agreement vouches for it.")
                            .arg(String(modelData.toName || "") || String(modelData.to).slice(0, 10) + "…")
                            .arg(String(modelData.payTo))
                color: modelData.toMe && !modelData.payToMine ? Theme.palette.warning : Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }
        }
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.settleUp && cardRoot.settleUp.across
                  ? qsTr("Each member's balance across these splits is kept exactly, at these rates. Once agreed, the covered shares are paid only through this; once its payments are received, each creditor marks the shares it covered received, on whatever chain they were.")
                  : qsTr("Each member's balance across these splits is kept exactly; each person is paid where their own split said. Once agreed, the covered shares are paid only through this; once its payments are received, each creditor marks the shares it covered received.")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }
        // expired before anyone paid (exo-a90.16): it pays nothing more, and after a
        // day's grace — for a payment sent just before the expiry — it covers nothing
        LogosText {
            objectName: "cardSettleUpExpired"
            visible: !!(cardRoot.settleUp && cardRoot.settleUp.expired)
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: !cardRoot.settleUp ? ""
                  : cardRoot.settleUp.lapsed
                  ? qsTr("Expired before anyone paid. It no longer covers its shares: each can be paid directly again, or settled up anew.")
                  : qsTr("Expired before anyone paid. Its shares are released %1, in case a payment sent just before the expiry is still to be reported.")
                        .arg(new Date(Number(cardRoot.settleUp.releasesAt) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat))
            color: Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }
    }

    // ── a split (exo-a90): who owes whom what, and where each share stands ──
    ColumnLayout {
        objectName: "cardSplit"
        visible: cardRoot.isSplit
        Layout.fillWidth: true
        spacing: 2

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.isRequest
                  ? cardRoot.requestLine()
                  : cardRoot.split
                  ? qsTr("%1 %2%3 — %4 paid; %5%6")
                        .arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit)
                        .arg(String(cardRoot.split.memo || "").length > 0 ? " · " + String(cardRoot.split.memo) : "")
                        .arg(cardRoot.creditorName)
                        .arg(cardRoot.parts.length === 1 ? qsTr("1 person owes a share")
                                                         : qsTr("%1 people owe a share").arg(cardRoot.parts.length))
                        .arg(cardRoot.split.private ? qsTr(" · private: the chain names no one") : "")
                  : ""
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightMedium
        }

        Repeater {
            model: cardRoot.parts
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    Layout.preferredWidth: 110
                    elide: Text.ElideRight
                    text: String(modelData.name || "").length > 0 ? String(modelData.name)
                          : String(modelData.who || "").slice(0, 10) + "…"
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.cardCaption
                }
                LogosText {
                    text: qsTr("%1 %2").arg(cardRoot.eth(modelData.amount)).arg(cardRoot.unit)
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.cardCaption
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    // while Mark received is armed: what pressing it again does
                    text: markRow.armed
                          ? (cardRoot.isXmr
                             ? qsTr("Your word, with no wallet check: the share counts as paid and can't be paid through the room after.")
                             : qsTr("Your word, with no check: the share counts as paid and can't be paid through the room after."))
                          : cardRoot.partState(modelData)
                    color: markRow.armed ? Theme.palette.warning
                         : modelData.confirmed ? Theme.palette.success
                         : modelData.settled ? Theme.palette.textSecondary : Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.cardCaption
                }
                // the creditor's word: a share paid in cash, or anywhere muster cannot see.
                // It ends the share for good, so it takes a second press. On Monero the
                // creditor's own wallet confirms on its own, so it is offered only once the
                // payer has said they paid: before that there is nothing to have received,
                // and marking it would close the payment unpaid.
                RowLayout {
                    id: markRow
                    property bool armed: false
                    visible: cardRoot.iAmCreditor && cardRoot.ready && !cardRoot.paid && !modelData.confirmed
                             && (!cardRoot.isXmr || !!modelData.settled)
                    spacing: Theme.spacing.tiny
                    ActionButton {
                        objectName: "cardMarkReceived"
                        text: markRow.armed ? qsTr("Yes, I have it") : qsTr("Mark received")
                        variant: markRow.armed ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: {
                            if (!markRow.armed) { markRow.armed = true; markDisarm.restart(); return; }
                            markRow.armed = false;
                            cardRoot.confirmPart(String(modelData.part || ""));
                        }
                    }
                    ActionButton {
                        objectName: "cardMarkReceivedCancel"
                        visible: markRow.armed
                        text: qsTr("Cancel")
                        variant: LogosButton.Variant.Secondary
                        onClicked: markRow.armed = false
                    }
                    Timer { id: markDisarm; interval: 15000; onTriggered: markRow.armed = false }
                }
            }
        }

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            // a request's payTo stays on the face: it is what the payer checks
            visible: cardRoot.split !== null && (cardRoot.isRequest || cardRoot.detailsOpen)
            text: cardRoot.isRequest
                  ? qsTr("Paid to %1%2.").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                        .arg(!cardRoot.isXmr ? ""
                             : cardRoot.iAmCreditor ? qsTr(", a subaddress of your own Monero wallet on %1")
                                                          .arg(String(cardRoot.xmr.chainLabel || ""))
                             : qsTr(", a subaddress of %1's own Monero wallet on %2")
                                   .arg(cardRoot.creditorName).arg(String(cardRoot.xmr.chainLabel || "")))
                  : cardRoot.split
                  ? qsTr("%1 own share: %2 %3 (it absorbs any rounding). Paid to %4.")
                        .arg(cardRoot.iAmCreditor ? qsTr("Your") : cardRoot.creditorName + qsTr("'s"))
                        .arg(cardRoot.eth(cardRoot.split.creditorShare)).arg(cardRoot.unit)
                        .arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                  : ""
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }
        // the whole payTo, however the line above shortened it: what a payer pays to from a
        // wallet of their own, in any asset
        CopyButton {
            objectName: "cardPayToCopy"
            label: qsTr("Copy address")
            visible: value.length > 0 && cardRoot.split !== null && (cardRoot.isRequest || cardRoot.detailsOpen)
            value: String((cardRoot.split && cardRoot.split.payTo) || "")
        }

        // a bill in fiat (exo-3a4): the quote everyone agreeing is trusting — named, sourced,
        // timed — so it is checked before anyone agrees, not after
        LogosText {
            objectName: "cardSplitQuote"
            readonly property var q: (cardRoot.split && cardRoot.split.quote) ? cardRoot.split.quote : null
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: q !== null
            text: {
                if (!q) return "";
                var fd = Number(q.fiatDecimals || 2), r = String(q.fiatTotal || "0");
                while (r.length <= fd) r = "0" + r;
                var fiat = fd === 0 ? r : r.slice(0, r.length - fd) + "." + r.slice(r.length - fd);
                var who = (cardRoot.card && Array.isArray(cardRoot.card.proposedBy) && cardRoot.card.proposedBy.length > 0)
                          ? String(cardRoot.card.proposedBy[0].name || "") : "";
                var when = new Date(Number(q.at || 0) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat);
                return qsTr("A bill of %1 %2, converted at 1 %2 = %3 %4 — %5 quote, from “%6”, %7. Agreeing means trusting this rate: check it first.")
                       .arg(fiat).arg(String(q.currency)).arg(cardRoot.eth(String(q.rateAsset))).arg(cardRoot.unit)
                       .arg(who === "you" ? qsTr("your") : who.length > 0 ? who + qsTr("'s") : qsTr("the proposer's"))
                       .arg(String(q.source)).arg(when);
            }
            color: Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }

        // a split paid in a token: which token, by address — its symbol is its own claim
        LogosText {
            objectName: "cardSplitToken"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: cardRoot.detailsOpen && cardRoot.token.length > 0
            text: qsTr("Paid in %1 — the token at %2 (a token names itself; the address is what counts).")
                      .arg(cardRoot.unit).arg(cardRoot.token.slice(0, 10) + "…" + cardRoot.token.slice(-6))
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }

        // on someone's behalf (exo-770): who proposed it, and whether the creditor has
        // said payTo is theirs — nobody pays before they do
        LogosText {
            objectName: "cardSplitOnBehalf"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: cardRoot.onBehalfBy.length > 0 && (!cardRoot.creditorAgreed || cardRoot.detailsOpen)
            text: cardRoot.creditorAgreed && cardRoot.iAmCreditor
                  ? qsTr("Proposed by %1 on your behalf. ✓ You agreed that %2 is yours.")
                        .arg(cardRoot.onBehalfBy).arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                  : cardRoot.creditorAgreed
                  ? qsTr("Proposed by %1 on %2's behalf. ✓ %2 agreed the address is theirs.")
                        .arg(cardRoot.onBehalfBy).arg(cardRoot.creditorName)
                  : cardRoot.iAmCreditor
                  ? qsTr("Proposed by %1 on your behalf. Nobody pays until you agree that %2 is yours.")
                        .arg(cardRoot.onBehalfBy).arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                  : qsTr("Proposed by %1 on %2's behalf. Nobody pays until %2 agrees the address is theirs.")
                        .arg(cardRoot.onBehalfBy).arg(cardRoot.creditorName)
            color: cardRoot.creditorAgreed ? Theme.palette.textSecondary : Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }
        // the creditor's own client: a payTo it does not hold is never agreed to
        LogosText {
            objectName: "cardSplitPayToNotMine"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: cardRoot.iAmCreditor && !cardRoot.creditorAgreed && !cardRoot.payToMine && !cardRoot.payToMineUnknown
            text: qsTr("⚠ %1 is not an address this client holds, so muster will not agree for you: payments would go to whoever holds it. Share your own address and ask for the split again.")
                      .arg(cardRoot.shortPayTo(String(cardRoot.split ? cardRoot.split.payTo || "" : "")))
            color: Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }

        LogosText {
            objectName: "cardMyShare"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: cardRoot.detailsOpen && cardRoot.iAmDebtor && !cardRoot.isXmr
            text: cardRoot.myPart
                  ? qsTr("Your share: %1 %2 → %3, from your own wallet%4. Muster builds the payment from this split — nothing to type, and nothing else can be sent.")
                        .arg(cardRoot.eth(cardRoot.myPart.amount)).arg(cardRoot.unit).arg(cardRoot.creditorName)
                        .arg(cardRoot.split && cardRoot.split.private ? qsTr(", on the private rail") : "")
                  : ""
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }

        // ── a Monero request (exo-dcc.5): MY share's link, from the module's
        // projection — derived from the request everyone agreed, never typed ──
        ColumnLayout {
            id: xmrPayBox
            objectName: "cardXmrPay"
            visible: cardRoot.isXmr && cardRoot.iAmDebtor && cardRoot.xmrPay !== null
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny
            readonly property var pay: cardRoot.xmrPay || ({})
            readonly property bool linkShown: !!pay.ok && !pay.reported && !pay.confirmed && !cardRoot.splitExpired
            property bool walletAsked: false   // Pay with Monero Wallet was pressed

            LogosText {
                objectName: "cardXmrPayLine"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var p = xmrPayBox.pay;
                    if (p.confirmed)
                        return String((cardRoot.myPart && cardRoot.myPart.tx) || "").length > 0
                               ? qsTr("✓ %1's wallet confirmed your payment.").arg(cardRoot.creditorName)
                               : qsTr("✓ %1 marked it received.").arg(cardRoot.creditorName);
                    if (p.reported)
                        return qsTr("You said you paid. %1's own wallet confirms it once it has %2 confirmations (about 20 minutes).")
                               .arg(cardRoot.creditorName).arg(cardRoot.xmrDepth);
                    if (!p.ok)
                        return String(p.why || "").indexOf("not-agreed") === 0
                               ? qsTr("Your share: %1 XMR to %2. The link to pay it appears here once everyone named has agreed.")
                                     .arg(cardRoot.eth(cardRoot.myPart ? cardRoot.myPart.amount : "0")).arg(cardRoot.creditorName)
                               : qsTr("⚠ No link to pay: %1").arg(cardRoot.xmrDetail(p.why));
                    return qsTr("Pay %1 XMR to %2 from any Monero wallet: Cake, Feather or Basecamp's Monero Wallet. Scan the code or copy the link: it carries the address and the exact amount. Muster never sends Monero.")
                           .arg(cardRoot.eth(p.amount)).arg(cardRoot.creditorName);
                }
                color: !xmrPayBox.pay.ok && String(xmrPayBox.pay.why || "").indexOf("not-agreed") !== 0
                       ? Theme.palette.warning : Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }

            // the link as a QR code, for a wallet on a phone
            QrCode {
                objectName: "cardXmrQr"
                visible: xmrPayBox.linkShown && size > 0
                text: xmrPayBox.linkShown ? String(xmrPayBox.pay.uri || "") : ""
                Layout.preferredWidth: 196
                Layout.preferredHeight: 196
            }
            // the link itself, whole: what the code holds
            TextEdit {
                objectName: "cardXmrUri"
                visible: xmrPayBox.linkShown
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                text: String(xmrPayBox.pay.uri || "")
                color: Theme.palette.text
                selectionColor: Theme.palette.primary
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.cardCaption
            }
            RowLayout {
                visible: xmrPayBox.linkShown
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                ActionButton {
                    id: copyLink
                    objectName: "cardXmrCopy"
                    property bool copied: false
                    text: copied ? qsTr("✓ Copied") : qsTr("Copy link")
                    variant: LogosButton.Variant.Secondary
                    onClicked: {
                        clip.text = String(cardRoot.xmrPay ? cardRoot.xmrPay.uri || "" : "");
                        clip.selectAll();
                        clip.copy();
                        copied = true;
                        copiedReset.restart();
                    }
                    TextEdit { id: clip; visible: false; width: 0; height: 0 }
                    Timer { id: copiedReset; interval: 1500; onTriggered: copyLink.copied = false }
                }
                // the address alone, for a wallet that takes an address and an amount
                // rather than a monero: link
                CopyButton {
                    objectName: "cardXmrCopyAddress"
                    label: qsTr("Copy address")
                    value: String(xmrPayBox.pay.payTo || "")
                }
                // Pay with Basecamp's own Monero Wallet: ask it to fill its Send tab with the
                // agreed address and amount (monero.wallet.send); the person checks them and
                // sends there. A wallet without that intent (0.1.1) is brought up on its own
                // view instead, and the two go across by hand. The address is copied either
                // way. Muster still sends nothing and approves nothing (ADR-018).
                ActionButton {
                    objectName: "cardXmrPayWithWallet"
                    text: qsTr("Pay with Monero Wallet")
                    onClicked: {
                        clip.text = String(xmrPayBox.pay.payTo || "");
                        clip.selectAll();
                        clip.copy();
                        xmrPayBox.walletAsked = true;
                        cardRoot.presentMoneroWallet(String(xmrPayBox.pay.payTo || ""), cardRoot.eth(xmrPayBox.pay.amount));
                    }
                }
                ActionButton {
                    objectName: "cardXmrCopyAmount"
                    visible: xmrPayBox.walletAsked
                    text: qsTr("Copy amount")
                    variant: LogosButton.Variant.Secondary
                    onClicked: {
                        clip.text = cardRoot.eth(xmrPayBox.pay.amount);
                        clip.selectAll();
                        clip.copy();
                    }
                }
                Item { Layout.fillWidth: true }
            }
            LogosText {
                objectName: "cardXmrPayWithWalletHint"
                visible: xmrPayBox.linkShown && xmrPayBox.walletAsked
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                // the steps always; the wallet's answer too when it did not simply open
                text: {
                    var steps = cardRoot.moneroWalletFilled
                        ? qsTr("Monero Wallet's Send is filled in with %1's address and %2 XMR. Check both there, send, then come back and press I paid.")
                              .arg(cardRoot.creditorName).arg(cardRoot.eth(xmrPayBox.pay.amount))
                        : qsTr("The address is copied. If Monero Wallet's Send isn't filled in, paste the address there and enter exactly %1 XMR (Copy amount puts it on the clipboard). Send from there, then come back and press I paid.")
                              .arg(cardRoot.eth(xmrPayBox.pay.amount));
                    var n = cardRoot.moneroWalletNote;
                    return (n.length > 0 && n.indexOf(qsTr("Monero Wallet is open")) !== 0 && n !== qsTr("Your Monero wallet is open."))
                           ? steps + "\n" + n : steps;
                }
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }

            // "I paid": the debtor's claim, with the transaction id if they give one
            RowLayout {
                visible: xmrPayBox.linkShown
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: xmrTx
                    objectName: "cardXmrTx"
                    Layout.fillWidth: true
                    placeholderText: qsTr("transaction id (optional)")
                    font.family: MusterStyle.mono
                }
                ActionButton {
                    objectName: "cardXmrPaid"
                    readonly property string tx: String(xmrTx.text || "").trim().toLowerCase()
                    enabled: tx.length === 0 || /^[0-9a-f]{64}$/.test(tx)
                    text: qsTr("I paid")
                    onClicked: cardRoot.reportPaid(tx)
                }
            }
            LogosText {
                visible: xmrPayBox.linkShown
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: String(xmrTx.text || "").trim().length > 0 && !/^[0-9a-fA-F]{64}$/.test(String(xmrTx.text || "").trim())
                      ? qsTr("⚠ A transaction id is 64 hex characters. Leave it empty if you don't have it.")
                      : qsTr("“I paid” tells the room; it doesn't confirm anything. %1's own wallet confirms the payment when it reaches %2 confirmations.")
                            .arg(cardRoot.creditorName).arg(cardRoot.xmrDepth)
                color: String(xmrTx.text || "").trim().length > 0 && !/^[0-9a-fA-F]{64}$/.test(String(xmrTx.text || "").trim())
                       ? Theme.palette.warning : Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }
        }

        // on the creditor's client: can my own wallet confirm these payments?
        ColumnLayout {
            id: xmrWalletBox
            objectName: "cardXmrWallet"
            visible: cardRoot.isXmr && cardRoot.iAmCreditor && cardRoot.xmrWallet !== null && !cardRoot.paid
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny
            readonly property var w: cardRoot.xmrWallet || ({})
            LogosText {
                objectName: "cardXmrWalletLine"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: xmrWalletBox.w.ready
                      ? qsTr("Your Monero wallet is open on %1: it confirms each payment once it has %2 confirmations. You can also mark a share received yourself.")
                            .arg(String(cardRoot.xmr ? cardRoot.xmr.chainLabel || "" : "")).arg(cardRoot.xmrDepth)
                      : String(xmrWalletBox.w.code || "") === "wallet-unread" || String(xmrWalletBox.w.code || "") === "wallet-busy"
                      ? qsTr("Your Monero wallet hasn't answered yet, so nothing is confirmed for now. %1").arg(cardRoot.xmrDetail(xmrWalletBox.w.detail))
                      : qsTr("⚠ Your Monero wallet can't confirm payments now: %1").arg(cardRoot.xmrDetail(xmrWalletBox.w.detail, xmrWalletBox.w.code))
                color: xmrWalletBox.w.ready ? Theme.palette.textSecondary
                     : String(xmrWalletBox.w.request || "").length > 0 ? Theme.palette.warning : Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }
            // which wallet Monero Wallet opens (exo-dcc.20): the one the module names;
            // several that could be it, one button each; none at all, set one up there
            readonly property var choices: Array.isArray(xmrWalletBox.w.wallets) ? xmrWalletBox.w.wallets : []
            readonly property bool asks: !xmrWalletBox.w.ready && String(xmrWalletBox.w.request || "") === "monero.wallet.unlock"
            ActionButton {
                objectName: "cardXmrOpenWallet"
                visible: xmrWalletBox.asks && xmrWalletBox.choices.length < 2
                text: xmrWalletBox.w.noWallet ? qsTr("Set up a wallet in Monero Wallet") : qsTr("Open Monero Wallet")
                variant: LogosButton.Variant.Secondary
                onClicked: cardRoot.openMoneroWallet(String(xmrWalletBox.w.wallet || ""))
            }
            LogosText {
                objectName: "cardXmrPickWallet"
                visible: xmrWalletBox.asks && xmrWalletBox.choices.length > 1
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Which wallet is this request's? Open it in Monero Wallet:")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
            Flow {
                visible: xmrWalletBox.asks && xmrWalletBox.choices.length > 1
                Layout.fillWidth: true
                spacing: Theme.spacing.tiny
                Repeater {
                    model: xmrWalletBox.asks && xmrWalletBox.choices.length > 1 ? xmrWalletBox.choices : []
                    delegate: ActionButton {
                        required property var modelData
                        objectName: "cardXmrOpenWallet_" + String(modelData)
                        text: qsTr("Open %1").arg(String(modelData))
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.openMoneroWallet(String(modelData))
                    }
                }
            }
            LogosText {
                objectName: "cardXmrWalletNote"
                visible: !xmrWalletBox.w.ready && cardRoot.moneroWalletNote.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.moneroWalletNote
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
        }
    }

    // What a Safe transaction CALLS and HOW (exo-a50.1.4): the data it carries, and
    // a DELEGATECALL named for what it is — the target's code runs AS the Safe and
    // can rewrite its owners (the Bybit vector). Muster refuses to sign one unless
    // this client allowlists the target; the card says so rather than hiding it.
    LogosText {
        Layout.fillWidth: true
        visible: cardRoot.detailsOpen && String((cardRoot.card && cardRoot.card.safeData) || "").length > 2
        text: {
            var d = String((cardRoot.card && cardRoot.card.safeData) || "");
            var n = Math.max(0, Math.floor((d.length - 2) / 2));
            return qsTr("with data %1 (%2 bytes)").arg(d.slice(0, 10) + (d.length > 10 ? "…" : "")).arg(n);
        }
        color: Theme.palette.textSecondary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.cardCaption
        wrapMode: Text.WrapAnywhere
    }
    LogosText {
        objectName: "cardDelegatecall"
        Layout.fillWidth: true
        visible: cardRoot.card && Number(cardRoot.card.operation) === 1
        text: qsTr("DELEGATECALL: this runs %1's code as the Safe itself. It can change the Safe's owners, threshold and modules. Muster signs it only if you have allowlisted that target.")
              .arg(String((cardRoot.card && cardRoot.card.to) || ""))
        color: Theme.palette.error
        font.pixelSize: MusterStyle.cardCaption
        font.weight: Theme.typography.weightMedium
        wrapMode: Text.WordWrap
    }

    // trace this: the effect is a peer-message (someone proposed it into the
    // room). One tap opens the lineage focused on that origin — the card
    // element leads to where it came from, not a separate hunt.
    Item {
        Layout.fillWidth: true
        implicitHeight: effectTrace.implicitHeight
        visible: cardRoot.detailsOpen && !!(cardRoot.card && cardRoot.card.provenance)
                 && cardRoot.card.provenance.length > 0
        LogosText {
            id: effectTrace
            text: qsTr("⌕ trace this")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: cardRoot.traceClass("peer-message")
        }
    }

    // which rail the room is being asked to agree to
    // a LEZ rail in words; any other value is the driver's kind, said elsewhere already
    LogosText {
        readonly property string railWords: {
            var r = String((cardRoot.card && cardRoot.card.rail) || "");
            return r === "public" ? qsTr("Public: both ends and the amount are visible on the zone")
                 : r === "shield" ? qsTr("Into a private account: who receives is hidden")
                 : r === "deshield" ? qsTr("Out of a private account: who pays is hidden")
                 : r === "private" ? qsTr("Private: both ends and the amount are hidden")
                 : "";
        }
        Layout.fillWidth: true
        visible: cardRoot.detailsOpen && railWords.length > 0
        wrapMode: Text.WordWrap
        text: railWords
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.cardCaption
    }

    // ── status rail: proposed → collecting → ready → paid ──────────
    // The whole path is drawn from the first card; a step at or before
    // the current state is lit, everything after stays drawn but unlit.
    RowLayout {
        visible: cardRoot.detailsOpen    // the header's pill says where it stands; this, the whole path
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        spacing: Theme.spacing.tiny

        Repeater {
            model: [{ k: "proposed", t: qsTr("proposed") },
                    { k: "collecting", t: qsTr("collecting") },
                    { k: "ready", t: qsTr("ready") },
                    { k: "paid", t: qsTr("final") }]

            delegate: RowLayout {
                id: step
                required property var modelData
                required property int index
                spacing: 3

                readonly property bool lit:
                    step.index <= ["proposed", "collecting", "ready", "paid"]
                                    .indexOf(cardRoot.state)

                Rectangle {
                    implicitWidth: 6
                    implicitHeight: 6
                    radius: 3
                    color: step.lit ? Theme.palette.success
                                    : Theme.palette.borderSubtle
                }

                LogosText {
                    text: step.modelData.t
                    color: step.lit ? Theme.palette.textSecondary
                                    : Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.cardCaption
                }

                Item { Layout.preferredWidth: Theme.spacing.small }
            }
        }
    }

    // ── a LEZ step the chain has not included yet (exo-3c9) ────────
    // A vote-locus approval and the Execute are members' own chain
    // transactions: sent at once, they count only once a block includes them.
    LogosText {
        objectName: "cardChainPending"
        visible: cardRoot.kind === "intent-propose" && !!(cardRoot.card && cardRoot.card.chainPending)
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: cardRoot.card && cardRoot.card.chainPending === "settle"
              ? qsTr("⏳ Executing on chain — final once a block includes it.")
              : qsTr("⏳ Your vote is on its way to the chain — it counts once a block includes it.")
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.cardCaption
    }

    // ── approval slots ─────────────────────────────────────────────
    // Slots fill as approvals arrive; the empty ones are drawn too,
    // because the shape of what is missing is the information. An
    // approver's initials show when the card carried them.
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        spacing: 4

        Repeater {
            model: cardRoot.threshold

            delegate: Rectangle {
                id: slot
                required property int index

                // Filled up to the approvals so far; initials come from
                // the approvers array when it is long enough.
                readonly property bool filled: slot.index < cardRoot.approvals
                // committed approvals fill first; the last `unattested` filled
                // slots are the pasted ones, drawn as a ring, not a solid dot.
                readonly property bool pasted: slot.filled
                    && slot.index >= cardRoot.approvals - cardRoot.unattested
                readonly property var who: cardRoot.card && cardRoot.card.approvers
                    && slot.index < cardRoot.card.approvers.length
                    ? cardRoot.card.approvers[slot.index] : null

                implicitWidth: 22
                implicitHeight: 22
                radius: 11
                color: slot.filled && !slot.pasted ? Theme.palette.success : "transparent"
                border.width: slot.pasted ? 2 : (slot.filled ? 0 : 1)
                border.color: slot.pasted ? Theme.palette.warning : Theme.palette.borderSubtle

                // who, as the same face they have in the roster: their colour, your name's letter
                Avatar {
                    anchors.centerIn: parent
                    visible: slot.filled && !slot.pasted && slot.who !== null
                    size: 22
                    identity: slot.who ? String(slot.who.who || "") : ""
                    name: slot.who ? (slot.who.mine ? qsTr("you") : String(slot.who.name || "")) : ""
                }
                LogosText {
                    anchors.centerIn: parent
                    visible: slot.filled && (slot.pasted || slot.who === null)
                    text: slot.who && slot.who.initials
                        ? String(slot.who.initials).charAt(0) : ""
                    color: slot.pasted ? Theme.palette.warning : Theme.palette.background
                    font.pixelSize: MusterStyle.cardCaption
                    font.weight: Theme.typography.weightMedium
                }
            }
        }

        Item { Layout.fillWidth: true }

        LogosText {
            text: cardRoot.threshold > 0
                ? qsTr("%1 of %2").arg(cardRoot.approvals).arg(cardRoot.threshold)
                : ""
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
            font.weight: Theme.typography.weightMedium
        }
    }

    // Who approved, by name ("you" for this member) — the slots' initials, spelled out.
    LogosText {
        objectName: "cardApproverNames"
        readonly property var named: (cardRoot.card && Array.isArray(cardRoot.card.approvers))
                                     ? cardRoot.card.approvers : []
        visible: named.length > 0
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("by %1").arg(named.map(function (a) {
                  var n = String(a.name || "");
                  if (n.length > 0) return n;
                  var w = String(a.who || "");
                  return w.length > 12 ? w.slice(0, 6) + "…" + w.slice(-4) : w; }).join(", "))
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.cardCaption
    }

    // ── lez-msig (exo-0d3): what the approval signs, decoded from those very bytes (RFP U.6) ──
    ColumnLayout {
        objectName: "cardMsig"
        Layout.fillWidth: true
        visible: cardRoot.msig !== null
        spacing: 2
        readonly property var m: cardRoot.msig || ({})
        readonly property var a: (cardRoot.msig && cardRoot.msig.action) ? cardRoot.msig.action : ({})
        function abbr(h) { h = String(h || ""); return h.length > 16 ? h.slice(0, 8) + "…" + h.slice(-6) : h; }
        // base units → LEZ as an exact decimal string (9 decimals), never through a float
        function lez(base) {
            var t = String(base || "0").replace(/^0+(?=[0-9])/, "");
            if (!/^[0-9]+$/.test(t)) return "?";
            while (t.length < 10) t = "0" + t;
            var whole = t.slice(0, t.length - 9), frac = t.slice(t.length - 9).replace(/0+$/, "");
            return frac.length > 0 ? whole + "." + frac : whole;
        }
        LogosText {
            objectName: "cardMsigAction"
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
            text: parent.m.error ? "⚠ " + String(parent.m.error)
                : parent.a.kind === "transfer"
                  ? qsTr("Pays %1 LEZ to %2").arg(parent.lez(parent.a.amount)).arg(String(parent.a.to))
                : parent.a.kind === "call"
                  ? qsTr("Calls program %1 with %2 accounts and instruction %3").arg(String(parent.a.program))
                        .arg((parent.a.rows || []).length).arg(String(parent.a.data))
                : parent.a.kind === "config"
                  ? qsTr("Changes the multisig: %1").arg((parent.a.changes || []).map(function (c) {
                        return String(c.change) + (c.timelockMs !== undefined ? " " + Number(c.timelockMs) / 60000 + " min"
                                                 : c.threshold !== undefined ? " " + c.threshold
                                                 : c.key !== undefined ? " " + parent.abbr(c.key) : ""); }).join(", "))
                : parent.a.kind === "cancel"
                  ? qsTr("Cancels proposal #%1").arg((parent.a.nonces || []).join(", #"))
                : ""
            color: parent.m.error ? Theme.palette.error : Theme.palette.text
            font.pixelSize: MusterStyle.cardBody
        }
        LogosText {
            objectName: "cardMsigBinding"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: !parent.m.error
            text: qsTr("Proposal #%1 · settings v%2 · expires %3 · id %4")
                  .arg(String(parent.m.nonce)).arg(String(parent.m.epoch))
                  .arg(new Date(Number(parent.m.expiresMs)).toLocaleString(Qt.locale(), Locale.ShortFormat))
                  .arg(parent.abbr(parent.m.proposalId))
            color: Theme.palette.textSecondary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.cardCaption
        }
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: !parent.m.error
            text: qsTr("Decoded from the exact bytes your approval signs. Any change to the multisig's settings voids it; so does its expiry.")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }
    }

    // Committed vs unattested, in words — only when something was pasted in, so a
    // card whose approvals were all signed in muster stays quiet.
    LogosText {
        objectName: "cardUnattested"
        visible: cardRoot.unattested > 0
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: (cardRoot.approvals - cardRoot.unattested > 0
                ? qsTr("%1 signed in muster — committed to where every input came from. ")
                      .arg(cardRoot.approvals - cardRoot.unattested)
                : "")
            + qsTr("%n signed outside muster and pasted in (ringed) — counted, but committed to nothing beyond the transaction itself.", "", cardRoot.unattested)
        color: Theme.palette.warning
        font.pixelSize: MusterStyle.cardCaption
    }

    // trace these: each filled slot is a driver-contribution the driver
    // verified recovers to a configured member. One tap opens the lineage
    // focused on the approvals — who signed, and the guarantee behind each.
    Item {
        Layout.fillWidth: true
        implicitHeight: approvalsTrace.implicitHeight
        visible: cardRoot.detailsOpen && cardRoot.approvals > 0 && cardRoot.card
                 && cardRoot.card.provenance && cardRoot.card.provenance.length > 0
        LogosText {
            id: approvalsTrace
            text: qsTr("⌕ trace the approvals")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: cardRoot.traceClass("driver-contribution")
        }
    }

    // Compact (exo-720.10, U-5): what the verify and provenance boxes below prove, in one
    // line — the re-derived match (invariant 1) and the inputs traced (invariant 10). A tap
    // opens Details, where both boxes are.
    RowLayout {
        visible: !cardRoot.detailsOpen && proofLine.text.length > 0
        Layout.fillWidth: true
        Layout.topMargin: 2
        spacing: Theme.spacing.small
        LogosText {
            id: proofLine
            objectName: "cardProofLine"
            readonly property int traced: (cardRoot.card && Array.isArray(cardRoot.card.provenance))
                                          ? cardRoot.card.provenance.length : 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: {
                var parts = [];
                if (String((cardRoot.card && cardRoot.card.txhash) || "").length > 0)
                    parts.push(qsTr("✓ Checked on your device"));
                if (traced > 0)
                    parts.push(traced === 1 ? qsTr("1 input, traced to where it came from")
                                           : qsTr("%1 inputs, each traced to where it came from").arg(traced));
                return parts.join("  ·  ");
            }
            color: String((cardRoot.card && cardRoot.card.txhash) || "").length > 0 ? MusterStyle.settled
                                                                                     : Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
            TapHandler { onTapped: cardRoot.detailsOpen = true }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
        WhyLink { objectName: "cardWhyProof"; step: "propose"; Layout.alignment: Qt.AlignTop }
    }

    // Where the rule lives — the FAMILY's own answer (exo-a50.1.6), never a fixed
    // caveat: a Safe's threshold IS enforced by its contract, a room threshold is
    // final in the room. Empty rows (an old module) → nothing claimed at all.
    LogosText {
        Layout.fillWidth: true
        Layout.topMargin: 2
        wrapMode: Text.WordWrap
        visible: cardRoot.detailsOpen && text.length > 0
        text: cardRoot.rowText("where")
        color: Theme.palette.textTertiary
        font.pixelSize: MusterStyle.cardCaption
    }

    // ── how this account works: the fixed rows (exo-a50.1.6) ─────────
    // The same ten questions for every multisig family, answered by the module
    // from the family profile, each tagged with its credibility and, where
    // someone is relied on or can see, who. Collapsed to one line by default.
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        visible: cardRoot.detailsOpen && cardRoot.rows.length > 0
        LogosText {
            objectName: "cardRowsToggle"
            text: (cardRoot.rowsOpen ? "▾ " : "▸ ") + qsTr("How this account works")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
            font.weight: Theme.typography.weightMedium
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: cardRoot.rowsOpen = !cardRoot.rowsOpen
            }
        }
        Repeater {
            model: cardRoot.rowsOpen ? cardRoot.rows : []
            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 0
                LogosText {
                    Layout.fillWidth: true
                    text: String(modelData.label || "")
                          + (modelData.credibility ? "  ·  " + String(modelData.credibility) : "")
                    color: modelData.credibility === "exposed" ? Theme.palette.error
                         : modelData.credibility === "motivational" ? Theme.palette.warning
                         : Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.cardCaption
                }
                LogosText {
                    Layout.fillWidth: true
                    text: String(modelData.text || "")
                          + (modelData.party ? "  (" + qsTr("relies on / seen by: %1").arg(String(modelData.party)) + ")" : "")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.cardCaption
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    // ── verify: dive in to what you'd sign (F-4 / F-5) ──────────────
    // Collapsed, a one-line reassurance; expanded, the safeTxHash this
    // client RE-DERIVED and the domain it is bound to. The effect shown
    // was rebuilt here and compared — a mismatch is refused by the core
    // before an intent ever reaches this fold, so what shows is the honest
    // "matches" state, and the trail is one tap away.
    Rectangle {
        objectName: "verifyBox"
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: cardRoot.detailsOpen && !!(cardRoot.card && cardRoot.card.txhash)
        implicitHeight: verifyCol.implicitHeight + 2 * Theme.spacing.small
        radius: Theme.spacing.radiusSmall
        color: Theme.palette.surfaceRecessed
        border.width: 1
        border.color: Theme.palette.success

        // Below the content: LogosText does not accept mouse events, so a
        // tap anywhere on the box falls through to here and toggles it.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: cardRoot.verifyOpen = !cardRoot.verifyOpen
        }

        ColumnLayout {
            id: verifyCol
            anchors.fill: parent
            anchors.margins: Theme.spacing.small
            spacing: Theme.spacing.tiny

            // header: the claim + the caret affordance.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    objectName: "verifyHeader"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("✓ Checked on your device — this is exactly what you would sign")
                    color: Theme.palette.success
                    font.pixelSize: MusterStyle.cardCaption
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    text: cardRoot.verifyOpen ? "−" : "+"
                    color: Theme.palette.success
                    font.pixelSize: MusterStyle.cardCaption
                }
            }

            // body: shown / re-derived / domain — only when opened. Three
            // explicit rows (the dashboard's re-materialization strip
            // pattern), each a mono key + a wrapping value.
            Repeater {
                model: cardRoot.verifyOpen
                    ? [{ id: "shown",      k: qsTr("shown"),      v: cardRoot.verifyShown() },
                       { id: "re-derived", k: qsTr("checked"), v: String((cardRoot.card && cardRoot.card.txhash) || "") },
                       { id: "domain",     k: qsTr("domain"),     v: cardRoot.verifyDomain() }]
                    : []

                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        Layout.preferredWidth: 66
                        Layout.alignment: Qt.AlignTop
                        text: modelData.k
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.cardCaption
                    }

                    SelectableText {
                        objectName: "verifyVal_" + modelData.id
                        Layout.fillWidth: true
                        text: modelData.v
                        color: Theme.palette.textSecondary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.cardCaption
                    }
                }
            }
        }
    }

    // ── provenance: how do I know this? (invariant 10) ──────────────
    // The deepest dive-in: every input that put this decision in front of
    // you, by class + where it came from + why it can be trusted. Neutral
    // ground (not the verify box's green) — this is lineage, not a verdict.
    Rectangle {
        objectName: "provenanceBox"
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: cardRoot.detailsOpen && !!(cardRoot.card && cardRoot.card.provenance)
                 && cardRoot.card.provenance.length > 0
        implicitHeight: provCol.implicitHeight + 2 * Theme.spacing.small
        radius: Theme.spacing.radiusSmall
        color: Theme.palette.surfaceRecessed
        border.width: 1
        border.color: Theme.palette.borderSubtle

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // Opened from its own header = no element focus: show the whole
            // lineage evenly. A "trace this" tap sets focus before opening.
            onClicked: {
                cardRoot.provOpen = !cardRoot.provOpen;
                cardRoot.provFocus = "";
            }
        }

        ColumnLayout {
            id: provCol
            anchors.fill: parent
            anchors.margins: Theme.spacing.small
            spacing: Theme.spacing.tiny

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("How do I know this? — where each of its %1 inputs came from")
                        .arg(cardRoot.card && cardRoot.card.provenance
                             ? cardRoot.card.provenance.length : 0)
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.cardCaption
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    text: cardRoot.provOpen ? "−" : "+"
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.cardCaption
                }
            }

            // Collapsed glance: who is behind this decision (names where known).
            LogosText {
                readonly property string who:
                    cardRoot.provWho(cardRoot.card ? cardRoot.card.provenance : [])
                visible: !cardRoot.provOpen && who.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("by %1").arg(who)
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }

            // intro — only when open.
            LogosText {
                visible: cardRoot.provOpen
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Where each piece of this came from. Nothing here is "
                         + "unaccountable — an input the client couldn't trace would "
                         + "have been refused before signing.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }

            // one entry per input in the lineage.
            Repeater {
                model: (cardRoot.provOpen && cardRoot.card && cardRoot.card.provenance)
                       ? cardRoot.card.provenance : []

                // A "trace this" tap focuses one class: its entries are lit
                // with an accent bar, the rest dimmed, so the tapped card
                // element leads the eye to exactly its own lineage.
                delegate: RowLayout {
                    id: provEntry
                    required property var modelData
                    readonly property bool focused: cardRoot.provFocus.length > 0
                        && String((modelData && modelData["class"]) || "") === cardRoot.provFocus
                    readonly property bool dimmed: cardRoot.provFocus.length > 0 && !focused
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: Theme.spacing.tiny
                    opacity: dimmed ? 0.4 : 1.0

                    Rectangle {
                        Layout.fillHeight: true
                        Layout.preferredWidth: 2
                        radius: 1
                        visible: provEntry.focused
                        color: Theme.palette.textSecondary
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            // WHAT this input is, and its concrete content — the
                            // proposal shows the effect it carried ("pay 42 to
                            // 0x…"), an approval its round; so you investigate the
                            // actual piece of information, not a generic label.
                            text: {
                                var lbl = "[" + String((modelData && modelData["class"]) || "") + "]  "
                                        + String((modelData && modelData.what) || "");
                                var d = String((modelData && modelData.detail) || "");
                                return d.length > 0 ? lbl + "  —  " + d : lbl;
                            }
                            color: Theme.palette.text
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.cardCaption
                            font.weight: Theme.typography.weightMedium
                        }

                        LogosText {
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.small
                            wrapMode: Text.WrapAnywhere
                            text: cardRoot.provTrust(modelData)
                            color: Theme.palette.textTertiary
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.cardCaption
                        }
                    }
                }
            }
        }
    }
}
