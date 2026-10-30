import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The composer's voice note (docs/design/voice-notes.md §8), above the message row. The
// module records, holds the draft and sends it; nothing reaches this view but voice_status
// and each call's answer (Room.voice, Room.voiceResult). Four states:
//   starting   the same banner, "Starting the microphone…", with Stop and Discard: the module
//              answered at once and starts the device on a thread of its own, and nothing is
//              recorded until it runs (§8, §9);
//   recording  a banner whenever voice_status says so, whoever started it (§13): the time on a
//              clock of this view's own (the module's 60 s cap is the one that counts), the
//              level, Stop and Discard. It is part of the room's composer, so it shows only
//              while a room's view is on screen; on every page, this one included, Main's
//              strip says Muster is using the microphone while it starts or records;
//   draft      Play, Send and Discard, and who will see what, before anything is sent;
//   a notice   the module's refusal or note, in its own words where it has them.
ColumnLayout {
    id: vn
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    objectName: "voiceComposer"
    Layout.fillWidth: true
    // a layout in a layout fills its height by default, which would take the thread's space;
    // and with nothing to show it takes no row of the composer either
    Layout.fillHeight: false
    visible: vn.recState !== "idle" || (vn.noticeText.length > 0 && !voiceNotice.dismissed)
    spacing: Theme.spacing.small

    readonly property var rec: (vn.room.voice && vn.room.voice.recording) || ({})
    readonly property var ready: (vn.room.voice && vn.room.voice.ready) || ({})
    readonly property string recState: vn.room.voiceState
    readonly property bool starting: vn.recState === "starting"
    readonly property int capMs: Number(vn.rec.capMs || 60000)
    readonly property bool draftPlaying: !!vn.room.voicePlaying && String(vn.room.voicePlaying.note || "") === "draft"
    function mss(ms) {
        var s = Math.floor(Math.max(0, Number(ms) || 0) / 1000);
        return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60);
    }

    // the elapsed time, on this view's clock from the moment it saw the recording (less what
    // the module had captured by then), so it moves smoothly between polls
    property double startedAt: 0
    property double nowMs: 0
    function startClock() { vn.nowMs = Date.now(); vn.startedAt = vn.nowMs - Number(vn.rec.elapsedMs || 0); }
    onRecStateChanged: if (vn.recState === "recording") vn.startClock()
    Component.onCompleted: if (vn.recState === "recording") vn.startClock()
    Timer {
        interval: 200; repeat: true
        running: vn.recState === "recording"
        onTriggered: vn.nowMs = Date.now()
    }
    readonly property int elapsedMs: vn.recState === "recording"
                                     ? Math.min(vn.capMs, Math.max(0, vn.nowMs - vn.startedAt))
                                     : Number(vn.rec.elapsedMs || 0)

    // ── starting, then recording: the banner ─────────────────────────────
    Rectangle {
        objectName: "voiceRecording"
        visible: vn.recState === "recording" || vn.starting
        Layout.fillWidth: true
        implicitHeight: recRow.implicitHeight + 2 * Theme.spacing.medium
        radius: Theme.spacing.radiusLarge
        color: MusterStyle.refusedSoft
        border.width: 1
        border.color: MusterStyle.tint(MusterStyle.refused, 0.42)
        Accessible.role: Accessible.AlertMessage
        Accessible.name: vn.starting ? qsTr("Starting the microphone") : qsTr("Recording a voice note")

        RowLayout {
            id: recRow
            anchors.fill: parent
            anchors.margins: Theme.spacing.medium
            spacing: Theme.spacing.medium

            Rectangle {
                implicitWidth: 10; implicitHeight: 10; radius: 5
                // hollow while the microphone starts: nothing is recorded yet
                color: vn.starting ? "transparent" : MusterStyle.refused
                border.width: vn.starting ? 2 : 0
                border.color: MusterStyle.refused
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: Theme.spacing.small
                    LogosText {
                        objectName: "voiceRecordingTitle"
                        text: vn.starting ? qsTr("Starting the microphone…") : qsTr("Recording a voice note")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        objectName: "voiceRecordingTime"
                        visible: !vn.starting
                        text: qsTr("%1 of %2").arg(vn.mss(vn.elapsedMs)).arg(vn.mss(vn.capMs))
                        color: Theme.palette.textSecondary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                }
                LogosText {
                    objectName: "voiceRecordingLine"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: vn.starting
                          ? qsTr("Nothing is recorded until it starts. If you are asked whether to allow the microphone, answer that first.")
                          : vn.rec.silent
                          ? qsTr("The microphone is on, but no sound has reached it yet.")
                          : qsTr("The microphone is on. Nothing is sent until you press Send.")
                    color: vn.rec.silent && !vn.starting ? MusterStyle.warning : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                }
                // the level: the loudest sample since the last look, on a square-root scale
                // so speech moves it
                Rectangle {
                    objectName: "voiceLevel"
                    visible: !vn.starting
                    Layout.preferredWidth: 160
                    implicitHeight: 4
                    radius: 2
                    color: Theme.palette.borderSubtle
                    Rectangle {
                        width: parent.width * Math.min(1, Math.sqrt(Math.max(0, Number(vn.rec.peak || 0)) / 32767))
                        height: parent.height
                        radius: 2
                        color: MusterStyle.refused
                    }
                }
            }
            ActionButton {
                objectName: "voiceStopButton"
                text: qsTr("Stop")
                variant: LogosButton.Variant.Primary
                onClicked: vn.room.stopVoice()
            }
            ActionButton {
                objectName: "voiceRecordingDiscard"
                text: qsTr("Discard")
                quiet: true
                onClicked: vn.room.discardVoice()
            }
        }
    }

    // ── draft: heard, sent or dropped, and said who sees it first ────────
    Surface {
        objectName: "voiceDraft"
        visible: vn.recState === "draft"
        Layout.fillWidth: true
        implicitHeight: draftCol.implicitHeight + 2 * Theme.spacing.medium

        ColumnLayout {
            id: draftCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacing.medium
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                IconAction {
                    objectName: "voiceDraftPlay"
                    label: vn.draftPlaying ? qsTr("Stop") : qsTr("Play it back")
                    icon: MusterStyle.icon(vn.draftPlaying ? "stop" : "play")
                    // one stream at a time: while a note in the thread plays, the draft
                    // waits, as the thread's cards and the mic do (the module would say busy)
                    enabled: vn.draftPlaying || !vn.room.voicePlaying
                    opacity: enabled ? 1 : 0.4
                    onClicked: vn.draftPlaying ? vn.room.stopVoicePlay() : vn.room.playVoice("draft")
                }
                LogosText {
                    text: qsTr("Your voice note")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.body
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    objectName: "voiceDraftTime"
                    Layout.fillWidth: true
                    text: vn.draftPlaying && !!vn.room.voicePlaying.starting
                          ? qsTr("Starting the speaker…")
                          : vn.draftPlaying
                          ? qsTr("%1 / %2").arg(vn.mss(vn.room.voicePlaying.positionMs)).arg(vn.mss(vn.elapsedMs))
                          : vn.mss(vn.elapsedMs)
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }
                ActionButton {
                    objectName: "voiceSendButton"
                    text: qsTr("Send")
                    variant: LogosButton.Variant.Primary
                    onClicked: vn.room.sendVoice()
                }
                ActionButton {
                    objectName: "voiceDiscardButton"
                    text: qsTr("Discard")
                    quiet: true
                    onClicked: vn.room.discardVoice()
                }
            }
            LogosText {
                visible: !!vn.rec.capped
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("It stopped at the one-minute limit.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            // who will see what, before anything is sent (material-and-disclosure.md §4, rule 2)
            LogosText {
                objectName: "voiceDisclosure"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Everyone in this room can play it. Your voice can identify you, here and outside this room. "
                         + "The store node sees two sealed frames of one fixed size, and when.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
        }
    }

    // ── what the module said ─────────────────────────────────────────────
    readonly property var result: vn.room.voiceResult || ({})
    readonly property string err: String(vn.result.error || "")
    readonly property string detail: String(vn.result.detail || "")
    // the module's words for a voice call's refusal, as Main's microphone strip says them too
    function refusalWords(e, op) { return MusterStyle.voiceRefusalWords(e, op); }
    readonly property string noticeTitle: vn.err.length === 0 ? ""
        : vn.room.voiceOp === "send" ? qsTr("Nothing was sent.")
        : vn.room.voiceOp === "record" ? qsTr("Recording did not start.")
        : vn.room.voiceOp === "play" ? qsTr("Nothing played.")
        : ""
    readonly property string noticeText: {
        if (vn.err.length > 0)
            return vn.refusalWords(vn.err, vn.room.voiceOp) + (vn.detail.length > 0 ? " " + vn.detail : "");
        // a recording the module dropped: its device did not start (the module says that
        // word as ready.capture too), or the encoder refused what it captured
        var re = String(vn.rec.error || "");
        if (re.length > 0) {
            if (re === String(vn.ready.capture || ""))
                return vn.refusalWords(re, "record");
            return qsTr("The recording stopped: the voice encoder could not encode it (%1).").arg(re);
        }
        // a Play the module took, whose speaker then did not start (ready.playback says why)
        if (vn.playFailed.length > 0 && vn.room.voiceOp === "play" && !vn.room.voicePlaying)
            return vn.refusalWords(vn.playFailed, "play");
        // a note the platform gives (on macOS, why the microphone gave nothing)
        return String(vn.ready.note || "");
    }
    readonly property string playFailed: {
        var p = String(vn.ready.playback || "");
        return p === "" || p === "ok" || p === "unknown" ? "" : p;
    }
    InlineNotice {
        id: voiceNotice
        objectName: "voiceNotice"
        visible: vn.noticeText.length > 0 && !dismissed
        dismissible: true
        // a refusal is one answer: dismissed, it stays hidden until a new answer arrives (while
        // the next call is in flight Room shows no answer at all), and shows again if that
        // answer refuses in the same words; a platform note is dismissed until its words change
        occasion: vn.err.length > 0 ? String(vn.room.voiceAnswers) : ""
        tone: vn.err.length > 0 || String(vn.rec.error || "").length > 0
              || (vn.playFailed.length > 0 && vn.room.voiceOp === "play") ? "error" : "info"
        title: vn.noticeTitle
        text: vn.noticeText
    }
}
