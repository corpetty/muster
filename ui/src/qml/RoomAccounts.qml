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
// Pure-render: `accounts` is coordinate_accounts' array; the only outputs are the two
// signals (disclose one, or disclose the local test Safe describe() suggests). No state.
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
    signal lezMemberRequested()
    signal lezCreateRequested(string threshold, string members)
    property var frostCeremonies: []      // the room's FROST key ceremonies (Phase D)
    property var frostCeremony: ({})      // the last open/join result ({ceremony, host} or {error})
    signal frostOpenRequested(string ceremonyId, string network, string t, string n)
    signal frostJoinRequested(string ceremonyId)
    // the Bitcoin multisig form: which family, and each network's CAIP-2 chain id
    // (module/src/bitcoin/network.nim)
    property string btcFamily: "btc.p2wsh-sortedmulti"
    readonly property var btcChains: ({
        mainnet: "bip122:000000000019d6689c085ae165831e93",
        testnet: "bip122:000000000933ea01ad0ee984209779ba",
        testnet4: "bip122:00000000da84f2bafbbc53dee25a72ae",
        signet: "bip122:00000008819873e925422c1ff0f99f7c",
        regtest: "bip122:0f9188f13cb7b2c71f2a335e3a4fc328" })

    implicitHeight: col.implicitHeight

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
            text: qsTr("No one has disclosed an account here yet. A Safe payment acts from an account a member discloses into the room.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
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
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
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
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    LogosButton {
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
                    font.pixelSize: Theme.typography.badgeText
                    wrapMode: Text.WordWrap
                }
                LogosText {
                    Layout.fillWidth: true
                    text: acc.checkLabel(modelData.check ? modelData.check.status : "")
                          + (modelData.check && modelData.check.detail ? " — " + String(modelData.check.detail) : "")
                    color: modelData.check && modelData.check.status === "disagrees" ? Theme.palette.error : Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                    wrapMode: Text.WordWrap
                }
                LogosText {
                    Layout.fillWidth: true
                    visible: modelData.conflict === true
                    text: qsTr("Members disclosed different signers or thresholds for this account. The first disclosure governs until they agree.")
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // disclose: the local test Safe (one click on anvil), or any Safe by chain + address
        LogosButton {
            objectName: "discloseSuggestedSafe"
            Layout.fillWidth: true
            text: qsTr("Disclose the local test Safe")
            variant: LogosButton.Variant.Secondary
            onClicked: acc.discloseSuggested()
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosTextField {
                id: chainField
                objectName: "discloseChain"
                Layout.preferredWidth: 80
                placeholderText: qsTr("chain id")
                text: "31337"
            }
            LogosTextField {
                id: addrField
                objectName: "discloseAddress"
                Layout.fillWidth: true
                placeholderText: qsTr("Safe address 0x…")
            }
        }
        LogosButton {
            objectName: "discloseSafe"
            Layout.fillWidth: true
            enabled: addrField.text.trim().length === 42 && chainField.text.trim().length > 0
            text: qsTr("Disclose this Safe")
            variant: LogosButton.Variant.Secondary
            onClicked: acc.discloseRequested(JSON.stringify({
                family: "evm.safe", chain: "eip155:" + chainField.text.trim(),
                address: addrField.text.trim(), label: "" }))
        }
        // ── a Bitcoin multisig (exo-a50.2 families; this form, exo-59c) ──
        // k of n members' compressed keys (each finds theirs in Settings → YOUR BITCOIN KEY).
        // The address is derived from the keys, so nothing here is taken on trust: every
        // member re-derives it, and the module refuses a key list that doesn't parse.
        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            text: qsTr("Bitcoin multisig")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.badgeText
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosButton {
                objectName: "btcFamilyP2wsh"
                text: qsTr("P2WSH")
                variant: acc.btcFamily === "btc.p2wsh-sortedmulti" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: acc.btcFamily = "btc.p2wsh-sortedmulti"
            }
            LogosButton {
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
                text: "regtest"
            }
        }
        LogosTextField {
            id: btcKeys
            objectName: "btcKeys"
            Layout.fillWidth: true
            placeholderText: qsTr("members' Bitcoin keys (66 hex each), comma-separated")
        }
        LogosButton {
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
        // ── a FROST key ceremony (Phase D) ──
        // The room is the ceremony's coordinator. Each participant's part runs on the room's
        // tick, and the t-of-n taproot account is disclosed here when it completes. To the
        // chain it will look like one key: one signature, no policy.
        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            text: qsTr("FROST key ceremony (Bitcoin taproot)")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.badgeText
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
            LogosTextField {
                id: frostNet
                objectName: "frostNetwork"
                Layout.preferredWidth: 90
                placeholderText: qsTr("network")
                text: "regtest"
            }
        }
        LogosButton {
            objectName: "frostOpen"
            Layout.fillWidth: true
            enabled: frostCid.text.trim().length > 0
            text: qsTr("Open the ceremony and join it")
            variant: LogosButton.Variant.Secondary
            onClicked: acc.frostOpenRequested(frostCid.text.trim(), frostNet.text.trim(), frostT.text.trim(), frostN.text.trim())
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
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
                LogosButton {
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
            font.pixelSize: Theme.typography.badgeText
            wrapMode: Text.WordWrap
        }

        // ── a LEZ multisig (exo-3c9) ──
        // Each member gives the creator a FRESH LEZ account (its key stays in their own
        // keystore); the creator puts the k-of-n on chain, and it is disclosed here once
        // a block includes it. An existing one is disclosed by its config.
        LogosText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            text: qsTr("LEZ multisig")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.badgeText
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosButton {
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
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
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
                font.family: Theme.typography.mono
            }
        }
        LogosButton {
            objectName: "lezCreate"
            Layout.fillWidth: true
            enabled: lezMembers.text.trim().length > 0 && lezThreshold.text.trim().length > 0
            text: qsTr("Create this LEZ multisig on chain")
            variant: LogosButton.Variant.Secondary
            onClicked: acc.lezCreateRequested(lezThreshold.text.trim(), lezMembers.text.trim())
        }
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
            font.pixelSize: Theme.typography.badgeText
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosTextField {
                id: lezConfig
                objectName: "lezDiscloseConfig"
                Layout.fillWidth: true
                placeholderText: qsTr("an existing LEZ multisig's config {program, createKey, pda, layout}")
                font.family: Theme.typography.mono
            }
            LogosButton {
                objectName: "lezDisclose"
                text: qsTr("Disclose")
                variant: LogosButton.Variant.Secondary
                enabled: lezConfig.text.trim().length > 0
                onClicked: acc.discloseRequested(JSON.stringify({
                    family: "lez.multisig-program", chain: "", address: "", label: "",
                    config: lezConfig.text.trim() }))
            }
        }
        LogosText {
            Layout.fillWidth: true
            visible: acc.discloseResult && acc.discloseResult.error !== undefined
            text: acc.discloseResult && acc.discloseResult.error
                  ? String(acc.discloseResult.error) + (acc.discloseResult.detail ? " — " + String(acc.discloseResult.detail) : "")
                  : ""
            color: Theme.palette.error
            font.pixelSize: Theme.typography.badgeText
            wrapMode: Text.WordWrap
        }
    }
}
