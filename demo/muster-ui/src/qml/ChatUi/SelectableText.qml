import QtQuick

import Logos.Theme

// Read-only, mouse-selectable text carrying LogosText's typography defaults. A
// bare TextEdit rather than LogosTextArea, whose background and paddings read as
// an input field. Standalone.
// TODO(upstream: logos-design-system): a selectable text label.
TextEdit {
    id: root

    readOnly: true
    selectByMouse: true
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    font.family: Theme.typography.publicSans
    font.pixelSize: Theme.typography.primaryText
    font.weight: Theme.typography.weightRegular
    color: Theme.palette.text
}
