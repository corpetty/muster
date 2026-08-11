pragma ComponentBehavior: Bound

import QtQuick

import Logos.Theme

// Ghost bubbles standing in for a thread that is still loading: bottom-aligned
// and alternating sides like the real thread, pulsing so they read as a wait
// rather than as content. Standalone; no data, no interaction.
// TODO(upstream: logos-design-system): a shared skeleton placeholder.
Item {
    id: root

    // Ghost row widths as a fraction of the pane; odd rows sit on the own side.
    readonly property var rowWidths: [0.55, 0.4, 0.62, 0.3]

    implicitWidth: 200
    implicitHeight: rows.implicitHeight + rows.anchors.bottomMargin

    Column {
        id: rows
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.spacing.large
        anchors.rightMargin: Theme.spacing.large
        anchors.bottomMargin: Theme.spacing.medium
        spacing: Theme.spacing.small

        Repeater {
            model: root.rowWidths.length

            Rectangle {
                id: ghost
                required property int index

                readonly property bool own: ghost.index % 2 === 1

                x: ghost.own ? rows.width - ghost.width : 0
                width: rows.width * root.rowWidths[ghost.index]
                height: 36
                radius: Theme.spacing.radiusLarge
                color: Theme.palette.surfaceRecessed
            }
        }
    }

    SequentialAnimation on opacity {
        running: root.visible
        loops: Animation.Infinite
        NumberAnimation {
            from: 0.5
            to: 1.0
            duration: 700
            easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            from: 1.0
            to: 0.5
            duration: 700
            easing.type: Easing.InOutQuad
        }
    }
}
