import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import Logos.Theme
import Logos.Controls

// Jump to a room by name (exo-720.12, U-10: keyboard operable). Ctrl+K anywhere, or the
// sidebar's "Jump to…". Type to filter, ↑ ↓ to move, Enter to open, Esc to close.
Popup {
    id: switcher
    required property var app            // Main.qml's root

    parent: Overlay.overlay
    // (parent is the overlay; null for a moment while the window is still being made)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round(parent.height * 0.12) : 0
    width: parent ? Math.min(520, parent.width - 32) : 520
    modal: true
    focus: true          // a Popup's content takes keyboard focus only when the Popup does
    padding: 0
    background: Surface { level: 2 }

    property int selected: 0
    readonly property var rooms: {
        var q = field.text.trim().toLowerCase();
        var out = [];
        var convs = switcher.app.conversations || [];
        for (var i = 0; i < convs.length; ++i) {
            var topic = String(convs[i].topic || "");
            var title = switcher.app.titleOf(topic) || switcher.app.shortRoom(topic);
            if (q.length === 0 || title.toLowerCase().indexOf(q) >= 0)
                out.push({ topic: topic, title: title,
                           needs: !!(convs[i].needs && convs[i].needs.length > 0) });
        }
        return out;
    }
    onRoomsChanged: selected = Math.min(selected, Math.max(0, rooms.length - 1))
    onOpened: { field.text = ""; selected = 0; field.textInput.forceActiveFocus(); }   // LogosTextField does not pass focus to its input

    function openSelected() {
        var r = switcher.rooms[switcher.selected];
        if (!r) return;
        switcher.close();
        switcher.app.enterRoom(r.topic);
    }

    contentItem: ColumnLayout {
        spacing: 0
        LogosTextField {
            id: field
            objectName: "roomSwitcherField"
            Layout.fillWidth: true
            Layout.margins: Theme.spacing.small
            placeholderText: qsTr("Jump to a room…")
            Keys.onDownPressed: switcher.selected = Math.min(switcher.selected + 1, switcher.rooms.length - 1)
            Keys.onUpPressed: switcher.selected = Math.max(switcher.selected - 1, 0)
            Keys.onReturnPressed: switcher.openSelected()
            Keys.onEnterPressed: switcher.openSelected()
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.spacing.small
            spacing: 2
            Repeater {
                model: switcher.rooms
                delegate: SidebarRow {
                    required property var modelData
                    required property int index
                    objectName: "roomSwitcherRow"
                    label: String(modelData.title)
                    avatarId: String(modelData.topic)
                    needs: !!modelData.needs
                    current: index === switcher.selected
                    onClicked: { switcher.selected = index; switcher.openSelected(); }
                }
            }
            LogosText {
                textFormat: Text.PlainText
                visible: switcher.rooms.length === 0
                Layout.margins: Theme.spacing.medium
                text: (switcher.app.conversations || []).length === 0 ? qsTr("No rooms yet.") : qsTr("No room by that name.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.body
            }
        }
    }
}
