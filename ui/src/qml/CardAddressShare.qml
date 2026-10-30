import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// An address-share card's body (exo-720.3, moved verbatim out of MusterCard.qml): the
// address a member shared, its form, and who can see what lands there. `cardRoot` is the
// MusterCard, as before the move.
// ── address-share ({asset, address, form}) ─────────────────────────
ColumnLayout {
    required property var cardRoot

    visible: cardRoot.kind === "address-share"
    Layout.fillWidth: true
    spacing: Theme.spacing.tiny

    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: cardRoot.card && cardRoot.card.asset
            ? String(cardRoot.card.asset) : qsTr("private account")
        color: Theme.palette.text
        font.family: Theme.typography.publicSans
        font.pixelSize: MusterStyle.cardBody
    }

    // What kind of destination it is matters more than the sixty
    // characters no one reads — so name the form, then show a clipped
    // address after it. `form` 0 is shielded, 1 is a public account;
    // getting this wrong is the exact lie a labelled address must not
    // tell, so an absent form reads as the safer "shielded".
    LogosText {
        objectName: "cardShareForm"
        Layout.fillWidth: true
        wrapMode: Text.WrapAnywhere
        elide: Text.ElideRight
        text: {
            var form = cardRoot.card && cardRoot.card.form !== undefined
                ? Number(cardRoot.card.form) : 0;
            var addr = cardRoot.card && cardRoot.card.address
                ? String(cardRoot.card.address).replace(/\s+/g, "") : "";
            var shown = addr.slice(0, 48) + (addr.length > 48 ? "…" : "");
            // a Monero subaddress is no public account (exo-dcc.20): the chain shows no
            // payer, payee or amount for what lands there
            var xmr = String((cardRoot.card && cardRoot.card.asset) || "") === "XMR";
            return (xmr ? qsTr("Monero subaddress") : form === 1 ? qsTr("public account") : qsTr("shielded"))
                + (shown.length > 0 ? "  ·  " + shown : "");
        }
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.cardCaption
    }

    // The whole address, however the line above clipped it: what someone pays to from a
    // wallet of their own.
    CopyButton {
        objectName: "cardShareCopy"
        label: qsTr("Copy address")
        value: cardRoot.card && cardRoot.card.address ? String(cardRoot.card.address).replace(/\s+/g, "") : ""
    }

    // A public account is worth a word: the payer should know the
    // destination is readable before choosing how to pay. "Zone" is the
    // LEZ's word; on Ethereum or Bitcoin it is the chain (exo-4d4).
    LogosText {
        objectName: "cardShareReadable"
        Layout.fillWidth: true
        visible: cardRoot.card && cardRoot.card.form !== undefined
            && Number(cardRoot.card.form) === 1
        wrapMode: Text.WordWrap
        text: String((cardRoot.card && cardRoot.card.asset) || "") === "XMR"
              ? qsTr("The chain shows no payer, payee or amount: only the wallet that holds this address sees what lands here.")
              : (String((cardRoot.card && cardRoot.card.chain) || "").indexOf("lez:") === 0
               || String((cardRoot.card && cardRoot.card.asset) || "") === "LEZ")
              ? qsTr("Anyone reading the zone can see what lands here.")
              : qsTr("Anyone reading the chain can see what lands here.")
        color: Theme.palette.textTertiary
        font.pixelSize: MusterStyle.cardCaption
    }

    // Close the loop: use the address the counterparty just disclosed as the
    // recipient of the payment being composed, instead of retyping it. Only for
    // a public account (form 1) that carries an address, and never on the
    // reader's own card: that would pay themselves (exo-1d9).
    ActionButton {
        objectName: "cardUseAddress"
        visible: cardRoot.card && !cardRoot.postedByMe && Number(cardRoot.card.form || 0) === 1
            && String(cardRoot.card.asset || "") !== "XMR"     // muster never sends Monero
            && String((cardRoot.card && cardRoot.card.address) || "").replace(/\s+/g, "").length > 0
        Layout.fillWidth: true
        text: qsTr("Use as recipient")
        variant: LogosButton.Variant.Secondary
        onClicked: cardRoot.useAddress(
            String(cardRoot.card.address).replace(/\s+/g, ""))
    }
}
