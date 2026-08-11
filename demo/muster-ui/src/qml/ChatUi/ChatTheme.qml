pragma Singleton

import QtQuick

import Logos.Theme

// Chat-local design tokens layered on Logos.Theme: only what the design system
// does not provide yet.
QtObject {
    id: root

    // ── semantic accents ─────────────────────────────────────────────────
    // Named by meaning rather than hue, so the components below say what they
    // mean and the palette can move without touching them.
    //
    // These point at the platform's own accents. A Muster-violet variant was
    // tried against the prototype tokens and looked worse than the salmon it
    // replaced, so the platform accent stays — and being platform-native is
    // arguably the more honest look for an app whose whole argument is that it
    // is composed from Logos modules.
    readonly property color signal: Theme.palette.primary       // live, ours, in-room
    readonly property color signalSoft: Theme.palette.primaryHover
    readonly property color settled: Theme.palette.success      // done, confirmed
    readonly property color alarm: Theme.palette.error          // blocked, failed

    // The prototype's dark pair, kept for the one place it belongs: the "what
    // the outside sees" view, where the ground changes on purpose. This is the
    // only surface in the app that leaves the in-room ground, and that is the
    // point of it.
    readonly property color outside: "#23282A"
    readonly property color outsideInk: "#DCE2DE"
    readonly property color outsideRule: "#3A4144"
    readonly property color outsideAccent: "#8FA3F5"

    // Message-bubble pair. Peer bubbles reuse the recessed surface; own bubbles
    // carry the signal accent. That accent is light, so its foreground is dark
    // (6.8:1 on the salmon); anything drawn on `signal` needs the same.
    // TODO(upstream: logos-design-system): bubble roles + an on-primary text token.
    readonly property color bubblePeer: Theme.palette.surfaceRecessed
    readonly property color bubblePeerText: Theme.palette.text
    readonly property color bubbleOwn: root.signal
    readonly property color bubbleOwnText: "#000000"

    // Selection highlight for message text, inverted per side so the marked run
    // stays legible on either bubble background.
    // TODO(upstream: logos-design-system): selection roles.
    readonly property color bubblePeerSelection: root.signal
    readonly property color bubblePeerSelectedText: "#000000"
    readonly property color bubbleOwnSelection: "#000000"
    readonly property color bubbleOwnSelectedText: root.signal

    // Avatar gradients, indexed by a model's avatarRamp role. There are exactly
    // as many as Identity::kAvatarRampCount in the backend, which is what
    // spreads identities across them.
    readonly property list<Gradient> avatarRamps: [
        Gradient {
            GradientStop {
                position: 0
                color: Theme.palette.accentYellowSoft
            }
            GradientStop {
                position: 1
                color: Theme.palette.accentOrangeMid
            }
        },
        Gradient {
            GradientStop {
                position: 0
                color: Theme.palette.info
            }
            GradientStop {
                position: 1
                color: Theme.palette.accentOrangeDeep
            }
        },
        Gradient {
            GradientStop {
                position: 0
                color: Theme.palette.successHover
            }
            GradientStop {
                position: 1
                color: Theme.palette.info
            }
        },
        Gradient {
            GradientStop {
                position: 0
                color: Theme.palette.warning
            }
            GradientStop {
                position: 1
                color: Theme.palette.accentBurntOrange
            }
        },
        Gradient {
            GradientStop {
                position: 0
                color: Theme.palette.primarySoft
            }
            GradientStop {
                position: 1
                color: Theme.palette.warning
            }
        }
    ]

    // This account's own avatar, on the brand ramp rather than a hashed one, so
    // your own entry is recognisable in any list.
    readonly property Gradient selfAvatarRamp: Gradient {
        GradientStop {
            position: 0
            color: root.signalSoft
        }
        GradientStop {
            position: 1
            color: root.signal
        }
    }

    // Ink for what sits on an avatar's light gradient, where the theme's text
    // colours have no contrast.
    // TODO(upstream: logos-design-system): an on-accent text token.
    readonly property color avatarInk: Qt.rgba(0, 0, 0, 0.74)
}
