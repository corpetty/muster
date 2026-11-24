import QtQuick

import Logos.Theme

// Text a person can select and copy: a transaction hash, a re-derived hash, a receipt's id.
// LogosText is a Text, and Qt never lets the mouse select a Text, so a hash shown with it
// cannot be copied (seen 2026-10-11, the settled transaction's hash). Read-only; select
// with the mouse, then Ctrl+C, or call copyAll().
TextEdit {
    textFormat: TextEdit.PlainText
    readOnly: true
    selectByMouse: true
    activeFocusOnPress: true
    wrapMode: Text.WrapAnywhere
    color: Theme.palette.textSecondary
    selectionColor: Theme.palette.primary
    selectedTextColor: Theme.palette.background
    font.family: MusterStyle.mono
    font.pixelSize: MusterStyle.caption
    Accessible.role: Accessible.StaticText
    Accessible.name: text

    function copyAll() { selectAll(); copy(); deselect(); }
}
