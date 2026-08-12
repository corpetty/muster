pragma Singleton

import QtQuick

// What the app claims about privacy, as data rather than prose baked into a
// view.
//
// The vision doc's rule is that every claim traces to something real: a
// protection names the mechanism that delivers it, a comparison names the
// system and the observer, and a gap names the fix *and that fix's honest
// status*. Keeping them as records is what makes that checkable — a claim with
// no evidence shows up here as an empty field, where prose in a delegate would
// read fine and be wrong.
//
// `kind` is a closed set:
//   "protects"    — what stays inside, and what makes it so
//   "others-leak" — the same step on a conventional stack
//   "gap"         — what leaks here anyway, with `fix` and `status`
//
// `status` is a closed set too, and "coming soon" is not in it:
//   "shipped" | "specified" | "partial" | "none"
//
// `disclosures` is the concrete half, modelled on the prototype's scope sheet:
// row by row, what a given step does and does not put in front of an outsider.
// Naming the fields and marking most of them "not disclosed" is a stronger
// claim than a paragraph saying "it's private", because it says *which* facts.
QtObject {
    id: root

    readonly property string stepDiscovery: "discovery"
    readonly property string stepConversation: "conversation"
    readonly property string stepAddress: "address"
    readonly property string stepAuthorization: "authorization"
    readonly property string stepPayment: "payment"

    readonly property var stepOrder: [root.stepDiscovery, root.stepConversation,
                                      root.stepAddress, root.stepAuthorization,
                                      root.stepPayment]

    function rankOf(step) {
        const i = root.stepOrder.indexOf(step);
        return i < 0 ? 0 : i;
    }

    function titleOf(step) {
        switch (step) {
        case root.stepConversation:
            return qsTr("Talking");
        case root.stepAddress:
            return qsTr("Agreeing where to pay");
        case root.stepAuthorization:
            return qsTr("Agreeing to pay");
        case root.stepPayment:
            return qsTr("Paying");
        default:
            return qsTr("Finding each other");
        }
    }

    readonly property var claims: [
        // ── discovery ────────────────────────────────────────────────────
        {
            step: root.stepDiscovery,
            kind: "protects",
            title: qsTr("Nobody was asked"),
            body: qsTr("This address was minted on this machine seconds after launch. No account, "
                     + "no reservation, no confirmation step. There is no directory to look anyone "
                     + "up in, so there is no lookup for anyone to observe."),
            evidence: qsTr("chat_module.get_address")
        },
        {
            step: root.stepDiscovery,
            kind: "others-leak",
            title: qsTr("Elsewhere, adding a contact is a request"),
            body: qsTr("On a conventional messenger, finding someone means asking a server, which "
                     + "learns that you two are now connected and keeps that edge. The graph is "
                     + "the product; the message content is almost beside the point."),
            evidence: qsTr("any directory-backed messenger")
        },
        {
            step: root.stepDiscovery,
            kind: "gap",
            title: qsTr("The introduction is unauthenticated"),
            body: qsTr("You sent this address over something else — Signal, a QR code, a business "
                     + "card. If that channel was compromised, whoever compromised it is the "
                     + "conversation. Muster cannot see that, and does not claim to."),
            fix: qsTr("An out-of-band verification step: compare a short fingerprint over a "
                    + "channel the attacker does not control."),
            status: "none",
            evidence: qsTr("no in-band verification in this build")
        },
        {
            step: root.stepDiscovery,
            kind: "gap",
            title: qsTr("A relay still learns who talks to whom"),
            body: qsTr("Conversations ride content topics. A store node sees which topics a client "
                     + "subscribes to, and when it publishes and fetches. That is the conversation "
                     + "graph, pseudonymously — and end-to-end encryption does not touch it. "
                     + "Running your own node does not fix it: that protects the operator's "
                     + "metadata, not the metadata of the people they talk to."),
            fix: qsTr("A mixnet at the transport layer — not an application change, and not Tor, "
                    + "which hides who-by-IP rather than what-links-to-what."),
            status: "specified",
            evidence: qsTr("FS-9 · LOGOS-MIXNET status raw, send-only PoC")
        },

        // ── conversation ─────────────────────────────────────────────────
        {
            step: root.stepConversation,
            kind: "protects",
            title: qsTr("The room is the boundary"),
            body: qsTr("Messages are end-to-end encrypted to the people in this conversation. The "
                     + "cards below — the ask, the address, the receipt — are ordinary messages "
                     + "carrying structured content, so they are encrypted exactly as text is. "
                     + "This app adds no cryptography of its own; the chat module does it."),
            evidence: qsTr("chat_module · MLS")
        },
        {
            step: root.stepConversation,
            kind: "others-leak",
            title: qsTr("Elsewhere, coordination is a database row"),
            body: qsTr("Arrange a payment in a group chat and the operator holds the whole "
                     + "negotiation — who suggested what, who hesitated, what was agreed and "
                     + "when — indefinitely, and can be compelled to produce it."),
            evidence: qsTr("any hosted chat")
        },
        {
            step: root.stepConversation,
            kind: "gap",
            title: qsTr("Timing and size are still visible"),
            body: qsTr("A relay cannot read a word of this, but it can see that a message passed, "
                     + "roughly how big it was, and exactly when. Over a conversation, that shape "
                     + "says a good deal about what kind of exchange it is."),
            fix: qsTr("Padding and cover traffic, which is the same mixnet work."),
            status: "specified",
            evidence: qsTr("LOGOS-MIXNET status raw")
        },

        // ── address ──────────────────────────────────────────────────────
        {
            step: root.stepAddress,
            kind: "protects",
            title: qsTr("A shielded destination, agreed in the room"),
            body: qsTr("What was shared is not an account number. It is a shielded receiving key "
                     + "set: an outsider cannot associate it with a payment, and it was handed "
                     + "over inside the encrypted conversation, so no third party was asked to "
                     + "resolve a name."),
            evidence: qsTr("lez_core.get_private_account_keys")
        },
        {
            step: root.stepAddress,
            kind: "others-leak",
            title: qsTr("The alternative is a public directory"),
            body: qsTr("The zone also offers on-chain labels: register a name, and anyone can "
                     + "resolve it. Nicer to use, and a permanent public mapping — the lookup is "
                     + "itself a public act. Same stack, two discovery models, real costs on "
                     + "both. Which is right depends on whether you would rather be findable or "
                     + "unlinkable."),
            evidence: qsTr("lez_core.add_label / resolve_label")
        },
        {
            step: root.stepAddress,
            kind: "gap",
            title: qsTr("Nothing binds this address to this person"),
            body: qsTr("The encryption means only your peer could have sent this address — but no "
                     + "cryptographic statement connects the identity you are chatting with to "
                     + "the account you are about to pay. Here the conversation is the "
                     + "authentication. That stops being enough the moment an address is relayed "
                     + "by anyone else."),
            fix: qsTr("An authenticated binding between the chat identity and the settlement "
                    + "account, signed by both."),
            status: "none",
            evidence: qsTr("ADR-010 open · the two identities are minted independently")
        },

        // ── authorization ────────────────────────────────────────────────
        {
            step: root.stepAuthorization,
            kind: "protects",
            title: qsTr("Every approval is bound to who gave it"),
            body: qsTr("An approval is an ordinary message, so the chat module authenticates it "
                     + "the way it authenticates anything else: it carries its author, and nobody "
                     + "in the room can forge one, replay someone else's, or approve twice. The "
                     + "count on the card is a real count of real members — and it was collected "
                     + "without a coordination server that would have learned who was deciding "
                     + "what, and when."),
            evidence: qsTr("chat_module message sender · one approval per author, deduplicated")
        },
        {
            step: root.stepAuthorization,
            kind: "others-leak",
            title: qsTr("Elsewhere, collecting approvals is a hosted service"),
            body: qsTr("The usual multisig flow pools proposals and signatures in a transaction "
                     + "service. Its operator — and often anyone with the URL — sees the proposal, "
                     + "who has signed, who has not, and the timing of each, before anything "
                     + "reaches a chain. The negotiation leaks before the transaction does."),
            evidence: qsTr("any hosted multisig coordination service")
        },
        {
            step: root.stepAuthorization,
            kind: "gap",
            title: qsTr("The zone does not enforce the threshold"),
            body: qsTr("This is the honest limit of what you just saw. The approvals are real and "
                     + "the count is real, but no chain checks them: the account that pays is "
                     + "single-key, so whoever proposed it could have paid without waiting, and "
                     + "the only record that they did wait is this conversation. \"2 of 3\" is "
                     + "enforced by the room, not by the zone."),
            fix: qsTr("An account whose policy the zone itself enforces, so the threshold is "
                    + "checked where the money moves rather than where it was agreed."),
            status: "partial",
            evidence: qsTr("lez-multisig implements M-of-N on a local sequencer; not deployed to "
                         + "this testnet, and its accounts are public — today it is a threshold "
                         + "or a shielded amount, not both")
        },
        {
            step: root.stepAuthorization,
            kind: "gap",
            title: qsTr("An approval is not bound to what it approves"),
            body: qsTr("Approvals name a proposal by an id this app minted. Nothing in one commits "
                     + "to an execution environment, an account, a slot or an expiry, so their "
                     + "scope is this conversation by convention rather than by construction."),
            fix: qsTr("Signing payloads that commit to environment, account, slot and expiry, so "
                    + "a contribution is worthless anywhere else."),
            status: "none",
            evidence: qsTr("F-5 in the real client's requirements · this demo builds no signing "
                         + "payloads of its own")
        },

        // ── payment ──────────────────────────────────────────────────────
        {
            step: root.stepPayment,
            kind: "protects",
            title: qsTr("Private on both ends"),
            body: qsTr("This was a shielded-to-shielded transfer. The amount is not on the public "
                     + "record, and neither account appears on it. Funding deliberately shields "
                     + "into the private account first, so the balance a payment draws on is "
                     + "already private — the transfer is hidden at both ends rather than only "
                     + "on arrival."),
            evidence: qsTr("lez_core.transfer_private")
        },
        {
            step: root.stepPayment,
            kind: "others-leak",
            title: qsTr("Elsewhere, the transfer is the disclosure"),
            body: qsTr("A public-chain transfer puts the amount, both addresses and the timestamp "
                     + "on a permanent record that indexers join to everything else those "
                     + "addresses ever did. The coordination that led to it is usually visible "
                     + "too, in whatever service hosted it."),
            evidence: qsTr("any public-chain transfer")
        },
        {
            step: root.stepPayment,
            kind: "gap",
            title: qsTr("That it happened, and when, is visible"),
            body: qsTr("The zone learns that a transfer occurred and at what time, even though it "
                     + "learns nothing about who or how much. On a testnet with few users that "
                     + "timing is more revealing than it would be in a crowd: the anonymity set "
                     + "is the protection, and right now it is small."),
            fix: qsTr("A larger anonymity set, and timing decorrelation."),
            status: "partial",
            evidence: qsTr("shielded transfers work; the crowd does not exist yet")
        },
        {
            step: root.stepPayment,
            kind: "gap",
            title: qsTr("Privacy costs about seven minutes"),
            body: qsTr("Producing the proof took 6m41s at full CPU on a desktop machine. That is "
                     + "the real price of the row of \"not disclosed\" below, and it is why this "
                     + "is a job you start rather than an interaction you wait on."),
            fix: qsTr("Faster proving, or hardware acceleration."),
            status: "none",
            evidence: qsTr("measured 2026-08-11, single-note transfer")
        }
    ]

    // What an outsider actually gets, field by field, for a given step. The
    // shape is deliberately the same at every step so the rows can be compared:
    // the interesting thing about the payment step is how many of them read
    // "not disclosed" where a public chain would fill every one in.
    readonly property var disclosures: ({
        "discovery": {
            caption: qsTr("What a relay sees"),
            rows: [
                { label: qsTr("who you are"), value: qsTr("a public key, not a name") },
                { label: qsTr("who you talk to"), value: qsTr("visible as topic shape") },
                { label: qsTr("when"), value: qsTr("visible") },
                { label: qsTr("what you said"), value: qsTr("not disclosed") }
            ]
        },
        "conversation": {
            caption: qsTr("What a relay sees"),
            rows: [
                { label: qsTr("message content"), value: qsTr("not disclosed") },
                { label: qsTr("that a message passed"), value: qsTr("visible") },
                { label: qsTr("approximate size"), value: qsTr("visible") },
                { label: qsTr("timing"), value: qsTr("visible") }
            ]
        },
        "address": {
            caption: qsTr("What a relay sees"),
            rows: [
                { label: qsTr("the address shared"), value: qsTr("not disclosed") },
                { label: qsTr("that something was shared"), value: qsTr("visible") },
                { label: qsTr("any name resolved"), value: qsTr("none — nothing was looked up") }
            ]
        },
        "authorization": {
            caption: qsTr("What a relay sees"),
            rows: [
                { label: qsTr("what was proposed"), value: qsTr("not disclosed") },
                { label: qsTr("who approved"), value: qsTr("not disclosed") },
                { label: qsTr("how many approved"), value: qsTr("not disclosed") },
                { label: qsTr("that the room is deciding"), value: qsTr("visible as timing") },
                // The one row here that is about the chain rather than the
                // relay, and it belongs on this step: the deciding never
                // reaches the chain at all, which is the good half of the same
                // fact whose bad half is that the chain cannot enforce it.
                { label: qsTr("any of it, on-chain"), value: qsTr("none — nothing was published") }
            ]
        },
        "payment": {
            caption: qsTr("What the chain records, forever"),
            rows: [
                { label: qsTr("amount"), value: qsTr("not disclosed") },
                { label: qsTr("recipient"), value: qsTr("not disclosed") },
                { label: qsTr("sender"), value: qsTr("not disclosed") },
                { label: qsTr("that a transfer happened"), value: qsTr("visible") },
                { label: qsTr("when"), value: qsTr("block timestamp") }
            ]
        }
    })

    // The rows for one step, in declaration order: what is protected first,
    // then the comparison, then what is still open. That order is the argument.
    function forStep(step) {
        return root.claims.filter(function (c) {
            return c.step === step;
        });
    }

    // Every step reached so far, most recent first — so the current step leads
    // and the ones that got you here stay readable underneath. Losing the
    // earlier context the moment a message is sent is exactly what this avoids.
    function stepsUpTo(step) {
        return root.stepOrder.slice(0, root.rankOf(step) + 1).reverse();
    }

    // The whole panel as one flat list of typed rows.
    //
    // Flat on purpose: the view renders this with a single Repeater. Nesting
    // Repeaters, each with its own `required property var modelData`, is a
    // scoping hazard in Qt 6 — the inner one shadows the outer, and the
    // failure is a component that silently does not load, with no error
    // anywhere the app can show you. Building the rows here keeps that
    // structure in a place where it can be read and reasoned about.
    //
    // `type` is one of: "step" | "claim" | "disclosure-head" | "disclosure-row".
    function rowsUpTo(step) {
        const out = [];
        const steps = root.stepsUpTo(step);
        for (let i = 0; i < steps.length; ++i) {
            const s = steps[i];
            out.push({ type: "step", step: s, title: root.titleOf(s), current: s === step });

            const claims = root.forStep(s);
            for (let j = 0; j < claims.length; ++j) {
                const c = claims[j];
                out.push({
                    type: "claim",
                    kind: c.kind,
                    title: c.title,
                    body: c.body,
                    fix: c.fix || "",
                    statusText: root.statusTextOf(c.status),
                    isShipped: c.status === "shipped",
                    isGap: c.kind === "gap",
                    evidence: c.evidence || ""
                });
            }

            const d = root.disclosures[s];
            if (d) {
                out.push({ type: "disclosure-head", caption: d.caption });
                for (let k = 0; k < d.rows.length; ++k) {
                    const r = d.rows[k];
                    out.push({
                        type: "disclosure-row",
                        label: r.label,
                        value: r.value,
                        // Withheld is the good outcome here, so the view gives
                        // it the accent rather than the alarm.
                        withheld: r.value.indexOf(qsTr("not disclosed")) === 0
                               || r.value.indexOf(qsTr("none")) === 0,
                        last: k === d.rows.length - 1
                    });
                }
            }
        }
        return out;
    }

    function statusTextOf(status) {
        switch (status) {
        case "shipped":
            return qsTr("status: shipped");
        case "specified":
            return qsTr("status: specified, not built");
        case "partial":
            return qsTr("status: partly there");
        case "none":
            return qsTr("status: nothing shipped, nothing specified");
        default:
            return "";
        }
    }
}
