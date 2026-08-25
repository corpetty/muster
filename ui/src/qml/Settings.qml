import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The settings surface — the start of the config shell (vision § "The end state",
// layer 1). It shows this module's identity and the *user-configurable* infra it
// points at: the RPC endpoint the wallet/Safe path reads against, and the delivery
// createNode config the next room join boots with. Invariant 8 says the store nodes
// and RPC are untrusted, user-chosen infrastructure — which is empty if the user
// can't configure it, so here it is configurable. In-memory today; the real home is
// inside basecamp, reading identity/wallet/settings from the platform (the shell we
// don't rebuild). Full identity/wallet/plugin *management* is that platform's job.
//
// PURE-RENDER: reads settingsJson from the backend, and the only things that leave
// are setSetting(key, value) calls. It holds no state of its own.
//
// NB (ADR-011): nix build does not evaluate QML; a bad type here blanks the view.
// Restricted to Theme keys + the Logos.Controls types Main.qml already proves.
Item {
    id: settings

    property var backend

    readonly property var s: {
        try { return JSON.parse(backend ? backend.settingsJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var identity: (settings.s && settings.s.identity) ? settings.s.identity : ({})

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: col
            y: Theme.spacing.xlarge
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("Settings")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }

            // ── identity ──────────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: idCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: idCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    LogosText {
                        text: qsTr("IDENTITY")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    Repeater {
                        model: [
                            { k: qsTr("address"), v: String((settings.identity && settings.identity.address) || "") },
                            { k: qsTr("ed25519"), v: String((settings.identity && settings.identity.ed25519) || "") },
                            { k: qsTr("x25519"),  v: String((settings.identity && settings.identity.x25519) || "") }
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small

                            LogosText {
                                Layout.preferredWidth: 70
                                Layout.alignment: Qt.AlignTop
                                text: modelData.k
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WrapAnywhere
                                text: modelData.v.length > 0 ? modelData.v : qsTr("(not loaded)")
                                color: Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }

                    LogosText {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        wrapMode: Text.WordWrap
                        text: qsTr("Your keys stay in the module's keystore — the client never hands them out. "
                                 + "Backup, import, and Keycard are the platform's to provide (basecamp).")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }

            // ── infrastructure (invariant 8) ──────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: infraCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: infraCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.small

                    LogosText {
                        text: qsTr("INFRASTRUCTURE")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Store nodes and RPC are untrusted infrastructure you choose (invariant 8). "
                                 + "Point them at your own node.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // ── RPC endpoint ──
                    LogosText {
                        text: qsTr("RPC endpoint  ·  now: %1")
                              .arg(String((settings.s && settings.s.rpc) || "(unset)"))
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: rpcField
                            objectName: "settingsRpc"
                            Layout.fillWidth: true
                            placeholderText: qsTr("new RPC URL, e.g. http://127.0.0.1:8545")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsRpcSave"
                            text: qsTr("Save")
                            enabled: rpcField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("rpc", rpcField.text);
                                rpcField.text = "";
                            }
                        }
                    }

                    // ── delivery config ──
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("Delivery node config  ·  now: %1")
                              .arg(String((settings.s && settings.s.delivery) || "{}"))
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: deliveryField
                            objectName: "settingsDelivery"
                            Layout.fillWidth: true
                            placeholderText: qsTr("createNode config JSON, e.g. {}")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsDeliverySave"
                            text: qsTr("Save")
                            enabled: deliveryField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("delivery", deliveryField.text);
                                deliveryField.text = "";
                            }
                        }
                    }

                    LogosText {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        wrapMode: Text.WordWrap
                        text: qsTr("RPC applies to the wallet/Safe path on next use; delivery config applies to "
                                 + "the next room you join. In-memory today — the real home persists these in basecamp.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }
        }
    }
}
