import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A proposal's "What this needs" box (exo-720.3, moved verbatim out of MusterCard.qml;
// exo-002.3): the five questions and YOUR readiness. `cardRoot` is the MusterCard, as
// before the move.
Rectangle {
    required property var cardRoot

    objectName: "needsBox"
    // behind Details, except when it names something missing: a blocked card keeps its
    // cause and remedy on its face (U-8)
    visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
             && (cardRoot.detailsOpen || cardRoot.needsBlocked)
    Layout.fillWidth: true
    Layout.topMargin: Theme.spacing.tiny
    implicitHeight: needsCol.implicitHeight + 2 * Theme.spacing.small
    radius: Theme.spacing.radiusSmall
    color: Theme.palette.surfaceRecessed
    border.width: 1
    border.color: (cardRoot.readiness && cardRoot.readiness.ready) ? Theme.palette.success
                : (cardRoot.readiness && cardRoot.readiness.declared === false) ? Theme.palette.warning
                : Theme.palette.borderSubtle

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            cardRoot.needsOpen = !cardRoot.needsOpen;
            if (cardRoot.needsOpen) cardRoot.installNow = Date.now();
            if (cardRoot.needsOpen && !cardRoot.readiness) cardRoot.needs();
            // every reopening reads readiness again: a module may have been
            // installed or started since it was last read (exo-dcc.10)
            else if (cardRoot.needsOpen) cardRoot.recheckReadiness();
        }
    }

    ColumnLayout {
        id: needsCol
        anchors.fill: parent
        anchors.margins: Theme.spacing.small
        spacing: Theme.spacing.tiny

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosText {
                textFormat: Text.PlainText
                objectName: "needsHeader"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.readiness ? qsTr("What this needs — %1").arg(cardRoot.readinessSummary())
                                         : qsTr("What this needs")
                color: (cardRoot.readiness && cardRoot.readiness.ready) ? Theme.palette.success : Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
                font.weight: Theme.typography.weightMedium
            }
            LogosText {
                textFormat: Text.PlainText
                text: cardRoot.needsOpen ? "−" : "+"
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
        }

        LogosText {
            textFormat: Text.PlainText
            visible: cardRoot.needsOpen && !cardRoot.readiness
            text: qsTr("checking with the module…")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.cardCaption
        }

        // needs: one row per requirement — status, what, detail, remedy.
        Repeater {
            model: (cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.items) ? cardRoot.readiness.items : []
            delegate: ColumnLayout {
                id: needRow
                required property var modelData
                // a module need (exo-dcc.10): the package to ask Package Manager
                // for, and what that request answered
                readonly property string pkg: cardRoot.installPkg(needRow.modelData)
                readonly property var req: cardRoot.installReq(needRow.pkg)
                readonly property string note: needRow.modelData.status === "met" ? ""
                                               : cardRoot.installNote(needRow.pkg, needRow.modelData)
                Layout.fillWidth: true
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "needStatus_" + String(modelData.kind) + "_" + String(modelData.name)
                        text: modelData.status === "met" ? "✓" : modelData.status === "missing" ? "✗" : "?"
                        color: modelData.status === "met" ? Theme.palette.success
                             : modelData.status === "missing" ? Theme.palette.warning : Theme.palette.textTertiary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.cardCaption
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: String(modelData.kind) + ": " + String(modelData.name)
                            + (modelData.party === "contributor" ? qsTr(" (each signer)")
                               : modelData.party === "payer" ? qsTr(" (each person who pays their part)") : "")
                            + (modelData.detail ? " — " + String(modelData.detail) : "")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.cardCaption
                    }
                }
                RowLayout {
                    visible: !!modelData.remedy
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    spacing: Theme.spacing.small
                    // module remedies are whole instructions now ("install … from
                    // Basecamp's Package Manager", "start …"), so every row reads
                    // "To fix:"; the Install button below is the one-click form
                    LogosText {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("To fix: ") + String(modelData.remedy || "")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.cardCaption
                    }
                    // A LEZ account is provisioned in the LEZ Wallet App, not
                    // Settings (exo-44b). Muster only detects + points; the
                    // automatic hand-off (logos.request) rides the app-to-app
                    // broker (L4), so today this is an honest prompt, not a button
                    // that would open the wrong place.
                    LogosText {
                        textFormat: Text.PlainText
                        visible: modelData.kind === "infra" && modelData.name === "lez-account"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("↳ Open the LEZ Wallet App to set up a funded account, then reopen this.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.cardCaption
                    }
                    ActionButton {
                        objectName: "needRemedy_" + String(modelData.kind)
                        visible: ((modelData.kind === "infra" && modelData.name !== "lez-account")
                                  || modelData.kind === "environment")
                                 && String(modelData.request || "").length === 0
                        text: qsTr("Open settings")
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.openSettings()
                    }
                    // a Monero wallet that is closed or on another network (exo-dcc.5):
                    // Monero Wallet opens it; muster never holds its password
                    ActionButton {
                        objectName: "needRequest_" + String(modelData.name)
                        visible: String(modelData.request || "") === "monero.wallet.unlock"
                                 && modelData.status !== "met"
                        text: qsTr("Open Monero Wallet")
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.openMoneroWallet(String(modelData.wallet || ""))
                    }
                }
                // A module that is not installed (exo-dcc.10): ask Basecamp's
                // Package Manager to open on the package the module names. The
                // person confirms the install there; Muster installs nothing. An
                // ok answer means Package Manager is open, not that it installed,
                // so the card re-reads readiness until the module runs.
                ColumnLayout {
                    visible: needRow.modelData.kind === "module" && needRow.modelData.status !== "met"
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    spacing: Theme.spacing.tiny
                    ActionButton {
                        objectName: "needInstall_" + String(needRow.modelData.name)
                        visible: cardRoot.canInstall(needRow.modelData)
                        enabled: !(needRow.req && needRow.req.state === "asking")
                        text: qsTr("Install %1").arg(String(needRow.modelData.install || ""))
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.askInstall(needRow.modelData)
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "installStatus_" + needRow.pkg
                        visible: needRow.note.length > 0
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: needRow.note
                        color: (needRow.req && (needRow.req.state === "open" || needRow.req.state === "asking"))
                               ? Theme.palette.textSecondary : Theme.palette.warning
                        font.pixelSize: MusterStyle.cardCaption
                    }
                    // not in any enabled catalogue: show the package in Package
                    // Manager, where the catalogues are
                    ActionButton {
                        objectName: "installShow_" + needRow.pkg
                        visible: !!(needRow.req && needRow.req.state === "failed")
                        text: qsTr("Open Package Manager")
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.showPackage(needRow.pkg)
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        visible: !!(needRow.req && needRow.req.state === "failed" && needRow.req.showError)
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        // "failed": Package Manager opened, but found no such package
                        text: String((needRow.req && needRow.req.showError) || "") === "failed"
                              ? qsTr("Package Manager opened, but could not find %1. Check its catalogues.").arg(needRow.pkg)
                              : qsTr("Package Manager could not be opened (%1). Open it from Basecamp.")
                                .arg(String((needRow.req && needRow.req.showError) || ""))
                        color: Theme.palette.warning
                        font.pixelSize: MusterStyle.cardCaption
                    }
                    // read readiness again on demand: the module may have been
                    // installed or started since (and the re-read window is over)
                    ActionButton {
                        objectName: "needRecheck_" + String(needRow.modelData.name)
                        visible: !cardRoot.installAwaited
                        text: qsTr("Check again")
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.recheckReadiness()
                    }
                }
            }
        }

        // ── From you (exo-45e K6): which of MY holdings fill the slots this asks
        // of me — graded about me only. Each candidate shows its public face, its
        // F-10 grade, and what choosing it discloses; a pick shares the PUBLIC face.
        LogosText {
            textFormat: Text.PlainText
            visible: cardRoot.showFromYou && cardRoot.needsOpen && cardRoot.shareableOffers.length > 0
            text: qsTr("From you:")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
            font.weight: Theme.typography.weightMedium
        }
        Repeater {
            model: (cardRoot.showFromYou && cardRoot.needsOpen) ? cardRoot.shareableOffers : []
            delegate: ColumnLayout {
                id: offerSlot
                required property var modelData
                readonly property string reqName: (modelData.requirement && modelData.requirement.name)
                                                  ? String(modelData.requirement.name) : ""
                Layout.fillWidth: true
                Layout.leftMargin: Theme.spacing.medium
                spacing: 0
                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: {
                        var r = offerSlot.modelData.requirement || ({});
                        var what = String(r.field || r.name || "");
                        if (offerSlot.modelData.status === "unsatisfiable") return "✗ " + what + qsTr(" — nothing you hold fits this");
                        if (offerSlot.modelData.status === "unknown") return "? " + what + qsTr(" — can't tell yet");
                        return what + qsTr(" — pick what to share:");
                    }
                    color: offerSlot.modelData.status === "satisfiable" ? Theme.palette.text : Theme.palette.warning
                    font.pixelSize: MusterStyle.cardCaption
                }
                Repeater {
                    model: offerSlot.modelData.candidates || []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.medium
                        spacing: Theme.spacing.small
                        LogosText {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: {
                                var d = (modelData.discloses || []).map(function (x) {
                                    return String(x.field) + "→" + String(x.to); }).join(", ");
                                return String(modelData["public"]) + "  (" + String(modelData.grade) + ")"
                                     + (d.length > 0 ? "  ·  " + qsTr("discloses ") + d : "");
                            }
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.cardCaption
                        }
                        ActionButton {
                            objectName: "shareCandidate"
                            text: qsTr("Share")
                            variant: LogosButton.Variant.Secondary
                            onClicked: cardRoot.shareMaterial(offerSlot.reqName, String(modelData["public"]))
                        }
                    }
                }
            }
        }

        // touches
        LogosText {
            textFormat: Text.PlainText
            visible: cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.manifest
                     && cardRoot.readiness.manifest.touches && cardRoot.readiness.manifest.touches.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: visible ? qsTr("Touches: ") + cardRoot.readiness.manifest.touches.map(function (t) {
                      return String(t.target) + " (" + String(t.mode) + ")"; }).join(", ") : ""
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }

        // what will happen: the disclosure, grouped by observer, outside-the-room included
        LogosText {
            textFormat: Text.PlainText
            visible: cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.declared !== false
            text: qsTr("Who will see what:")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
            font.weight: Theme.typography.weightMedium
        }
        Repeater {
            model: cardRoot.needsOpen ? cardRoot.disclosureGroups() : []
            delegate: LogosText {
                textFormat: Text.PlainText
                required property var modelData
                objectName: "disclose_" + String(modelData.to)
                Layout.fillWidth: true
                Layout.leftMargin: Theme.spacing.medium
                wrapMode: Text.WordWrap
                text: String(modelData.label) + ": " + String(modelData.fields)
                color: modelData.to === "room-member" ? Theme.palette.textSecondary : Theme.palette.warning
                font.pixelSize: MusterStyle.cardCaption
            }
        }

        // how we agree
        LogosText {
            textFormat: Text.PlainText
            visible: cardRoot.needsOpen && cardRoot.agreementLine().length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Agreement: ") + cardRoot.agreementLine()
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }
    }
}
