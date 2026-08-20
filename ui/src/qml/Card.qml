import QtQuick

// Themed surface panel (prototype `.acct-card` / row surface). A pre-styled
// frame; place content inside and size it via Layout or anchors.
Rectangle {
    color: Theme.palette.surface
    border.color: Theme.palette.border
    border.width: 1
    radius: Theme.radius.medium
}
