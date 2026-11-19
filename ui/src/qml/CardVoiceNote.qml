import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A voice note in the thread (docs/design/voice-notes.md §7): one member's words in another
// medium. It is drawn ONLY from a thread row's `voice` field, which only the module's fold of
// the note's two signed parts sets, never a message body; so the name on it is the author
// that fold verified. Pure render: the note comes in through `voice`, where it stands through
// `playing` and `positionMs`; Play and Stop leave as signals, and the thread that hosts it
// makes the module calls. No audio reaches this view: the module decodes and plays the note
// itself, and only a complete note plays.
Item {
    id: card

    // the row's `voice` field: {v, note, durationMs, state: complete | arriving | broken}
    property var voice: ({})
    property string rowId: ""              // the row's id: names this card's parts
    property string authorName: ""
    property var ts: 0
    property bool playing: false           // this is the note the module is playing
    property bool starting: false          // …and its speaker has not started yet (§9)
    property int positionMs: 0
    property bool canPlay: true            // false while something else records or plays
    signal playVoice(string note)
    signal stopVoice()

    readonly property string note: String((card.voice && card.voice.note) || "")
    readonly property string noteState: String((card.voice && card.voice.state) || "")
    readonly property int durationMs: Math.max(0, Number((card.voice && card.voice.durationMs) || 0))
    readonly property bool complete: card.noteState === "complete"
    readonly property real progress: card.playing && card.durationMs > 0
                                     ? Math.min(1, Math.max(0, card.positionMs / card.durationMs)) : 0
    // m:ss, as a player says it
    function mss(ms) {
        var s = Math.floor(Math.max(0, Number(ms) || 0) / 1000);
        return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60);
    }

    objectName: "voiceNoteCard_" + card.rowId
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 2

        // who and when, as a chat line says it
        RowLayout {
            Layout.topMargin: Theme.spacing.small
            spacing: Theme.spacing.small
            LogosText {
                objectName: "voiceNoteAuthor_" + card.rowId
                text: card.authorName
                color: Theme.palette.text
                font.pixelSize: MusterStyle.caption
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                visible: !!card.ts
                text: MusterStyle.ago(card.ts)
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.caption
                HoverHandler { id: timeHover }
                LogosToolTip { visible: timeHover.hovered; text: MusterStyle.fullTime(card.ts) }
            }
        }

        Surface {
            Layout.preferredWidth: Math.min(360, col.width)
            implicitHeight: player.implicitHeight + 2 * Theme.spacing.small

            RowLayout {
                id: player
                anchors.fill: parent
                anchors.leftMargin: Theme.spacing.small
                anchors.rightMargin: Theme.spacing.medium
                spacing: Theme.spacing.small

                IconAction {
                    objectName: "voicePlay_" + card.rowId
                    label: card.playing ? qsTr("Stop") : qsTr("Play")
                    icon: MusterStyle.icon(card.playing ? "stop" : "play")
                    enabled: card.playing || (card.complete && card.canPlay)
                    opacity: enabled ? 1 : 0.4
                    onClicked: card.playing ? card.stopVoice() : card.playVoice(card.note)
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    LogosText {
                        text: qsTr("Voice note")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                    }
                    // how far it has played
                    Rectangle {
                        id: track
                        objectName: "voiceNoteProgress_" + card.rowId
                        readonly property real value: card.progress
                        Layout.fillWidth: true
                        implicitHeight: 4
                        radius: 2
                        color: Theme.palette.borderSubtle
                        Rectangle {
                            width: parent.width * track.value
                            height: parent.height
                            radius: 2
                            color: Theme.palette.primary
                        }
                    }
                }
                LogosText {
                    objectName: "voiceNoteTime_" + card.rowId
                    text: card.playing && card.starting ? qsTr("Starting…")
                        : card.playing ? qsTr("%1 / %2").arg(card.mss(card.positionMs)).arg(card.mss(card.durationMs))
                        : card.mss(card.durationMs)
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }
            }
        }

        // a note that cannot play says why, in its place
        LogosText {
            objectName: "voiceNoteState_" + card.rowId
            visible: !card.complete
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: card.noteState === "arriving"
                  ? qsTr("Still arriving: one of its two parts has reached you so far.")
                  : card.noteState === "broken"
                  ? qsTr("This voice note can't be played: it arrived damaged.")
                  : qsTr("This voice note can't be played here.")
            color: card.noteState === "broken" ? MusterStyle.warning : Theme.palette.textTertiary
            font.pixelSize: MusterStyle.caption
        }
    }
}
