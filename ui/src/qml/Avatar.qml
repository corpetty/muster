import QtQuick
import Logos.Theme
import Logos.Controls

// A member, as a face (exo-720.5). The colour comes from their id (MusterStyle.colorFor) and
// the letter from the name YOU gave them, else none: it shows nothing the member did not
// disclose (invariant 9). Room avatars pass `room: true` for a rounded square.
Rectangle {
    id: avatar

    property string identity: ""        // the member's id (hex), or a room's topic
    property string name: ""            // your alias for them, if any
    property int size: 28
    property bool room: false

    readonly property string letter: {
        var n = String(avatar.name || "").trim();
        // a short id standing in for a name ("34bd8a…") is not a name either
        if (n.length > 0 && n.indexOf("…") < 0 && !/^(0x)?[0-9a-f]{6,}$/i.test(n)) return n.charAt(0).toUpperCase();
        // unnamed: the colour alone (exo-d1a) — a hex digit reads as an initial they never had
        return "";
    }

    implicitWidth: size
    implicitHeight: size
    radius: room ? Theme.spacing.radiusLarge : size / 2
    color: room ? Theme.palette.surface : MusterStyle.colorFor(avatar.identity)
    Accessible.role: Accessible.Graphic
    Accessible.name: avatar.name.length > 0 ? avatar.name : avatar.identity

    LogosText {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: avatar.letter
        color: avatar.room ? Theme.palette.text : Theme.palette.background
        font.pixelSize: Math.round(avatar.size * 0.43)
        font.weight: Theme.typography.weightBold
    }
}
