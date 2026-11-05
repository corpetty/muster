import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls
import Logos.Icons

// The room's composer (exo-720.3, moved verbatim out of Room.qml): the proposal
// forms the "+" opens, the outcome of the last proposal, and the message row. Each
// `room.x` is the Room's own state, as before the move.
// ── composer: chat + propose ──────────────────────────────────────
// A proposal originates in the conversation the same way a message does —
// the "+" opens the effect fields, and proposing posts it inline as a card.
// Its fields fill the column but never widen it: long placeholders and rows of
// kind buttons used to push the right-hand column past the window's edge when the
// composer opened (exo-a90.19, seen on a display).
ColumnLayout {
    id: composerRoot
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    // the payment form's recipient and amount fields, which the Room fills from
    // elsewhere (prefillPayment, a card's "Use as recipient")
    readonly property Item proposeToField: proposeTo
    readonly property Item proposeValueField: proposeValue

    visible: room.joined
    Layout.fillWidth: true
    Layout.preferredWidth: 0
    spacing: Theme.spacing.small

    // ── the proposal panel (exo-720.9, docs/design/ui-modernization.md §4 U5) ─────
    // The kind the "+" picker chose, its form, titled and closable. It scrolls within about
    // half the room, so the thread stays on screen; the forms themselves are as they were.
    Surface {
        id: composePanel
        objectName: "roomComposePanel"
        level: 2
        visible: room.composing
        Layout.fillWidth: true
        implicitHeight: panelCol.implicitHeight + 2

        ColumnLayout {
            id: panelCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 1
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                Layout.leftMargin: Theme.spacing.large
                Layout.rightMargin: Theme.spacing.small
                spacing: Theme.spacing.small
                LogosText {
                    objectName: "roomComposeTitle"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: room.composeType === "statement" ? qsTr("Propose a statement")
                            : room.composeType === "action" ? qsTr("Propose an action")
                            : room.composeType === "split" && room.splitRequest ? qsTr("Request a payment")
                            : room.composeType === "split" && room.splitSend
                              ? (room.splitFor.length > 0 ? qsTr("Send %1 to %2").arg(room.splitUnit).arg(room.memberLabel(room.splitFor))
                                                          : qsTr("Send money"))
                            : room.composeType === "split" ? (room.splitFor.length > 0
                                                              ? qsTr("Split a bill %1 paid").arg(room.memberLabel(room.splitFor))
                                                              : qsTr("Split a bill you paid"))
                            : qsTr("Propose a payment")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.subtitle
                    font.weight: Theme.typography.weightBold
                }
                ActionButton {
                    objectName: "roomComposeChange"
                    text: qsTr("Something else")
                    quiet: true
                    compact: true
                    onClicked: actionPicker.open()
                }
                IconAction {
                    objectName: "roomComposeClose"
                    label: qsTr("Close the form")
                    icon: LogosIcons.close
                    onClicked: room.composing = false
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }

            Flickable {
                id: composeFlick
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(composeCol.implicitHeight + 2 * Theme.spacing.large,
                                                 Math.max(220, room.height * 0.55))
                clip: true
                contentWidth: width
                contentHeight: composeCol.implicitHeight + 2 * Theme.spacing.large
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: composeCol
                    x: Theme.spacing.large
                    y: Theme.spacing.large
                    width: composeFlick.width - 2 * Theme.spacing.large
                    spacing: Theme.spacing.tiny
                    // policy picker (RoomComposePolicyPicker.qml)
                    RoomComposePolicyPicker { room: composerRoot.room }

                    // what the kind needs (RoomComposeNeeds.qml)
                    RoomComposeNeeds { room: composerRoot.room }

                    // from which account (RoomComposeAccountPicker.qml)
                    RoomComposeAccountPicker { room: composerRoot.room }

                    // attest identity (RoomComposeAttestIdentity.qml)
                    RoomComposeAttestIdentity { room: composerRoot.room }

                    // payment: the sending context — WHAT you're sending (the Safe's own
                    // balance, so you send from real holdings, not a blind number) and WHO
                    // you act as (surfaced here at propose time — ask-then-disclose — with
                    // an owner check so you know before proposing whether your approval will
                    // count on-chain). Only for the Safe policy; a statement settles nothing.
                    Rectangle {
                        objectName: "roomSendContext"
                        visible: room.composeType === "payment" && room.policyKind === "safe"
                        Layout.fillWidth: true
                        implicitHeight: sendCtx.implicitHeight + 2 * Theme.spacing.small
                        radius: Theme.spacing.radiusSmall
                        color: Theme.palette.surfaceRaised
                        border.width: 1
                        border.color: Theme.palette.borderSubtle

                        ColumnLayout {
                            id: sendCtx
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacing.small
                            anchors.rightMargin: Theme.spacing.small
                            spacing: 2

                            // WHAT can be sent: the asset + the Safe's live balance (or an
                            // honest error — never a false zero).
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small
                                LogosText {
                                    text: qsTr("Sending")
                                    color: Theme.palette.textTertiary
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
                                    font.weight: Theme.typography.weightMedium
                                }
                                LogosText {
                                    Layout.fillWidth: true
                                    text: {
                                        if (!room.roomAsset) return qsTr("checking the Safe…");
                                        if (room.roomAsset.error) return qsTr("⚠ balance unavailable — %1").arg(String(room.roomAsset.error));
                                        return qsTr("%1  ·  %2 available  (%3 wei)")
                                               .arg(String(room.roomAsset.symbol || "ETH"))
                                               .arg(String(room.roomAsset.display || "?"))
                                               .arg(String(room.roomAsset.raw || "0"));
                                    }
                                    color: (room.roomAsset && room.roomAsset.error) ? Theme.palette.warning : Theme.palette.textSecondary
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
                                    wrapMode: Text.WrapAnywhere
                                }
                            }

                            // from the Safe (the room's account — whose funds move)
                            LogosText {
                                Layout.fillWidth: true
                                text: qsTr("from Safe %1").arg(String((room.roomAccount && room.roomAccount.account) || "…"))
                                color: Theme.palette.textTertiary
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.caption
                                elide: Text.ElideMiddle
                            }

                            // WHO you act as — the disclosure, made explicit here, with the
                            // owner check that turns the old "insufficient-signatures"
                            // surprise into a warning you see before you propose.
                            LogosText {
                                Layout.fillWidth: true
                                text: {
                                    var a = String((room.roomAccount && room.roomAccount.actingAs) || "");
                                    if (a.length === 0) return qsTr("acting as: (loading…)");
                                    var isOwner = room.roomAccount && room.roomAccount.isOwner;
                                    return qsTr("you act as %1  ·  %2")
                                           .arg(a)
                                           .arg(isOwner ? qsTr("✓ a Safe owner — your approval counts")
                                                        : qsTr("⚠ not a Safe owner — your approval won't count on-chain"));
                                }
                                color: (room.roomAccount && room.roomAccount.isOwner) ? Theme.palette.success : Theme.palette.warning
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.caption
                                wrapMode: Text.WrapAnywhere
                            }

                            // soft guard: typing more than the Safe holds would revert
                            // on-chain — say so before the propose, not after the settle.
                            LogosText {
                                Layout.fillWidth: true
                                visible: room.overSends(proposeValue.text)
                                text: qsTr("⚠ more than the Safe holds — Propose is off until the amount fits")
                                color: Theme.palette.warning
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.caption
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // ── action: pick a module method the room will coordinate ──────
                    // The menu is coordinate_available_actions — only the actions your
                    // loaded modules expose (allowlist + MUSTER_INVOKE_MODULES, never a
                    // blind scan). Picking one composes an invoke intent; the room endorses
                    // it k-of-n and the core invokes it (the driver never does, invariant 3).
                    ColumnLayout {
                        visible: room.composeType === "action"
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: room.availableActions.length > 0
                                  ? qsTr("What your modules let the room do:")
                                  : qsTr("No coordinatable actions — set MUSTER_INVOKE_MODULES "
                                       + "or the invoke allowlist to expose a module's methods.")
                            color: Theme.palette.textTertiary
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.caption
                        }

                        // one selectable row per available action.
                        Repeater {
                            model: room.availableActions

                            delegate: Rectangle {
                                id: actionRow
                                required property var modelData
                                readonly property bool chosen: room.chosenAction
                                    && String(room.chosenAction.module || "") === String(modelData.module || "")
                                    && String(room.chosenAction.method || "") === String(modelData.method || "")
                                Layout.fillWidth: true
                                implicitHeight: actionLbl.implicitHeight + Theme.spacing.small
                                radius: Theme.spacing.radiusSmall
                                color: actionRow.chosen ? Theme.palette.surfaceRaised : "transparent"
                                border.width: 1
                                border.color: actionRow.chosen ? Theme.palette.textSecondary
                                                               : Theme.palette.borderSubtle

                                LogosText {
                                    id: actionLbl
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacing.small
                                    anchors.rightMargin: Theme.spacing.small
                                    wrapMode: Text.WordWrap
                                    text: {
                                        var sig = String(actionRow.modelData.signature
                                                         || actionRow.modelData.method || "");
                                        var mod = String(actionRow.modelData.module || "");
                                        var mark = actionRow.modelData.allowed
                                                 ? qsTr("  ·  ✓ runs now")
                                                 : qsTr("  ·  needs opt-in to run");
                                        return mod + "." + sig + mark;
                                    }
                                    color: Theme.palette.text
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: room.chosenAction = actionRow.modelData
                                }
                            }
                        }

                        // args for the chosen action — a JSON array, exactly what the effect
                        // carries. Kept honest: the raw args the module.method will receive.
                        LogosTextField {
                            id: proposeArgs
                            objectName: "roomProposeArgs"
                            visible: room.chosenAction !== null
                            Layout.fillWidth: true
                            placeholderText: qsTr("args as a JSON array, e.g. [\"/room\",\"hello\"]")
                            font.family: MusterStyle.mono
                        }

                        // Mode B (exo-45e): mark this action as a COORDINATED TRANSFER, where the
                        // recipient supplies their own address rather than the proposer guessing
                        // it. Naming which arg is the recipient (+ the chain) makes the proposal
                        // declare a counterparty slot the room asks the recipient to fill; for a
                        // lez:* chain it also declares the proposer's LEZ-account requirement. Left
                        // off, the action proposes as a plain invoke — nothing changes.
                        ActionButton {
                            objectName: "roomModeBToggle"
                            visible: room.chosenAction !== null
                            Layout.fillWidth: true
                            text: room.modeB
                                ? qsTr("✓ Coordinated transfer — recipient shares their address")
                                : qsTr("Make it a coordinated transfer (ask the recipient)")
                            variant: room.modeB ? LogosButton.Variant.Secondary
                                                : LogosButton.Variant.Secondary
                            onClicked: room.modeB = !room.modeB
                        }
                        ColumnLayout {
                            visible: room.chosenAction !== null && room.modeB
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small

                            LogosTextField {
                                id: proposeCounterparty
                                objectName: "roomProposeCounterparty"
                                Layout.fillWidth: true
                                // which arg name holds the recipient — the effect field the shared
                                // address lands in (e.g. "to"). The room then asks the recipient.
                                placeholderText: qsTr("recipient arg name (e.g. to)")
                                text: "to"
                                font.family: MusterStyle.mono
                            }
                            LogosTextField {
                                id: proposeChain
                                objectName: "roomProposeChain"
                                Layout.fillWidth: true
                                placeholderText: qsTr("chain (e.g. lez:testnet)")
                                font.family: MusterStyle.mono
                            }
                        }
                    }

                    // ── split (exo-a90): the total, who paid, who's in, and what each owes ──
                    // Whoever paid is the creditor: you, paid at your own address, or someone
                    // else, paid at the address they shared (exo-770). Every person named — the
                    // creditor too — must agree before anyone pays. Amounts are ETH here and
                    // exact wei on the card (string arithmetic — no floats).
                    ColumnLayout {
                        visible: room.composeType === "split"
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosTextField {
                                id: splitTotal
                                objectName: "roomSplitTotal"
                                visible: !room.acrossOpen     // a settle-up has no total of its own
                                Layout.preferredWidth: 160
                                placeholderText: (room.splitRequest || room.splitSend)
                                                 ? qsTr("amount (%1)").arg(room.splitFiat ? String(room.splitFiatCurrency).toUpperCase()
                                                                                           : room.splitUnit)
                                                 : qsTr("total (%1)").arg(room.splitFiat ? String(room.splitFiatCurrency).toUpperCase()
                                                                                         : room.splitUnit)
                                font.family: MusterStyle.mono
                            }
                            LogosTextField {
                                id: splitMemo
                                objectName: "roomSplitMemo"
                                Layout.fillWidth: true
                                placeholderText: qsTr("what for (only the room sees this)")
                            }
                        }

                        // pay in a token instead of ETH (exo-5ab): the token's own answer — its
                        // symbol and decimals — shown beside its address, because a token names itself
                        // a bill in another currency (exo-3a4): the total above is then in that
                        // currency, and the rate is YOUR quote — recorded with the proposal
                        ActionButton {
                            objectName: "roomSplitFiat"
                            // a Monero request is in XMR only (the module refuses a quote)
                            visible: !room.acrossOpen && !room.splitMonero
                            Layout.preferredWidth: 320   // the label whole, never "…curre…"
                            text: room.splitFiat ? qsTr("✓ The bill is in another currency") : qsTr("The bill is in another currency")
                            variant: room.splitFiat ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: room.splitFiat = !room.splitFiat
                        }
                        RowLayout {
                            visible: room.splitFiat && !room.acrossOpen
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosTextField {
                                objectName: "roomSplitFiatCurrency"
                                Layout.preferredWidth: 70
                                text: room.splitFiatCurrency
                                placeholderText: qsTr("EUR")
                                onTextChanged: room.splitFiatCurrency = String(text).trim().toUpperCase()
                            }
                            LogosTextField {
                                objectName: "roomSplitFiatRate"
                                Layout.preferredWidth: 200
                                placeholderText: qsTr("1 %1 = ? %2").arg(room.splitFiatCurrency || "EUR").arg(room.splitUnit)
                                font.family: MusterStyle.mono
                                onTextChanged: room.splitFiatRate = String(text).trim()
                            }
                            LogosTextField {
                                objectName: "roomSplitFiatSource"
                                Layout.fillWidth: true
                                placeholderText: qsTr("where the rate is from (everyone will see it)")
                                onTextChanged: room.splitFiatSource = String(text)
                            }
                        }
                        LogosText {
                            objectName: "roomSplitFiatNote"
                            visible: room.splitFiat && !room.acrossOpen
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            wrapMode: Text.WordWrap
                            readonly property string conv: room.fiatTotal(splitTotal.text)
                            text: conv.length > 0
                                  ? qsTr("%1 %2 at 1 %2 = %3 %4 comes to %5 %4. The rate is your quote: it is recorded with the proposal, and everyone agreeing trusts it.")
                                        .arg(splitTotal.text).arg(room.splitFiatCurrency).arg(room.splitFiatRate)
                                        .arg(room.splitUnit).arg(room.weiToEth(conv))
                                  : qsTr("⚠ Type the bill in %1 (at most %2 decimals), and the rate as %3 per 1 %1.")
                                        .arg(room.splitFiatCurrency || "EUR").arg(room.fiatDecimals(room.splitFiatCurrency))
                                        .arg(room.splitUnit)
                            color: conv.length > 0 && String(room.splitFiatSource).trim().length > 0
                                   ? Theme.palette.textSecondary : Theme.palette.warning
                            font.pixelSize: MusterStyle.caption
                        }

                        LogosTextField {
                            objectName: "roomSplitToken"
                            visible: !room.splitPrivate && !room.splitBitcoin && !room.splitMonero
                            Layout.fillWidth: true
                            placeholderText: qsTr("pay in a token instead of ETH: its address (0x…), or leave empty")
                            font.family: MusterStyle.mono
                            onTextChanged: {
                                var t = String(text).trim().toLowerCase();
                                room.splitToken = /^0x[0-9a-f]{40}$/.test(t) ? t : (t.length > 0 ? t : "");
                                if (/^0x[0-9a-f]{40}$/.test(t) && room.backend) room.backend.lookupToken("", t);
                            }
                        }
                        LogosText {
                            visible: !room.splitPrivate && !room.splitBitcoin && !room.splitMonero && room.splitToken.length > 0
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            wrapMode: Text.WordWrap
                            text: room.splitTokenInfo
                                  ? qsTr("%1 — the token at %2 says so; %3 decimals. A token names itself: check the address.")
                                        .arg(room.splitUnit)
                                        .arg(room.splitToken.slice(0, 8) + "…" + room.splitToken.slice(-6))
                                        .arg(room.splitDecimals)
                                  : !/^0x[0-9a-f]{40}$/.test(room.splitToken)
                                  ? qsTr("⚠ A token is named by its address: 0x and 40 hex characters.")
                                  : qsTr("⚠ Your RPC could not read that token (no decimals()) — is it on this chain?")
                            color: room.splitTokenInfo ? Theme.palette.textSecondary : Theme.palette.warning
                            font.pixelSize: MusterStyle.caption
                        }

                        // settle up instead (exo-3c6): net the room's agreed, unpaid shares on this rail
                        // into fewer payments — every party agrees before anything is paid
                        ActionButton {
                            objectName: "roomSettleUp"
                            visible: !room.splitPrivate && !room.splitMonero && !room.splitRequest && !room.acrossOpen
                            enabled: !room.composeBlocked     // exo-dcc.10, as Propose
                            Layout.preferredWidth: 320
                            text: qsTr("Settle up the room's open splits instead")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                if (!room.backend) return;
                                room.backend.proposeSettleUp("", room.splitTokenInfo ? String(room.splitTokenInfo.asset) : "",
                                                             String(splitMemo.text || ""));
                                room.composing = false;
                            }
                        }

                        // across assets and chains (exo-a90.17): the shares owed in other assets
                        // or on other chains too, each at the rate YOU give — everyone agrees to it
                        ActionButton {
                            objectName: "roomSettleUpAcrossOpen"
                            visible: !room.splitPrivate && !room.splitMonero && !room.splitRequest && !room.acrossOpen
                            Layout.preferredWidth: 320
                            text: qsTr("Settle up across assets and chains…")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                room.acrossRates = ({});
                                acrossSource.text = "";
                                room.acrossPending = false;
                                room.acrossOpen = true;
                                if (room.backend) room.backend.loadOpenAssets();
                            }
                        }
                        ColumnLayout {
                            objectName: "roomSettleUpAcrossBox"
                            visible: !room.splitPrivate && room.acrossOpen
                            Layout.fillWidth: true
                            spacing: Theme.spacing.tiny
                            LogosText {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                wrapMode: Text.WordWrap
                                text: qsTr("Paid in %1. Give a rate for each other asset the room owes in: the shares in it are converted at your rate, rounded down. Everyone the shares name must agree, and agreeing means trusting your rates.")
                                      .arg(room.splitUnit)
                                color: Theme.palette.textSecondary
                                font.pixelSize: MusterStyle.caption
                            }
                            Repeater {
                                // only while open: closing destroys the fields, so what they show is
                                // always what acrossRates holds
                                model: room.acrossOpen ? room.acrossOthers : []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.small
                                    LogosText {
                                        // wraps: a chain id is long, and the row never widens the column
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        wrapMode: Text.Wrap
                                        text: qsTr("1 %1 on %2 (%3) =").arg(String(modelData.symbol || modelData.asset))
                                              .arg(String(modelData.chainLabel || modelData.chain))
                                              .arg(Number(modelData.parts) === 1 ? qsTr("1 share") : qsTr("%1 shares").arg(modelData.parts))
                                        color: Theme.palette.text
                                        font.pixelSize: Theme.typography.secondaryText
                                    }
                                    LogosTextField {
                                        objectName: "roomAcrossRate_" + String(modelData.asset).replace(/[^A-Za-z0-9]/g, "").slice(0, 16)
                                        Layout.preferredWidth: 140
                                        placeholderText: qsTr("rate")
                                        onTextChanged: {
                                            var r = Object.assign({}, room.acrossRates);
                                            r[String(modelData.chain) + "|" + String(modelData.asset)] = String(text);
                                            room.acrossRates = r;
                                        }
                                    }
                                    LogosText {
                                        text: room.splitUnit
                                        color: Theme.palette.textSecondary
                                        font.pixelSize: Theme.typography.secondaryText
                                    }
                                }
                            }
                            LogosText {
                                visible: room.acrossOthers.length === 0
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("The room owes in no other asset and on no other chain right now.")
                                color: Theme.palette.textTertiary
                                font.pixelSize: MusterStyle.caption
                            }
                            LogosTextField {
                                id: acrossSource
                                objectName: "roomAcrossSource"
                                visible: room.acrossOthers.length > 0
                                Layout.fillWidth: true
                                placeholderText: qsTr("where these rates come from (everyone sees this)")
                            }
                            RowLayout {
                                spacing: Theme.spacing.small
                                ActionButton {
                                    objectName: "roomSettleUpAcross"
                                    text: qsTr("Propose the settle-up")
                                    enabled: !room.composeBlocked && room.acrossPriced.length > 0
                                             && String(acrossSource.text || "").trim().length > 0
                                    onClicked: {
                                        if (!room.backend) return;
                                        var rates = room.acrossPriced.map(function (r) {
                                            return {chain: r.chain, asset: r.asset, rate: r.rate,
                                                    source: String(acrossSource.text || "").trim()};
                                        });
                                        room.acrossPending = true;
                                        room.backend.proposeSettleUpAcross("", room.acrossPayAsset === "ETH" || room.acrossPayAsset === "BTC"
                                                                               ? "" : room.acrossPayAsset,
                                                                           JSON.stringify(rates), String(splitMemo.text || ""));
                                    }
                                }
                                ActionButton {
                                    objectName: "roomSettleUpAcrossCancel"
                                    text: qsTr("Cancel")
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: { room.acrossOpen = false; room.acrossPending = false; }
                                }
                            }
                        }

                        // who fronted it (exo-770): you, or someone else — then it is paid at the
                        // address they shared, and nobody pays until they agree it is theirs
                        LogosText {
                            visible: (room.splitSend || (!room.splitPrivate && !room.splitBitcoin && !room.splitRequest))
                                     && room.members.length > 1 && !room.acrossOpen
                            text: room.splitSend ? qsTr("Send to:") : qsTr("Who paid the bill?")
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        Flow {
                            visible: (room.splitSend || (!room.splitPrivate && !room.splitBitcoin && !room.splitRequest))
                                     && room.members.length > 1 && !room.acrossOpen
                            Layout.fillWidth: true
                            spacing: Theme.spacing.tiny
                            Repeater {
                                // a send goes to someone else: never "I did" (exo-dcc.32)
                                model: room.members.filter(function (m) { return !!m && !(room.splitSend && m.self); })
                                delegate: ActionButton {
                                    required property var modelData
                                    readonly property string ident: modelData.self ? "" : String(modelData.identity || "")
                                    objectName: "roomSplitPaidBy_" + (modelData.self ? "me" : ident.slice(0, 8))
                                    text: modelData.self ? qsTr("I did") : room.memberLabel(ident)
                                    variant: (room.splitSend ? room.sendTo === ident : room.splitCreditor === ident) ? LogosButton.Variant.Primary
                                                                         : LogosButton.Variant.Secondary
                                    onClicked: { room.splitCreditor = ident; room.splitOut = ({}); }
                                }
                            }
                        }
                        LogosText {
                            objectName: "roomSplitPaidTo"
                            visible: room.splitFor.length > 0 && !room.acrossOpen
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            wrapMode: Text.WordWrap
                            readonly property string addr: room.splitForAddress
                            text: addr.length > 0
                                  ? (room.splitMonero
                                     ? (room.splitSend
                                        ? qsTr("Sent to %1, the Monero address %2 shared from their own wallet. You pay once %2 agrees it is theirs, from any wallet; their wallet confirms it.")
                                        : qsTr("Paid to %1, the Monero address %2 shared from their own wallet. Nobody pays until %2 agrees it is theirs."))
                                     : room.splitSend
                                     ? qsTr("Sent to %1, the address %2 shared. You pay once %2 accepts it is theirs.")
                                     : qsTr("Paid to %1, the address %2 shared. Nobody pays until %2 agrees it is theirs."))
                                        .arg(addr).arg(room.memberLabel(room.splitFor))
                                  : room.splitForAddressUsed
                                  ? qsTr("⚠ The Monero address %1 shared already backs a payment here, and one address can't tell two payments apart: ask them for a new one.")
                                        .arg(room.memberLabel(room.splitFor))
                                  : room.splitMonero
                                  ? (room.splitSend
                                     ? qsTr("⚠ %1 hasn't shared a Monero address on %2: ask them for one, then send.")
                                     : qsTr("⚠ %1 hasn't shared a Monero address on %2: ask them for one, then split it for them."))
                                        .arg(room.memberLabel(room.splitFor)).arg(room.moneroChainLabel(room.splitMoneroChain))
                                  : room.splitSend
                                  ? qsTr("⚠ %1 hasn't shared %2 address in this room: ask them for one, then send.")
                                        .arg(room.memberLabel(room.splitFor))
                                        .arg(room.splitBitcoin ? qsTr("a Bitcoin") : room.splitPrivate ? qsTr("a LEZ") : qsTr("an Ethereum"))
                                  : qsTr("⚠ %1 hasn't shared an address in this room: ask them to share one (the Pay composer's “Ask the room”), then split it for them.")
                                        .arg(room.memberLabel(room.splitFor))
                            color: addr.length > 0 ? Theme.palette.textSecondary : Theme.palette.warning
                            font.pixelSize: MusterStyle.caption
                        }
                        // ask them for one (exo-dcc.20): an address-request of them alone, for a
                        // Monero address on this chain — answered by "Share my Monero address"
                        ActionButton {
                            objectName: "roomAskMoneroAddress"
                            visible: room.splitMonero && room.splitFor.length > 0 && room.splitForAddress.length === 0 && !room.acrossOpen
                            Layout.preferredWidth: 360
                            text: (room.splitForAddressUsed ? qsTr("Ask %1 for a new Monero address")
                                                             : qsTr("Ask %1 for a Monero address")).arg(room.memberLabel(room.splitFor))
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                if (!room.backend) return;
                                var label = room.moneroChainLabel(room.splitMoneroChain);
                                room.backend.postMessage(JSON.stringify({
                                    kind: "address-request", intent: "split", asset: "XMR",
                                    chain: room.splitMoneroChain, chainLabel: label, "for": room.splitFor,
                                    purpose: (room.splitSend ? qsTr("Monero to be sent to you: an address on %1")
                                                             : qsTr("A Monero split to be paid to you: an address on %1")).arg(label)
                                }));
                            }
                        }

                        // a send on another rail: ask them for an address on it (exo-dcc.33) — the
                        // rail only for Bitcoin and LEZ; their module answers with its own network
                        ActionButton {
                            objectName: "roomAskSendAddress"
                            visible: room.splitSend && !room.splitMonero && room.splitFor.length > 0
                                     && room.splitForAddress.length === 0 && !room.acrossOpen
                            Layout.preferredWidth: 360
                            text: qsTr("Ask %1 for an address").arg(room.memberLabel(room.splitFor))
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                if (!room.backend) return;
                                var asset = room.splitBitcoin ? "BTC" : room.splitPrivate ? "LEZ" : "ETH";
                                var ask = { kind: "address-request", intent: "send", asset: asset, "for": room.splitFor,
                                            purpose: qsTr("A payment to be sent to you: an address to send it to") };
                                if (asset === "BTC") ask.chain = "bip122";
                                if (asset === "LEZ") ask.chain = "lez";
                                room.backend.postMessage(JSON.stringify(ask));
                            }
                        }

                        LogosText {
                            visible: !room.acrossOpen && !room.splitSend
                            text: room.splitRequest
                                  ? (room.members.length > 1 ? qsTr("Who pays you? Tap one person:")
                                     : qsTr("Nobody here to ask yet: invite and admit the person who pays you, then request."))
                                  : room.members.length > 1
                                  ? (room.splitFor.length > 0
                                     ? qsTr("Who owes %1 a share — tap to leave someone out:").arg(room.memberLabel(room.splitFor))
                                     : qsTr("Who owes you a share — tap to leave someone out:"))
                                  : qsTr("Nobody here owes you yet: invite and admit the people who shared it, then split.")
                            color: room.members.length > 1 ? Theme.palette.textTertiary : Theme.palette.warning
                            font.pixelSize: MusterStyle.caption
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }

                        Flow {
                            visible: !room.acrossOpen && !room.splitSend
                            Layout.fillWidth: true
                            spacing: Theme.spacing.tiny
                            Repeater {
                                // everyone but whoever fronted it — you among them when it was someone else
                                model: room.members.filter(function (m) {
                                    return m && (room.splitFor.length === 0 ? !m.self
                                                 : String(m.identity || "").toLowerCase() !== room.splitFor.toLowerCase());
                                })
                                delegate: ActionButton {
                                    required property var modelData
                                    readonly property string ident: String(modelData.identity || "")
                                    objectName: "roomSplitWho_" + ident.slice(0, 8)
                                    text: modelData.self ? qsTr("You")
                                          : (modelData.alias && String(modelData.alias).length > 0)
                                          ? String(modelData.alias) : ident.slice(0, 10) + "…"
                                    variant: (room.splitRequest ? room.splitDebtors().indexOf(ident) < 0 : !!room.splitOut[ident])
                                             ? LogosButton.Variant.Secondary : LogosButton.Variant.Primary
                                    onClicked: if (room.splitRequest) room.splitPayer = ident; else room.splitToggle(ident)
                                }
                            }
                            ActionButton {
                                objectName: "roomSplitMine"
                                visible: !room.splitRequest      // a request: you are never in it
                                text: room.splitFor.length > 0
                                      ? (room.splitCreditorShares ? qsTr("✓ %1 is in it too").arg(room.memberLabel(room.splitFor))
                                                                  : qsTr("%1 is not in it").arg(room.memberLabel(room.splitFor)))
                                      : room.splitCreditorShares ? qsTr("✓ I'm in it too") : qsTr("I'm not in it (chip in)")
                                variant: room.splitCreditorShares ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                                onClicked: room.splitCreditorShares = !room.splitCreditorShares
                            }
                        }

                        LogosText {
                            objectName: "roomSplitPreview"
                            readonly property var pv: room.splitPreview(splitTotal.text)
                            visible: splitTotal.text.length > 0 && !room.acrossOpen
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0   // wrap within the column; never widen it
                            wrapMode: Text.WordWrap
                            text: room.splitTotalOf(splitTotal.text).length === 0
                                  ? (room.splitFiat ? qsTr("⚠ The bill and the rate are needed to work out each share (see above).")
                                     : qsTr("⚠ Type the total in %1, e.g. 1.2 (at most %2 decimals).").arg(room.splitUnit).arg(room.splitDecimals))
                                  : pv === null ? qsTr("Leave at least one person in.")
                                  : room.splitDust(pv)
                                  ? qsTr("⚠ Each share would be %1 sat — below Bitcoin's 546-sat dust limit, so it could never be paid.").arg(pv.each)
                                  : room.splitSend
                                  ? (room.splitFor.length === 0
                                     ? qsTr("Pick who to send it to.")
                                     : room.splitMonero
                                     ? qsTr("You send %1 %2 XMR. Once they accept the address is theirs, pay from any Monero wallet with the link the room gives you; their own wallet confirms it.")
                                           .arg(room.memberLabel(room.splitFor)).arg(room.weiToEth(pv.each))
                                     : room.splitPrivate
                                     ? qsTr("You send %1 %2 LEZ privately, from your own wallet, once they accept: the chain learns only that a private transfer happened, and their scan finds it.")
                                           .arg(room.memberLabel(room.splitFor)).arg(room.weiToEth(pv.each))
                                     : qsTr("You send %1 %2 %3 from your own wallet once they accept; their own read confirms it. The payment is public on the chain.")
                                           .arg(room.memberLabel(room.splitFor)).arg(room.weiToEth(pv.each)).arg(room.splitUnit))
                                  : room.splitRequest
                                  ? (room.splitMonero
                                     ? qsTr("%1 pays you %2 XMR from any Monero wallet, with a link the room gives them.")
                                           .arg(room.memberLabel(room.splitDebtors()[0])).arg(room.weiToEth(pv.each))
                                     : qsTr("%1 pays you %2 %3 from their own wallet — the payment is public on the chain.")
                                           .arg(room.memberLabel(room.splitDebtors()[0])).arg(room.weiToEth(pv.each)).arg(room.splitUnit))
                                  : room.splitMonero && room.splitFor.length > 0
                                  ? (pv.n === 1
                                     ? qsTr("1 person owes %3 %1 XMR; %3's own share is %2 XMR (it absorbs any rounding). They pay from any Monero wallet, with a link the room gives them.")
                                           .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.memberLabel(room.splitFor))
                                     : qsTr("%1 people owe %3 about %2 XMR each — every share a few piconero apart, so %3's wallet can tell whose payment arrived; %3's own share absorbs the rest. Each pays from any Monero wallet, with a link the room gives them.")
                                           .arg(pv.n).arg(room.weiToEth(pv.each)).arg(room.memberLabel(room.splitFor)))
                                  : room.splitMonero
                                  ? (pv.n === 1
                                     ? qsTr("1 person owes you %1 XMR; your own share is %2 XMR (it absorbs any rounding). They pay from any Monero wallet, with a link the room gives them.")
                                           .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine))
                                     : qsTr("%1 people owe you about %2 XMR each — every share a few piconero apart, so your wallet can tell whose payment arrived; your own share absorbs the rest. Each pays from any Monero wallet, with a link the room gives them.")
                                           .arg(pv.n).arg(room.weiToEth(pv.each)))
                                  : room.splitFor.length > 0
                                  ? (pv.n === 1
                                     ? qsTr("1 person owes %4 %1 %3; %4's own share is %2 %3 (it absorbs any rounding). They pay from their own wallet — the payment is public on the chain.")
                                           .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                           .arg(room.memberLabel(room.splitFor))
                                     : qsTr("%1 people owe %5 %2 %4 each; %5's own share is %3 %4 (it absorbs any rounding). Each pays from their own wallet — every payment is public on the chain.")
                                           .arg(pv.n).arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                           .arg(room.memberLabel(room.splitFor)))
                                  : room.splitPrivate
                                  ? (pv.n === 1
                                     ? qsTr("1 person owes you about %1 LEZ. They pay privately from their own wallet: the chain learns only that a private transfer happened, and your own scan finds the note by its amount.")
                                           .arg(room.weiToEth(pv.each))
                                     : qsTr("%1 people owe you about %2 LEZ each — every share a few base units apart, so your scan can tell whose payment arrived without the chain naming anyone; your own share absorbs the rest. Each pays privately from their own wallet: the chain learns only that private transfers happened.")
                                           .arg(pv.n).arg(room.weiToEth(pv.each)))
                                  : (pv.n === 1
                                     ? qsTr("1 person owes you %1 %3; your own share is %2 %3 (it absorbs any rounding). They pay from their own wallet — the payment is public on the chain.")
                                           .arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit)
                                     : qsTr("%1 people owe you %2 %4 each; your own share is %3 %4 (it absorbs any rounding). Each pays from their own wallet — every payment is public on the chain.")
                                           .arg(pv.n).arg(room.weiToEth(pv.each)).arg(room.weiToEth(pv.mine)).arg(room.splitUnit))
                                  // a Bitcoin share in the unit it is paid and confirmed in: exact satoshis
                                  + (room.splitBitcoin && pv !== null && !room.splitDust(pv)
                                     ? qsTr(" Each share is exactly %1 sat.").arg(pv.each) : "")
                            color: (pv === null || room.splitDust(pv))
                                   ? Theme.palette.warning : Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }

                        // where a Monero request is paid: an address your own wallet makes for it
                        LogosText {
                            objectName: "roomSplitMoneroNote"
                            visible: room.splitMonero && !room.acrossOpen
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            wrapMode: Text.WordWrap
                            text: room.splitSend && room.splitFor.length === 0
                                  ? qsTr("On %1. Sent to the address the person you pick shared from their own wallet; their wallet confirms it at %2 confirmations. Muster never sends Monero.")
                                        .arg(room.moneroChainLabel(room.splitMoneroChain)).arg(room.splitXmrDepthOk ? String(room.splitXmrDepth).trim() : "10")
                                  : room.splitFor.length > 0
                                  ? qsTr("On %1. Paid at the address %2 shared; %2's own wallet confirms each payment at %3 confirmations. Muster never sends Monero.")
                                        .arg(room.moneroChainLabel(room.splitMoneroChain)).arg(room.memberLabel(room.splitFor))
                                        .arg(room.splitXmrDepthOk ? String(room.splitXmrDepth).trim() : "10")
                                  : qsTr("On %1. Proposing asks your open Monero wallet for a new address for this request; your wallet confirms each payment at %2 confirmations. Muster never sends Monero.")
                                        .arg(room.moneroChainLabel(room.splitMoneroChain)).arg(room.splitXmrDepthOk ? String(room.splitXmrDepth).trim() : "10")
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        // how deep a payment must be before the payee's wallet counts it: the
                        // payee bears a reorg's risk, so the request says it and both agree
                        RowLayout {
                            objectName: "roomSplitXmrDepthRow"
                            visible: room.splitMonero && !room.acrossOpen
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 0
                                wrapMode: Text.WordWrap
                                text: qsTr("Counts as paid at this many confirmations (1–720). Fewer is faster for a small amount; 10 is Monero's spend lock.")
                                color: room.splitXmrDepthOk ? Theme.palette.textTertiary : Theme.palette.error
                                font.pixelSize: MusterStyle.caption
                            }
                            LogosTextField {
                                objectName: "roomSplitXmrDepth"
                                Layout.preferredWidth: 70
                                text: "10"
                                // the composer exists before a room does (Start something): set it only in one
                                onTextChanged: if (room) room.splitXmrDepth = String(text)
                            }
                        }
                    }

                    // payment: recipient (+ amount below). You can type it, or ask the room —
                    // the counterparty answers with their own address (ask-then-disclose), so
                    // the demo shows the Safe's recipient being DISCLOSED, not pre-known.
                    RowLayout {
                        visible: room.composeType === "payment"
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosTextField {
                            id: proposeTo
                            objectName: "roomProposeTo"
                            Layout.fillWidth: true
                            placeholderText: room.shownLez ? qsTr("recipient token holding (base58 or hex)")
                                           : room.shownBtc ? qsTr("recipient Bitcoin address (bc1… / tb1… / bcrt1…)")
                                           : qsTr("recipient (0x…)")
                            font.family: MusterStyle.mono
                        }

                        // Post an address-request card into the thread. A room member (the
                        // counterparty) answers it with "Share an address", disclosing their
                        // own address; "Use as recipient" on that card fills this field.
                        ActionButton {
                            objectName: "roomAskAddress"
                            // No one to ask until someone else is in the room — and a request
                            // posted while you're alone can't reach a later joiner anyway (the
                            // room re-keys when they're admitted, F-16), so it's disabled until
                            // the roster has someone else. Admitting a member re-sends any
                            // outstanding ask into their epoch (see onAdmit below).
                            enabled: room.members.length >= 2
                            text: room.members.length >= 2 ? qsTr("Ask the room")
                                                           : qsTr("Ask the room (no one else yet)")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                if (!room.backend) return;
                                room.backend.postMessage(JSON.stringify({
                                    kind: "address-request",
                                    intent: "pay",
                                    purpose: proposeValue.text.length > 0
                                        ? qsTr("Pay %1 %2").arg(proposeValue.text).arg(room.payUnit)
                                        : qsTr("Pay someone from the room")
                                }));
                            }
                        }
                    }

                    // statement: the text the room ratifies.
                    LogosTextField {
                        id: proposeText
                        objectName: "roomProposeText"
                        visible: room.composeType === "statement"
                        Layout.fillWidth: true
                        placeholderText: qsTr("what the room ratifies…")
                    }

                    // Not enough people to act on a proposal yet — say so, and that Propose
                    // is off until the room fills. You compose it now; you submit it once the
                    // people it takes to agree are here (so it isn't sealed away from them).
                    LogosText {
                        objectName: "roomProposeGate"
                        visible: !room.enoughToPropose
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Waiting for the room to fill — a proposal needs at least %1 "
                                 + "people here to act on it. Invite someone and admit them, "
                                 + "then Propose. (%2 here now.)")
                              .arg(room.requiredToPropose).arg(room.members.length)
                        color: Theme.palette.warning
                        font.pixelSize: MusterStyle.caption
                    }

                    // a Bitcoin payment's fee rate: sat/vB over an upper bound of its signed size,
                    // paid out of the account's own coins. On its own labelled line, so the amount
                    // beside Propose keeps room for its unit (exo-dcc.31).
                    RowLayout {
                        visible: room.composeType === "payment" && room.shownBtc
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            text: qsTr("Fee rate")
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosTextField {
                            id: proposeFeeRate
                            objectName: "roomProposeFeeRate"
                            Layout.preferredWidth: 90
                            placeholderText: qsTr("2")
                            text: "2"
                            font.family: MusterStyle.mono
                            validator: IntValidator { bottom: 1 }
                        }
                        LogosText {
                            text: qsTr("sat/vB, paid from the account's own coins")
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        Item { Layout.fillWidth: true }
                    }

                    RowLayout {
                        // the across box has its own Propose and Cancel (exo-a90.17)
                        visible: !(room.composeType === "split" && room.acrossOpen)
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosTextField {
                            id: proposeValue
                            objectName: "roomProposeValue"
                            visible: room.composeType === "payment"
                            Layout.fillWidth: true
                            Layout.minimumWidth: 160   // room for the unit: "amount (token units)"
                            // wei — the Safe transfers this exact value; the balance above is
                            // shown in ETH and in wei so the unit you type against is explicit.
                            // A Bitcoin payment is in satoshis.
                            placeholderText: qsTr("amount (%1)").arg(room.payUnit)
                            font.family: MusterStyle.mono
                            // Any run of digits: amounts are arbitrary precision (wei exceeds
                            // 32 bits: 0.001 ETH is 10^15). IntValidator capped input at
                            // 2147483647 (exo-4da).
                            validator: RegularExpressionValidator { regularExpression: /[0-9]*/ }
                        }


                        // keep the buttons right-aligned when the amount field is hidden.
                        Item { visible: room.composeType !== "payment"; Layout.fillWidth: true }

                        ActionButton {
                            objectName: "roomProposeSubmit"
                            text: (room.composeType === "split" && room.splitSend) ? qsTr("Send") : qsTr("Propose")
                            // a payment needs a recipient AND an amount within the Safe's known
                            // balance — can't over-send (exo-bf9); the ⚠ above says why it's off.
                            // AND the room must have enough people to act on it (see the hint):
                            // don't submit a proposal into a room that can't yet agree to it.
                            // AND no module your own part needs is definitely missing (exo-dcc.10;
                            // the line under the kind picker says which).
                            enabled: !room.composeBlocked && (
                                     room.composeType === "split" ? room.splitPreview(splitTotal.text) !== null && !room.splitTokenPending
                                                                    && !room.splitDust(room.splitPreview(splitTotal.text))
                                                                    && (!room.splitFiat || String(room.splitFiatSource).trim().length > 0)
                                                                    && (room.splitFor.length === 0 || room.splitForAddress.length > 0)
                                                                    && !(room.splitSend && room.splitFor.length === 0)
                                                                    && (!room.splitMonero || room.splitXmrDepthOk)
                                   : room.enoughToPropose && (
                                     room.composeType === "statement" ? proposeText.text.length > 0
                                   : room.composeType === "action" ? room.chosenAction !== null
                                   : room.isBtcPolicy ? proposeTo.text.length > 0 && proposeValue.text.length > 0
                                   : room.isLezPolicy ? proposeTo.text.length > 0 && proposeValue.text.length > 0
                                   : proposeTo.text.length > 0 && !room.overSends(proposeValue.text)))
                            onClicked: {
                                if (room.composeType === "split") {
                                    room.proposeSplit(splitTotal.text, splitMemo.text);
                                    splitTotal.text = "";
                                    splitMemo.text = "";
                                } else if (room.composeType === "statement") {
                                    room.proposeStatement(proposeText.text);
                                    proposeText.text = "";
                                } else if (room.composeType === "action") {
                                    // Mode B passes the counterparty arg + chain (exo-45e); off,
                                    // they're empty and it proposes as a plain invoke.
                                    room.proposeAction(room.chosenAction, proposeArgs.text,
                                        room.modeB ? proposeCounterparty.text : "",
                                        room.modeB ? proposeChain.text : "");
                                    proposeArgs.text = "";
                                    proposeChain.text = "";
                                } else if (room.isLezPolicy) {
                                    // the proposer's own Propose, sent now; the card appears
                                    // once a block includes it
                                    if (room.backend) room.backend.proposeLezTransfer(proposeTo.text, proposeValue.text);
                                    proposeTo.text = "";
                                    proposeValue.text = "";
                                    room.composing = false;
                                } else if (room.isBtcPolicy) {
                                    // coins read from your node, change back to the account
                                    if (room.backend)
                                        room.backend.proposeBtcSpend(proposeTo.text, proposeValue.text,
                                                                     proposeFeeRate.text.length > 0 ? proposeFeeRate.text : "1");
                                    proposeTo.text = "";
                                    proposeValue.text = "";
                                    room.composing = false;
                                } else {
                                    room.proposeFrom(proposeTo.text, proposeValue.text);
                                    proposeTo.text = "";
                                    proposeValue.text = "";
                                }
                            }
                        }

                        ActionButton {
                            objectName: "roomProposeCancel"
                            text: qsTr("Cancel")
                            onClicked: room.composing = false
                        }
                    }

                    RowLayout {
                        objectName: "roomLezVaultInit"
                        visible: room.policyKind === "lez-multisig" && room.composing
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: lezDefinition
                            objectName: "roomLezDefinition"
                            Layout.fillWidth: true
                            placeholderText: qsTr("token definition account — to set up the vault to hold it")
                            font.family: MusterStyle.mono
                        }
                        ActionButton {
                            objectName: "roomLezVaultInitPropose"
                            text: qsTr("Propose vault setup")
                            enabled: !room.composeBlocked && room.enoughToPropose && lezDefinition.text.length > 0
                            onClicked: {
                                if (room.backend) room.backend.proposeLezVaultInit(lezDefinition.text);
                                lezDefinition.text = "";
                                room.composing = false;
                            }
                        }
                    }
                }
            }
        }
    }

    // ── outcomes, said where they happened (exo-720.9, U-8) ───────────────────────
    // What came of the last proposal, payment or approval: the cause and the remedy, as
    // InlineNotices, each dismissible (it comes back when a new outcome changes its words:
    // exo-408 #7, "the last result never clears"). The words are as they were.

    // a split action that did nothing says why — never a silent no-op (exo-a90)
    InlineNotice {
        id: splitNotice
        objectName: "roomSplitFeedback"
        readonly property var r: room.splitResult || ({})
        visible: !!(room.splitResult && room.splitResult.error) && !room.moneroRefusalResolved && !dismissed
        dismissible: true
        tone: room.noAddressAnswered ? "info" : "error"
        readonly property string raw: {
            var r = room.splitResult || {};
            var what = r.op === "pay" ? qsTr("Your share was not paid")
                     : r.op === "share" ? (String(r.chain || "").indexOf("monero:") === 0 || String(r.request || "") === "monero.wallet.unlock"
                                           ? qsTr("Your Monero address was not shared") : qsTr("Your address was not shared"))
                     : r.op === "confirm" ? qsTr("The share was not confirmed")
                     : r.op === "settle-up" ? qsTr("Nothing was settled up")
                     : qsTr("The split was not proposed");
            if (String(r.error || "") === "no-address")
                return room.noAddressAnswered
                       ? qsTr("✓ %1 has shared an address on %2 — propose the settle-up again.")
                             .arg(String(r.name || "")).arg(String(r.chainLabel || r.chain || ""))
                       : qsTr("⚠ %1 — %2 has shared no address on %3 to be paid at. Ask them to share one, then propose again.")
                             .arg(what).arg(String(r.name || "")).arg(String(r.chainLabel || r.chain || ""));
            if (String(r.error || "") === "expired-duplicate")
                return qsTr("⚠ %1 — an identical split expired in this room. Change its note to propose it again, or renew the old one's unpaid shares from its card.").arg(what);
            // a Monero wallet refusal (exo-dcc.5): the request names the remedy
            if (String(r.request || "") === "monero.wallet.unlock" || String(r.error || "").indexOf("wallet-") === 0
                || String(r.error || "") === "no-wallet" || String(r.error || "") === "payto-not-mine")
                return qsTr("⚠ %1 — %2").arg(what)
                                         .arg(room.moneroWhy(r.error, r.detail));
            // no node or wallet for the chain (exo-408 item 9): the setting that fixes it
            var chainWords = room.chainErrorWords(String(r.error || ""), r.detail);
            if (chainWords.length > 0) return qsTr("⚠ %1 — %2").arg(what).arg(chainWords);
            return qsTr("⚠ %1 — %2%3").arg(what).arg(String(r.error || ""))
                       .arg(r.detail ? ": " + String(r.detail) : "");
        }
        text: MusterStyle.plain(raw)

        // a Monero refusal's remedies (exo-dcc.5): open the wallet, or install it.
        // Which wallet (exo-dcc.20): the one the module names, else one button per wallet
        // that could be it, else none at all — set one up in Monero Wallet.
        readonly property bool moneroRemedy: String(r.request || "") === "monero.wallet.unlock" && String(r.error || "") !== "wallet-busy"
                                             && !room.moneroRefusalResolved
        readonly property var choices: Array.isArray(r.wallets) ? r.wallets : []
        ActionButton {
            objectName: "roomOpenMoneroWallet"
            visible: splitNotice.moneroRemedy && splitNotice.choices.length < 2
            compact: true
            text: splitNotice.r.noWallet ? qsTr("Set up a wallet in Monero Wallet") : qsTr("Open Monero Wallet")
            enabled: String((room.moneroWallet || {}).state || "") !== "asking"
            onClicked: room.moneroWalletRequested(String((room.splitResult || {}).wallet || ""))
        }
        Repeater {
            model: splitNotice.moneroRemedy && splitNotice.choices.length > 1 ? splitNotice.choices : []
            delegate: ActionButton {
                required property var modelData
                objectName: "roomOpenMoneroWallet_" + String(modelData)
                compact: true
                text: qsTr("Open %1").arg(String(modelData))
                enabled: String((room.moneroWallet || {}).state || "") !== "asking"
                onClicked: room.moneroWalletRequested(String(modelData))
            }
        }
        ActionButton {
            objectName: "roomInstallMoneroWallet"
            readonly property string pkg: String((room.splitResult || {}).install || "")
            visible: splitNotice.moneroRemedy && pkg.length > 0
                     && (String((room.splitResult || {}).error || "") === "wallet-unread"
                         || String((room.moneroWallet || {}).state || "") === "unavailable")
            compact: true
            quiet: true
            text: qsTr("Install %1").arg(pkg)
            onClicked: room.packageInstallRequested(pkg)
        }
        // a settle-up across chains needs an address the recipient shared (exo-a90.17): ask
        ActionButton {
            objectName: "roomAskSettleAddress"
            visible: !!(room.splitResult && String(room.splitResult.error || "") === "no-address") && !room.noAddressAnswered
            compact: true
            text: qsTr("Ask %1 to share an address").arg(String((room.splitResult && room.splitResult.name) || ""))
            onClicked: {
                if (!room.backend) return;
                var ch = String(room.splitResult.chain || "");
                var label = String(room.splitResult.chainLabel || ch);
                // asked of one member (exo-8e2): only they are offered "Share", and the
                // card says when they have answered
                room.backend.postMessage(JSON.stringify({
                    kind: "address-request", intent: "settle-up",
                    asset: ch.indexOf("bip122:") === 0 ? "BTC" : "ETH", chain: ch, chainLabel: label,
                    "for": String(room.splitResult.who || ""),
                    purpose: qsTr("Settle up across chains: an address on %1").arg(label)
                }));
            }
        }
    }
    InlineNotice {
        objectName: "roomMoneroWalletNote"
        visible: String((room.splitResult || {}).request || "") === "monero.wallet.unlock" && room.moneroWalletNote().length > 0
        tone: String((room.moneroWallet || {}).state || "") === "open" ? "info" : "warning"
        text: room.moneroWalletNote() + (room.moneroRefusalResolved ? qsTr(" Try again.") : "")
    }

    // a Bitcoin payment that could not be proposed says why (no node configured,
    // the node unreachable, not enough in the account) — never a silent no-op
    InlineNotice {
        objectName: "roomBtcProposeFeedback"
        visible: !!(room.btcPropose && room.btcPropose.error) && !dismissed
        dismissible: true
        tone: "error"
        title: qsTr("The Bitcoin payment was not proposed.")
        text: String((room.btcPropose && room.btcPropose.error) || "")
              + (room.btcPropose && room.btcPropose.detail ? ": " + String(room.btcPropose.detail) : "")
    }

    // a LEZ multisig proposal is sent at once and appears once the chain has it;
    // say which, or why it was not sent (exo-3c9)
    InlineNotice {
        objectName: "roomLezProposeFeedback"
        visible: !!(room.lezPropose && (room.lezPropose.error || room.lezPropose.pending)) && !dismissed
        dismissible: true
        tone: room.lezPropose && room.lezPropose.error ? "error" : "info"
        text: MusterStyle.plain(room.lezPropose && room.lezPropose.error
              ? qsTr("⚠ The LEZ proposal was not sent — %1%2")
                    .arg(String(room.lezPropose.error))
                    .arg(room.lezPropose.detail ? ": " + String(room.lezPropose.detail) : "")
              : qsTr("⏳ Proposal #%1 is on its way to the chain (tx %2…) — it appears here once a block includes it.")
                    .arg(String((room.lezPropose && room.lezPropose.index) || "?"))
                    .arg(String((room.lezPropose && room.lezPropose.tx) || "").slice(0, 12)))
    }

    // a vote-locus approval is the member's own chain transaction: sent now, it
    // counts once a block includes it
    InlineNotice {
        objectName: "roomApprovePending"
        visible: !!(room.contributeResult && String(room.contributeResult.state || "").indexOf("pending") === 0)
        tone: "info"
        text: qsTr("Your vote is on its way to the chain — it counts once a block includes it.")
    }

    // approval feedback — an in-app Approve that didn't count says WHY, right
    // here, instead of silently doing nothing. The common case: your key isn't
    // a recognized signer for the intent's policy (a Safe owner / an attester).
    InlineNotice {
        objectName: "roomApproveFeedback"
        visible: !!(room.contributeResult && room.contributeResult.ok === false) && !dismissed
        dismissible: true
        tone: "error"
        readonly property string raw: {
            var r = room.contributeResult || ({});
            var reason = String(r.reason || "");
            if (reason === "rejected")
                return qsTr("⚠ Your approval didn't count: this proposal doesn't recognize "
                          + "your key (it needs a Safe owner, or an account the room "
                          + "recognizes). Check which account signs, above.");
            if (reason === "not-joined")
                return qsTr("⚠ Not in a room — join one first.");
            if (reason === "unknown-intent")
                return qsTr("⚠ That proposal isn't in the room's log yet — give it a moment.");
            // A proposal reaches you as several log entries; its signing context can
            // arrive a moment after the proposal itself (exo-ca3). Nothing is signed
            // without it (invariant 2), so say that, and that trying again will do.
            if (reason === "no-context")
                return qsTr("⚠ Nothing was signed — this proposal's signing context (the "
                          + "environment, account and expiry your signature binds to) hasn't "
                          + "reached you yet. Give it a moment and approve again.");
            if (reason === "unaccountable-input")
                return qsTr("⚠ Nothing was signed — an input that reached this proposal's bytes "
                          + "can't be accounted for. If its log entry is still on the way, "
                          + "approving again in a moment will work; if not, it can't be signed.");
            if (reason === "attestation-mismatch")
                return qsTr("⚠ Your approval wasn't sent: its signature didn't check out "
                          + "against your key, so everyone would have rejected it.");
            return qsTr("⚠ Approval didn't count — %1").arg(reason);
        }
        text: MusterStyle.plain(raw)
    }

    // a voice note recording, its draft, and what the module said of either (RoomVoiceNote)
    RoomVoiceNote { room: composerRoot.room }

    // ── the message row (exo-720.9): "+" opens the action picker; Enter sends ──────
    function sendMessage() {
        if (room.backend && composer.text.length > 0) {
            room.sendChat(composer.text);      // shows at once, "sending…" (exo-49d)
            composer.text = "";
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        Rectangle {
            id: plusButton
            objectName: "roomProposeButton"
            signal clicked()
            implicitWidth: 40
            implicitHeight: 40
            radius: Theme.spacing.radiusLarge
            color: actionPicker.opened || plusHover.hovered ? Theme.palette.primary : Theme.palette.surface
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Propose something")
            Keys.onReturnPressed: clicked()
            Keys.onSpacePressed: clicked()
            onClicked: actionPicker.opened ? actionPicker.close() : actionPicker.open()
            LogosIcon {
                anchors.centerIn: parent
                width: 20; height: 20
                source: MusterStyle.icon("plus")
                color: actionPicker.opened || plusHover.hovered ? Theme.palette.background : Theme.palette.text
            }
            HoverHandler { id: plusHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: plusButton.clicked() }
            LogosToolTip { visible: plusHover.hovered && !actionPicker.opened; text: qsTr("Propose something") }

            RoomActionPicker {
                id: actionPicker
                room: composerRoot.room
                // its own parent is the 40 px "+": size it by the composer (seen 2026-10-11,
                // a picker as narrow as the button, its tiles spilling out of it)
                width: Math.min(560, composerRoot.width)
                y: -height - Theme.spacing.small
            }
        }

        LogosTextField {
            id: composer
            objectName: "messageComposer"
            Layout.fillWidth: true
            placeholderText: room.roomTitle.length > 0 ? qsTr("Message %1").arg(room.roomTitle) : qsTr("Say something")
        }

        // Enter sends — the inner TextInput emits accepted on Return.
        Connections {
            target: composer.textInput
            function onAccepted() { composerRoot.sendMessage(); }
        }

        // record a voice note (docs/design/voice-notes.md §8, §14): a message in another
        // medium, so here in the message row, not among the proposals the "+" offers. The
        // module records; nothing is sent until the draft's own Send.
        IconAction {
            objectName: "voiceRecordButton"
            visible: room.voiceState === "idle"
            label: qsTr("Record a voice note")
            icon: MusterStyle.icon("mic")
            enabled: !room.voicePlaying
            opacity: enabled ? 1 : 0.4
            size: 40
            onClicked: room.startVoice()
        }

        IconAction {
            objectName: "sendMessageButton"
            label: qsTr("Send (Enter)")
            icon: MusterStyle.icon("send")
            enabled: composer.text.length > 0
            opacity: enabled ? 1 : 0.4
            size: 40
            onClicked: composerRoot.sendMessage()
        }
    }
}
