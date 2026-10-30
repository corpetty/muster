import QtQuick
import Logos.Controls

// A button that puts `value` on the clipboard and says so for a moment: an address, a link,
// an amount — anything a person has to carry to another app by hand. Copies `value` whole,
// however the view shortened it.
ActionButton {
    id: btn
    property string value: ""
    property string label: qsTr("Copy")
    property bool copied: false
    visible: value.length > 0
    text: copied ? qsTr("✓ Copied") : label
    variant: LogosButton.Variant.Secondary
    onClicked: {
        clip.text = btn.value;
        clip.selectAll();
        clip.copy();
        copied = true;
        reset.restart();
    }
    TextEdit { id: clip; visible: false; width: 0; height: 0 }
    Timer { id: reset; interval: 1500; onTriggered: btn.copied = false }
}
