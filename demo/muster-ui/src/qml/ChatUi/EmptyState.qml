import QtQuick

import Logos.Theme
import Logos.Controls

// Centered placeholder shown when a list is empty. Bind `visible` to the list's
// count and set `text`. Standalone.
LogosText {
    id: root

    text: ""
    textFormat: Text.PlainText
    color: Theme.palette.textTertiary
    font.pixelSize: Theme.typography.secondaryText
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
}
