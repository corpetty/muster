import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The proposal a room is currently about, held above the thread.
//
// From U-3: the live proposal is pinned with its state and a one-tap way to
// reach the card. A room deciding something should say so before you have
// scrolled to find out, because the reason you opened it is usually that.
//
// It is deliberately not a second place to act. The one action it carries is
// "Show it" — the card in the thread is where a proposal is approved, paid or
// dropped, so there is one set of buttons for a decision and no chance of two
// surfaces disagreeing about what is possible.
Rectangle {
    id: root

    // The folded live intent, or an empty map when nothing is in flight.
    property var intent: null

    signal reviewRequested

    readonly property string state_: root.intent && root.intent.state
        ? String(root.intent.state) : ""
    readonly property bool active: !!root.intent && root.state_ !== ""
        && root.state_ !== "final" && root.state_ !== "dropped"

    visible: root.active
    implicitHeight: root.active ? row.implicitHeight + 2 * Theme.spacing.small : 0
    color: ChatTheme.signalSoft
    radius: Theme.spacing.radiusSmall

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.medium
        anchors.rightMargin: Theme.spacing.small
        anchors.topMargin: Theme.spacing.small
        anchors.bottomMargin: Theme.spacing.small
        spacing: Theme.spacing.small

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 5
            Layout.preferredHeight: 5
            radius: 2.5
            color: ChatTheme.signal
        }

        // What it wants, then the count. Ready-and-yours is the only state that
        // is an instruction; the rest are status.
        LogosText {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: {
                if (!root.intent)
                    return "";
                const n = Number(root.intent.approvals);
                const m = Number(root.intent.threshold);
                const count = qsTr("%1 of %2").arg(n).arg(m);
                if (root.state_ === "ready")
                    return root.intent.proposedByMe
                        ? qsTr("Ready to pay · %1").arg(count)
                        : qsTr("Ready · waiting on the proposer · %1").arg(count);
                if (!root.intent.approvedByMe)
                    return qsTr("Needs your approval · %1").arg(count);
                return qsTr("Waiting on approvals · %1").arg(count);
            }
            color: Theme.palette.text
            font.pixelSize: Theme.typography.secondaryText
            font.weight: Theme.typography.weightMedium
        }

        LogosButton {
            text: qsTr("Show it")
            onClicked: root.reviewRequested()
        }
    }
}
