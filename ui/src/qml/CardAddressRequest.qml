import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// An address-request card's body (exo-720.3, moved verbatim out of MusterCard.qml):
// who is asked for an address on which chain, and the Share answer. `cardRoot` is the
// MusterCard, as before the move.
// ── address-request ────────────────────────────────────────────────
// Primed by the room's intention: it names what the room is for and asks
// whoever holds the needed address to share it.
ColumnLayout {
    required property var cardRoot

    visible: cardRoot.kind === "address-request"
    Layout.fillWidth: true
    spacing: 2

    LogosText {
        textFormat: Text.PlainText
        visible: !!(cardRoot.card && cardRoot.card.purpose)
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("For: %1").arg(String((cardRoot.card && cardRoot.card.purpose) || ""))
        color: Theme.palette.text
        font.family: Theme.typography.publicSans
        font.pixelSize: MusterStyle.cardBody
        font.weight: Theme.typography.weightMedium
    }
    LogosText {
        textFormat: Text.PlainText
        // the ask, while it is still yours to answer
        objectName: "cardAddressAsk"
        visible: cardRoot.askedOfMe && !cardRoot.answeredByMe
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        readonly property string askAsset: String((cardRoot.card && cardRoot.card.asset) || "ETH")
        readonly property string askChain: String((cardRoot.card && (cardRoot.card.chainLabel || cardRoot.card.chain)) || "")
        text: askAsset === "BTC"
              ? qsTr("This room needs a Bitcoin address on %1 to pay you at. Sharing gives your own key's address there.").arg(askChain)
              // exo-dcc.20: a fresh subaddress your own open wallet makes for the room
              : askAsset === "XMR"
              ? qsTr("This room needs a Monero address on %1 to pay you at. Sharing asks your own open Monero wallet for a new address; your client checks it is yours before you agree to anything paid there.").arg(askChain)
              : qsTr("This room needs somewhere to send funds. Share an address to continue.")
        color: Theme.palette.textSecondary
        font.family: Theme.typography.publicSans
        font.pixelSize: MusterStyle.cardCaption
    }
    LogosText {
        textFormat: Text.PlainText
        objectName: "cardAddressWaiting"
        visible: !cardRoot.askedOfMe && (cardRoot.askedOf.length > 0 ? !cardRoot.answeredByAsked
                                                                     : (cardRoot.answers || []).length === 0)
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: cardRoot.askedOf.length > 0 ? qsTr("Waiting for %1 to share an address.").arg(cardRoot.askedOfName || qsTr("them"))
                                          : qsTr("Waiting for someone in the room to share an address.")
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.cardCaption
    }
    Repeater {
        model: cardRoot.answers || []
        delegate: LogosText {
            textFormat: Text.PlainText
            required property var modelData
            objectName: "cardAddressAnswer"
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
            readonly property string shortAddr: {
                var a = String(modelData.address || "");
                return a.length > 18 ? a.slice(0, 10) + "…" + a.slice(-6) : a;
            }
            text: modelData.self ? qsTr("✓ You shared %1").arg(shortAddr)
                                 : qsTr("✓ %1 shared %2").arg(String(modelData.name || "")).arg(shortAddr)
            color: Theme.palette.success
            font.pixelSize: MusterStyle.cardCaption
        }
    }
}
