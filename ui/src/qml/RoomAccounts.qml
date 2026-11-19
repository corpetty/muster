import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's accounts (exo-a50.1.3): accounts live in the room, as disclosed by its
// members. An account exists here only once a named member discloses it into the log;
// each reader then checks the disclosure against the chain themselves — verified,
// disagrees (and what differs), or unknown (and why). Two members disclosing different
// signers or thresholds for one account is shown as a conflict, never merged.
//
// Pure-render: `accounts` is coordinate_accounts' array; the only outputs are the
// signals (disclose one, disclose the local test Safe describe() suggests, the LEZ and
// FROST requests). The one piece of state is which add-an-account form is open.
//
// Quiet by default (exo-dcc.30): a fresh room shows the heading, one line, and "Add an
// account". The four families' forms stay folded until a member picks one — or until the
// composer asks for an account no one has disclosed (`wantedFamilies`), when the matching
// form opens so the remedy is one step away. What the room already holds (the disclosed
// accounts, key ceremonies, a LEZ create in flight, any error) always shows. The forms are
// hidden, never destroyed, so every control keeps its objectName.
//
// NB (ADR-011): nix build does not evaluate QML; a stray type or Theme key blanks the
// view. Restricted to Theme keys + the Logos.Controls types the room proves.
Item {
    id: acc

    property var accounts: []
    property var discloseResult: ({})     // the last disclose's result ({error} or the account)
    property var lezMember: ({})          // this instance's LEZ member account ({base58, account, fresh} or {error})
    property var lezCreate: ({})          // the last LEZ multisig create ({address, tx, pending} or {error, detail})
    signal discloseRequested(string accountJson)
    signal discloseSuggested()
    property bool suggestionAvailable: true   // describe()'s test Safe can work here (exo-d4d.6)
    property string defaultChainId: "31337"   // where a Safe disclosure starts: describe()'s defaultChainId
    // where a Bitcoin form starts: the local regtest node in the developer runner (where the
    // local test Safe also works), a public test network in a real install (exo-132)
    readonly property string defaultBtcNetwork: acc.suggestionAvailable ? "regtest" : "signet"
    signal lezMemberRequested()
    signal lezCreateRequested(string threshold, string members)
    property var frostCeremonies: []      // the room's FROST key ceremonies (Phase D)
    property var frostCeremony: ({})      // the last open/join result ({ceremony, host} or {error})
    signal frostOpenRequested(string ceremonyId, string network, string t, string n)
    signal frostJoinRequested(string ceremonyId)
    // Monero multisig (ADR-020): each member's own wallet runs the setup and signs the spends
    property var xmrMsigSetups: []        // the room's setups [{ceremony, k, n, joined, address, disclosedBy, last, wallet, mine, joinedByMe}]
    property var xmrMsigSetup: ({})       // the last open/join result ({ceremony, ...} or {error, detail})
    property var xmrMsigPropose: ({})     // the last spend proposal ({intentId} or {error, detail})
    property bool xmrMsigWalletSet: false // whether this member's xmr-msig-rpc setting is set
    signal xmrMsigSetupRequested(string ceremonyId, string k, string membersJson)
    property var roomMembers: []          // the room's roster [{identity, self, alias}], for the setup's member picker
    property var xmrOut: ({})             // members left out of the next setup, by identity (exo-cdc)
    // the members the next setup names: you, and everyone not left out
    function xmrMembers() {
        var out = [];
        for (var i = 0; i < acc.roomMembers.length; ++i) {
            var m = acc.roomMembers[i];
            var id = String(m.identity || "");
            if (id.length > 0 && (m.self || !acc.xmrOut[id])) out.push(id);
        }
        return out;
    }
    signal xmrMsigJoinRequested(string ceremonyId)
    signal xmrMsigProposeRequested(string account, string recipientsJson, string feeCap, string memo)

    // lez-msig (exo-0d3): the room's creation ceremonies, the last open / propose results, and
    // the room's lez-msig account's state as its program holds it
    property var lezMsigCeremonies: []
    property var lezMsigOpen: ({})
    property var lezMsigPropose: ({})
    property var lezMsigFund: ({})
    property var lezMsigRecover: ({})
    property var lezMsigState: ({})
    signal lezMsigOpenRequested(string specJson)
    signal lezMsigProposeRequested(string account, string actionJson)
    signal lezMsigFundRequested(string account, string amount)
    signal lezMsigRecoverRequested(string account)

    // a member's own accounts, disclosed to the room (exo-1f9): anyone may pick one where an
    // account of that member is needed, e.g. as their approval key in a LEZ multisig
    property var memberAccounts: []
    property var discloseAccount: ({})
    property var msigPicks: ({})            // room identity -> the disclosed key picked for them
    signal discloseMyAccountRequested(string specJson)
    signal retractMyAccountRequested(string accountId)
    function bareId(s) {
        var h = String(s || "").toLowerCase();
        return h.indexOf("0x") === 0 ? h.slice(2) : h;
    }
    function lezAccountsOf(identity) {
        var out = [];
        for (var i = 0; i < acc.memberAccounts.length; ++i) {
            var a = acc.memberAccounts[i];
            if (a.kind === "lez-key" && acc.bareId(a.member) === acc.bareId(identity)) out.push(a);
        }
        return out;
    }
    function shortB58(s) {
        var t = String(s || "");
        return t.length > 14 ? t.slice(0, 6) + "…" + t.slice(-6) : t;
    }
    function msigSpec(isPrivate) {
        var spec = { threshold: Number(msigK.text.trim()), timelockMs: Number(msigLock.text.trim()) * 60000 };
        if (isPrivate) spec.private = true;
        if (Object.keys(acc.msigPicks).length > 0) spec.accounts = acc.msigPicks;
        return JSON.stringify(spec);
    }
    readonly property var msigAccount: {
        for (var i = 0; i < acc.accounts.length; ++i)
            if (acc.accounts[i] && acc.accounts[i].family === "lez.msig") return acc.accounts[i];
        return null;
    }
    // base units → LEZ as an exact decimal string (9 decimals), never through a float
    function lezText(base) {
        var t = String(base || "0").replace(/^0+(?=[0-9])/, "");
        if (!/^[0-9]+$/.test(t)) return "?";
        while (t.length < 10) t = "0" + t;
        var whole = t.slice(0, t.length - 9), frac = t.slice(t.length - 9).replace(/0+$/, "");
        return frac.length > 0 ? whole + "." + frac : whole;
    }
    // LEZ in base units (9 decimals), "" for anything else
    function lezBase(text) {
        var t = String(text || "").trim();
        if (!/^[0-9]+(\.[0-9]{0,9})?$/.test(t)) return "";
        var parts = t.split(".");
        var frac = ((parts[1] || "") + "000000000").slice(0, 9);
        var whole = String(parts[0]).replace(/^0+(?=[0-9])/, "");
        var out = (whole === "0" ? "" : whole) + frac;
        out = String(out).replace(/^0+/, "");
        return out.length > 0 ? out : "0";
    }
    // the room's Monero multisig account, if a member disclosed one (its CAIP-10 id is the account)
    readonly property var xmrAccount: {
        for (var i = 0; i < acc.accounts.length; ++i)
            if (acc.accounts[i] && String(acc.accounts[i].family || "") === "monero.multisig-coordinated")
                return acc.accounts[i];
        return null;
    }
    readonly property bool xmrWalletMissing: {
        if (!acc.xmrMsigWalletSet) return true;
        for (var i = 0; i < acc.xmrMsigSetups.length; ++i)
            if (acc.xmrMsigSetups[i] && acc.xmrMsigSetups[i].wallet === false) return true;
        return false;
    }
    // XMR → atomic units (12 decimals) by string arithmetic, never a float: digits with at
    // most one point and at most 12 decimals; "" when it is not such an amount.
    function xmrAtomic(text) {
        var t = String(text || "").trim();
        if (!/^[0-9]+(\.[0-9]{0,12})?$/.test(t)) return "";
        var parts = t.split(".");
        var frac = parts.length > 1 ? parts[1] : "";
        while (frac.length < 12) frac += "0";
        var s = String(parts[0] + frac).replace(/^0+/, "");
        return s.length > 0 ? s : "0";
    }
    // the Bitcoin multisig form: which family, and each network's CAIP-2 chain id
    // (module/src/bitcoin/network.nim)
    property string btcFamily: "btc.p2wsh-sortedmulti"
    readonly property var btcChains: ({
        mainnet: "bip122:000000000019d6689c085ae165831e93",
        testnet: "bip122:000000000933ea01ad0ee984209779ba",
        testnet4: "bip122:00000000da84f2bafbbc53dee25a72ae",
        signet: "bip122:00000008819873e925422c1ff0f99f7c",
        regtest: "bip122:0f9188f13cb7b2c71f2a335e3a4fc328" })

    // Which add-an-account form is open: "" (folded), "chooser" (the four families, none
    // picked yet), or one family: "safe" | "btc" | "frost" | "lez".
    property string openForm: ""
    // A form (or the chooser) just opened: the host may scroll it into view.
    signal formShown()
    onOpenFormChanged: if (acc.openForm.length > 0) acc.formShown()
    // The account families the composer needs and the room lacks (its no-account refusal);
    // a non-empty list opens the matching form. Room.qml binds it.
    property var wantedFamilies: []
    onWantedFamiliesChanged: if (acc.wantedFamilies && acc.wantedFamilies.length > 0)
                                 acc.expandForFamilies(acc.wantedFamilies)

    implicitHeight: col.implicitHeight

    // An account family (kinds.nim accountFamilies) → the form that discloses it.
    function formForFamily(f) {
        f = String(f || "");
        if (f === "evm.safe") return "safe";
        if (f === "monero.multisig-coordinated") return "xmr";
        if (f.indexOf("frost") >= 0) return "frost";
        if (f === "btc.p2wsh-sortedmulti" || f === "btc.tapscript-multi-a") return "btc";
        if (f === "lez.multisig-program") return "lez";
        if (f === "lez.msig") return "msig";
        return "";
    }
    function formTitle(form) {
        return form === "safe" ? qsTr("Disclose a Safe")
             : form === "btc" ? qsTr("Disclose a Bitcoin multisig")
             : form === "frost" ? qsTr("Make a key in a FROST ceremony")
             : form === "lez" ? qsTr("Create or disclose a LEZ multisig")
             : form === "xmr" ? qsTr("Set up a Monero multisig")
             : form === "msig" ? qsTr("Create a LEZ multisig (approvals in the room)")
             : qsTr("Add an account");
    }
    function expandForFamilies(fams) {
        for (var i = 0; i < fams.length; ++i) {
            var form = acc.formForFamily(fams[i]);
            if (form.length === 0) continue;
            if (form === "btc") acc.btcFamily = String(fams[i]);
            acc.openForm = form;
            return;
        }
    }

    function checkColor(st) {
        return st === "verified" ? Theme.palette.success
             : st === "disagrees" ? Theme.palette.error
             : Theme.palette.textTertiary;
    }
    function checkLabel(st) {
        return st === "verified" ? qsTr("the chain agrees")
             : st === "disagrees" ? qsTr("the chain disagrees")
             : qsTr("couldn't check");
    }
    function shortAddr(a) { a = String(a || ""); return a.length > 14 ? a.slice(0, 8) + "…" + a.slice(-4) : a; }
    function discloserNames(a) {
        var names = [];
        var al = a.disclosedByAlias || [];
        var ids = a.disclosedBy || [];
        for (var i = 0; i < ids.length; ++i) {
            var n = al[i] ? String(al[i]) : "";
            names.push(n.length > 0 ? n : acc.shortAddr(ids[i]));
        }
        return names.join(", ");
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.spacing.small

        LogosText {
            text: qsTr("Accounts")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            visible: acc.accounts.length === 0
            text: qsTr("No shared accounts yet")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.caption
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: acc.accounts
            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 5
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        radius: 4
                        color: acc.checkColor(modelData.check ? modelData.check.status : "")
                    }
                    LogosText {
                        Layout.fillWidth: true
                        text: (modelData.label ? String(modelData.label) : acc.shortAddr(modelData.address))
                              + " · " + qsTr("%1 of %2").arg(modelData.threshold).arg((modelData.signers || []).length)
                        color: Theme.palette.text
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: Theme.typography.weightMedium
                        wrapMode: Text.WordWrap
                    }
                }
                LogosText {
                    Layout.fillWidth: true
                    text: String(modelData.family || "") + " · " + String(modelData.chain || "") + " · " + acc.shortAddr(modelData.address)
                    color: Theme.palette.textTertiary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WrapAnywhere
                }
                // The whole address, selectable and copyable — funding an account (a Bitcoin
                // FROST key on regtest, a LEZ vault) needs it in full, not shortened.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    visible: String(modelData.address || "").length > 0
                    TextEdit {
                        id: fullAddr
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        text: String(modelData.address || "")
                        color: Theme.palette.textSecondary
                        selectionColor: Theme.palette.primary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                    ActionButton {
                        objectName: "copyAccountAddress"
                        text: qsTr("Copy address")
                        variant: LogosButton.Variant.Secondary
                        onClicked: { fullAddr.selectAll(); fullAddr.copy(); fullAddr.deselect(); }
                    }
                }
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("disclosed by %1").arg(acc.discloserNames(modelData))
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                LogosText {
                    Layout.fillWidth: true
                    text: acc.checkLabel(modelData.check ? modelData.check.status : "")
                          + (modelData.check && modelData.check.detail ? " — " + String(modelData.check.detail) : "")
                    color: modelData.check && modelData.check.status === "disagrees" ? Theme.palette.error : Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                LogosText {
                    Layout.fillWidth: true
                    visible: modelData.conflict === true
                    text: qsTr("Members disclosed different signers or thresholds for this account. The first disclosure governs until they agree.")
                    color: Theme.palette.warning
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── what the room already holds, shown whatever is folded ──
        // The FROST key ceremonies under way here (Phase D), each with Join while it has room.
        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            visible: acc.frostCeremonies.length > 0
            text: qsTr("Key ceremonies")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
        }
        Repeater {
            model: acc.frostCeremonies
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: modelData.address
                          ? qsTr("%1 · %2 of %3 · %4").arg(modelData.ceremony).arg(modelData.t).arg(modelData.n).arg(modelData.address)
                          : qsTr("%1 · %2 of %3 · %4 joined · step 1 %5/%3 · step 2 %6/%3%7")
                              .arg(modelData.ceremony).arg(modelData.t).arg(modelData.n).arg(modelData.joined)
                              .arg(modelData.step1).arg(modelData.step2)
                              .arg(modelData.last ? " · " + String(modelData.last) : "")
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }
                ActionButton {
                    visible: !modelData.participant && !modelData.address && Number(modelData.joined) < Number(modelData.n)
                    text: qsTr("Join")
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.frostJoinRequested(String(modelData.ceremony))
                }
            }
        }
        LogosText {
            Layout.fillWidth: true
            visible: !!(acc.frostCeremony && acc.frostCeremony.error)
            text: acc.frostCeremony && acc.frostCeremony.error
                  ? "⚠ " + String(acc.frostCeremony.error) + (acc.frostCeremony.detail ? " — " + String(acc.frostCeremony.detail) : "")
                  : ""
            color: Theme.palette.error
            font.pixelSize: MusterStyle.caption
            wrapMode: Text.WordWrap
        }
        // A LEZ multisig sent to the chain, disclosed here once a block includes it.
        LogosText {
            objectName: "lezCreateResult"
            Layout.fillWidth: true
            visible: !!(acc.lezCreate && (acc.lezCreate.error || acc.lezCreate.address))
            wrapMode: Text.WordWrap
            text: acc.lezCreate && acc.lezCreate.error
                  ? "⚠ " + String(acc.lezCreate.error) + (acc.lezCreate.detail ? " — " + String(acc.lezCreate.detail) : "")
                  : qsTr("⏳ Sent to %1 (tx %2…) — it is disclosed here once a block includes it.")
                        .arg(String((acc.lezCreate && acc.lezCreate.chain) || ""))
                        .arg(String((acc.lezCreate && acc.lezCreate.tx) || "").slice(0, 12))
            color: acc.lezCreate && acc.lezCreate.error ? Theme.palette.error : Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
        }
        LogosText {
            Layout.fillWidth: true
            visible: acc.discloseResult && acc.discloseResult.error !== undefined
            text: acc.discloseResult && acc.discloseResult.error
                  ? String(acc.discloseResult.error) + (acc.discloseResult.detail ? " — " + String(acc.discloseResult.detail) : "")
                  : ""
            color: Theme.palette.error
            font.pixelSize: MusterStyle.caption
            wrapMode: Text.WordWrap
        }

        // ── add an account: one button, then a family, then only that family's form ──
        RowLayout {      // visibility on a wrapper: a LogosButton's own did not take in Basecamp
            Layout.fillWidth: true
            visible: acc.openForm === ""
            ActionButton {
                objectName: "addAccountButton"
                Layout.fillWidth: true
                text: qsTr("Add an account")
                variant: LogosButton.Variant.Secondary
                onClicked: acc.openForm = "chooser"
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: acc.openForm !== ""
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                LogosText {
                    objectName: "addAccountTitle"
                    Layout.fillWidth: true
                    text: acc.formTitle(acc.openForm)
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                    wrapMode: Text.WordWrap
                }
                ActionButton {
                    objectName: "addAccountClose"
                    Layout.preferredWidth: 90
                    text: qsTr("Close")
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.openForm = ""
                }
            }
            LogosText {
                Layout.fillWidth: true
                visible: acc.openForm === "chooser"
                text: qsTr("An account is shared here once a member discloses it. Every member checks it against the chain.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }
            // The four families, until one is picked; then only its form shows (Close
            // folds it, and Add an account offers the four again).
            GridLayout {
                Layout.fillWidth: true
                visible: acc.openForm === "chooser"
                columns: 2
                columnSpacing: Theme.spacing.small
                rowSpacing: Theme.spacing.small
                ActionButton {
                    objectName: "addAccountSafe"
                    Layout.fillWidth: true
                    text: qsTr("Safe")
                    variant: acc.openForm === "safe" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "safe"
                }
                ActionButton {
                    objectName: "addAccountBtc"
                    Layout.fillWidth: true
                    text: qsTr("Bitcoin multisig")
                    variant: acc.openForm === "btc" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "btc"
                }
                ActionButton {
                    objectName: "addAccountFrost"
                    Layout.fillWidth: true
                    text: qsTr("FROST key ceremony")
                    variant: acc.openForm === "frost" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "frost"
                }
                ActionButton {
                    objectName: "addAccountLez"
                    Layout.fillWidth: true
                    text: qsTr("LEZ multisig")
                    variant: acc.openForm === "lez" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "lez"
                }
                ActionButton {
                    objectName: "addAccountMsig"
                    Layout.fillWidth: true
                    text: qsTr("LEZ multisig (approvals in the room)")
                    variant: acc.openForm === "msig" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "msig"
                }
                ActionButton {
                    objectName: "addAccountXmr"
                    Layout.fillWidth: true
                    text: qsTr("Monero multisig")
                    variant: acc.openForm === "xmr" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.openForm = "xmr"
                }
            }
        }

        // ── a Safe: the local test Safe (one click on anvil), or any Safe by chain + address ──
        ColumnLayout {
            Layout.fillWidth: true
            visible: acc.openForm === "safe"
            spacing: Theme.spacing.small

            RowLayout {      // visibility on a wrapper: a LogosButton's own did not take in Basecamp
                Layout.fillWidth: true
                visible: acc.suggestionAvailable
                ActionButton {
                    objectName: "discloseSuggestedSafe"
                    Layout.fillWidth: true
                    text: qsTr("Disclose the local test Safe")
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.discloseSuggested()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: chainField
                    objectName: "discloseChain"
                    Layout.preferredWidth: 80
                    placeholderText: qsTr("chain id")
                    text: acc.defaultChainId
                }
                LogosTextField {
                    id: addrField
                    objectName: "discloseAddress"
                    Layout.fillWidth: true
                    placeholderText: qsTr("Safe address 0x…")
                }
            }
            ActionButton {
                objectName: "discloseSafe"
                Layout.fillWidth: true
                enabled: addrField.text.trim().length === 42 && chainField.text.trim().length > 0
                text: qsTr("Disclose this Safe")
                variant: LogosButton.Variant.Secondary
                onClicked: acc.discloseRequested(JSON.stringify({
                    family: "evm.safe", chain: "eip155:" + chainField.text.trim(),
                    address: addrField.text.trim(), label: "" }))
            }
        }

        // ── a Bitcoin multisig (exo-a50.2 families; this form, exo-59c) ──
        // k of n members' compressed keys (each finds theirs in Settings → YOUR BITCOIN KEY).
        // The address is derived from the keys, so nothing here is taken on trust: every
        // member re-derives it, and the module refuses a key list that doesn't parse.
        ColumnLayout {
            Layout.fillWidth: true
            visible: acc.openForm === "btc"
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                ActionButton {
                    objectName: "btcFamilyP2wsh"
                    text: qsTr("P2WSH")
                    variant: acc.btcFamily === "btc.p2wsh-sortedmulti" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.btcFamily = "btc.p2wsh-sortedmulti"
                }
                ActionButton {
                    objectName: "btcFamilyTaproot"
                    text: qsTr("Taproot")
                    variant: acc.btcFamily === "btc.tapscript-multi-a" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                    onClicked: acc.btcFamily = "btc.tapscript-multi-a"
                }
                LogosTextField {
                    id: btcK
                    objectName: "btcThreshold"
                    Layout.preferredWidth: 44
                    placeholderText: qsTr("k")
                    text: "2"
                }
                LogosTextField {
                    id: btcNet
                    objectName: "btcNetwork"
                    Layout.fillWidth: true
                    placeholderText: qsTr("network")
                    text: acc.defaultBtcNetwork
                }
            }
            LogosTextField {
                id: btcKeys
                objectName: "btcKeys"
                Layout.fillWidth: true
                placeholderText: qsTr("members' Bitcoin keys (66 hex each), comma-separated")
            }
            ActionButton {
                objectName: "discloseBtc"
                Layout.fillWidth: true
                readonly property var keys: btcKeys.text.split(",").map(function (k) { return k.trim().replace(/^0x/i, ""); })
                                                        .filter(function (k) { return k.length > 0; })
                enabled: keys.length >= 1 && Number(btcK.text) >= 1 && Number(btcK.text) <= keys.length
                         && acc.btcChains[btcNet.text.trim()] !== undefined
                text: qsTr("Disclose this Bitcoin multisig")
                variant: LogosButton.Variant.Secondary
                onClicked: acc.discloseRequested(JSON.stringify({
                    family: acc.btcFamily, chain: acc.btcChains[btcNet.text.trim()],
                    signers: keys, threshold: Number(btcK.text), label: "" }))
            }
        }

        // ── a FROST key ceremony (Phase D) ──
        // The room is the ceremony's coordinator. Each participant's part runs on the room's
        // tick, and the t-of-n taproot account is disclosed here when it completes. To the
        // chain it will look like one key: one signature, no policy.
        ColumnLayout {
            Layout.fillWidth: true
            visible: acc.openForm === "frost"
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                text: qsTr("One key the room holds together, t of n. The chain sees one signature, and nothing of who signed.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: frostCid
                    objectName: "frostCeremonyId"
                    Layout.fillWidth: true
                    placeholderText: qsTr("a name for the key")
                }
                LogosTextField {
                    id: frostT
                    objectName: "frostT"
                    Layout.preferredWidth: 50
                    placeholderText: qsTr("t")
                    text: "2"
                }
                LogosTextField {
                    id: frostN
                    objectName: "frostN"
                    Layout.preferredWidth: 50
                    placeholderText: qsTr("n")
                    text: "3"
                }
            }
            LogosTextField {
                id: frostNet
                objectName: "frostNetwork"
                Layout.fillWidth: true
                placeholderText: qsTr("network")
                text: acc.defaultBtcNetwork
            }
            ActionButton {
                objectName: "frostOpen"
                Layout.fillWidth: true
                enabled: frostCid.text.trim().length > 0
                text: qsTr("Open the ceremony and join it")
                variant: LogosButton.Variant.Secondary
                onClicked: acc.frostOpenRequested(frostCid.text.trim(), frostNet.text.trim(), frostT.text.trim(), frostN.text.trim())
            }
        }

        // ── a Monero multisig (ADR-020, exo-dcc.34) ──
        // Each member's OWN monero-wallet-rpc holds the key and does the multisig; the room
        // carries its messages in order, and Muster holds no Monero key. Shown while the form is
        // open, or once the room has a setup or an account (a spend is sent from here).
        ColumnLayout {
            objectName: "xmrMsigSection"
            Layout.fillWidth: true
            visible: acc.openForm === "xmr" || acc.xmrMsigSetups.length > 0 || acc.xmrAccount !== null
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.small
                text: qsTr("Monero multisig (your own wallet)")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            ColumnLayout {
                objectName: "xmrMsigWarning"
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                Repeater {
                    model: [
                        qsTr("Your own Monero wallet holds the key, outside Basecamp."),
                        qsTr("Monero multisig is experimental upstream: a dishonest member could take the funds. Stagenet only."),
                        qsTr("One spend at a time, about 20 minutes each (10 blocks)."),
                        qsTr("Built before FCMP++: the wallet will need re-creating after Monero's upgrade.")
                    ]
                    delegate: LogosText {
                        required property var modelData
                        Layout.fillWidth: true
                        text: "• " + String(modelData)
                        color: Theme.palette.warning
                        font.pixelSize: MusterStyle.caption
                        wrapMode: Text.WordWrap
                    }
                }
            }
            LogosText {
                objectName: "xmrMsigNoWallet"
                Layout.fillWidth: true
                visible: acc.xmrWalletMissing
                text: qsTr("Set your Monero multisig wallet in Settings first.")
                color: Theme.palette.error
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }

            // the setup form, while it is the open one
            ColumnLayout {
                Layout.fillWidth: true
                visible: acc.openForm === "xmr"
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Who takes part, and how many must sign? Each must join from their own wallet; one who never joins holds the setup up.")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                    wrapMode: Text.WordWrap
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    Repeater {
                        model: acc.roomMembers
                        delegate: ActionButton {
                            required property var modelData
                            readonly property string ident: String(modelData.identity || "")
                            objectName: "xmrMsigWho_" + ident.slice(0, 8)
                            text: modelData.self ? qsTr("You")
                                  : (modelData.alias && String(modelData.alias).length > 0)
                                  ? String(modelData.alias) : ident.slice(0, 10) + "…"
                            enabled: !modelData.self            // the one who sets it up takes part
                            variant: (modelData.self || !acc.xmrOut[ident]) ? LogosButton.Variant.Primary
                                                                             : LogosButton.Variant.Secondary
                            onClicked: {
                                var o = Object.assign({}, acc.xmrOut);
                                if (o[ident]) delete o[ident]; else o[ident] = true;
                                acc.xmrOut = o;
                            }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: xmrK
                        objectName: "xmrMsigK"
                        Layout.preferredWidth: 60
                        placeholderText: qsTr("M")
                        text: "2"
                    }
                    ActionButton {
                        objectName: "xmrMsigSetupOpen"
                        Layout.fillWidth: true
                        // M of N with 2 <= M <= N and at least two members (the module refuses the rest)
                        enabled: /^[0-9]+$/.test(xmrK.text.trim()) && Number(xmrK.text.trim()) >= 2
                                 && Number(xmrK.text.trim()) <= acc.xmrMembers().length
                        text: acc.xmrMembers().length < 2
                              ? qsTr("A multisig needs at least two members")
                              : qsTr("Set up a %1-of-%2 Monero multisig").arg(xmrK.text.trim()).arg(acc.xmrMembers().length)
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.xmrMsigSetupRequested("xmr-" + Date.now(), xmrK.text.trim(),
                                                             JSON.stringify(acc.xmrMembers()))
                    }
                }
            }

            // the room's setups
            Repeater {
                model: acc.xmrMsigSetups
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("%1 of %2 · joined %3 of %2").arg(modelData.k).arg(modelData.n)
                                  .arg((modelData.joined || []).length)
                            color: Theme.palette.textSecondary
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.caption
                        }
                        ActionButton {
                            objectName: "xmrMsigJoin"
                            visible: modelData.mine === true && modelData.joinedByMe !== true
                            text: qsTr("Join")
                            variant: LogosButton.Variant.Secondary
                            onClicked: acc.xmrMsigJoinRequested(String(modelData.ceremony))
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: String(modelData.address || "").length > 0
                        wrapMode: Text.WrapAnywhere
                        text: qsTr("%1 · disclosed by %2 of %3").arg(String(modelData.address || ""))
                              .arg((modelData.disclosedBy || []).length).arg(modelData.n)
                        color: Theme.palette.textSecondary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: String(modelData.last || "").length > 0
                        wrapMode: Text.WordWrap
                        text: String(modelData.last || "")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }
            LogosText {
                objectName: "xmrMsigSetupResult"
                Layout.fillWidth: true
                visible: !!(acc.xmrMsigSetup && acc.xmrMsigSetup.error)
                text: acc.xmrMsigSetup && acc.xmrMsigSetup.error
                      ? "⚠ " + String(acc.xmrMsigSetup.error) + (acc.xmrMsigSetup.detail ? " — " + String(acc.xmrMsigSetup.detail) : "")
                      : ""
                color: Theme.palette.error
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }

            // a spend from the multisig, once the room has its account
            ColumnLayout {
                objectName: "xmrMsigSendForm"
                Layout.fillWidth: true
                visible: acc.xmrAccount !== null
                spacing: Theme.spacing.small
                readonly property string amountAtomic: acc.xmrAtomic(xmrSendAmount.text)
                readonly property string feeAtomic: acc.xmrAtomic(xmrSendFee.text)

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Send from the multisig")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                    wrapMode: Text.WordWrap
                }
                LogosTextField {
                    id: xmrSendAddress
                    objectName: "xmrMsigSendAddress"
                    Layout.fillWidth: true
                    placeholderText: qsTr("recipient's Monero address")
                    font.family: MusterStyle.mono
                }
                LogosText {
                    Layout.fillWidth: true
                    // the fee cap is prefilled, so its placeholder never shows: say what each field is
                    text: qsTr("Amount, then the most the network fee may be (both in XMR)")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: xmrSendAmount
                        objectName: "xmrMsigSendAmount"
                        Layout.fillWidth: true
                        placeholderText: qsTr("amount, in XMR")
                    }
                    LogosTextField {
                        id: xmrSendFee
                        objectName: "xmrMsigSendFeeCap"
                        Layout.fillWidth: true
                        placeholderText: qsTr("fee cap, in XMR")
                        text: "0.001"
                    }
                }
                LogosTextField {
                    id: xmrSendMemo
                    objectName: "xmrMsigSendMemo"
                    Layout.fillWidth: true
                    placeholderText: qsTr("a note for the room (optional)")
                }
                LogosText {
                    Layout.fillWidth: true
                    visible: (xmrSendAmount.text.length > 0 && parent.amountAtomic === "")
                             || (xmrSendFee.text.length > 0 && parent.feeAtomic === "")
                    text: qsTr("Amounts are plain numbers in XMR, with at most 12 decimals.")
                    color: Theme.palette.warning
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                ActionButton {
                    objectName: "xmrMsigSend"
                    Layout.fillWidth: true
                    enabled: xmrSendAddress.text.trim().length > 0 && parent.amountAtomic !== ""
                             && parent.amountAtomic !== "0" && parent.feeAtomic !== ""
                    text: qsTr("Propose this spend")
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.xmrMsigProposeRequested(
                        acc.xmrAccount ? String(acc.xmrAccount.id || "") : "",
                        JSON.stringify([{ address: xmrSendAddress.text.trim(), amount: parent.amountAtomic }]),
                        parent.feeAtomic, xmrSendMemo.text)
                }
                LogosText {
                    objectName: "xmrMsigProposeResult"
                    Layout.fillWidth: true
                    visible: !!(acc.xmrMsigPropose && (acc.xmrMsigPropose.error || acc.xmrMsigPropose.intentId))
                    text: acc.xmrMsigPropose && acc.xmrMsigPropose.error
                          ? "⚠ " + String(acc.xmrMsigPropose.error) + (acc.xmrMsigPropose.detail ? " — " + String(acc.xmrMsigPropose.detail) : "")
                          : qsTr("Proposed to the room. The members approve it on its card.")
                    color: acc.xmrMsigPropose && acc.xmrMsigPropose.error ? Theme.palette.error : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── accounts members disclosed (exo-1f9) ──
        ColumnLayout {
            objectName: "memberAccountsSection"
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.small
                text: qsTr("Members' own accounts")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Share an account of your own with this room, and anyone here can use it where an account of yours is needed, for example as your approval key when setting up a LEZ multisig. Only this room sees it, until a public multisig that uses it puts it on chain; using one account in several multisigs links them there.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }
            Repeater {
                model: acc.memberAccounts
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        objectName: "memberAccount"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0          // the row's width is the column's, never the text's
                        wrapMode: Text.WordWrap
                        text: (modelData.mine ? qsTr("You") : String(modelData.memberName || acc.bareId(modelData.member).slice(0, 10)))
                              + " · " + (String(modelData.name || "").length > 0 ? String(modelData.name) + " · " : "")
                              + qsTr("LEZ account %1").arg(acc.shortB58(modelData.base58))
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.caption
                    }
                    ActionButton {
                        objectName: "memberAccountRetract"
                        visible: modelData.mine === true
                        text: qsTr("Stop sharing")
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.retractMyAccountRequested(String(modelData.id))
                    }
                }
            }
            LogosText {
                Layout.fillWidth: true
                visible: acc.memberAccounts.length === 0
                text: qsTr("No one has shared an account of their own yet.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            LogosTextField {
                id: accountName
                objectName: "memberAccountName"
                Layout.fillWidth: true
                placeholderText: qsTr("a name for it (optional)")
            }
            // a Flow, not a row: the panel is narrow, and a row's width would widen the column
            Flow {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                ActionButton {
                    objectName: "memberAccountShareNew"
                    text: qsTr("Share a new LEZ account")
                    variant: LogosButton.Variant.Secondary
                    onClicked: { acc.discloseMyAccountRequested(JSON.stringify({ which: "new", name: accountName.text.trim() })); accountName.text = ""; }
                }
                ActionButton {
                    objectName: "memberAccountSharePayer"
                    text: qsTr("Share my paying account")
                    variant: LogosButton.Variant.Secondary
                    onClicked: { acc.discloseMyAccountRequested(JSON.stringify({ which: "payer", name: accountName.text.trim() })); accountName.text = ""; }
                }
            }
            LogosText {
                objectName: "memberAccountResult"
                Layout.fillWidth: true
                visible: !!(acc.discloseAccount && acc.discloseAccount.error)
                text: acc.discloseAccount && acc.discloseAccount.error
                      ? "⚠ " + String(acc.discloseAccount.error) + (acc.discloseAccount.detail ? " — " + String(acc.discloseAccount.detail) : "")
                      : ""
                color: Theme.palette.error
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }
        }

        // ── lez-msig (exo-0d3, docs/design/lez-msig.md) ──
        // Members approve in the room with a key of their own for this multisig; one
        // transaction carries the proposal and its approvals, and the program checks them.
        // Shown while the form is open, or once the room has a ceremony or an account.
        ColumnLayout {
            objectName: "msigSection"
            Layout.fillWidth: true
            visible: acc.openForm === "msig" || acc.lezMsigCeremonies.length > 0 || acc.msigAccount !== null
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.small
                text: qsTr("LEZ multisig (approvals in the room)")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Approving costs nothing and names no one on chain until it runs. One transaction then carries the proposal and every approval, and the program checks them. The members, the threshold and, when it runs, who approved are public on the chain.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }

            // the creation form, while it is the open one
            ColumnLayout {
                Layout.fillWidth: true
                visible: acc.openForm === "msig"
                spacing: Theme.spacing.small
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Every member of this room takes part, each with a new key for this multisig unless you pick an account they shared below. How many must approve, and how long must an approved action wait?")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: msigK
                        objectName: "msigK"
                        Layout.preferredWidth: 60
                        placeholderText: qsTr("M")
                        text: "2"
                    }
                    LogosTextField {
                        id: msigLock
                        objectName: "msigTimelockMinutes"
                        Layout.preferredWidth: 140
                        placeholderText: qsTr("time lock, minutes")
                        text: "0"
                    }
                }
                // each member's approval key: a new one, or an account they shared (exo-1f9)
                Repeater {
                    model: acc.roomMembers
                    delegate: ColumnLayout {
                        id: pickRow
                        required property var modelData
                        readonly property string ident: acc.bareId(modelData.identity)
                        readonly property var shared: acc.lezAccountsOf(ident)
                        Layout.fillWidth: true
                        visible: shared.length > 0
                        spacing: Theme.spacing.tiny
                        LogosText {
                            Layout.fillWidth: true
                            text: pickRow.modelData.self ? qsTr("Your approval key")
                                  : qsTr("%1's approval key").arg(pickRow.modelData.alias && String(pickRow.modelData.alias).length > 0
                                                                 ? String(pickRow.modelData.alias) : pickRow.ident.slice(0, 10) + "…")
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.tiny
                            ActionButton {
                                objectName: "msigPickNew_" + pickRow.ident.slice(0, 8)
                                text: qsTr("A new key for this multisig")
                                variant: acc.msigPicks[pickRow.ident] ? LogosButton.Variant.Secondary
                                                                            : LogosButton.Variant.Primary
                                onClicked: {
                                    var o = Object.assign({}, acc.msigPicks);
                                    delete o[pickRow.ident];
                                    acc.msigPicks = o;
                                }
                            }
                            Repeater {
                                model: pickRow.shared
                                delegate: ActionButton {
                                    required property var modelData
                                    objectName: "msigPick_" + String(modelData.id).slice(0, 8)
                                    text: (String(modelData.name || "").length > 0 ? String(modelData.name) + " · " : "")
                                          + acc.shortB58(modelData.base58)
                                    variant: acc.msigPicks[acc.bareId(modelData.member)] === String(modelData.key)
                                             ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                                    onClicked: {
                                        var o = Object.assign({}, acc.msigPicks);
                                        o[acc.bareId(modelData.member)] = String(modelData.key);
                                        acc.msigPicks = o;
                                    }
                                }
                            }
                        }
                    }
                }
                ActionButton {
                    id: msigOpenButton
                    objectName: "msigOpen"
                    Layout.fillWidth: true
                    readonly property int n: Math.max(acc.roomMembers.length, 1)
                    readonly property bool valid: /^[0-9]+$/.test(msigK.text.trim()) && Number(msigK.text.trim()) >= 1
                             && Number(msigK.text.trim()) <= n && /^[0-9]+$/.test(msigLock.text.trim())
                    enabled: valid
                    text: qsTr("Create a %1-of-%2 LEZ multisig").arg(msigK.text.trim()).arg(n)
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.lezMsigOpenRequested(acc.msigSpec(false))
                }
                // the private posture (exo-efa): the same rules over a private account
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Or keep it private: only the members can see it. The chain sees a proof, never who is in it or who approved. Its transactions are proved on this device, which takes a few minutes each.")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                ActionButton {
                    objectName: "msigOpenPrivate"
                    Layout.fillWidth: true
                    enabled: msigOpenButton.valid
                    text: qsTr("Create a private %1-of-%2 LEZ multisig").arg(msigK.text.trim()).arg(msigOpenButton.n)
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.lezMsigOpenRequested(acc.msigSpec(true))
                }
            }

            // the room's ceremonies
            Repeater {
                model: acc.lezMsigCeremonies
                delegate: LogosText {
                    required property var modelData
                    objectName: "msigCeremony"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    readonly property int joined: (modelData.members || []).filter(function (m) { return m.joined; }).length
                    text: (modelData.private ? qsTr("private") + " · " : "")
                          + qsTr("%1 of %2 · joined %3 of %2").arg(modelData.threshold).arg((modelData.members || []).length).arg(joined)
                          + (String(modelData.account || "").length > 0 ? "  ·  " + qsTr("created, disclosed")
                             : modelData.createSent ? "  ·  " + qsTr("creating on chain…")
                             : modelData.ready ? "  ·  " + qsTr("everyone joined; the opener creates it")
                             : "  ·  " + qsTr("waiting for members to join"))
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }
            }
            LogosText {
                objectName: "msigOpenResult"
                Layout.fillWidth: true
                visible: !!(acc.lezMsigOpen && acc.lezMsigOpen.error)
                text: acc.lezMsigOpen && acc.lezMsigOpen.error
                      ? "⚠ " + String(acc.lezMsigOpen.error) + (acc.lezMsigOpen.detail ? " — " + String(acc.lezMsigOpen.detail) : "")
                      : ""
                color: Theme.palette.error
                font.pixelSize: MusterStyle.caption
                wrapMode: Text.WordWrap
            }

            // the account, as its program holds it, and proposing from it
            ColumnLayout {
                id: msigBox
                objectName: "msigAccountBox"
                Layout.fillWidth: true
                visible: acc.msigAccount !== null
                spacing: Theme.spacing.small
                readonly property var st: acc.lezMsigState || ({})
                readonly property string payBase: acc.lezBase(msigPayAmount.text)

                LogosText {
                    objectName: "msigState"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: parent.st.error
                          ? (parent.st.error === "not-a-lez-msig-policy"
                             ? qsTr("Proposals from this room go elsewhere: propose from this multisig to read it.")
                             : "⚠ " + String(parent.st.error) + (parent.st.detail ? " — " + String(parent.st.detail) : ""))
                          : parent.st.epoch !== undefined
                          ? qsTr("Vault %1 LEZ  ·  %2 of %3  ·  settings v%4  ·  %5 queued").arg(acc.lezText(parent.st.balance))
                                .arg(parent.st.config ? parent.st.config.threshold : "?")
                                .arg(parent.st.config ? parent.st.config.members.length : "?")
                                .arg(parent.st.epoch).arg((parent.st.queue || []).length)
                            + (Number(parent.st.config && parent.st.config.timelockMs || 0) > 0
                               ? "  ·  " + qsTr("time lock %1 min").arg(Number(parent.st.config.timelockMs) / 60000) : "")
                          : qsTr("reading the multisig…")
                    color: parent.st.error && parent.st.error !== "not-a-lez-msig-policy" ? Theme.palette.error : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                }
                LogosText {
                    objectName: "msigPrivateNote"
                    Layout.fillWidth: true
                    visible: parent.st.private === true
                    text: qsTr("Private: only the members can read this. On chain each action is one proof, with no member, approval or settings in it; a payment to a public account shows that account and the amount.")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: parent.st.private === true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: msigFundAmount
                        objectName: "msigFundAmount"
                        Layout.fillWidth: true
                        placeholderText: qsTr("amount to put in, in LEZ")
                    }
                    ActionButton {
                        objectName: "msigFund"
                        readonly property string base: acc.lezBase(msigFundAmount.text)
                        enabled: base !== "" && base !== "0"
                        text: qsTr("Put in from my account")
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.lezMsigFundRequested(String(acc.msigAccount.id), base)
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: parent.st.private === true
                    spacing: Theme.spacing.small
                    LogosText {
                        objectName: "msigRecoverNote"
                        Layout.fillWidth: true
                        text: acc.lezMsigRecover && acc.lezMsigRecover.error
                              ? "⚠ " + String(acc.lezMsigRecover.error) + (acc.lezMsigRecover.detail ? " — " + String(acc.lezMsigRecover.detail) : "")
                              : acc.lezMsigRecover && acc.lezMsigRecover.job
                              ? qsTr("Reading the multisig from the chain on this device…")
                              : qsTr("Looks out of date? Each member shares the newest state after their transaction lands; if one did not, read it from the chain.")
                        color: acc.lezMsigRecover && acc.lezMsigRecover.error ? Theme.palette.error : Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                        wrapMode: Text.WordWrap
                    }
                    ActionButton {
                        objectName: "msigRecover"
                        text: qsTr("Read it from the chain")
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.lezMsigRecoverRequested(String(acc.msigAccount.id))
                    }
                }
                LogosText {
                    objectName: "msigFundResult"
                    Layout.fillWidth: true
                    visible: !!(acc.lezMsigFund && (acc.lezMsigFund.error || acc.lezMsigFund.job))
                    text: acc.lezMsigFund && acc.lezMsigFund.error
                          ? "⚠ " + String(acc.lezMsigFund.error) + (acc.lezMsigFund.detail ? " — " + String(acc.lezMsigFund.detail) : "")
                          : qsTr("Proving your deposit on this device; the vault shows it once the chain includes it.")
                    color: acc.lezMsigFund && acc.lezMsigFund.error ? Theme.palette.error : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Pay from the vault")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    font.weight: Theme.typography.weightMedium
                }
                LogosTextField {
                    id: msigPayTo
                    objectName: "msigPayTo"
                    Layout.fillWidth: true
                    placeholderText: qsTr("recipient's LEZ account (hex or base58)")
                    font.family: MusterStyle.mono
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: msigPayAmount
                        objectName: "msigPayAmount"
                        Layout.fillWidth: true
                        placeholderText: qsTr("amount, in LEZ")
                    }
                    ActionButton {
                        objectName: "msigProposePay"
                        enabled: msigPayTo.text.trim().length > 0 && msigBox.payBase !== "" && msigBox.payBase !== "0"
                        text: qsTr("Propose this payment")
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.lezMsigProposeRequested(String(acc.msigAccount.id),
                            JSON.stringify({ kind: "transfer", to: msigPayTo.text.trim(), amount: msigBox.payBase }))
                    }
                }
                // spending limits (exo-0d3.12): k of a limit's signers move up to its amount each
                // period with no vote and no time lock: the one bypass of the quorum
                Repeater {
                    model: (msigBox.st && msigBox.st.config && msigBox.st.config.limits) ? msigBox.st.config.limits : []
                    delegate: RowLayout {
                        required property var modelData
                        readonly property bool mine: (modelData.signers || []).indexOf(String(msigBox.st.myKey || "")) >= 0
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "msigLimit"
                            Layout.fillWidth: true
                            text: qsTr("Spending limit %1: %2 of %3 signers may spend up to %4 LEZ every %5 h, without a vote")
                                  .arg(modelData.id).arg(modelData.threshold).arg((modelData.signers || []).length)
                                  .arg(acc.lezText(modelData.amount)).arg(Number(modelData.periodMs) / 3600000)
                                  + (parent.mine ? "" : qsTr(" (you are not one of its signers)"))
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                            wrapMode: Text.WordWrap
                        }
                        ActionButton {
                            objectName: "msigSpend"
                            visible: parent.mine
                            enabled: msigPayTo.text.trim().length > 0 && msigBox.payBase !== "" && msigBox.payBase !== "0"
                            text: qsTr("Spend under limit %1").arg(modelData.id)
                            variant: LogosButton.Variant.Secondary
                            onClicked: acc.lezMsigProposeRequested(String(acc.msigAccount.id), JSON.stringify({
                                kind: "spend", limit: Number(modelData.id), to: msigPayTo.text.trim(), amount: msigBox.payBase }))
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    readonly property var members: (msigBox.st && msigBox.st.config) ? (msigBox.st.config.members || []) : []
                    readonly property string limitBase: acc.lezBase(msigLimitAmount.text)
                    LogosTextField {
                        id: msigLimitAmount
                        objectName: "msigLimitAmount"
                        Layout.fillWidth: true
                        placeholderText: qsTr("limit, LEZ per period")
                    }
                    LogosTextField {
                        id: msigLimitHours
                        objectName: "msigLimitHours"
                        Layout.preferredWidth: 90
                        placeholderText: qsTr("hours")
                    }
                    LogosTextField {
                        id: msigLimitK
                        objectName: "msigLimitK"
                        Layout.preferredWidth: 90
                        placeholderText: qsTr("signers k")
                    }
                    ActionButton {
                        objectName: "msigProposeLimit"
                        readonly property int k: /^[0-9]+$/.test(msigLimitK.text.trim()) ? Number(msigLimitK.text.trim()) : 0
                        enabled: parent.limitBase !== "" && parent.limitBase !== "0" && /^[0-9]+$/.test(msigLimitHours.text.trim())
                                 && Number(msigLimitHours.text.trim()) > 0 && k >= 1 && k <= parent.members.length
                        text: qsTr("Propose a spending limit")
                        variant: LogosButton.Variant.Secondary
                        onClicked: {
                            var ids = ((msigBox.st.config && msigBox.st.config.limits) || []).map(function (l) { return Number(l.id); });
                            var id = ids.length > 0 ? Math.max.apply(null, ids) + 1 : 1;
                            acc.lezMsigProposeRequested(String(acc.msigAccount.id), JSON.stringify({
                                kind: "config", changes: [{ change: "add-limit", limit: {
                                    id: id, signers: parent.members.map(function (m) { return String(m.key); }),
                                    threshold: k, amount: parent.limitBase,
                                    periodMs: Number(msigLimitHours.text.trim()) * 3600000 } }] }));
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: msigNewLock
                        objectName: "msigNewTimelock"
                        Layout.preferredWidth: 140
                        placeholderText: qsTr("time lock, minutes")
                    }
                    ActionButton {
                        objectName: "msigProposeTimelock"
                        enabled: /^[0-9]+$/.test(msigNewLock.text.trim())
                        text: qsTr("Propose a new time lock")
                        variant: LogosButton.Variant.Secondary
                        onClicked: acc.lezMsigProposeRequested(String(acc.msigAccount.id), JSON.stringify({
                            kind: "config", changes: [{ change: "set-timelock", timelockMs: Number(msigNewLock.text.trim()) * 60000 }] }))
                    }
                }
                Repeater {
                    model: (parent.st && parent.st.queue) ? parent.st.queue : []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "msigQueued"
                            Layout.fillWidth: true
                            text: qsTr("Queued: proposal #%1, runs from %2").arg(modelData.nonce)
                                  .arg(new Date(Number(modelData.etaMs)).toLocaleString(Qt.locale(), Locale.ShortFormat))
                                  + (modelData.proposerRemoved
                                     ? qsTr(". Proposed by a member who has since been removed: it still runs unless you cancel it.")
                                     : "")
                            color: modelData.proposerRemoved ? Theme.palette.warning : Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                            wrapMode: Text.WordWrap
                        }
                        ActionButton {
                            objectName: "msigProposeCancel"
                            text: qsTr("Propose to cancel")
                            variant: LogosButton.Variant.Secondary
                            onClicked: acc.lezMsigProposeRequested(String(acc.msigAccount.id),
                                JSON.stringify({ kind: "cancel", nonces: [Number(modelData.nonce)] }))
                        }
                    }
                }
                LogosText {
                    objectName: "msigProposeResult"
                    Layout.fillWidth: true
                    visible: !!(acc.lezMsigPropose && (acc.lezMsigPropose.error || acc.lezMsigPropose.intentId))
                    text: acc.lezMsigPropose && acc.lezMsigPropose.error
                          ? "⚠ " + String(acc.lezMsigPropose.error) + (acc.lezMsigPropose.detail ? " — " + String(acc.lezMsigPropose.detail) : "")
                          : qsTr("Proposed to the room with your approval. Other members approve it on its card; anyone may settle it once enough have.")
                    color: acc.lezMsigPropose && acc.lezMsigPropose.error ? Theme.palette.error : Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── a LEZ multisig (exo-3c9) ──
        // Each member gives the creator a FRESH LEZ account (its key stays in their own
        // keystore); the creator puts the k-of-n on chain, and it is disclosed here once
        // a block includes it. An existing one is disclosed by its config.
        ColumnLayout {
            Layout.fillWidth: true
            visible: acc.openForm === "lez"
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                ActionButton {
                    objectName: "lezShowMember"
                    text: qsTr("My LEZ member account")
                    variant: LogosButton.Variant.Secondary
                    onClicked: acc.lezMemberRequested()
                }
                LogosText {
                    objectName: "lezMemberAccount"
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    text: acc.lezMember && acc.lezMember.base58 ? String(acc.lezMember.base58)
                        : acc.lezMember && acc.lezMember.error ? "⚠ " + String(acc.lezMember.error)
                          + (acc.lezMember.detail ? ": " + String(acc.lezMember.detail) : "")
                        : qsTr("give this to whoever creates the multisig")
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: lezThreshold
                    objectName: "lezCreateThreshold"
                    Layout.preferredWidth: 60
                    placeholderText: qsTr("k")
                    text: "2"
                }
                LogosTextField {
                    id: lezMembers
                    objectName: "lezCreateMembers"
                    Layout.fillWidth: true
                    placeholderText: qsTr("members' LEZ accounts, comma-separated")
                    font.family: MusterStyle.mono
                }
            }
            ActionButton {
                objectName: "lezCreate"
                Layout.fillWidth: true
                enabled: lezMembers.text.trim().length > 0 && lezThreshold.text.trim().length > 0
                text: qsTr("Create this LEZ multisig on chain")
                variant: LogosButton.Variant.Secondary
                onClicked: acc.lezCreateRequested(lezThreshold.text.trim(), lezMembers.text.trim())
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: lezConfig
                    objectName: "lezDiscloseConfig"
                    Layout.fillWidth: true
                    placeholderText: qsTr("an existing LEZ multisig's config {program, createKey, pda, layout}")
                    font.family: MusterStyle.mono
                }
                ActionButton {
                    objectName: "lezDisclose"
                    text: qsTr("Disclose")
                    variant: LogosButton.Variant.Secondary
                    enabled: lezConfig.text.trim().length > 0
                    onClicked: acc.discloseRequested(JSON.stringify({
                        family: "lez.multisig-program", chain: "", address: "", label: "",
                        config: lezConfig.text.trim() }))
                }
            }
        }
    }
}
