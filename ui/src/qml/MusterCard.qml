import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A typed card that rode inside a room message as JSON, rendered where it was
// agreed. Five kinds: the ask for an address, the address that answers it, a
// proposal the room decides on, a bare approval, and the receipt for the
// payment that followed. This component is pure render — data comes in through
// `card`, and the only things that leave are the four action signals. It calls
// no backend and holds no state; the thread that hosts it owns both.
//
// An unknown kind renders nothing (implicitHeight 0, visible false), so the
// thread can fall back to a plain-text bubble. Every field is guarded, because
// a card is peer JSON: a missing field is normal, never an error.
//
// NB (ADR-011): nix build does not evaluate QML; a bad type name here blanks
// the whole view invisibly. Restricted to Theme keys and the Logos.Controls
// types Room.qml / Walkthrough.qml already prove — LogosText, LogosButton.
Rectangle {
    id: cardRoot

    // The parsed card object: { kind, ... }. Never assume more than `kind`.
    property var card

    // Actions belong to the reader, and the thread decides what each does. The
    // card only says which button was pressed.
    signal approve()
    signal pay()
    signal drop()
    signal shareAddress()

    readonly property string kind: cardRoot.card ? String(cardRoot.card.kind || "") : ""

    // The kinds this component knows how to draw. Anything else is not ours to
    // render, so we disappear and let the thread show plain text.
    readonly property bool known:
        cardRoot.kind === "address-request"
        || cardRoot.kind === "address-share"
        || cardRoot.kind === "intent-propose"
        || cardRoot.kind === "intent-approve"
        || cardRoot.kind === "send-receipt"

    // ── intent-propose reading ────────────────────────────────────────────
    // The terms come off the card; the live counts do too, since this build
    // has no fold to consult — so guard each one and never invent a default
    // that would overstate agreement.
    readonly property string state: cardRoot.card && cardRoot.card.state
        ? String(cardRoot.card.state) : "proposed"
    readonly property int threshold: cardRoot.card ? Number(cardRoot.card.threshold || 0) : 0
    readonly property int approvals: cardRoot.card ? Number(cardRoot.card.approvals || 0) : 0
    readonly property bool paid: cardRoot.state === "paid"
    // "Ready" means enough approvals have landed to pay — by declared state, or
    // by the count reaching the threshold. Either is enough to stop asking.
    readonly property bool ready: cardRoot.state === "ready" || cardRoot.paid
        || (cardRoot.threshold > 0 && cardRoot.approvals >= cardRoot.threshold)

    visible: cardRoot.known
    Layout.fillWidth: true
    implicitHeight: cardRoot.known ? body.implicitHeight + 2 * Theme.spacing.medium : 0

    radius: Theme.spacing.radiusMedium
    // The receipt is the one moment value leaves the room, so it carries the
    // outside ground inside it — every other kind stays on the raised surface.
    color: cardRoot.kind === "send-receipt"
        ? Theme.palette.surfaceRecessed
        : Theme.palette.surfaceRaised
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.tiny

        // ── a one-line heading, in mono — the "this is data" voice ─────────
        LogosText {
            Layout.fillWidth: true
            text: cardRoot.kind === "address-request" ? qsTr("Asked for an address")
                : cardRoot.kind === "address-share" ? qsTr("Shared an address")
                : cardRoot.kind === "intent-propose" ? qsTr("Proposed a payment")
                : cardRoot.kind === "intent-approve" ? qsTr("Approved")
                : qsTr("Payment sent")
            color: cardRoot.kind === "send-receipt"
                ? Theme.palette.textSecondary
                : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        // ── address-request ────────────────────────────────────────────────
        LogosText {
            visible: cardRoot.kind === "address-request"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("They want somewhere to send funds.")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.primaryText
        }

        // ── address-share ({asset, address, form}) ─────────────────────────
        ColumnLayout {
            visible: cardRoot.kind === "address-share"
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.card && cardRoot.card.asset
                    ? String(cardRoot.card.asset) : qsTr("private account")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
            }

            // What kind of destination it is matters more than the sixty
            // characters no one reads — so name the form, then show a clipped
            // address after it. `form` 0 is shielded, 1 is a public account;
            // getting this wrong is the exact lie a labelled address must not
            // tell, so an absent form reads as the safer "shielded".
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                text: {
                    var form = cardRoot.card && cardRoot.card.form !== undefined
                        ? Number(cardRoot.card.form) : 0;
                    var addr = cardRoot.card && cardRoot.card.address
                        ? String(cardRoot.card.address).replace(/\s+/g, "") : "";
                    var shown = addr.slice(0, 48) + (addr.length > 48 ? "…" : "");
                    return (form === 1 ? qsTr("public account") : qsTr("shielded"))
                        + (shown.length > 0 ? "  ·  " + shown : "");
                }
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
            }

            // A public account is worth a word: the payer should know the
            // destination is readable before choosing how to pay.
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.form !== undefined
                    && Number(cardRoot.card.form) === 1
                wrapMode: Text.WordWrap
                text: qsTr("Anyone reading the zone can see what lands here.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── intent-approve ─────────────────────────────────────────────────
        // Deliberately thin: an approval is a fact in the thread, not a thing
        // to act on. It earns a line so the record reads in order, no more.
        LogosText {
            visible: cardRoot.kind === "intent-approve"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Added to the proposal above.")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.primaryText
        }

        // ── intent-propose (the heart) ─────────────────────────────────────
        // The room deciding something before anyone acts on it. The effect
        // leads (amount → destination), a status rail shows how far it has
        // got, and approvals are drawn as filled slots — because "who is still
        // to weigh in" is the question people actually have.
        ColumnLayout {
            visible: cardRoot.kind === "intent-propose"
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            // header: label · M of N
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var label = cardRoot.card && cardRoot.card.label
                        ? String(cardRoot.card.label) : qsTr("Proposal");
                    return cardRoot.threshold > 0
                        ? label + "  ·  " + qsTr("%1 of %2").arg(cardRoot.threshold)
                                                            .arg(cardRoot.threshold)
                        : label;
                }
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
            }

            // the effect: amount denom → to
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var amt = String((cardRoot.card && cardRoot.card.amount) || "");
                    var den = String((cardRoot.card && cardRoot.card.denom) || "");
                    var to = String((cardRoot.card && cardRoot.card.to) || "");
                    var lead = (amt + " " + den).trim();
                    return to.length > 0 ? lead + "  →  " + to : lead;
                }
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightMedium
            }

            // which rail the room is being asked to agree to
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.rail
                wrapMode: Text.WordWrap
                text: String((cardRoot.card && cardRoot.card.rail) || "")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // ── status rail: proposed → collecting → ready → paid ──────────
            // The whole path is drawn from the first card; a step at or before
            // the current state is lit, everything after stays drawn but unlit.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                spacing: Theme.spacing.tiny

                Repeater {
                    model: [{ k: "proposed", t: qsTr("proposed") },
                            { k: "collecting", t: qsTr("collecting") },
                            { k: "ready", t: qsTr("ready") },
                            { k: "paid", t: qsTr("paid") }]

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
                                            : Theme.palette.borderDefault
                        }

                        LogosText {
                            text: step.modelData.t
                            color: step.lit ? Theme.palette.textSecondary
                                            : Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        Item { Layout.preferredWidth: Theme.spacing.small }
                    }
                }
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
                        readonly property var who: cardRoot.card && cardRoot.card.approvers
                            && slot.index < cardRoot.card.approvers.length
                            ? cardRoot.card.approvers[slot.index] : null

                        implicitWidth: 22
                        implicitHeight: 22
                        radius: 11
                        color: slot.filled ? Theme.palette.success : "transparent"
                        border.width: slot.filled ? 0 : 1
                        border.color: Theme.palette.borderDefault

                        LogosText {
                            anchors.centerIn: parent
                            visible: slot.filled
                            text: slot.who && slot.who.initials
                                ? String(slot.who.initials) : ""
                            color: Theme.palette.background
                            font.pixelSize: Theme.typography.badgeText
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
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
            }

            // The honesty caveat this card must not overstate. The count above
            // is real in the room; the chain is not asked to check it.
            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                wrapMode: Text.WordWrap
                text: qsTr("The threshold is authenticated in the room; "
                           + "the chain does not enforce it.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── send-receipt ({amount, denom, rail, tx, discloses}) ────────────
        // The one moment something leaves the room, on the recessed ground.
        // Names the effect, then lists what the chain actually got.
        ColumnLayout {
            visible: cardRoot.kind === "send-receipt"
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: (String((cardRoot.card && cardRoot.card.amount) || "")
                    + " " + String((cardRoot.card && cardRoot.card.denom) || "")).trim()
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightMedium
            }

            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.rail
                text: String((cardRoot.card && cardRoot.card.rail) || "")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // ── what left the room ─────────────────────────────────────────
            // Read straight off the receipt's own `discloses`. A withheld
            // field is the good outcome, so it takes the success accent; a
            // disclosed one is stated plainly. An absent `discloses` says so
            // rather than guessing what a rail leaked.
            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                text: qsTr("WHAT LEFT THE ROOM")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }

            Repeater {
                model: {
                    var d = cardRoot.card && cardRoot.card.discloses
                        ? cardRoot.card.discloses : {};
                    return [
                        { k: qsTr("amount"),
                          v: d.amount ? String((cardRoot.card && cardRoot.card.amount) || "")
                                      : qsTr("not disclosed"),
                          withheld: !d.amount },
                        { k: qsTr("who paid"),
                          v: d.payer ? qsTr("on the record") : qsTr("not disclosed"),
                          withheld: !d.payer },
                        { k: qsTr("who was paid"),
                          v: d.payee ? qsTr("on the record") : qsTr("not disclosed"),
                          withheld: !d.payee }];
                }

                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: modelData.k
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }

                    Item { Layout.fillWidth: true }

                    LogosText {
                        text: modelData.v
                        color: modelData.withheld
                            ? Theme.palette.success : Theme.palette.textSecondary
                        horizontalAlignment: Text.AlignRight
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                }
            }

            // The tx id, last and quietest — the thing you would take to an
            // explorer, and the least interesting fact on the card.
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.tx
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                text: String((cardRoot.card && cardRoot.card.tx) || "")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── actions ────────────────────────────────────────────────────────
        // address-request: the reader answers with an address.
        LogosButton {
            objectName: "cardShareAddress"
            visible: cardRoot.kind === "address-request"
            Layout.fillWidth: true
            text: qsTr("Share an address")
            onClicked: cardRoot.shareAddress()
        }

        // intent-propose: approve while it still needs you; pay only if it is
        // ready and yours to pay; drop while it is yours and unpaid.
        LogosButton {
            objectName: "cardApprove"
            visible: cardRoot.kind === "intent-propose"
                && !(cardRoot.card && cardRoot.card.approvedByMe)
                && !cardRoot.ready
            Layout.fillWidth: true
            text: qsTr("Approve")
            onClicked: cardRoot.approve()
        }

        LogosButton {
            objectName: "cardPay"
            visible: cardRoot.kind === "intent-propose"
                && cardRoot.ready && !cardRoot.paid
                && cardRoot.card && cardRoot.card.proposedByMe
            Layout.fillWidth: true
            text: qsTr("Pay it")
            onClicked: cardRoot.pay()
        }

        LogosButton {
            objectName: "cardDrop"
            visible: cardRoot.kind === "intent-propose"
                && !cardRoot.paid
                && cardRoot.card && cardRoot.card.proposedByMe
            Layout.fillWidth: true
            text: qsTr("Drop it")
            onClicked: cardRoot.drop()
        }
    }
}
