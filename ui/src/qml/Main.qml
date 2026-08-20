import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// P4 loading spike: prove the QML -> C++ backend -> muster_module (logos API)
// seam, composed from the interim Muster component set (Eyebrow / StateChip /
// Card / ListRow) over the Theme singleton (ADR-011). Migrates to
// `import Logos.Theme` + platform controls when the design system is on the
// host's QML path (see Theme.qml / exo-e9f).
Item {
    id: root

    // Typed replica of the backend: auto-synced PROPs + callable SLOTs.
    readonly property var backend: logos.module("muster_ui")
    property bool ready: false

    // "health" PROP from muster_ui.rep, pushed here by QtRO on every setHealth.
    readonly property string health: backend ? backend.health : "(no backend)"

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
        width: Math.min(parent.width - 2 * Theme.spacing.xlarge, 420)

        Eyebrow {
            text: "Module health"
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: "Muster"
            font.family: Theme.typography.sans
            font.pixelSize: Theme.typography.titleSize
            font.weight: Theme.typography.weightSemiBold
            color: Theme.palette.text
            Layout.alignment: Qt.AlignHCenter
        }

        StateChip {
            Layout.alignment: Qt.AlignHCenter
            text: root.ready ? "connected" : "connecting…"
            variant: root.ready ? "settled" : "wait"
        }

        Card {
            Layout.fillWidth: true
            implicitHeight: 64
            Text {
                anchors.centerIn: parent
                text: "muster_module.health() → " + root.health
                font.pixelSize: Theme.typography.monoSize
                font.family: Theme.typography.mono
                color: root.health === "ok" ? Theme.palette.settled : Theme.palette.text
            }
        }

        ListRow {
            Layout.fillWidth: true
            heading: "muster_module"
            subtitle: "core · logos API"
            trailing: root.health === "ok" ? "ok" : root.health
            live: root.ready
        }

        Button {
            text: "Re-check health"
            enabled: root.ready
            Layout.alignment: Qt.AlignHCenter
            onClicked: if (root.backend) root.backend.checkHealth()

            contentItem: Text {
                text: parent.text
                font.family: Theme.typography.sans
                font.pixelSize: Theme.typography.bodySize
                color: parent.enabled ? Theme.palette.accentText : Theme.palette.textMuted
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                radius: Theme.radius.small
                color: parent.enabled ? Theme.palette.accent : Theme.palette.accentSoft
                implicitHeight: 40
                implicitWidth: 160
            }
        }
    }
}
