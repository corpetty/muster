pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What a rail puts on the public record, as three chips: the amount, you, them.
//
// Extracted so the picker that offers a rail and the wallet that lists it draw
// the same square from the same struct. A second rendering of `discloses` is a
// second chance to describe it differently, and the two claims disagreeing is
// exactly the failure the honesty rules are for.
//
// Withheld takes the accent, because withheld is the good outcome — the same
// colour rule the receipt's "what left the room" table uses, so the promise
// before a payment and the account of it afterwards read as one claim.
RowLayout {
    id: root

    // The rail's `discloses` map: {amount, payer, payee}.
    required property var discloses

    spacing: Theme.spacing.tiny

    Repeater {
        model: [{ k: qsTr("amount"), shown: root.discloses.amount },
                { k: qsTr("you"), shown: root.discloses.payer },
                { k: qsTr("them"), shown: root.discloses.payee }]

        delegate: Rectangle {
            id: chip
            required property var modelData

            implicitWidth: chipText.implicitWidth + 2 * Theme.spacing.small
            implicitHeight: chipText.implicitHeight + 4
            radius: Theme.spacing.radiusSmall
            color: chip.modelData.shown
                ? Theme.colors.getColor(ChatTheme.alarm, 0.14)
                : Theme.colors.getColor(ChatTheme.settled, 0.14)

            LogosText {
                id: chipText
                anchors.centerIn: parent
                text: chip.modelData.shown
                    ? qsTr("%1 public").arg(chip.modelData.k)
                    : qsTr("%1 hidden").arg(chip.modelData.k)
                color: chip.modelData.shown ? ChatTheme.alarm : ChatTheme.settled
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }
    }

    Item { Layout.fillWidth: true }
}
