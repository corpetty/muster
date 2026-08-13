import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The way out of a context, and what is waiting outside it.
//
// Showing one thing at a time costs the user the glance that used to tell them
// something else needed them: the home list was always on screen, and now it is
// not. So the way back carries the count. A back button that says "2 waiting"
// is the whole of what the hidden list was doing, in the one place someone
// looks when they are done here.
//
// The count excludes where you are. "1 waiting" while you are looking at the
// one thing waiting would be the interface arguing with itself.
Item {
    id: root

    // Where back goes, named — "Home", "Wallet". Not an arrow alone: the user
    // arrived here from somewhere specific and should be told where they land.
    required property string label
    // Where you are now. Empty for a destination that names itself.
    property string title: ""
    // Conversations waiting on the user, other than this one.
    property int waitingCount: 0

    signal backRequested

    implicitWidth: 400
    implicitHeight: 36

    RowLayout {
        anchors.fill: parent
        spacing: Theme.spacing.small

        LogosButton {
            objectName: "backButton"
            //: Button leaving the current context, naming where it goes back to
            text: root.waitingCount > 0
                ? qsTr("← %1 · %2 waiting").arg(root.label).arg(root.waitingCount)
                : qsTr("← %1").arg(root.label)
            variant: LogosButton.Variant.Secondary
            radius: Theme.spacing.radiusLarge
            font.pixelSize: Theme.typography.secondaryText
            onClicked: root.backRequested()
            Layout.preferredHeight: 30
        }

        LogosText {
            objectName: "backBarTitle"
            visible: root.title !== ""
            text: root.title
            textFormat: Text.PlainText
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
        }

        Item {
            visible: root.title === ""
            Layout.fillWidth: true
        }
    }
}
