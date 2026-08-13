pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The wallet, under the account card in the sidebar: everywhere this instance's
// money can be, and the actions that move it.
//
// Kept beside the identity rather than on a screen of its own, because the
// point of the demo is that paying someone is part of talking to them, not a
// trip to another application.
//
// A list, not two numbers. Every row comes from the backend's `assets`
// catalogue, so a holding added in ChatBackendAssets.cpp appears here without
// this file being touched — and, more to the point, so does the fact that money
// can sit in more than one place. The first build showed one balance and called
// it "the wallet", which made the shielding step look like an implementation
// detail rather than the thing it is.
Rectangle {
    id: root

    required property bool ready
    required property bool busy
    // The backend's own word for what it is doing — "syncing", "mining",
    // "claiming", "shielding", "sending". Zone work runs for minutes, so a
    // named stage is the difference between waiting and wondering.
    required property string stage
    required property string statusLabel
    // One map per balance this wallet can hold. See ChatBackend.rep.
    required property var assets
    // True when the private balance sums in accounts the user never created.
    property bool receivedElsewhere: false
    property string errorText: ""

    signal openRequested
    signal fundRequested
    signal refreshRequested
    signal claimRequested(string assetId)
    // The whole wallet, opened out. This card is the summary — what you have —
    // and that is all a conversation needs; where each holding can go and what
    // going there discloses is a page, not a sidebar.
    signal detailsRequested

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

            // On the heading rather than among the buttons below: those three
            // move money, and the way to a page that only reads should not sit
            // in the same row as them.
            ChatIconButton {
                id: detailsButton
                objectName: "walletDetailsButton"
                size: 24
                iconSize: 12
                iconSource: Qt.resolvedUrl("icons/info.png")
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Open the whole wallet")
                onClicked: root.detailsRequested()
                Layout.alignment: Qt.AlignVCenter

                LogosToolTip {
                    text: qsTr("Open the whole wallet")
                    placement: LogosToolTip.Top
                    visible: detailsButton.hovered
                }
            }
        }

        // Every holding, in the catalogue's order — most private first. An empty
        // one is drawn dimmed rather than hidden: where money *could* be is as
        // much the point as where it is, and a row that appears only once it has
        // a balance teaches nothing about the shape of the wallet.
        Repeater {
            model: root.ready ? root.assets : []

            delegate: ColumnLayout {
                id: holding
                required property var modelData

                Layout.fillWidth: true
                spacing: 1

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        objectName: "assetBalance_" + holding.modelData.id
                        text: qsTr("%1 %2")
                            .arg(holding.modelData.balance === ""
                                 ? "—" : holding.modelData.balance)
                            .arg(holding.modelData.denom)
                        color: holding.modelData.empty
                            ? Theme.palette.textTertiary : Theme.palette.text
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.primaryText
                    }

                    Item { Layout.fillWidth: true }

                    LogosText {
                        text: holding.modelData.name
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.secondaryText
                        elide: Text.ElideRight
                        Layout.maximumWidth: 120
                    }
                }

                // Where the money actually is. A number with no location is
                // what made the first build's single balance confusing once
                // there was more than one place it could have been.
                LogosText {
                    Layout.fillWidth: true
                    text: holding.modelData.sourceNote
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                    elide: Text.ElideRight
                }

                // Why this one is not usable yet, on the row it applies to
                // rather than as a wallet-wide state — one holding waiting is
                // not the app being hung, which is exactly how it read when the
                // wallet gated Ready on a private registration it turned out not
                // to need. Nothing sets a blocker today; the row stays because
                // the next holding that needs one should not have to reinvent it.
                LogosText {
                    objectName: "assetBlocked_" + holding.modelData.id
                    Layout.fillWidth: true
                    visible: holding.modelData.blocked
                    wrapMode: Text.WordWrap
                    text: holding.modelData.blockedNote
                    color: ChatTheme.alarm
                    font.pixelSize: Theme.typography.badgeText
                }

                // Only for a holding that says it can be claimed — a balance
                // that is owed rather than held. The catalogue supplies the
                // verb, so a new claimable holding needs nothing here.
                LogosButton {
                    objectName: "assetClaim_" + holding.modelData.id
                    visible: holding.modelData.canClaim
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    text: holding.modelData.claimVerb
                    enabled: !root.busy
                    onClicked: root.claimRequested(String(holding.modelData.id))
                }
            }
        }

        // A wallet that has never been funded shows nothing but zeros, which is
        // indistinguishable from a wallet that is broken or a Fund that did
        // nothing — and on this build the first thing anyone sees is exactly
        // that. So it says which, and what to press. Only while everything is
        // empty: the moment any holding has a balance this is noise.
        LogosText {
            objectName: "walletEmptyHint"
            Layout.fillWidth: true
            visible: root.ready && root.assets.length > 0
                     && root.assets.every(a => a.empty)
            wrapMode: Text.WordWrap
            text: qsTr("Nothing in it yet — that is empty, not broken. Fund claims from the "
                     + "zone's test faucet and shields the prize into your private account.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
        }

        // Said where the number is, not in a panel someone has to open. Every
        // received payment lands at an account the recipient never created, so
        // this figure is a sum over accounts found by scanning — and a single
        // send can only draw on one of them. Both facts are surprising enough
        // that the balance should not be shown without them.
        LogosText {
            objectName: "balanceScanNote"
            Layout.fillWidth: true
            visible: root.ready && root.receivedElsewhere
            wrapMode: Text.WordWrap
            text: qsTr("The private figure includes accounts you did not create — payments "
                     + "arrive at a derived address, not the one you shared. One send draws "
                     + "on one of them.")
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
