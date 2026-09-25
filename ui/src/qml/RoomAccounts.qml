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
