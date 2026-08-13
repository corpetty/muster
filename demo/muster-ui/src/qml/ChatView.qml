import QtQuick
import QtCore
import QtQuick.Layouts

import Logos.Theme

import ChatUi

// Entry view (metadata.json "view"). Instantiates the store, which is the sole
// reader of the host `logos` context property, and composes the panes, wiring
// their signals to the store's actions. All UI lives in the ChatUi module; this
// file is composition only.
//
// One context at a time. The app used to put four columns on screen at once —
// every conversation, the open one, who can see it, and the whole wallet — on
// the reasoning that each was worth having to hand. Together they said the
// opposite of what each said alone: that all of it applies all of the time.
// Inside a muster the other musters are not context, they are noise, and the
// whole wallet overstates what that room has to do with your money.
//
// So: three destinations, and a stack rather than a row.
//
//   home    what there is to do, who you are, what you hold
//   muster  one conversation, who can see it, the part of the wallet it uses
//   wallet  every holding opened out, and what moving each one discloses
//
// Two things refuse to be a destination and stay below the stack at all times:
// the job strip, because a seven-minute proof that vanishes when you navigate
// is indistinguishable from a hang, and the status bar, because a failure is
// not something you should have to be on the right screen to hear about.
Rectangle {
    id: root
    implicitWidth: 1000
    implicitHeight: 700
    color: Theme.palette.backgroundInset

    // Which of the three is showing: "home" | "muster" | "wallet".
    property string route: "home"
    // Where the wallet was opened from, so leaving it goes back rather than
    // home. The wallet is a detour off both of the other two.
    property string walletReturnRoute: "home"

    // The muster the running job belongs to, captured when the job is named
    // rather than tracked by the backend — the backend has one wallet and no
    // notion of which room asked it to work. Empty for a job started outside
    // any muster, which is honest: funding the wallet belongs to nobody.
    property string jobConversationId: ""
    property string jobConversationName: ""

    // The row the user just picked, carrying its own data so the sidebar and the
    // header move in the same frame as the click instead of waiting for the
    // backend. It stops applying as soon as the backend reports that
    // conversation loaded, from when on the store is the truth again.
    property var pendingSelection: null

    readonly property var optimisticSelection: root.pendingSelection && store.loadedConversationId !== root.pendingSelection.conversationId ? root.pendingSelection : null

    readonly property string selectedConversationId: root.optimisticSelection ? root.optimisticSelection.conversationId : store.currentConversationId
    readonly property string selectedDisplayName: root.optimisticSelection ? root.optimisticSelection.displayName : store.currentDisplayName
    readonly property string selectedDescription: root.optimisticSelection ? root.optimisticSelection.description : store.currentDescription
    readonly property bool selectedIsGroup: root.optimisticSelection ? root.optimisticSelection.isGroup : store.currentIsGroup
    readonly property string selectedAvatarInitials: root.optimisticSelection ? root.optimisticSelection.avatarInitials : store.currentAvatarInitials
    readonly property int selectedAvatarRamp: root.optimisticSelection ? root.optimisticSelection.avatarRamp : store.currentAvatarRamp
    // Whether the models hold the selected conversation's data.
    readonly property bool selectionLoaded: store.loadedConversationId === root.selectedConversationId

    // Whether the conversation's details panel is showing, toggled from the
    // thread header and left as the user last set it.
    property bool detailsShown: false

    // The newest failure the status bar is holding, and how many nobody has
    // looked at yet. Both stand until the logs are opened, which is what marks
    // them seen; the failures themselves are retained by the backend either way.
    property string lastError: ""
    property int unseenErrorCount: 0

    ChatStore {
        id: store
    }

    Connections {
        target: store
        function onErrorOccurred(message) {
            root.lastError = message;
            root.unseenErrorCount += 1;
        }
        function onSendFailed(conversationId, content) {
            threadPane.restoreFailedSend(conversationId, content);
        }
        // The backend switched somewhere else (a new conversation opening, the
        // selected one going away), which retires the pending row.
        function onCurrentConversationIdChanged() {
            if (root.pendingSelection && store.currentConversationId !== root.pendingSelection.conversationId)
                root.pendingSelection = null;
            // Selection is the thing being on the muster screen means, so the
            // screen follows it rather than only following the click. That
            // covers starting something — which creates a room and selects it
            // a beat later — and it keeps the inspector-driven doc-tests, which
            // select through the store and never touch a row, on the screen
            // they are taking pictures of.
            if (store.currentConversationId !== "")
                root.route = "muster";
        }
        // Who the running job is for. Read at the moment it is named, because
        // that is the only moment the answer is on screen: by the time a
        // seven-minute proof lands the user may be three screens away.
        function onWalletJobChanged() {
            const inMuster = store.walletJob !== "" && root.route === "muster";
            root.jobConversationId = inMuster ? store.currentConversationId : "";
            root.jobConversationName = inMuster ? store.currentDisplayName : "";
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.medium

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Every destination stays instantiated. Switching is a change of
            // what is shown, not of what exists: the thread keeps its scroll
            // and its draft, and the wallet keeps its place in a long list.
            currentIndex: root.route === "muster" ? 1 : root.route === "wallet" ? 2 : 0

            // ── home ─────────────────────────────────────────────────────
            // What there is to do, and — off to the side, because it is who
            // you are rather than what you are doing — your identity and what
            // you hold.
            RowLayout {
                spacing: Theme.spacing.medium

                ActionsPane {
                    id: actionsPane
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    actions: store.actions
                    currentConversationId: root.selectedConversationId
                    online: store.online
                    onConversationSelected: function (conversationId) {
                        store.selectConversation(conversationId);
                        // Set here as well as from the selection changing, so
                        // the screen turns on the click rather than on the
                        // round trip — and so re-opening the conversation
                        // already loaded, which the backend answers with
                        // nothing, still goes there.
                        root.route = "muster";
                    }
                    onNewActivityRequested: newActivityDialog.open()
                }

                ColumnLayout {
                    // A layout nested in a layout fills by default, which would
                    // hand this column the slack meant for the list.
                    Layout.fillWidth: false
                    Layout.preferredWidth: 320
                    Layout.minimumWidth: 260
                    Layout.fillHeight: true
                    spacing: Theme.spacing.medium

                    AccountCard {
                        Layout.fillWidth: true
                        address: store.myAddress
                        label: store.myLabel
                        initials: store.myInitials
                        online: store.online
                        statusLabel: store.statusLabel
                    }

                    // Under the identity: what you can spend is part of who you
                    // are here. The summary only — what you have. Where each
                    // holding can go, and what going there tells everyone, is
                    // the wallet page, one press away.
                    WalletCard {
                        objectName: "walletCard"
                        Layout.fillWidth: true
                        // A list of holdings is taller than the two numbers this
                        // replaced, and a squeezed wallet clips the row that says
                        // why a holding is unusable.
                        Layout.minimumHeight: implicitHeight
                        ready: store.walletReady
                        busy: store.walletBusy
                        stage: store.walletStage
                        statusLabel: store.walletLabel
                        assets: store.assets
                        receivedElsewhere: store.receivedElsewhere
                        errorText: store.walletError
                        onOpenRequested: store.openWallet()
                        onFundRequested: store.fundWallet()
                        onRefreshRequested: store.refreshBalances()
                        // Empty amount means all of it, which is what the card's
                        // one-tap claim asks for.
                        onClaimRequested: function (assetId) {
                            store.claimHolding(assetId, "");
                        }
                        onDetailsRequested: root.showWallet("home")
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }
            }

            // ── muster ───────────────────────────────────────────────────
            // One conversation and its own context: who can see it, and the
            // part of the wallet it has reached into. Nothing about the other
            // conversations, except the count on the way out.
            ColumnLayout {
                spacing: Theme.spacing.small

                BackBar {
                    Layout.fillWidth: true
                    label: qsTr("Home")
                    title: root.selectedDisplayName
                    waitingCount: store.needsYouExcept(root.selectedConversationId)
                    onBackRequested: root.route = "home"
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Theme.spacing.medium

                    MessageThreadPane {
                        id: threadPane
                        Layout.fillWidth: true
                        // The thread is what the window is for, so a window too
                        // narrow for all three columns clips the right one
                        // rather than the thread.
                        Layout.minimumWidth: 360
                        Layout.fillHeight: true
                        messageModel: store.messageModel
                        currentIsGroup: root.selectedIsGroup
                        title: root.selectedDisplayName
                        description: root.selectedDescription
                        avatarInitials: root.selectedAvatarInitials
                        avatarRamp: root.selectedAvatarRamp
                        conversationId: root.selectedConversationId
                        memberModel: store.memberModel
                        memberCount: store.memberCount
                        pendingMemberCount: store.pendingMemberCount
                        action: store.currentAction
                        detailsShown: root.detailsShown
                        hasConversation: root.selectedConversationId !== ""
                        hasConversations: store.actions.length > 0
                        online: store.online
                        ready: root.selectionLoaded
                        walletReady: store.walletReady
                        onMessageSubmitted: function (text) {
                            store.sendMessage(text);
                        }
                        onDetailsRequested: root.detailsShown = !root.detailsShown
                        onAddressRequested: store.requestAddress()
                        // More than one answer to "where do I pay you", and the
                        // choice is the payee's — sharing a public account
                        // invites a payment anyone can read. One receivable
                        // holding still asks, because the dialog is where that
                        // trade-off is stated.
                        onShareAddressRequested: shareAddressDialog.open()
                        onPayRequested: function (toAddress, addressForm, assetName, label) {
                            sendDialog.toAddress = toAddress;
                            sendDialog.addressForm = addressForm;
                            sendDialog.assetName = assetName;
                            sendDialog.assetKnown = store.railsPaying(addressForm).length > 0;
                            sendDialog.peerLabel = label;
                            // Only the rails that can pay this form of address.
                            // The dialog is handed the answer rather than the
                            // catalogue, so it never has to know what a rail is.
                            sendDialog.rails = store.railsPaying(addressForm);
                            sendDialog.open();
                        }
                        intents: store.intents
                        liveIntent: store.liveIntent
                        onProposeRequested: function (toAddress, addressForm, assetName, label) {
                            proposeDialog.toAddress = toAddress;
                            proposeDialog.addressForm = addressForm;
                            proposeDialog.assetName = assetName;
                            proposeDialog.assetKnown = store.railsPaying(addressForm).length > 0;
                            proposeDialog.peerLabel = label;
                            proposeDialog.rails = store.railsPaying(addressForm);
                            proposeDialog.memberCount = store.memberCount;
                            proposeDialog.open();
                        }
                        onApproveRequested: function (intentId) {
                            store.approveIntent(intentId);
                        }
                        onDropRequested: function (intentId) {
                            store.dropIntent(intentId, "");
                        }
                        onSubmitRequested: function (intentId) {
                            store.submitIntent(intentId);
                        }
                    }

                    // The two things that are attributes of *this* muster and of
                    // nothing else: who can see it, and what of the wallet it
                    // has put in play. Neither belongs on the home screen, where
                    // there is no conversation for them to be about — which is
                    // the argument for this column existing only here.
                    ColumnLayout {
                        Layout.fillWidth: false
                        Layout.preferredWidth: 300
                        Layout.fillHeight: true
                        spacing: Theme.spacing.medium

                        // "Who can see this" is still not a question you ask
                        // once — it is asked continuously, for as long as you
                        // are in the room it is about.
                        VisibilityPanel {
                            objectName: "visibilityPanel"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            step: store.journeyStep
                            trail: store.journeyTrail
                        }

                        MusterWalletStrip {
                            objectName: "musterWalletStrip"
                            Layout.fillWidth: true
                            Layout.minimumHeight: implicitHeight
                            assets: store.musterAssets
                            ready: store.walletReady
                            onWalletRequested: root.showWallet("muster")
                        }
                    }

                    ColumnLayout {
                        visible: root.selectedConversationId !== "" && (root.selectedIsGroup || root.detailsShown)
                        Layout.fillWidth: false
                        Layout.preferredWidth: 280
                        Layout.fillHeight: true
                        spacing: Theme.spacing.medium

                        DetailsPanel {
                            id: detailsPanel
                            visible: root.detailsShown
                            Layout.fillWidth: true
                            isGroup: root.selectedIsGroup
                            description: root.selectedDescription
                            conversationId: root.selectedConversationId
                            peerAddress: store.currentPeerAddress
                            memberCount: store.memberCount
                            pendingMemberCount: store.pendingMemberCount
                            onCloseRequested: root.detailsShown = false
                        }

                        MembersPane {
                            visible: root.selectedIsGroup
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            memberModel: store.memberModel
                            memberCount: store.memberCount
                            online: store.online
                            ready: root.selectionLoaded
                            onAddMemberRequested: addMemberDialog.open()
                        }
                    }
                }
            }

            // ── wallet ───────────────────────────────────────────────────
            // The detour, off either of the other two. Held to a column width
            // rather than stretched: it is a page to read, and a rail's promise
            // set on one line across a wide window is a line nobody reads.
            ColumnLayout {
                spacing: Theme.spacing.small

                BackBar {
                    Layout.fillWidth: true
                    label: root.walletReturnRoute === "muster" && root.selectedDisplayName !== ""
                        ? root.selectedDisplayName : qsTr("Home")
                    title: qsTr("Wallet")
                    waitingCount: store.needsYouExcept(
                        root.walletReturnRoute === "muster" ? root.selectedConversationId : "")
                    onBackRequested: root.route = root.walletReturnRoute
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0

                    Item { Layout.fillWidth: true }

                    WalletPane {
                        objectName: "walletPane"
                        Layout.preferredWidth: 720
                        Layout.maximumWidth: 720
                        Layout.fillHeight: true
                        ready: store.walletReady
                        busy: store.walletBusy
                        stage: store.walletStage
                        statusLabel: store.walletLabel
                        assets: store.assets
                        rails: store.rails
                        receivedElsewhere: store.receivedElsewhere
                        errorText: store.walletError
                        onOpenRequested: store.openWallet()
                        onFundRequested: store.fundWallet()
                        onRefreshRequested: store.refreshBalances()
                        onClaimRequested: function (assetId) {
                            store.claimHolding(assetId, "");
                        }
                    }

                    Item { Layout.fillWidth: true }
                }
            }
        }

        // Below the stack, on every screen. A job that only exists while you
        // are looking at the room that started it is a job you cannot leave
        // running, and leaving it running is the entire reason it is a job.
        JobStrip {
            objectName: "jobStrip"
            Layout.fillWidth: true
            Layout.minimumHeight: implicitHeight
            job: store.walletJob
            stage: store.walletStage
            context: root.jobConversationName
            onContextRequested: {
                if (root.jobConversationId === "")
                    return;
                store.selectConversation(root.jobConversationId);
                root.route = "muster";
            }
        }

        StatusBar {
            Layout.fillWidth: true
            errorMessage: root.lastError
            errorCount: root.unseenErrorCount
            onErrorActivated: root.showLogs()
            onLogsRequested: root.showLogs()
        }
    }

    // Opening the wallet remembers where from, so closing it is a return rather
    // than a reset to home.
    function showWallet(from) {
        root.walletReturnRoute = from;
        root.route = "wallet";
    }

    // Opening the logs is what marks the held failures seen: the strip goes
    // quiet, and nothing is discarded — the list is behind the button.
    function showLogs() {
        // The files rotate and get pruned while the app runs, so the list is
        // read at the moment it is shown.
        store.refreshLogRuns();
        root.lastError = "";
        root.unseenErrorCount = 0;
        sessionLogsDialog.open();
    }

    SessionLogsDialog {
        id: sessionLogsDialog
        errors: store.errors
        runs: store.logRuns
        logDir: store.logDir
    }

    // What you want to do, then who with, then which account — the order the
    // app is arguing for, rather than "one person or a group?".
    NewActivityDialog {
        id: newActivityDialog
        walletReady: store.walletReady
        assets: store.assets
        onActivityChosen: function (verb, peerAddress) {
            store.startActivity(verb, peerAddress);
        }
    }

    NewConversationDialog {
        id: newConvDialog
        onAddressEntered: function (address) {
            store.createConversation(address);
        }
    }

    NewGroupDialog {
        id: newGroupDialog
        onGroupDetailsEntered: function (name, description) {
            store.createGroup(name, description);
        }
    }

    // Answering "where do I pay you". The payee chooses which of their holdings
    // to advertise, because that choice decides what a payment to them can
    // hide — see ShareAddressDialog.
    ShareAddressDialog {
        id: shareAddressDialog
        assets: store.receivableAssets
        onConfirmed: function (assetId) {
            store.shareAddress(assetId);
        }
    }

    // Opened by the "Send" action on an address-share card; the recipient is
    // carried from that card, so this only asks for an amount and a rail.
    SendDialog {
        id: sendDialog
        onConfirmed: function (railId, amount) {
            store.sendPayment(railId, sendDialog.toAddress, amount);
        }
    }

    // The same card's other action: put the payment to the room first. Asks
    // for an amount, a rail, and how many people must agree before it can be
    // paid.
    ProposeDialog {
        id: proposeDialog
        onConfirmed: function (railId, amount, threshold) {
            store.proposePayment(railId, proposeDialog.toAddress, proposeDialog.peerLabel,
                                 amount, threshold);
        }
    }

    AddMemberDialog {
        id: addMemberDialog
        onAddressEntered: function (address) {
            // First member add: explain the async commit delay first, then invite.
            if (chatPrefs.memberAddExplained) {
                store.addMember(address);
            } else {
                memberAddInfoDialog.pendingAddress = address;
                memberAddInfoDialog.open();
            }
        }
    }

    MemberAddInfoDialog {
        id: memberAddInfoDialog
        // The address whose add opened the explainer, applied once confirmed.
        property string pendingAddress: ""
        onConfirmed: function (dontShowAgain) {
            if (dontShowAgain)
                chatPrefs.memberAddExplained = true;
            if (pendingAddress !== "")
                store.addMember(pendingAddress);
            pendingAddress = "";
        }
    }

    // Persisted UI preferences.
    Settings {
        id: chatPrefs
        category: "chat_ui"
        property bool memberAddExplained: false
    }
}
