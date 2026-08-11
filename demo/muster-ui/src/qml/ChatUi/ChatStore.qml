import QtQuick

// ChatBackend is host-registered at runtime and `logos` is host-injected; static
// analysis sees neither, so those import/unqualified warnings are disabled here.
// qmllint disable import unqualified
import Logos.ChatBackend 1.0

// The sole reader of the host `logos` context: resolves the backend and its
// models, exposes the view state as bindings, and wraps the actions. Everything
// else reads from here and stays standalone; tests pass a mock with this surface.
QtObject {
    id: root

    readonly property var backend: typeof logos !== "undefined" && logos ? logos.module("muster_ui") : null
    readonly property var conversationModel: typeof logos !== "undefined" && logos ? logos.model("muster_ui", "conversationModel") : null
    readonly property var messageModel: typeof logos !== "undefined" && logos ? logos.model("muster_ui", "messageModel") : null
    readonly property var memberModel: typeof logos !== "undefined" && logos ? logos.model("muster_ui", "memberModel") : null

    readonly property bool online: backend ? backend.chatStatus === ChatBackend.Online : false
    readonly property bool hasError: backend ? backend.chatStatus === ChatBackend.Error : false
    readonly property string currentConversationId: backend ? backend.currentConversationId : ""
    readonly property string loadedConversationId: backend ? backend.loadedConversationId : ""
    readonly property bool currentIsGroup: backend ? backend.currentIsGroup : false
    readonly property string currentDisplayName: backend ? backend.currentDisplayName : ""
    readonly property string currentDescription: backend ? backend.currentDescription : ""
    readonly property string currentAvatarInitials: backend ? backend.currentAvatarInitials : ""
    readonly property int currentAvatarRamp: backend ? backend.currentAvatarRamp : 0
    readonly property int memberCount: backend ? backend.memberCount : 0
    readonly property int pendingMemberCount: backend ? backend.pendingMemberCount : 0
    readonly property string currentPeerAddress: backend ? backend.currentPeerAddress : ""
    // This account's own address, empty until the backend is online, and its
    // short form.
    readonly property string myAddress: backend ? backend.myAddress : ""
    readonly property string myLabel: backend ? backend.myLabel : ""
    readonly property string myInitials: backend ? backend.myInitials : ""

    // ── journey ──────────────────────────────────────────────────────────
    // Where the open conversation has got to, and how it got there. Read off
    // the thread by the backend, so it always agrees with what is on screen.
    readonly property string journeyStep: backend ? backend.journeyStep : "discovery"
    readonly property var journeyTrail: backend ? backend.journeyTrail : []

    // The home surface: one row per conversation, ordered by what it wants
    // from you. This is what the app opens on.
    readonly property var actions: backend ? backend.actions : []

    // ── wallet ───────────────────────────────────────────────────────────
    // The execution-zone wallet this instance owns. Deliberately separate from
    // `online`: the conversation works whether or not the wallet ever opens.
    readonly property bool walletReady: backend ? backend.walletStatus === ChatBackend.WalletReady : false
    readonly property bool walletBusy: backend ? backend.walletBusy : false
    readonly property string walletStage: backend ? backend.walletStage : ""
    // The long-running thing in flight, or empty. The view times it from when
    // this becomes non-empty rather than from a backend clock, which keeps the
    // two processes from having to agree about time.
    readonly property string walletJob: backend ? backend.walletJob : ""

    // What this conversation is *for*, right now, as a headline.
    //
    // The app is about what you are doing before it is about who you are doing
    // it with, so this is what the thread names itself by. A job in flight wins
    // — it is the most present thing — otherwise it is read from how far the
    // journey has got, which is itself read off the thread.
    readonly property string currentAction: {
        if (walletJob !== "")
            return walletJob;
        switch (journeyStep) {
        case "address":
            return qsTr("Ready to pay");
        case "payment":
            return qsTr("Paid");
        case "conversation":
            return qsTr("Talking");
        default:
            return "";
        }
    }
    readonly property string walletError: backend ? backend.walletError : ""
    readonly property string privateBalance: backend ? backend.privateBalance : ""
    readonly property string publicBalance: backend ? backend.publicBalance : ""
    readonly property string myReceiveKeys: backend ? backend.myReceiveKeys : ""
    readonly property string newWalletMnemonic: backend ? backend.newWalletMnemonic : ""

    // What the wallet is doing, for the account card. The stage is the
    // backend's own word for it, so a long pause can name itself.
    readonly property string walletLabel: {
        if (!backend)
            return "";
        if (backend.walletBusy)
            return backend.walletStage !== "" ? backend.walletStage : qsTr("working...");
        switch (backend.walletStatus) {
        case ChatBackend.WalletClosed:
            return qsTr("No wallet");
        case ChatBackend.WalletOpening:
            return qsTr("Opening...");
        case ChatBackend.WalletReady:
            return qsTr("Ready");
        case ChatBackend.WalletError:
            return qsTr("Error");
        default:
            return "";
        }
    }

    function openWallet() {
        if (backend)
            backend.openWallet();
    }
    function fundWallet() {
        if (backend)
            backend.fundWallet();
    }
    function refreshBalances() {
        if (backend)
            backend.refreshBalances();
    }
    function requestAddress() {
        if (backend && currentConversationId !== "")
            backend.requestAddress(currentConversationId);
    }
    function shareAddress() {
        if (backend && currentConversationId !== "")
            backend.shareAddress(currentConversationId);
    }
    function sendPrivate(keysJson, amount) {
        if (backend && currentConversationId !== "")
            backend.sendPrivate(currentConversationId, keysJson, amount);
    }

    // The run's logs: every failure it reported, every run each writer kept, and
    // the directory they share.
    readonly property var errors: backend ? backend.errors : []
    readonly property var logRuns: backend ? backend.logRuns : []
    readonly property string logDir: backend ? backend.logDir : ""

    // Short connectivity label for the account card.
    readonly property string statusLabel: {
        if (!backend)
            return qsTr("No backend");
        switch (backend.chatStatus) {
        case ChatBackend.Stopped:
            return qsTr("Stopped");
        case ChatBackend.Initialising:
            return qsTr("Initialising...");
        case ChatBackend.Online:
            return qsTr("Online");
        case ChatBackend.Error:
            return qsTr("Error");
        default:
            return "";
        }
    }

    // Backend one-shot signals, relayed so the view never touches the backend
    // object directly.
    signal errorOccurred(string message)
    signal sendFailed(string conversationId, string content)

    // Actions. Discrete effects, so imperative here is appropriate.
    function selectConversation(conversationId) {
        if (backend)
            backend.selectConversation(conversationId);
    }
    function sendMessage(text) {
        if (backend && currentConversationId !== "")
            backend.sendMessage(currentConversationId, text);
    }
    function createConversation(address) {
        if (backend)
            backend.createConversation(address);
    }
    // What you want to do, who with — the account is implicit while there is
    // only one. The verb acts once the room exists.
    function startActivity(verb, address) {
        if (backend)
            backend.startActivity(verb, address);
    }
    function createGroup(name, description) {
        if (backend)
            backend.createGroupConversation(name, description);
    }
    function addMember(address) {
        if (backend && currentConversationId !== "")
            backend.addGroupMember(currentConversationId, address);
    }
    function refreshLogRuns() {
        if (backend)
            backend.refreshSessionLogs();
    }

    property Connections _backendSignals: Connections {
        target: root.backend
        function onError(message) {
            root.errorOccurred(message);
        }
        function onSendFailed(conversationId, content) {
            root.sendFailed(conversationId, content);
        }
    }
}
