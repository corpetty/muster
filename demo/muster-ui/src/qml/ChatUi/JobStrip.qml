import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A long-running job, named and timed, while the rest of the app stays usable.
//
// A private payment spends minutes producing a zero-knowledge proof — measured
// at 6m41s on a desktop for a single transfer. That is not a button you wait
// on, it is a job you started, and hiding it behind a spinner would misrepresent
// what the feature costs. So it gets a strip that names the job, names the
// stage inside it, and counts the seconds out loud.
//
// The count is the honest part. Privacy here is not free and not instant, and
// the interface should be the first place that says so rather than the last.
Rectangle {
    id: root

    // Empty when nothing is running; the strip hides itself.
    required property string job
    // Which part of the job is happening now — "syncing", "mining", "sending".
    required property string stage

    visible: root.job !== ""
    implicitHeight: visible ? layout.implicitHeight + 2 * Theme.spacing.small : 0
    radius: Theme.spacing.radiusMedium
    color: Theme.palette.surfaceRecessed
    border.width: 1
    border.color: Theme.palette.borderSubtle

    // Seconds since the job was named. Reset by the job changing, so a second
    // job does not inherit the first one's clock.
    property int elapsed: 0

    onJobChanged: root.elapsed = 0

    Timer {
        running: root.job !== ""
        interval: 1000
        repeat: true
        onTriggered: root.elapsed += 1
    }

    function clock(total) {
        const m = Math.floor(total / 60);
        const s = total % 60;
        return m > 0 ? qsTr("%1m %2s").arg(m).arg(s) : qsTr("%1s").arg(s);
    }

    RowLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Theme.spacing.small
        spacing: Theme.spacing.small

        // A quiet pulse rather than a spinner: this runs for minutes, and a
        // spinner at that duration reads as a hang.
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 6
            Layout.preferredHeight: 6
            radius: 3
            color: ChatTheme.signal

            SequentialAnimation on opacity {
                running: root.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            LogosText {
                Layout.fillWidth: true
                text: root.job
                color: Theme.palette.text
                elide: Text.ElideRight
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
            }

            LogosText {
                Layout.fillWidth: true
                text: root.stage !== "" ? root.stage : qsTr("working")
                color: Theme.palette.textTertiary
                elide: Text.ElideRight
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }

        LogosText {
            text: root.clock(root.elapsed)
            color: Theme.palette.textSecondary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
