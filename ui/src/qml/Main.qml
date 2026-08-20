import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// P4 loading spike: prove the QML -> C++ backend -> muster_module (logos API)
// seam. Themed via the interim Muster tokens (ADR-011, Theme.qml) seeded from the
// prototype v2 legend; migrates to `import Logos.Theme` when the design system is
// on the host's QML path (see Theme.qml).
Item {
    id: root

    // Interim design tokens (ADR-011). Swap for `import Logos.Theme` later; the
    // `theme.palette.*` / `theme.spacing.*` call sites are shaped to match.
    Theme { id: theme }

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

    // Paper background — the prototype's --paper, so the light palette reads.
    Rectangle {
        anchors.fill: parent
        color: theme.palette.background
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: theme.spacing.large
        width: Math.min(parent.width - 2 * theme.spacing.xlarge, 420)

        Text {
            text: "Muster — module health"
            font.pixelSize: theme.typography.titleSize
            color: theme.palette.text
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: root.ready ? "Connected to backend" : "Connecting to backend…"
            font.pixelSize: theme.typography.bodySize
            color: root.ready ? theme.palette.settled : theme.palette.textMuted
            Layout.alignment: Qt.AlignHCenter
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 64
            radius: theme.radius.medium
            color: theme.palette.surface
            border.color: theme.palette.border
            Text {
                anchors.centerIn: parent
                text: "muster_module.health() → " + root.health
                font.pixelSize: theme.typography.monoSize
                font.family: theme.typography.mono
                color: root.health === "ok" ? theme.palette.settled : theme.palette.text
            }
        }

        Button {
            text: "Re-check health"
            enabled: root.ready
            Layout.alignment: Qt.AlignHCenter
            onClicked: if (root.backend) root.backend.checkHealth()

            contentItem: Text {
                text: parent.text
                font.pixelSize: theme.typography.bodySize
                color: parent.enabled ? theme.palette.accentText : theme.palette.textMuted
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                radius: theme.radius.small
                color: parent.enabled ? theme.palette.accent : theme.palette.accentSoft
                implicitHeight: 40
                implicitWidth: 160
            }
        }
    }
}
