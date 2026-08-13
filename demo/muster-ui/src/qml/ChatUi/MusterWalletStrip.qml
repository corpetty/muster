pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What of your wallet is in play in this muster — and, by omission, what is not.
//
// A conversation reaches into part of a wallet, never all of it. Putting the
// whole wallet beside every thread said the opposite: that opening a room with
// someone puts everything you have on the table. This lists only the holdings
// this thread has actually used — an address shared into it, a payment drawn
// from it — each with the sentence saying which.
//
// The omission is the teaching. A holding absent from this list has not been
// named to this room, and that is a fact about the room worth being able to
// read at a glance. So an empty slice says so in words rather than rendering
// nothing.
//
// Rows come from the backend's fold joined to the live `assets`, so the figure
// here is the wallet's own. Nothing branches on a particular holding.
Rectangle {
    id: root

    // Rows from store.musterAssets: a holding's own row, plus `why`.
    required property var assets
    // Whether the wallet has opened. A closed wallet has put nothing in play
    // anywhere, which is not the same as this room having used none of it.
    required property bool ready

    // The whole wallet, a click away.
    signal walletRequested

    implicitWidth: 300
    implicitHeight: layout.implicitHeight + 2 * Theme.spacing.medium
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.backgroundTertiary
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        PanelHeader {
            Layout.fillWidth: true
            title: qsTr("In play here")
            count: root.assets.length
        }

        Repeater {
            model: root.assets

            delegate: ColumnLayout {
                id: holding
                required property var modelData

                Layout.fillWidth: true
                spacing: 1

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        objectName: "musterAssetBalance_" + holding.modelData.id
                        text: qsTr("%1 %2")
                            .arg(holding.modelData.balance === ""
                                 ? "—" : holding.modelData.balance)
                            .arg(holding.modelData.denom)
                        color: holding.modelData.empty
                            ? Theme.palette.textTertiary : Theme.palette.text
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.secondaryText
                    }

                    Item { Layout.fillWidth: true }

                    LogosText {
                        text: holding.modelData.name
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        elide: Text.ElideRight
                        Layout.maximumWidth: 110
                    }
                }

                // What this room did with it. The reason it is on the list is
                // the only thing this strip says that the wallet does not.
                LogosText {
                    objectName: "musterAssetWhy_" + holding.modelData.id
                    Layout.fillWidth: true
                    text: holding.modelData.why
                    color: Theme.palette.textTertiary
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.typography.badgeText
                }
            }
        }

        // Said, not left blank. "Nothing here yet" is a claim about the room's
        // reach into the wallet; an empty card is a claim about nothing.
        LogosText {
            objectName: "musterWalletEmpty"
            Layout.fillWidth: true
            visible: root.assets.length === 0
            wrapMode: Text.WordWrap
            text: root.ready
                ? qsTr("None of your wallet is in this conversation yet. Sharing an "
                     + "address or paying from a holding is what puts one here.")
                : qsTr("No wallet open, so nothing of yours is in this conversation.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
        }

        LogosButton {
            objectName: "musterWalletOpenFull"
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.tiny
            text: qsTr("Whole wallet")
            font.pixelSize: Theme.typography.secondaryText
            onClicked: root.walletRequested()
        }
    }
}
