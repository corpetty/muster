import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// How many people can read what you are about to type, on screen the whole
// time you are typing it.
//
// From the prototype, and from U-1 in the FURPS: the boundary is drawn, not
// explained. A line that says "2 can read" is a different kind of statement
// from a settings page that would tell you the same thing if you went looking
// — it is present at the moment the question actually matters, which is while
// you are deciding what to say.
//
// It reads count-first on purpose. "End-to-end encrypted" is a property people
// have learned to skim past; "2 can read" is a number they can check against
// the room.
RowLayout {
    id: root

    // Committed members of the current conversation.
    required property int memberCount
    // Invited but not yet joined — they cannot read anything yet, and saying
    // so is the honest reading of a roster that has grown but not committed.
    property int pendingCount: 0
    // False when delivery is down: the line must not claim a live boundary
    // when nothing is being delivered.
    required property bool online

    spacing: Theme.spacing.tiny

    // The live dot: present tense for the claim beside it.
    Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: 5
        Layout.preferredHeight: 5
        radius: 2.5
        color: root.online ? ChatTheme.settled : Theme.palette.textTertiary
    }

    LogosText {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: {
            if (!root.online)
                return qsTr("not connected — nothing is being delivered");
            if (root.memberCount <= 0)
                return qsTr("end-to-end · nobody else yet");
            const base = qsTr("end-to-end · %n can read", "", root.memberCount);
            return root.pendingCount > 0
                ? qsTr("%1 · %n invited, cannot read yet", "", root.pendingCount).arg(base)
                : base;
        }
        color: Theme.palette.textTertiary
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.badgeText
    }
}
