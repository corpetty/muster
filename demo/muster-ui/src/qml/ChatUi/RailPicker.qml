pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Choosing how to pay, which is choosing what to tell everyone.
//
// The four rails differ in one thing that matters to the person pressing the
// button — what the chain learns — so that is what this draws, as three chips
// per rail rather than a name they would have to already understand. Reading
// down the column, the amount / payer / payee marks make the same square the
// zone actually implements, which is the lesson the demo is for.
//
// Every row comes from the backend's `rails` catalogue, already filtered to the
// ones that can pay the address in hand. Nothing here knows a rail's name, and
// adding one in ChatBackendAssets.cpp puts it in both dialogs at once — which is
// why there is one of these and not a copy in each.
ColumnLayout {
    id: root

    // The rails that can pay this destination, most private first.
    required property var rails
    // The chosen rail's id. Two-way: the dialog seeds it and reads it back.
    property string selected: ""

    readonly property var selectedRail: {
        for (let i = 0; i < root.rails.length; ++i)
            if (root.rails[i].id === root.selected)
                return root.rails[i];
        return null;
    }

    spacing: Theme.spacing.tiny

    LogosText {
        Layout.fillWidth: true
        text: qsTr("HOW TO PAY IT")
        color: Theme.palette.textTertiary
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.badgeText
        font.weight: Theme.typography.weightMedium
    }

    // Nothing to choose between is still worth saying: it means this build has
    // no way to pay the address the peer shared, which is a fact about the
    // build and not an empty list to leave blank.
    LogosText {
        Layout.fillWidth: true
        visible: root.rails.length === 0
        wrapMode: Text.WordWrap
        text: qsTr("This build has no way to pay that kind of address.")
        color: ChatTheme.alarm
        font.pixelSize: Theme.typography.secondaryText
    }

    Repeater {
        model: root.rails

        delegate: Rectangle {
            id: rail
            required property var modelData

            readonly property bool chosen: rail.modelData.id === root.selected
            // A rail whose source holds nothing can still be chosen — the zone
            // is the authority on what it will accept, and refusing here would
            // be this view guessing. It is dimmed, and it says why.
            readonly property bool broke: rail.modelData.balance === ""
                || Number(rail.modelData.balance) <= 0

            Layout.fillWidth: true
            implicitHeight: railBody.implicitHeight + 2 * Theme.spacing.small
            radius: Theme.spacing.radiusSmall
            color: rail.chosen ? Theme.colors.getColor(ChatTheme.signal, 0.12) : "transparent"
            border.width: 1
            border.color: rail.chosen ? ChatTheme.signal : Theme.palette.borderSubtle

            MouseArea {
                anchors.fill: parent
                onClicked: root.selected = String(rail.modelData.id)
            }

            ColumnLayout {
                id: railBody
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        objectName: "railName_" + rail.modelData.id
                        text: rail.modelData.name
                        color: Theme.palette.text
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: rail.chosen ? Theme.typography.weightMedium
                                                 : Theme.typography.weightRegular
                    }

                    Item { Layout.fillWidth: true }

                    // What it can draw on. Which rail you can afford is a real
                    // question here: two of them spend the public balance and
                    // two the private one, and the faucet only fills one.
                    LogosText {
                        text: qsTr("%1 %2")
                            .arg(rail.modelData.balance === "" ? "—" : rail.modelData.balance)
                            .arg(rail.modelData.denom)
                        color: rail.broke ? ChatTheme.alarm : Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // The three facts, as chips. Withheld takes the accent, because
                // withheld is the good outcome — the same colour rule the
                // receipt's "what left the room" table uses, so the promise
                // before the payment and the account of it afterwards read as
                // the same claim.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    Repeater {
                        model: [{ k: qsTr("amount"), shown: rail.modelData.discloses.amount },
                                { k: qsTr("you"), shown: rail.modelData.discloses.payer },
                                { k: qsTr("them"), shown: rail.modelData.discloses.payee }]

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
            }
        }
    }

    // The chosen rail's own sentence, from the catalogue. This is the claim the
    // app makes at the moment of payment, and it lives beside the disclosure
    // flags it describes so the two cannot drift apart.
    LogosText {
        objectName: "railPromise"
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: !!root.selectedRail
        wrapMode: Text.WordWrap
        text: root.selectedRail ? String(root.selectedRail.promise) : ""
        color: Theme.palette.textTertiary
        font.pixelSize: Theme.typography.secondaryText
    }
}
