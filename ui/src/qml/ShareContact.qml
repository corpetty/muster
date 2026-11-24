import QtQuick
import QtQuick.Layouts
import QtCore as Prefs
import Logos.Theme
import Logos.Controls
import Logos.Icons

// Your contact link, to give to someone (exo-899): "muster:contact/<chat id>?name=…". It
// is your chat id — the identity an invite is sealed to — with the name you suggest they
// call you. Whoever has it can invite you to a room; it says nothing else about you. Copy
// it, or show it as a QR code for a phone to read.
ColumnLayout {
    id: share

    property string chatId: ""
    signal copied()

    Prefs.Settings {
        id: sharePrefs
        category: "MusterUiShare"
        property string myName: ""
    }
    readonly property string link: MusterStyle.contactLink(share.chatId, nameField.text)
    property bool qrShown: false

    spacing: Theme.spacing.small

    LogosText {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("Give this to someone so they can invite you to a room. It names nothing else about you.")
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
    }
    LogosTextField {
        id: nameField
        objectName: "shareNameField"
        Layout.fillWidth: true
        placeholderText: qsTr("Your name in the link (optional)")
        Component.onCompleted: nameField.text = sharePrefs.myName
        onTextChanged: sharePrefs.myName = nameField.text
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: linkText.implicitHeight + 2 * Theme.spacing.small
        radius: Theme.spacing.radiusMedium
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderSubtle
        TextEdit {
            textFormat: TextEdit.PlainText
            id: linkText
            objectName: "shareLinkText"
            anchors.fill: parent
            anchors.margins: Theme.spacing.small
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            text: share.chatId.length > 0 ? share.link : qsTr("(not loaded yet)")
            color: Theme.palette.text
            selectionColor: Theme.palette.primary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
        }
    }
    RowLayout {
        spacing: Theme.spacing.small
        ActionButton {
            id: copyLink
            objectName: "shareCopyLink"
            property bool done: false
            enabled: share.chatId.length > 0
            variant: LogosButton.Variant.Primary
            text: copyLink.done ? qsTr("Copied") : qsTr("Copy link")
            iconSource: LogosIcons.copy
            iconColor: Theme.palette.background
            onClicked: {
                linkText.selectAll(); linkText.copy(); linkText.deselect();
                copyLink.done = true; copiedReset.restart();
                share.copied();
            }
            Timer { id: copiedReset; interval: 2000; onTriggered: copyLink.done = false }
        }
        ActionButton {
            objectName: "shareShowQr"
            enabled: share.chatId.length > 0
            quiet: true
            text: share.qrShown ? qsTr("Hide QR code") : qsTr("QR code")
            iconSource: MusterStyle.icon("qr")
            onClicked: share.qrShown = !share.qrShown
        }
    }
    QrCode {
        objectName: "shareQr"
        visible: share.qrShown && size > 0
        text: share.qrShown ? share.link : ""
        Layout.preferredWidth: 220
        Layout.preferredHeight: 220
    }
}
