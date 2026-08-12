pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Which address to hand over.
//
// There is more than one answer now, and the choice belongs to whoever is being
// paid: sharing a public account invites a payment anyone can read, and that is
// their call to make before the payer ever sees a rail. So the payee picks the
// asset and the payer picks the rail, and neither decides for the other.
//
// Rows come from the backend's `assets`, filtered to the ones with an address.
// A holding added to the catalogue with a receive address appears here on its
// own; one without simply does not, which is why there is no list of what can
// be shared anywhere in this file.
LogosDialog {
    id: root

    // The holdings worth being paid at: `assets` where canReceive.
    property var assets: []

    signal confirmed(string assetId)

    title: qsTr("Share an address")
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    anchors.centerIn: Overlay.overlay
    width: Math.min(460, (Overlay.overlay ? Overlay.overlay.width : 460) - 2 * Theme.spacing.large)

    property string selected: ""

    readonly property var selectedAsset: {
        for (let i = 0; i < root.assets.length; ++i)
            if (root.assets[i].id === root.selected)
                return root.assets[i];
        return null;
    }

    leftActions: [
        LogosButton {
            implicitWidth: 96
            implicitHeight: 36
            text: qsTr("Cancel")
            onClicked: root.close()
        }
    ]
    rightActions: [
        LogosButton {
            objectName: "shareAddressConfirm"
            implicitWidth: 112
            implicitHeight: 36
            text: qsTr("Share it")
            enabled: root.selected !== "" && !!root.selectedAsset
                && !root.selectedAsset.blocked
            onClicked: {
                root.confirmed(root.selected);
                root.close();
            }
        }
    ]

    // Opens on the first one that can actually be shared — the catalogue orders
    // them most private first, so this is the safest usable choice. Falls back
    // to the first of any, so a wallet whose only address is still registering
    // opens showing that rather than nothing selected.
    onOpened: {
        let pick = "";
        for (let i = 0; i < root.assets.length; ++i) {
            if (!root.assets[i].blocked) {
                pick = String(root.assets[i].id);
                break;
            }
        }
        if (pick === "" && root.assets.length > 0)
            pick = String(root.assets[0].id);
        root.selected = pick;
    }

    contentItem: ColumnLayout {
        spacing: Theme.spacing.small

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("What you share decides what a payment to you can hide. A shielded "
                     + "address can be paid without naming you; a public account cannot.")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }

        Repeater {
            model: root.assets

            delegate: Rectangle {
                id: choice
                required property var modelData

                readonly property bool chosen: choice.modelData.id === root.selected

                Layout.fillWidth: true
                implicitHeight: body.implicitHeight + 2 * Theme.spacing.small
                radius: Theme.spacing.radiusSmall
                color: choice.chosen ? Theme.colors.getColor(ChatTheme.signal, 0.12) : "transparent"
                border.width: 1
                border.color: choice.chosen ? ChatTheme.signal : Theme.palette.borderSubtle

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.selected = String(choice.modelData.id)
                }

                ColumnLayout {
                    id: body
                    anchors.fill: parent
                    anchors.margins: Theme.spacing.small
                    spacing: 2

                    LogosText {
                        objectName: "shareAsset_" + choice.modelData.id
                        Layout.fillWidth: true
                        text: choice.modelData.name
                        color: Theme.palette.text
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: choice.chosen ? Theme.typography.weightMedium
                                                   : Theme.typography.weightRegular
                    }

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: choice.modelData.sourceNote
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // Shown and refused, rather than quietly missing. The
                    // reason is the useful part — a peer waiting on their
                    // private account's registration should see that it is
                    // coming, not conclude they have no private address.
                    LogosText {
                        objectName: "shareBlocked_" + choice.modelData.id
                        Layout.fillWidth: true
                        visible: choice.modelData.blocked
                        wrapMode: Text.WordWrap
                        text: choice.modelData.blockedNote
                        color: ChatTheme.alarm
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }
        }

        // Nothing to share is a state the wallet can genuinely be in — before
        // it opens, or when the zone would not give it an account — and it says
        // which rather than showing an empty dialog.
        LogosText {
            Layout.fillWidth: true
            visible: root.assets.length === 0
            wrapMode: Text.WordWrap
            text: qsTr("No addresses yet. Open the wallet first.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
