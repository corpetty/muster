import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A structured card inside a message bubble: the ask for an address, the
// shielded address that answers it, and the receipt for the payment that
// followed. Three steps of a transaction, rendered where they were agreed.
//
// `card` is the parsed JSON a peer sent (see src/MusterMessage.h). An unknown
// type never reaches here — MessageDelegate falls back to a plain bubble — so
// this component only has to render what it knows.
ColumnLayout {
    id: root

    required property var card
    // Whether this account sent the message. Actions belong to the receiver:
    // you answer someone else's request, and you pay someone else's address.
    required property bool isMe
    property bool walletReady: false

    // The folded state of the proposal this card names, or null. The card's own
    // JSON carries only the terms it was proposed with; how many people have
    // approved since is a reading of the whole thread, which only the backend
    // can do — so the terms come from `card` and everything live comes from
    // here, and the two can never disagree about who approved.
    property var intent: null

    signal shareAddressRequested
    signal payRequested(string toAddress, int addressForm, string assetName, string label)
    signal proposeRequested(string toAddress, int addressForm, string assetName, string label)
    signal approveRequested(string intentId)
    signal dropRequested(string intentId)
    signal submitRequested(string intentId)

    spacing: Theme.spacing.small

    readonly property string cardType: root.card ? String(root.card.type) : ""
    readonly property string intentState: root.intent ? String(root.intent.state) : "proposed"

    // What the sharer said they shared. A v1 card has no `assetName` and no
    // `form`, and v1 had exactly one of each — so those are the only defaults a
    // missing field can honestly carry.
    readonly property string sharedAssetName: root.card && root.card.assetName
        ? String(root.card.assetName) : qsTr("private account")
    readonly property int sharedForm: root.card && root.card.form !== undefined
        ? Number(root.card.form) : 0
    readonly property string sharedAddress: root.card && root.card.keys
        ? String(root.card.keys) : ""

    // A one-line heading naming the step, in mono — the same "this is data, not
    // chatter" voice the timestamps and addresses use.
    LogosText {
        Layout.fillWidth: true
        text: root.cardType === "conversation-ready" ? qsTr("Joined the conversation")
            : root.cardType === "address-request" ? qsTr("Asked for an address")
            : root.cardType === "address-share" ? qsTr("Shared an address")
            : root.cardType === "intent-propose" ? qsTr("Proposed a payment")
            : root.cardType === "intent-approve" ? qsTr("Approved")
            : root.cardType === "intent-drop" ? qsTr("Dropped the proposal")
            : qsTr("Payment sent")
        color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.7)
                         : Theme.palette.textTertiary
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.secondaryText
        font.weight: Theme.typography.weightMedium
    }

    // ── conversation-ready ───────────────────────────────────────────────
    // Small, because its job is done by arriving: it is what tells the other
    // side the room has two ends, so their first card can go out. Shown rather
    // than hidden so the pause before that card is legible instead of looking
    // like nothing happened. See MusterMessage::conversationReady.
    LogosText {
        visible: root.cardType === "conversation-ready"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.isMe ? qsTr("You joined, and they were told so.")
                        : qsTr("They are here. Anything waiting to be sent can go now.")
        color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
        font.pixelSize: Theme.typography.primaryText
    }

    // ── address-request ──────────────────────────────────────────────────
    LogosText {
        visible: root.cardType === "address-request"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.isMe ? qsTr("Waiting for them to share an address.")
                        : qsTr("They want somewhere to send funds.")
        color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
        font.pixelSize: Theme.typography.primaryText
    }

    // ── address-share ────────────────────────────────────────────────────
    ColumnLayout {
        visible: root.cardType === "address-share"
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.card && root.card.label
                ? qsTr("%1 · %2").arg(String(root.card.label)).arg(root.sharedAssetName)
                : root.sharedAssetName
            color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
            font.pixelSize: Theme.typography.primaryText
        }

        // The address itself is long and no one reads it; what matters is what
        // *kind* of destination it is, so say that instead of pasting sixty
        // characters nobody checks. Which kind comes off the card's `form`,
        // because getting this wrong is exactly the lie the version bump exists
        // to prevent: a public account labelled "shielded" is an invitation to
        // a payment the payer thinks is private.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 2
            elide: Text.ElideRight
            text: qsTr("%1 · %2")
                .arg(root.sharedForm === 0 ? qsTr("shielded") : qsTr("public account"))
                .arg(root.sharedAddress.replace(/\s+/g, "").slice(0, 48)
                     + (root.sharedAddress.length > 48 ? "…" : ""))
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.6)
                             : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
        }

        // A public account on a card is worth a word of its own: the peer has
        // chosen to be paid somewhere anyone can read, and the payer should
        // know that before choosing how to pay rather than discovering it in
        // the rail picker.
        LogosText {
            Layout.fillWidth: true
            visible: root.sharedForm === 1
            wrapMode: Text.WordWrap
            text: qsTr("Anyone reading the zone can see what lands here.")
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.6)
                             : Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
        }
    }

    // ── intent-approve / intent-drop ─────────────────────────────────────
    // Deliberately thin. An approval is a fact in the thread, not a thing to
    // act on; it earns a line so the record reads in order, and no more.
    LogosText {
        visible: root.cardType === "intent-approve" || root.cardType === "intent-drop"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.cardType === "intent-drop" && root.card && root.card.reason
            ? String(root.card.reason)
            : root.cardType === "intent-approve"
                ? qsTr("Added to the proposal above.")
                : qsTr("It will not be paid.")
        color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
        font.pixelSize: Theme.typography.primaryText
    }

    // ── intent-propose ───────────────────────────────────────────────────
    // The room deciding something before anyone acts on it. The amount leads,
    // the destination follows, and the approvals are drawn as presence (U-4)
    // rather than a number, because the question "who is still to weigh in" is
    // the one people actually have.
    ColumnLayout {
        visible: root.cardType === "intent-propose"
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            text: qsTr("%1 %2").arg(root.card ? String(root.card.amount) : "")
                               .arg(root.card ? String(root.card.denom) : "")
            color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightMedium
        }

        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.card && root.card.label
                ? qsTr("to %1").arg(String(root.card.label))
                : qsTr("to the address they shared")
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.7)
                             : Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }

        // Which rail the room is being asked to agree to, in this build's
        // words. A rail we do not know is named as unknown rather than
        // described: the card would otherwise be making a privacy claim on
        // behalf of code that is not here.
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.intent && root.intent.railKnown
                ? String(root.intent.railName)
                : qsTr("on a rail this build does not know (%1)")
                    .arg(root.intent ? String(root.intent.rail) : "")
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.7)
                             : Theme.palette.textSecondary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
        }

        // The rail. Four states, not the prototype's five: a shielded transfer
        // gives us no observable moment between "sent" and "accepted", so there
        // is no honest `submitted` step to draw and we do not draw one.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.tiny
            spacing: Theme.spacing.tiny
            visible: root.intentState !== "dropped"

            Repeater {
                model: [{ k: "proposed", t: qsTr("proposed") },
                        { k: "collecting", t: qsTr("collecting") },
                        { k: "ready", t: qsTr("ready") },
                        { k: "final", t: qsTr("paid") }]

                delegate: RowLayout {
                    id: step
                    required property var modelData
                    required property int index
                    spacing: 3

                    // How far the fold says this proposal has got. A step at or
                    // before it is lit; everything after stays drawn but unlit,
                    // so the whole path is visible from the first card.
                    readonly property bool lit:
                        step.index <= ["proposed", "collecting", "ready", "final"]
                                        .indexOf(root.intentState)

                    Rectangle {
                        implicitWidth: 6
                        implicitHeight: 6
                        radius: 3
                        color: step.lit
                            ? (root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.signal)
                            : Theme.palette.borderDefault
                    }

                    LogosText {
                        text: step.modelData.t
                        color: step.lit
                            ? (root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.8)
                                         : Theme.palette.textSecondary)
                            : Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }

                    Item { Layout.preferredWidth: Theme.spacing.small }
                }
            }
        }

        // Slots fill as approvals arrive. Empty slots are drawn too, because
        // the shape of what is missing is the information.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.tiny
            spacing: 4
            visible: root.intentState !== "dropped"

            Repeater {
                model: root.intent ? Number(root.intent.threshold) : 0

                delegate: Rectangle {
                    id: slot
                    required property int index
                    // Slots beyond the approvals so far are the empty ones.
                    readonly property var who: root.intent && root.intent.approvers
                        && slot.index < root.intent.approvers.length
                        ? root.intent.approvers[slot.index] : null

                    implicitWidth: 22
                    implicitHeight: 22
                    radius: 11
                    color: slot.who ? ChatTheme.signal : "transparent"
                    border.width: slot.who ? 0 : 1
                    border.color: Theme.palette.borderDefault

                    LogosText {
                        anchors.centerIn: parent
                        visible: !!slot.who
                        text: slot.who ? String(slot.who.initials) : ""
                        color: ChatTheme.avatarInk
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                }
            }

            Item { Layout.fillWidth: true }

            LogosText {
                text: root.intent
                    ? qsTr("%1 of %2 approved").arg(Number(root.intent.approvals))
                                               .arg(Number(root.intent.threshold))
                    : ""
                color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.8)
                                 : Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }
        }

        // The claim this card must not overstate. The count above is real —
        // every approval is bound to its author by the chat module — but the
        // zone will not check it, and a card showing filled slots beside a
        // shielded payment would imply otherwise if left to speak for itself.
        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: 2
            wrapMode: Text.WordWrap
            text: qsTr("Agreed in this room. The zone does not enforce the threshold — "
                       + "whoever proposed it pays from their own account.")
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.6)
                             : Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
        }

        LogosText {
            Layout.fillWidth: true
            visible: root.intentState === "dropped"
            wrapMode: Text.WordWrap
            text: root.intent && root.intent.reason
                ? qsTr("Dropped — %1").arg(String(root.intent.reason))
                : qsTr("Dropped.")
            color: ChatTheme.alarm
            font.pixelSize: Theme.typography.secondaryText
        }
    }

    // ── send-receipt ─────────────────────────────────────────────────────
    // The one moment something leaves the room. The prototype changes visual
    // ground exactly here and nowhere else, because this is the only step
    // where the boundary is actually crossed — so the card carries the outside
    // ground inside it, and names what the chain got.
    ColumnLayout {
        visible: root.cardType === "send-receipt"
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            text: qsTr("%1 %2").arg(root.card ? String(root.card.amount) : "")
                               .arg(root.card ? String(root.card.denom) : "")
            color: root.isMe ? ChatTheme.bubbleOwnText : ChatTheme.bubblePeerText
            font.pixelSize: Theme.typography.primaryText
            font.weight: Theme.typography.weightMedium
        }

        // What crossed. Same fields the visibility panel uses at every step, so
        // a reader who has seen them there can compare — and here almost all of
        // them read "not disclosed", which is the point of having paid seven
        // minutes for it.
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 2
            Layout.preferredHeight: crossing.implicitHeight + 2 * Theme.spacing.small
            radius: Theme.spacing.radiusSmall
            color: ChatTheme.outside

            ColumnLayout {
                id: crossing
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                spacing: 2

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("WHAT LEFT THE ROOM")
                    color: ChatTheme.outsideAccent
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }

                // Read off the receipt's own `discloses`, which the rail that
                // ran the payment wrote. This used to be two hand-written
                // lists chosen by a single `shielded` bool — which could only
                // describe the two rails at the ends of the square, and
                // described the two in the middle wrongly. A shield names the
                // payer and hides the payee; neither list said that.
                //
                // The last two rows are on every rail there is: nothing hides
                // that a transfer happened, or when. That is the floor, and
                // saying it on every receipt is the honest thing rather than
                // the repetitive one.
                Repeater {
                    model: {
                        const d = root.card && root.card.discloses
                            ? root.card.discloses
                            // A v1 receipt: one bool, and it meant this.
                            : { amount: !root.card || !root.card.shielded,
                                payer: !root.card || !root.card.shielded,
                                payee: !root.card || !root.card.shielded };
                        return [
                            { k: qsTr("amount"),
                              v: d.amount ? (root.card ? String(root.card.amount) : "")
                                          : qsTr("not disclosed"),
                              w: !d.amount },
                            { k: qsTr("who paid"),
                              v: d.payer ? qsTr("on the record") : qsTr("not disclosed"),
                              w: !d.payer },
                            { k: qsTr("who was paid"),
                              v: d.payee ? qsTr("on the record") : qsTr("not disclosed"),
                              w: !d.payee },
                            { k: qsTr("that it happened"), v: qsTr("on the record"), w: false },
                            { k: qsTr("when"), v: qsTr("block timestamp"), w: false }];
                    }

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosText {
                            text: modelData.k
                            color: "#96A19B"
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        Item { Layout.fillWidth: true }

                        // Withheld is the good outcome, so it takes the accent.
                        LogosText {
                            text: modelData.v
                            color: modelData.w ? ChatTheme.outsideAccent : ChatTheme.outsideInk
                            horizontalAlignment: Text.AlignRight
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            font.weight: Theme.typography.weightMedium
                        }
                    }
                }
            }
        }

        // The tx id, last and quietest: it is the thing you would take to an
        // explorer, and the least interesting fact on the card.
        LogosText {
            Layout.fillWidth: true
            visible: root.card && root.card.tx
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 1
            elide: Text.ElideRight
            text: root.card && root.card.tx ? String(root.card.tx) : ""
            color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.5)
                             : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
        }
    }

    // ── actions ──────────────────────────────────────────────────────────
    // Only ever on a message from the other side: this is the point where the
    // conversation turns into a transaction, and it should take one tap.
    LogosButton {
        objectName: "cardShareAddress"
        visible: root.cardType === "address-request" && !root.isMe
        Layout.fillWidth: true
        text: root.walletReady ? qsTr("Share my address") : qsTr("Open wallet first")
        enabled: root.walletReady
        onClicked: root.shareAddressRequested()
    }

    LogosButton {
        objectName: "cardPay"
        visible: root.cardType === "address-share" && !root.isMe
        Layout.fillWidth: true
        text: root.walletReady ? qsTr("Send") : qsTr("Open wallet first")
        enabled: root.walletReady
        onClicked: root.payRequested(root.sharedAddress, root.sharedForm, root.sharedAssetName,
                                     root.card && root.card.label ? String(root.card.label) : "")
    }

    // The same address can be paid outright or put to the room first. Both sit
    // on the card, because the choice between them is the interesting one and
    // hiding it in a menu would make agreeing feel like the advanced path.
    LogosButton {
        objectName: "cardPropose"
        visible: root.cardType === "address-share" && !root.isMe
        Layout.fillWidth: true
        text: root.walletReady ? qsTr("Propose it to the room") : qsTr("Open wallet first")
        enabled: root.walletReady
        onClicked: root.proposeRequested(root.sharedAddress, root.sharedForm,
                                         root.sharedAssetName,
                                         root.card && root.card.label ? String(root.card.label) : "")
    }

    // ── proposal actions ─────────────────────────────────────────────────
    // Approving is for everyone who has not; paying is only for whoever
    // proposed, because it is their account the money leaves.
    LogosButton {
        objectName: "cardApprove"
        visible: root.cardType === "intent-propose" && !!root.intent
            && !root.intent.approvedByMe
            && (root.intentState === "proposed" || root.intentState === "collecting")
        Layout.fillWidth: true
        text: qsTr("Approve")
        onClicked: root.approveRequested(root.intent ? String(root.intent.intentId) : "")
    }

    // A proposal agreed on a rail this build cannot run is not payable here,
    // and the button says which of the two things is wrong rather than sitting
    // there disabled. Paying it on a rail we *do* have would settle terms the
    // room never approved, so the offer is refused rather than substituted.
    LogosButton {
        objectName: "cardSubmitIntent"
        visible: root.cardType === "intent-propose" && !!root.intent
            && root.intentState === "ready" && root.intent.proposedByMe
        Layout.fillWidth: true
        text: !root.walletReady ? qsTr("Open wallet first")
            : !root.intent.railKnown ? qsTr("This build cannot pay that rail")
            : qsTr("Pay it")
        enabled: root.walletReady && !!root.intent && root.intent.railKnown
        onClicked: root.submitRequested(root.intent ? String(root.intent.intentId) : "")
    }

    // Says who it is waiting on rather than going flat, so a member who cannot
    // act still learns why.
    LogosText {
        Layout.fillWidth: true
        visible: root.cardType === "intent-propose" && !!root.intent
            && root.intentState === "ready" && !root.intent.proposedByMe
        wrapMode: Text.WordWrap
        text: qsTr("Ready. Waiting for whoever proposed it to pay.")
        color: root.isMe ? Theme.colors.getColor(ChatTheme.bubbleOwnText, 0.7)
                         : Theme.palette.textSecondary
        font.pixelSize: Theme.typography.secondaryText
    }

    LogosButton {
        objectName: "cardDropIntent"
        visible: root.cardType === "intent-propose" && !!root.intent
            && (root.intentState === "proposed" || root.intentState === "collecting"
                || root.intentState === "ready")
        Layout.fillWidth: true
        text: qsTr("Drop it")
        onClicked: root.dropRequested(root.intent ? String(root.intent.intentId) : "")
    }
}
