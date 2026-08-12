import QtQuick

import Logos.Theme
import Logos.Controls

// One message in a thread: a bubble on the right for this account, on the left
// for everyone else, headed by the sender's avatar and name where a run of
// theirs begins, and by the date where the day changes. Roles bind by name.
Item {
    id: root

    required property string content
    required property bool isMe
    // Clock time for the bubble, formatted by the model.
    required property string timeDisplay
    required property string sender
    // Avatar identity for the sender, computed by the model.
    required property string avatarInitials
    required property int avatarRamp
    // Whether the thread is a group; drives the sender label on incoming messages.
    property bool groupContext: false
    // Neighbour-derived roles: suppress a repeated sender label within a run of
    // messages, and head a new calendar day with a separator above the bubble.
    required property bool sameSenderAsPrevious
    required property bool showDaySeparator
    required property string dayLabel

    // Where a run of someone else's messages begins: the one row in it that
    // carries their face and name.
    readonly property bool startsRun: !root.isMe && !root.sameSenderAsPrevious
    readonly property bool showSender: root.groupContext && root.startsRun
    // What a copy of this message takes: the selection when the user made one,
    // else the whole message.
    readonly property string copyText: contentText.selectedText !== "" ? contentText.selectedText : root.content

    // The gutter an incoming bubble is inset by, whether or not this row is the
    // one carrying the avatar.
    readonly property int gutter: 28 + Theme.spacing.small

    // Emitted on a right-click, so the thread can offer its message actions.
    signal contextMenuRequested(string text)

    // Muster's own structured cards, which travel as JSON in an ordinary
    // message (see src/MusterMessage.h). A message that isn't one — including
    // one from a peer running a build that knows a type this one doesn't —
    // falls through to the plain bubble below, which is what lets the card
    // vocabulary grow without breaking anyone.
    property bool walletReady: false
    // Every proposal in this conversation, as the backend folded them. The
    // thread hands the whole list down rather than a per-message lookup so a
    // card's live state comes from the same read every other card used.
    property var intents: []
    readonly property var musterCard: {
        const text = root.content;
        if (!text || text.charAt(0) !== "{")
            return null;
        try {
            const parsed = JSON.parse(text);
            if (!parsed || !parsed.muster || !parsed.type)
                return null;
            // Only the ones we render; anything else is a plain bubble.
            const known = ["address-request", "address-share", "send-receipt",
                           "intent-propose", "intent-approve", "intent-drop"];
            if (known.indexOf(parsed.type) === -1)
                return null;
            return parsed;
        } catch (e) {
            return null;
        }
    }

    // The folded proposal this card is about, matched by the id the proposer
    // minted. Null until the fold catches up, which is why the card renders its
    // terms from its own JSON and only its progress from here.
    readonly property var musterIntent: {
        if (!root.musterCard || root.musterCard.type !== "intent-propose")
            return null;
        const id = String(root.musterCard.intentId || "");
        const list = root.intents || [];
        for (let i = 0; i < list.length; ++i) {
            if (String(list[i].intentId) === id)
                return list[i];
        }
        return null;
    }

    signal shareAddressRequested
    signal payRequested(string keysJson, string label)
    signal proposeRequested(string keysJson, string label)
    signal approveRequested(string intentId)
    signal dropRequested(string intentId)
    signal submitRequested(string intentId)

    implicitWidth: 200
    implicitHeight: bubble.y + bubble.height

    Accessible.role: Accessible.StaticText
    Accessible.name: root.content
    Accessible.description: qsTr("%1, %2").arg(root.sender).arg(timeText.text)

    Item {
        id: daySeparator
        y: 0
        width: root.width
        visible: root.showDaySeparator
        height: root.showDaySeparator ? dayChip.implicitHeight + 2 * Theme.spacing.small : 0

        DayChip {
            id: dayChip
            anchors.centerIn: parent
            text: root.dayLabel
        }
    }

    LogosText {
        id: senderLabel
        y: daySeparator.height
        visible: root.showSender
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.xlarge + root.gutter
        text: root.sender
        textFormat: Text.PlainText
        // The sender's own colour, taken from the ramp their avatar is drawn in,
        // so a name and a face read as the same person.
        color: ChatTheme.avatarRamps[root.avatarRamp].stops[0].color
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.secondaryText
        font.weight: Theme.typography.weightMedium
    }

    Avatar {
        // Bottom-aligned with the bubble, so a run reads as hanging off one face.
        y: bubble.y + bubble.height - height
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.xlarge
        visible: root.startsRun
        size: 28
        initials: root.avatarInitials
        ramp: root.avatarRamp
    }

    Rectangle {
        id: bubble
        objectName: "bubble"
        y: root.showSender ? senderLabel.y + senderLabel.height + Theme.spacing.tiny : daySeparator.height
        anchors.left: root.isMe ? undefined : parent.left
        anchors.right: root.isMe ? parent.right : undefined
        anchors.leftMargin: Theme.spacing.xlarge + root.gutter
        anchors.rightMargin: Theme.spacing.xlarge

        // Grow to the wider of the content and the timestamp (a short message
        // must not leave the time outside the bubble), capped at 70% of the row.
        // A card carries a heading, a body and often a button, so it is given a
        // floor to lay out in rather than being squeezed to its longest line.
        width: root.musterCard
            ? Math.min(Math.max(320, timeText.implicitWidth + 2 * Theme.spacing.medium), root.width * 0.8)
            : Math.min(Math.max(contentText.implicitWidth, timeText.implicitWidth) + 2 * Theme.spacing.medium, root.width * 0.7)
        height: (root.musterCard ? cardLoader.implicitHeight : contentText.implicitHeight)
            + timeText.implicitHeight + 2 * Theme.spacing.small + Theme.spacing.tiny
        radius: Theme.spacing.radiusXlarge
        // The corner nearest its sender is squared off, so a bubble points at
        // the side it came from, and a run's later bubbles square off at the top
        // to read as one block.
        bottomLeftRadius: root.isMe ? radius : Theme.spacing.radiusSmall
        bottomRightRadius: root.isMe ? Theme.spacing.radiusSmall : radius
        topLeftRadius: !root.isMe && !root.startsRun ? Theme.spacing.radiusSmall : radius
        color: root.isMe ? ChatTheme.bubbleOwn : ChatTheme.bubblePeer
        border.width: root.isMe ? 0 : 1
        border.color: Theme.palette.borderSubtle

        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: root.contextMenuRequested(root.copyText)
        }

        Column {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacing.medium
            anchors.rightMargin: Theme.spacing.medium
            anchors.topMargin: Theme.spacing.small
            anchors.bottomMargin: Theme.spacing.small
            spacing: Theme.spacing.tiny

            Loader {
                id: cardLoader
                objectName: "musterCard"
                width: parent.width
                active: root.musterCard !== null
                visible: active
                sourceComponent: MusterCard {
                    width: cardLoader.width
                    card: root.musterCard
                    intent: root.musterIntent
                    isMe: root.isMe
                    walletReady: root.walletReady
                    onShareAddressRequested: root.shareAddressRequested()
                    onPayRequested: function (keysJson, label) {
                        root.payRequested(keysJson, label);
                    }
                    onProposeRequested: function (keysJson, label) {
                        root.proposeRequested(keysJson, label);
                    }
                    onApproveRequested: function (intentId) {
                        root.approveRequested(intentId);
                    }
                    onDropRequested: function (intentId) {
                        root.dropRequested(intentId);
                    }
                    onSubmitRequested: function (intentId) {
                        root.submitRequested(intentId);
                    }
                }
            }

            SelectableText {
                id: contentText
                objectName: "messageText"
                width: parent.width
                visible: root.musterCard === null
                text: root.content
                color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
                selectionColor: root.isMe ? ChatTheme.bubbleOwnSelection : ChatTheme.bubblePeerSelection
                selectedTextColor: root.isMe ? ChatTheme.bubbleOwnSelectedText : ChatTheme.bubblePeerSelectedText
                font.pixelSize: Theme.typography.primaryText
            }

            LogosText {
                id: timeText
                width: parent.width
                text: root.timeDisplay
                color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.5) : Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
                horizontalAlignment: root.isMe ? Text.AlignRight : Text.AlignLeft
            }
        }
    }
}
