import QtQuick

// Muster's interim design tokens (ADR-011), seeded from the prototype v2 legend
// (ui/prototype/coordination-prototype-v2.html `:root`). Shaped like the
// platform's Logos.Theme singleton (palette / spacing / typography) so the
// eventual swap to `import Logos.Theme` is a call-site remap, not a rewrite.
//
// Why local, not `import Logos.Theme`: the platform design system is host-provided
// — basecamp resolves Logos.Theme exclusively from its own pinned copy and
// redirects a module's own copy away — and our current dev/CI host
// (logos-standalone-app) ships no design system at all. So until the design
// system is wired onto the standalone host's QML path (or we graduate to
// basecamp, itself blocked on the ui-host SDK skew), these are Muster's tokens.
// A plain component, not a `pragma Singleton`: the builder emits a bare `qmldir`
// (`module com.logos.module.muster_ui`) with no singleton registration, so a
// singleton would not survive packaging. Instantiate once (`Theme { id: theme }`).
QtObject {
    readonly property QtObject palette: QtObject {
        readonly property color background:  "#E4E6E0"  // --paper
        readonly property color surface:     "#F7F8F5"  // --surface
        readonly property color text:        "#1A1F1C"  // --ink
        readonly property color textMuted:   "#656E66"  // --muted
        readonly property color border:      "#C6CBC3"  // --rule
        readonly property color accent:      "#4B33C4"  // --signal (primary action)
        readonly property color accentSoft:  "#EAE6FA"  // --signal-soft
        readonly property color settled:     "#1E6B52"  // --settled (ok/success)
        readonly property color settledSoft: "#DFEDE6"  // --settled-soft
        readonly property color alarm:       "#A32D1E"  // --alarm (error)
        readonly property color alarmSoft:   "#F6E3DF"  // --alarm-soft
        readonly property color accentText:  "#FFFFFF"  // text on an accent fill
    }

    readonly property QtObject spacing: QtObject {
        readonly property int tiny:   4
        readonly property int small:  8
        readonly property int medium: 12
        readonly property int large:  16
        readonly property int xlarge: 24
    }

    readonly property QtObject radius: QtObject {
        readonly property int small:  7
        readonly property int medium: 12
        readonly property int large:  16
    }

    readonly property QtObject typography: QtObject {
        readonly property string mono: "monospace"
        readonly property int titleSize:  20
        readonly property int bodySize:   13
        readonly property int monoSize:   16
        readonly property int labelSize:  10
    }
}
