import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The wallet, under the account card in the sidebar: what this instance can
// spend, and the two actions that get it there.
//
// Kept beside the identity rather than on a screen of its own, because the
// point of the demo is that paying someone is part of talking to them, not a
// trip to another application.
Rectangle {
    id: root

    required property bool ready
    required property bool busy
    // The backend's own word for what it is doing — "syncing", "mining",
    // "claiming", "shielding", "sending". Zone work runs for minutes, so a
    // named stage is the difference between waiting and wondering.
    required property string stage
    required property string statusLabel
    required property string privateBalance
    required property string publicBalance
    // True when the balance sums in accounts the user never created.
    property bool receivedElsewhere: false
    property string errorText: ""

    signal openRequested
    signal fundRequested
    signal refreshRequested

    implicitHeight: layout.implicitHeight + 2 * Theme.spacing.medium
    color: Theme.palette.surface
    radius: Theme.spacing.radiusMedium
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                text: qsTr("Wallet")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
            }

            Item { Layout.fillWidth: true }

            LogosText {
                objectName: "walletStatus"
                text: root.statusLabel
                color: root.ready ? ChatTheme.settled : Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
                elide: Text.ElideRight
                Layout.maximumWidth: 140
            }
        }

        // Private balance is the headline: it is what a private payment can be
        // drawn from. The public one is shown only because the faucet pays into
        // it, and watching it move to private is half the lesson.
        RowLayout {
            Layout.fillWidth: true
            visible: root.ready
            spacing: Theme.spacing.small

            LogosText {
                objectName: "privateBalance"
                text: qsTr("%1 private").arg(root.privateBalance === "" ? "—" : root.privateBalance)
                color: Theme.palette.text
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.primaryText
            }

            Item { Layout.fillWidth: true }

            LogosText {
                objectName: "publicBalance"
                visible: root.publicBalance !== "" && root.publicBalance !== "0"
                text: qsTr("%1 public").arg(root.publicBalance)
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
            }
        }

        // Said where the number is, not in a panel someone has to open. A
        // received payment lands at an account the recipient never created, so
        // this figure is a sum over accounts found by scanning — and a single
        // send can only draw on one of them. Both facts are surprising enough
        // that the balance should not be shown without them.
        LogosText {
            objectName: "balanceWorkaroundNote"
            Layout.fillWidth: true
            visible: root.ready && root.receivedElsewhere
            wrapMode: Text.WordWrap
            text: qsTr("Includes accounts you did not create — payments arrive at a derived "
                     + "address, not the one you shared. One send draws on one of them.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
        }

        LogosText {
            Layout.fillWidth: true
            visible: root.busy && root.stage !== ""
            text: root.stage
            color: Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            elide: Text.ElideRight
        }

        LogosText {
            Layout.fillWidth: true
            visible: root.errorText !== ""
            text: root.errorText
            color: ChatTheme.alarm
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font.pixelSize: Theme.typography.secondaryText
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosButton {
                objectName: "walletOpen"
                visible: !root.ready
                Layout.fillWidth: true
                text: qsTr("Open wallet")
                enabled: !root.busy
                onClicked: root.openRequested()
            }

            LogosButton {
                objectName: "walletFund"
                visible: root.ready
                Layout.fillWidth: true
                text: qsTr("Fund")
                enabled: !root.busy
                onClicked: root.fundRequested()
            }

            LogosButton {
                objectName: "walletRefresh"
                visible: root.ready
                Layout.fillWidth: true
                text: qsTr("Refresh")
                enabled: !root.busy
                onClicked: root.refreshRequested()
            }
        }
    }
}
