import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// P4 shell — ADR-011 resolved: the specified client is built on Logos.Theme /
// Logos.Controls from logos-design-system, so Muster looks like the rest of the
// platform and inherits U-10's contrast / reduced-motion obligations rather than
// re-proving them. The `ui_qml` host supplies these imports on the QML import
// path (same as demo/muster-ui), so no metadata.json dependency is needed for
// them — but that is a *launch-time* fact: a missing import fails invisibly to
// `nix build` and surfaces two layers away as "Failed to load UI plugin"
// (docs/labbook/qml-errors-are-invisible-to-nix-build.md). Run qmllint against
// the design-system import path AND launch before believing this renders.
//
// Behaviour here is still only the loading-spike smoke test — QML → this view →
// C++ backend → muster_module.health() through the logos API. The intent card
// (propose → the real re-materialization strip → approve → executable) lands on
// this same shell next; every token below is one the demo already exercises
// against the shipping design system.
Item {
    id: root

    // Typed replica of the backend: auto-synced PROPs + callable SLOTs.
    readonly property var backend: logos.module("muster_ui")
    property bool ready: false

    // "health" PROP from muster_ui.rep, pushed here by QtRO on every setHealth.
    readonly property string health: backend ? backend.health : "(no backend)"
    readonly property bool healthy: root.health === "ok"

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "muster_ui")
                root.ready = isReady && root.backend !== null;
        }
    }
    Component.onCompleted: {
        root.ready = root.backend !== null && logos.isViewModuleReady("muster_ui");
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.palette.background
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Theme.spacing.large
        width: Math.min(parent.width - 2 * Theme.spacing.xlarge, 440)

        LogosText {
            text: qsTr("Muster")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
            Layout.alignment: Qt.AlignHCenter
        }

        LogosText {
            text: qsTr("Coordinating multi-party transactions inside a conversation")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }

        // Connection state. Named by meaning, coloured by the platform's own
        // semantic tokens — success once the backend replica is wired, warning
        // while it is still coming up.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.spacing.small

            Rectangle {
                implicitWidth: 8
                implicitHeight: 8
                radius: 4
                color: root.ready ? Theme.palette.success : Theme.palette.warning
            }

            LogosText {
                text: root.ready ? qsTr("Connected to backend")
                                 : qsTr("Connecting to backend…")
                color: root.ready ? Theme.palette.success : Theme.palette.warning
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
            }
        }

        // The one machine fact this spike surfaces, in mono — the same "this is
        // data, not chatter" voice the intent card's hashes and domain lines
        // will use. This is where muster_module.health() lands.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: healthRow.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surfaceRecessed
            border.width: 1
            border.color: Theme.palette.borderDefault

            RowLayout {
                id: healthRow
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    text: "muster_module.health()"
                    color: Theme.palette.textSecondary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.secondaryText
                }

                Item { Layout.fillWidth: true }

                LogosText {
                    text: "→ " + root.health
                    color: root.healthy ? Theme.palette.success : Theme.palette.text
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                }
            }
        }

        LogosButton {
            objectName: "recheckHealth"
            text: qsTr("Re-check health")
            enabled: root.ready
            Layout.alignment: Qt.AlignHCenter
            onClicked: if (root.backend) root.backend.checkHealth()
        }
    }
}
