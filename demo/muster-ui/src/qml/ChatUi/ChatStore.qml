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

    // How many conversations are waiting on the user, not counting the one
    // named. What the way out of a muster carries: navigation hid the home
    // list, so leaving has to say what leaving is for.
    function needsYouExcept(conversationId) {
        let n = 0;
        for (let i = 0; i < actions.length; ++i)
            if (actions[i].state === "needs-you"
                && actions[i].conversationId !== conversationId)
                n += 1;
        return n;
    }

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
    // See ChatBackend.rep. True once the balance includes an account this wallet
    // did not create, which is how received money always arrives here.
    readonly property bool receivedElsewhere: backend ? backend.receivedElsewhere : false
    readonly property string newWalletMnemonic: backend ? backend.newWalletMnemonic : ""

    // ── what this wallet holds, and how it can pay ───────────────────────
    // Both are catalogues published by the backend (see ChatBackend.rep). No
    // view branches on a particular asset: it reads what it needs off the row,
    // so a new entry in ChatBackendAssets.cpp appears here for free.
    readonly property var assets: backend ? backend.assets : []
    readonly property var rails: backend ? backend.rails : []

    // The holding a payment on `railId` draws on, or null. The dialogs ask this
    // rather than reaching for a private balance, which is what they used to do
    // when there was only one.
    function assetById(id) {
        for (let i = 0; i < assets.length; ++i)
            if (assets[i].id === id)
                return assets[i];
        return null;
    }
    function railById(id) {
        for (let i = 0; i < rails.length; ++i)
            if (rails[i].id === id)
                return rails[i];
        return null;
    }
    // Every rail that can pay an address of this form, most private first —
    // the order the catalogue declares them in. This is the whole of what a
    // picker needs to know, so a rail added there is offered here untouched.
    function railsPaying(form) {
        return rails.filter(r => Number(r.payTo) === Number(form));
    }
    // What a picker opens on: the most private rail that can pay this address.
    function defaultRailFor(form) {
        const candidates = railsPaying(form);
        return candidates.length > 0 ? candidates[0].id : "";
    }
    // ── this muster's slice of the wallet ────────────────────────────────
    // Which holdings the open conversation has put in play, folded off its
    // thread by the backend: [{id, why}].
    readonly property var conversationAssets: backend ? backend.conversationAssets : []
    // The same slice, joined to the live rows. The fold carries ids, not
    // numbers, so a balance shown inside a muster is the wallet's own figure
    // rather than a copy taken when the thread was last read — the two cannot
    // disagree, which they would if the backend published both.
    readonly property var musterAssets: {
        const out = [];
        for (let i = 0; i < conversationAssets.length; ++i) {
            const use = conversationAssets[i];
            const row = assetById(use.id);
            // A holding the fold named and the catalogue no longer has. Dropped
            // rather than drawn as a blank row: an id with no balance, address
            // or note is not a thing to show someone.
            if (!row)
                continue;
            out.push(Object.assign({}, row, {why: use.why}));
        }
        return out;
    }

    // The holdings worth being paid at. Drives the share-an-address choice.
    //
    // A holding that *has* an address but is blocked stays in the list, shown
    // and refused with its reason: dropping it would turn a stated wait into an
    // address that silently is not there, which is the same wait with none of
    // the explanation. A holding with no address at all is genuinely not a
    // choice, and is left out.
    readonly property var receivableAssets:
        assets.filter(a => a.canReceive || (a.blocked && a.address !== ""))

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
    function shareAddress(assetId) {
        if (backend && currentConversationId !== "")
            backend.shareAddress(currentConversationId, assetId);
    }
    function sendPayment(railId, toAddress, amount) {
        if (backend && currentConversationId !== "")
            backend.sendPayment(currentConversationId, railId, toAddress, amount);
    }
    function claimHolding(assetId, amount) {
        if (backend)
            backend.claimHolding(assetId, amount);
    }

    // ── proposals ────────────────────────────────────────────────────────
    // Every proposal in the open conversation, and the one it is currently
    // about. Both are folds over the thread, so they arrive with it rather
    // than being tracked here.
    readonly property var intents: backend ? backend.intents : []
    readonly property var liveIntent: backend ? backend.liveIntent : ({})

    function proposePayment(railId, toAddress, label, amount, threshold) {
        if (backend && currentConversationId !== "")
            backend.proposePayment(currentConversationId, railId, toAddress, label, amount,
                                   threshold);
    }
    function approveIntent(intentId) {
        if (backend && currentConversationId !== "")
            backend.approveIntent(currentConversationId, intentId);
    }
    function dropIntent(intentId, reason) {
        if (backend && currentConversationId !== "")
            backend.dropIntent(currentConversationId, intentId, reason);
    }
    function submitIntent(intentId) {
        if (backend && currentConversationId !== "")
            backend.submitIntent(currentConversationId, intentId);
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
