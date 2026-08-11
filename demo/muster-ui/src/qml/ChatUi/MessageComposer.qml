import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The thread composer: one field on a pill with the send action at its end,
// sharing the trim/guard/clear contract the thread relies on. Enter sends;
// Shift+Enter inserts a newline. The field grows with its content up to
// maxLines, then scrolls internally. Emits submitted() with the trimmed text.
Rectangle {
    id: root

    property string placeholder: ""
    // Placeholder shown while submitEnabled is false (e.g. "offline").
    property string disabledPlaceholder: ""
    // External gate (connectivity, a selected conversation, ...). The button is
    // additionally disabled while the trimmed text is empty.
    property bool submitEnabled: true
    property alias text: field.text

    signal submitted(string text)
    // "Ask them for an address to pay." Sits beside the send button because
    // starting a payment is an ordinary thing to say in a conversation, not a
    // mode the user has to leave the thread to enter.
    signal addressRequested

    // Put the caret in the field, for a caller that has just given the user a
    // conversation to type into.
    function takeFocus() {
        field.forceActiveFocus();
    }

    // The field grows from one line up to this many, then scrolls.
    readonly property int maxLines: 4

    implicitWidth: 200
    implicitHeight: layout.implicitHeight + 2 * Theme.spacing.small
    radius: height / 2
    color: Theme.palette.surfaceRecessed
    border.width: 1
    border.color: hover.hovered || field.activeFocus ? Theme.palette.borderStrong : Theme.palette.borderDark

    HoverHandler {
        id: hover
    }

    QtObject {
        id: d

        // Emit the trimmed text and clear. No-op when gated off or empty, so
        // neither Enter nor the button can submit blank input.
        function submit() {
            const value = field.text.trim();
            if (value === "" || !root.submitEnabled)
                return;
            root.submitted(value);
            field.text = "";
        }
    }

    FontMetrics {
        id: fontMetrics
        font: field.font
    }

    RowLayout {
        id: layout
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.large
        anchors.rightMargin: Theme.spacing.small
        anchors.topMargin: Theme.spacing.small
        anchors.bottomMargin: Theme.spacing.small
        spacing: Theme.spacing.small

        LogosScrollView {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            readonly property real chromeHeight: field.topPadding + field.bottomPadding
            readonly property real oneLine: fontMetrics.height + chromeHeight
            readonly property real maxHeight: root.maxLines * fontMetrics.height + chromeHeight
            Layout.preferredHeight: Math.max(oneLine, Math.min(field.implicitHeight, maxHeight))

            LogosTextArea {
                id: field
                enabled: root.submitEnabled
                placeholderText: root.submitEnabled ? root.placeholder : root.disabledPlaceholder
                // The pill is the field's surface; the control's own would draw
                // a second one inside it.
                background: null

                // Enter sends; Shift+Enter falls through to insert a newline.
                Keys.onReturnPressed: function (event) {
                    if (event.modifiers & Qt.ShiftModifier) {
                        event.accepted = false;
                    } else {
                        d.submit();
                        event.accepted = true;
                    }
                }
                Keys.onEnterPressed: function (event) {
                    if (event.modifiers & Qt.ShiftModifier) {
                        event.accepted = false;
                    } else {
                        d.submit();
                        event.accepted = true;
                    }
                }
            }
        }

        LogosIconButton {
            id: askAddressButton
            objectName: "askAddressButton"
            size: 40
            iconSize: 18
            iconSource: Qt.resolvedUrl("icons/plus.png")
            iconColor: Theme.palette.textSecondary
            enabled: root.submitEnabled
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Ask for an address")
            onClicked: root.addressRequested()
            Layout.alignment: Qt.AlignBottom
        }

        LogosIconButton {
            id: sendButton
            objectName: "sendButton"
            size: 40
            iconSize: 18
            iconSource: Qt.resolvedUrl("icons/send.png")
            iconColor: Theme.palette.backgroundBlack
            enabled: root.submitEnabled && field.text.trim() !== ""
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Send")
            onClicked: d.submit()
            Layout.alignment: Qt.AlignBottom

            // The one accent action in the thread, so it takes the accent fill
            // rather than the control's neutral pill.
            Binding {
                target: sendButton.backgroundItem
                property: "color"
                value: sendButton.isActive ? ChatTheme.signalSoft : ChatTheme.signal
            }
            Binding {
                target: sendButton.backgroundItem
                property: "border.color"
                value: "transparent"
            }
        }
    }
}
