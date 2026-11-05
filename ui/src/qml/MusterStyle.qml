pragma Singleton
import QtQuick
import Logos.Theme

// Muster's design tokens, on top of Logos.Theme (exo-720.5, docs/design/ui-modernization.md
// §4 U1). Logos.Theme stays the source of every colour and size it has; this adds only
// what it lacks, and names the scale the redesign uses, so a view says `caption`, never a
// pixel count. Reference build: ui/prototype/desktop-v3.html.
QtObject {
    id: style

    // ── news, said once (exo-773) ─────────────────────────────────────────
    // "Bob approved", "Bob joined": a short toast Main shows and lets go. For what other
    // people did; what I did is on the card already.
    signal notified(string text)
    function notify(t) { if (String(t || "").length > 0) style.notified(String(t)); }

    // ── a voice call's refusal, in words (docs/design/voice-notes.md §8) ──────
    // What the module's word means, for the room's voice banner (RoomVoiceNote) and for the
    // microphone strip above every page (Main), so both say one thing. `op` is the call:
    // record, stop, send, discard, play or stopPlay.
    function voiceRefusalWords(e, op) {
        var play = op === "play" || op === "stopPlay";
        if (e === "not-joined") return qsTr("Join the room first.");
        if (e === "busy") return qsTr("Something is already recording or playing. Stop it first.");
        // Play decodes, Start encodes: the module says codec for either
        if (e === "codec")
            return play ? qsTr("The voice decoder could not start on this device.") : qsTr("The voice encoder could not start on this device.");
        if (e === "no-device")
            return play ? qsTr("No speaker was found on this device.") : qsTr("No microphone was found on this device.");
        if (e === "device-format")
            return play ? qsTr("The speaker would not play sound in the form voice notes use.")
                        : qsTr("The microphone would not record in the form voice notes use.");
        if (e === "device-start-slow")
            return play ? qsTr("The speaker took too long to start. Try again in a moment.")
                        : qsTr("The microphone took too long to start. If you were asked whether to allow it, answer that, then try again.");
        if (e === "not-started") return qsTr("Nothing was recorded: the microphone had not started yet.");
        if (e === "not-recording") return qsTr("Nothing is recording.");
        if (e === "no-draft") return qsTr("There is no recording to send or play.");
        if (e === "too-short") return qsTr("Too short to send: record at least half a second.");
        if (e === "silent") return qsTr("The recording is silent: no sound reached the microphone.");
        if (e === "room-changed") return qsTr("This recording belongs to another room. Send it from there, or discard it.");
        if (e === "too-large") return qsTr("It was too large to send. Discard it and record it again.");
        if (e === "unknown-note") return qsTr("That voice note is not in this room.");
        if (e === "incomplete") return qsTr("That voice note has not fully arrived yet.");
        // the module says broken for parts that disagree, a record that fails its checks, and
        // a clip the decoder refuses: words true of each
        if (e === "broken") return qsTr("That voice note can't be played: it arrived damaged.");
        // any other word is the device's or the encoder's: what failed, in words, and the
        // module's own word after it, for a report
        return play ? qsTr("The speaker did not work (%1).").arg(e)
             : op === "record" ? qsTr("The microphone did not work (%1).").arg(e)
             : qsTr("It did not work (%1).").arg(e);
    }

    // ── a contact link (exo-899) ──────────────────────────────────────────
    // "muster:contact/<chat id>?name=Alice": the chat id (128 hex, the 64-byte identity an
    // invite is sealed to) with the name its owner suggests. It names nothing else and is
    // read only by whoever it is given to. Anywhere a chat id is pasted, a link does too.
    function contactLink(id, name) {
        var h = String(id || "").replace(/^0x/i, "").toLowerCase();
        if (h.length === 0) return "";
        var n = String(name || "").trim();
        return "muster:contact/" + h + (n.length > 0 ? "?name=" + encodeURIComponent(n) : "");
    }
    // {id, name} from a link or a bare chat id (0x optional), else null
    function parseContact(text) {
        var t = String(text || "").trim();
        var m = /^muster:contact\/(?:0x)?([0-9a-fA-F]{128})(?:\?name=([^&\s]*))?$/.exec(t);
        if (m) {
            var n = "";
            try { n = decodeURIComponent(m[2] || ""); } catch (e) { n = ""; }
            return { id: m[1].toLowerCase(), name: n.trim() };
        }
        m = /^(?:0x)?([0-9a-fA-F]{128})$/.exec(t);
        return m ? { id: m[1].toLowerCase(), name: "" } : null;
    }

    // ── "Why?" (exo-355a) ─────────────────────────────────────────────────
    // A surface says one line and offers "Why?"; the reasons live in Learn, at the
    // lifecycle step the line is about (ClaimsRegistry's step ids). Any view calls
    // learn(step); Main opens Learn there.
    signal learnRequested(string step)
    function learn(step) { style.learnRequested(String(step || "")); }

    // ── time, in words (exo-52d) ──────────────────────────────────────────
    // A message, a room's last activity, a step on a card: "just now", "4 min ago",
    // "14:05", "Yesterday 14:05", "Mon 14:05", "3 Oct". Never a raw count of seconds. `now`
    // ticks every 30 s so a label ages on its own; the module's times are unix seconds
    // (milliseconds are taken as they are).
    property double now: Date.now()
    readonly property Timer clock: Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: style.now = Date.now()
    }
    function msOf(ts) { var n = Number(ts || 0); return n > 1e12 ? n : n * 1000; }
    function dayKey(ts) {
        var d = new Date(style.msOf(ts));
        return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
    }
    function clockTime(ts) { return new Date(style.msOf(ts)).toLocaleTimeString(Qt.locale(), Locale.ShortFormat); }
    function daysAgo(ts) {
        var a = new Date(style.msOf(ts)), b = new Date(style.now);
        a.setHours(0, 0, 0, 0); b.setHours(0, 0, 0, 0);
        return Math.round((b.getTime() - a.getTime()) / 86400000);
    }
    // a day, for a divider: Today · Yesterday · Monday · 3 October · 3 October 2025
    function dayLabel(ts) {
        var n = style.daysAgo(ts), d = new Date(style.msOf(ts));
        if (n <= 0) return qsTr("Today");
        if (n === 1) return qsTr("Yesterday");
        if (n < 7) return d.toLocaleDateString(Qt.locale(), "dddd");
        if (d.getFullYear() === new Date(style.now).getFullYear()) return d.toLocaleDateString(Qt.locale(), "d MMMM");
        return d.toLocaleDateString(Qt.locale(), "d MMMM yyyy");
    }
    // when, beside a message or a room: relative while fresh, then the clock and the day
    function ago(ts) {
        if (!ts) return "";
        var s = (style.now - style.msOf(ts)) / 1000;
        if (s < 45) return qsTr("just now");
        if (s < 3600) return qsTr("%1 min ago").arg(Math.max(1, Math.round(s / 60)));
        var n = style.daysAgo(ts);
        if (n <= 0) return style.clockTime(ts);
        if (n === 1) return qsTr("Yesterday %1").arg(style.clockTime(ts));
        if (n < 7) return new Date(style.msOf(ts)).toLocaleDateString(Qt.locale(), "ddd") + " " + style.clockTime(ts);
        return new Date(style.msOf(ts)).toLocaleDateString(Qt.locale(), "d MMM");
    }
    // the full date and time, for a tooltip
    function fullTime(ts) { return new Date(style.msOf(ts)).toLocaleString(Qt.locale(), Locale.LongFormat); }

    // ── type ──────────────────────────────────────────────────────────────
    // Monospace for what is data: hashes, addresses, the room code, amounts in base units.
    // Bundled (DM Mono, SIL OFL 1.1, fonts/OFL.txt) so it reads the same on every host;
    // Logos.Theme ships no mono face, and `MusterStyle.mono` never existed.
    readonly property FontLoader monoRegular: FontLoader { source: Qt.resolvedUrl("fonts/DMMono-Regular.ttf") }
    readonly property FontLoader monoMedium: FontLoader { source: Qt.resolvedUrl("fonts/DMMono-Medium.ttf") }
    readonly property string mono: monoRegular.status === FontLoader.Ready ? monoRegular.name : "monospace"

    // The scale. Theme.typography's sizes, plus one it lacks: `badge` for counts and pills.
    // Theme.typography.badgeText (8 px) is too small to read and is not used for text.
    readonly property int title: Theme.typography.panelTitleText    // 24: a page's title
    readonly property int subtitle: Theme.typography.subtitleText   // 16: a section, a room's name
    readonly property int body: Theme.typography.primaryText        // 14: what people read
    readonly property int caption: Theme.typography.secondaryText   // 12: what explains it
    readonly property int badge: 11                                 // counts and status pills
    // a card is read closely, so its text is a step up from the page's (exo-01f)
    readonly property int cardBody: body + 1                         // 15
    readonly property int cardCaption: caption + 1                   // 13

    // ── colour: the theme's, with the tints a status needs ────────────────
    function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color needs: Theme.palette.primary            // waits on you
    readonly property color needsSoft: tint(Theme.palette.primary, 0.16)
    readonly property color settled: Theme.colors.green400          // done; readable on dark
    readonly property color settledSoft: tint(Theme.colors.green400, 0.14)
    readonly property color refused: Theme.colors.red400            // blocked, refused
    readonly property color refusedSoft: tint(Theme.colors.red400, 0.14)
    readonly property color warning: Theme.palette.warning
    readonly property color warningSoft: tint(Theme.palette.warning, 0.10)
    readonly property color info: Theme.palette.info                // what left the room (U-2)
    readonly property color infoSoft: tint(Theme.palette.info, 0.16)
    readonly property color neutralSoft: tint(Theme.colors.white, 0.07)
    // A status's words on its own tint, at the pill's 11 px, must clear WCAG AA's 4.5:1
    // (U-10): the theme's orange there is 4.4:1 and its blue 3.8:1, so a pill's text is a
    // step lighter — 5.7:1 and 6.1:1 (exo-720.12).
    readonly property color needsText: Qt.lighter(Theme.palette.primary, 1.15)
    readonly property color infoText: Qt.lighter(Theme.palette.info, 1.3)

    // A notice draws its own glyph: the ⚠ / ⏳ the old one-line notices led with go.
    function plain(s) { return String(s || "").replace(/^(⚠|⏳|✓)\uFE0F?\s*/, ""); }

    // ── icons: icons/<name>.svg, stroke icons in the grey LogosIcon tints ─────
    // For what Logos.Icons lacks (more, close, copy, search, warning come from there).
    // An icon draws only where Qt Quick renders with GL (MultiEffect): an icon-only
    // control always carries a label or a tooltip (IconAction does).
    function icon(name) { return Qt.resolvedUrl("icons/" + name + ".svg"); }

    // ── a member's colour: from their id, so it says nothing they did not disclose
    // (invariant 9) and stays the same in every room and on every device ──────
    readonly property var avatarColors: [Theme.colors.orange300, Theme.colors.yellow400, Theme.colors.green400,
                                         Theme.colors.blue400, Theme.colors.cyan400, Theme.colors.red400,
                                         Theme.colors.peach100, Theme.colors.green700]
    // one person, one key: a member's id appears as 128 hex (the roster), "ed:" + its first
    // 64 (an approver) or with 0x; all of them read as the same person, so the same colour
    function personKey(id) {
        var s = String(id || "").toLowerCase().replace(/^0x/, "").replace(/^ed:/, "");
        return /^[0-9a-f]{64,}$/.test(s) ? s.slice(0, 64) : s;
    }
    function colorFor(id) {
        // FNV-1a, then a final avalanche, so ids that differ in one character spread out
        var s = style.personKey(id), h = 0x811c9dc5;
        for (var i = 0; i < s.length; ++i) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193);
        h ^= h >>> 16; h = Math.imul(h, 0x45d9f3b); h ^= h >>> 16;
        return avatarColors[(h >>> 0) % avatarColors.length];
    }
}
