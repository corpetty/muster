pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The wallet, opened out: every place money can be, what is there, where a peer
// would pay it, and every way it can leave — each way saying what it puts on
// the public record.
//
// This is the destination the sidebar card is a summary of. The card answers
// "what have I got"; a conversation needs no more than that. This answers "what
// happens if I move it", which is a question you go somewhere to ask.
//
// It is the same two catalogues the rest of the app reads, drawn in full rather
// than filtered to a decision in hand: a rail appears here beneath the holding
// it spends whether or not anything on screen could be paid with it. Adding a
// holding or a rail in ChatBackendAssets.cpp fills this page without it being
// touched — if an addition needed an edit here, the entry is not carrying
// enough.
Rectangle {
    id: root

    required property bool ready
    required property bool busy
    required property string stage
    required property string statusLabel
    // The two catalogues. See ChatBackend.rep.
    required property var assets
    required property var rails
    property bool receivedElsewhere: false
    property string errorText: ""

    signal openRequested
    signal fundRequested
    signal refreshRequested
    signal claimRequested(string assetId)

    // Every rail that spends this holding, in the catalogue's order — most
    // private first, same as everywhere else it is offered.
    function railsFrom(assetId) {
        return root.rails.filter(r => String(r.source) === String(assetId));
    }

    implicitWidth: 640
    implicitHeight: 600
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.background
    border.width: 1
    border.color: Theme.palette.borderSubtle
    clip: true

    ClipboardProxy {
        id: clipboard
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        spacing: Theme.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                LogosText {
                    text: qsTr("Wallet")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }

                LogosText {
                    objectName: "walletPaneStatus"
                    text: root.busy && root.stage !== "" ? root.stage : root.statusLabel
                    color: root.ready ? ChatTheme.settled : Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.secondaryText
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            LogosButton {
                objectName: "walletPaneOpen"
                visible: !root.ready
                text: qsTr("Open wallet")
                enabled: !root.busy
                onClicked: root.openRequested()
            }

            LogosButton {
                objectName: "walletPaneFund"
                visible: root.ready
                text: qsTr("Fund")
                enabled: !root.busy
                onClicked: root.fundRequested()
            }

            LogosButton {
                objectName: "walletPaneRefresh"
                visible: root.ready
                text: qsTr("Refresh")
                enabled: !root.busy
                onClicked: root.refreshRequested()
            }
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

        LogosScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                width: root.width - 2 * Theme.spacing.large
                spacing: Theme.spacing.medium

                Repeater {
                    model: root.ready ? root.assets : []

                    delegate: Rectangle {
                        id: holding
                        required property var modelData

                        readonly property var outbound: root.railsFrom(holding.modelData.id)

                        Layout.fillWidth: true
                        implicitHeight: body.implicitHeight + 2 * Theme.spacing.medium
                        radius: Theme.spacing.radiusMedium
                        color: Theme.palette.surface
                        border.width: 1
                        border.color: Theme.palette.borderSubtle

                        ColumnLayout {
                            id: body
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.medium
                            spacing: Theme.spacing.small

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small

                                LogosText {
                                    objectName: "paneAssetName_" + holding.modelData.id
                                    text: holding.modelData.name
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.primaryText
                                    font.weight: Theme.typography.weightMedium
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                LogosText {
                                    objectName: "paneAssetBalance_" + holding.modelData.id
                                    text: qsTr("%1 %2")
                                        .arg(holding.modelData.balance === ""
                                             ? "—" : holding.modelData.balance)
                                        .arg(holding.modelData.denom)
                                    color: holding.modelData.empty
                                        ? Theme.palette.textTertiary : Theme.palette.text
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.primaryText
                                }
                            }

                            LogosText {
                                Layout.fillWidth: true
                                text: holding.modelData.sourceNote
                                color: Theme.palette.textTertiary
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.typography.secondaryText
                            }

                            LogosText {
                                objectName: "paneAssetBlocked_" + holding.modelData.id
                                Layout.fillWidth: true
                                visible: holding.modelData.blocked
                                text: holding.modelData.blockedNote
                                color: ChatTheme.alarm
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.typography.secondaryText
                            }

                            // Where a peer would pay it. On the summary card this
                            // is behind the share dialog, because sharing is a
                            // choice with consequences; here it is a fact about
                            // the holding, shown because this is the page for
                            // facts about holdings.
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.spacing.tiny
                                visible: String(holding.modelData.address) !== ""
                                spacing: 2

                                LogosText {
                                    text: qsTr("PEERS PAY IT AT")
                                    color: Theme.palette.textTertiary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                    font.weight: Theme.typography.weightMedium
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 28
                                    radius: Theme.spacing.radiusMedium
                                    color: Theme.palette.backgroundMuted
                                    border.width: 1
                                    border.color: Theme.palette.borderSubtle

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacing.small
                                        anchors.rightMargin: Theme.spacing.tiny
                                        spacing: Theme.spacing.tiny

                                        LogosText {
                                            objectName: "paneAssetAddress_" + holding.modelData.id
                                            text: holding.modelData.address
                                            textFormat: Text.PlainText
                                            color: Theme.palette.textTertiary
                                            font.family: Theme.typography.mono
                                            font.pixelSize: Theme.typography.secondaryText
                                            elide: Text.ElideMiddle
                                            Layout.fillWidth: true
                                        }

                                        ChatIconButton {
                                            objectName: "paneCopyAddress_" + holding.modelData.id
                                            size: 24
                                            iconSize: 12
                                            iconSource: Qt.resolvedUrl("icons/copy.png")
                                            Accessible.role: Accessible.Button
                                            Accessible.name: qsTr("Copy this address")
                                            onClicked: clipboard.copy(String(holding.modelData.address))
                                            Layout.alignment: Qt.AlignVCenter
                                        }
                                    }
                                }
                            }

                            LogosButton {
                                objectName: "paneAssetClaim_" + holding.modelData.id
                                visible: holding.modelData.canClaim
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.spacing.tiny
                                text: holding.modelData.claimVerb
                                enabled: !root.busy
                                onClicked: root.claimRequested(String(holding.modelData.id))
                            }

                            // Every way this holding can leave, and what each
                            // way tells everyone. The point of the page: money
                            // sitting still discloses nothing, and choosing how
                            // to move it is choosing what to disclose.
                            LogosText {
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.spacing.tiny
                                text: qsTr("WAYS OUT OF IT")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }

                            LogosText {
                                objectName: "paneNoRails_" + holding.modelData.id
                                Layout.fillWidth: true
                                visible: holding.outbound.length === 0
                                wrapMode: Text.WordWrap
                                text: qsTr("Nothing this build can spend it on. It can be held and "
                                         + "received, not sent.")
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                            }

                            Repeater {
                                model: holding.outbound

                                delegate: ColumnLayout {
                                    id: rail
                                    required property var modelData

                                    Layout.fillWidth: true
                                    Layout.topMargin: Theme.spacing.tiny
                                    spacing: 2

                                    LogosText {
                                        objectName: "paneRailName_" + rail.modelData.id
                                        Layout.fillWidth: true
                                        text: rail.modelData.name
                                        color: Theme.palette.text
                                        font.pixelSize: Theme.typography.secondaryText
                                        font.weight: Theme.typography.weightMedium
                                        elide: Text.ElideRight
                                    }

                                    LogosText {
                                        Layout.fillWidth: true
                                        text: rail.modelData.promise
                                        color: Theme.palette.textTertiary
                                        wrapMode: Text.WordWrap
                                        font.pixelSize: Theme.typography.badgeText
                                    }

                                    DisclosureChips {
                                        Layout.fillWidth: true
                                        Layout.topMargin: 2
                                        discloses: rail.modelData.discloses
                                    }
                                }
                            }
                        }
                    }
                }

                // Said here as well as on the card, because this is where
                // someone comes to reconcile a figure they did not expect. Not
                // a workaround note: a shielded payment always lands at a fresh
                // account the sender numbered, so scanning is how the balance is
                // read and there is nothing here to wait out.
                LogosText {
                    objectName: "paneBalanceScanNote"
                    Layout.fillWidth: true
                    visible: root.ready && root.receivedElsewhere
                    wrapMode: Text.WordWrap
                    text: qsTr("The private figure includes accounts you did not create — payments "
                             + "arrive at a derived address, not the one you shared. One send draws "
                             + "on one of them.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }

                LogosText {
                    objectName: "walletPaneClosed"
                    Layout.fillWidth: true
                    visible: !root.ready
                    wrapMode: Text.WordWrap
                    text: qsTr("No wallet is open, so there is nothing to show. Opening one creates "
                             + "it if this instance has none.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }
            }
        }
    }
}
