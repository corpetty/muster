import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons

// Something to know, said where it happened (exo-720.5): a refusal in the form that was
// refused, a join request in the thread, an RPC that is down above the room. One shape for
// every one of today's "⚠ …" lines, so the cause and the remedy always read the same (U-8):
//   tone      info | warning | error
//   title     the outcome, short: "Nothing was proposed."
//   text      the cause, and what to do
//   (children) the remedies, as buttons, at the right
//   dismissible  a × that hides it until its words change: a new outcome always shows.
//                A consumer ANDs `!dismissed` into its own `visible`.
//   occasion     what the words answer, when the same words can come back as a new
//                outcome (a retried call refused again): a × hides them for this
//                occasion only. Empty, the words alone decide.
Rectangle {
    id: notice

    property string tone: "info"
    property string title: ""
    property string text: ""
    default property alias actions: remedies.data
    property bool dismissible: false
    property string occasion: ""
    property string dismissedFor: ""
    readonly property string dismissKey: occasion + "\n" + title + "\n" + text
    readonly property bool dismissed: dismissible && dismissedFor.length > 0 && dismissedFor === dismissKey

    readonly property color accent: tone === "error" ? MusterStyle.refused
                                  : tone === "warning" ? MusterStyle.warning : MusterStyle.info

    Layout.fillWidth: true
    implicitWidth: row.implicitWidth + 2 * Theme.spacing.medium
    implicitHeight: row.implicitHeight + 2 * Theme.spacing.medium
    radius: Theme.spacing.radiusLarge
    color: MusterStyle.tint(notice.accent, 0.08)
    border.width: 1
    border.color: MusterStyle.tint(notice.accent, 0.42)
    Accessible.role: Accessible.AlertMessage
    Accessible.name: (notice.title + " " + notice.text).trim()

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.medium

        LogosText {
            Layout.alignment: Qt.AlignTop
            text: notice.tone === "error" ? "✕" : notice.tone === "warning" ? "!" : "i"
            color: notice.accent
            font.pixelSize: MusterStyle.body
            font.weight: Theme.typography.weightBold
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            LogosText {
                visible: notice.title.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: notice.title
                color: Theme.palette.text
                font.pixelSize: MusterStyle.body
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                visible: notice.text.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: notice.text
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
        }
        Flow {
            id: remedies
            Layout.alignment: Qt.AlignVCenter
            Layout.maximumWidth: notice.width * 0.5
            spacing: Theme.spacing.small
        }
        IconAction {
            objectName: notice.objectName.length > 0 ? notice.objectName + "Dismiss" : ""
            visible: notice.dismissible
            Layout.alignment: Qt.AlignTop
            size: 24
            label: qsTr("Dismiss")
            icon: LogosIcons.close
            onClicked: notice.dismissedFor = notice.dismissKey
        }
    }
}
