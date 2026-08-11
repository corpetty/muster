import QtQuick

import Logos.Theme
import Logos.Controls

// An icon action on a chat surface: the design system's icon button carrying a
// flat, borderless treatment, so it reads as an affordance on a card or a row
// rather than as a button of its own. Set `lit` for a toggle whose panel is
// open. Standalone.
LogosIconButton {
    id: root

    // Whether what this button toggles is currently showing.
    property bool lit: false

    size: 32
    iconSize: 16
    iconColor: root.lit ? ChatTheme.signal : root.isActive ? Theme.palette.text : Theme.palette.textSecondary

    // The surface underneath already carries the card, so only hover and the
    // lit state are drawn; the control's own pill and border are bound away.
    Binding {
        target: root.backgroundItem
        property: "color"
        value: root.lit ? Theme.palette.surfaceRaised : root.isActive ? Theme.palette.glassStrong : Theme.palette.overlayLight
    }
    Binding {
        target: root.backgroundItem
        property: "border.color"
        value: root.lit ? Theme.palette.borderDark : "transparent"
    }
    Binding {
        target: root.backgroundItem
        property: "radius"
        value: Theme.spacing.radiusLarge
    }
}
