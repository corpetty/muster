import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// P4 loading spike: prove the QML -> C++ backend -> muster_module (logos API)
// seam. Deliberately plain QtQuick — the Logos.Theme adoption (ADR-011) lands
// as the next step, once this seam is confirmed loading + answering.
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

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        width: Math.min(parent.width - 48, 420)

        Text {
            text: "Muster — module health"
            font.pixelSize: 20
            color: "#e8e8ea"
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: root.ready ? "Connected to backend" : "Connecting to backend…"
            font.pixelSize: 13
            color: root.ready ? "#57d38c" : "#c9a227"
            Layout.alignment: Qt.AlignHCenter
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 64
            radius: 10
            color: "#1b1c1f"
            border.color: "#33343a"
            Text {
                anchors.centerIn: parent
                text: "muster_module.health() → " + root.health
                font.pixelSize: 16
                font.family: "monospace"
                color: root.health === "ok" ? "#57d38c" : "#e8e8ea"
            }
        }

        Button {
            text: "Re-check health"
            enabled: root.ready
            Layout.alignment: Qt.AlignHCenter
            onClicked: if (root.backend) root.backend.checkHealth()
        }
    }
}
