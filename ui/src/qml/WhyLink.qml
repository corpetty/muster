import QtQuick
import Logos.Theme
import Logos.Controls

// "Why?" — one word after a line that would otherwise need a paragraph (exo-355a). It opens
// Learn at `step`, a ClaimsRegistry step id (open-room, propose, collect, executable,
// submit, settle), where the reasons are, with what each one protects and what is still open.
LogosText {
    textFormat: Text.PlainText
    id: why
    property string step: ""
    signal clicked()

    text: qsTr("Why?")
    color: hover.hovered ? Theme.palette.text : Theme.palette.primary
    font.pixelSize: MusterStyle.caption
    font.underline: hover.hovered
    onClicked: MusterStyle.learn(why.step)

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: why.clicked() }
}
