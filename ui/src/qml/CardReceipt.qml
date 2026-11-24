import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A send-receipt card's body (exo-720.3, moved verbatim out of MusterCard.qml).
// `cardRoot` is the MusterCard, as before the move.
// ── send-receipt ({amount, denom, rail, tx, discloses}) ────────────
// The one moment something leaves the room, on the recessed ground.
// Names the effect, then lists what the chain actually got.
ColumnLayout {
    required property var cardRoot

    visible: cardRoot.kind === "send-receipt"
    Layout.fillWidth: true
    spacing: Theme.spacing.tiny

    LogosText {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: (String((cardRoot.card && cardRoot.card.amount) || "")
            + " " + String((cardRoot.card && cardRoot.card.denom) || "")).trim()
        color: Theme.palette.text
        font.family: Theme.typography.publicSans
        font.pixelSize: MusterStyle.cardBody
        font.weight: Theme.typography.weightMedium
    }

    LogosText {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: !!(cardRoot.card && cardRoot.card.rail)
        text: String((cardRoot.card && cardRoot.card.rail) || "")
        color: Theme.palette.textSecondary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.cardCaption
    }

    // ── what left the room ─────────────────────────────────────────
    // Read straight off the receipt's own `discloses`. A withheld
    // field is the good outcome, so it takes the success accent; a
    // disclosed one is stated plainly. An absent `discloses` says so
    // rather than guessing what a rail leaked.
    LogosText {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        text: qsTr("What left the room")
        color: Theme.palette.textTertiary
        font.pixelSize: MusterStyle.cardCaption
        font.weight: Theme.typography.weightBold
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
                textFormat: Text.PlainText
                text: modelData.k
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }

            Item { Layout.fillWidth: true }

            LogosText {
                textFormat: Text.PlainText
                text: modelData.v
                color: modelData.withheld
                    ? Theme.palette.success : Theme.palette.textSecondary
                horizontalAlignment: Text.AlignRight
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.cardCaption
                font.weight: Theme.typography.weightMedium
            }
        }
    }

    // The tx id, last and quietest — the thing you would take to an
    // explorer, and the least interesting fact on the card.
    SelectableText {
        objectName: "receiptTx"
        Layout.fillWidth: true
        visible: !!(cardRoot.card && cardRoot.card.tx)
        text: String((cardRoot.card && cardRoot.card.tx) || "")
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.cardCaption
    }
}
