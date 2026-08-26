# A `required property` on a delegate suppresses `modelData` injection (2026-08-26)

A one-line delegate change blanked the **entire room thread** — priming card, proposal
cards, address-share, receipts, chat — and neither `qmllint` nor `nix build` caught it,
because it is a *runtime* failure (see the sibling note
`qml-errors-are-invisible-to-nix-build.md`).

## The shape

`Room.qml`'s message `ListView` binds a **JS array** model (`room.messages`, parsed
from `coordinate_messages`). The duplicate-card fix needed each row's position, so the
delegate gained:

```qml
delegate: Item {
    required property int index          // <-- added for the dedup
    // ...uses modelData.body, modelData.author elsewhere...
}
```

In Qt 6, declaring **any** `required property` on a view delegate switches it into
required-properties mode: the view now injects model roles / `index` / `modelData`
**only where they are declared required**, and **stops providing the implicit context
properties**. So `modelData` — used but not declared — became `undefined`.

Every downstream read failed silently:
- `JSON.parse(modelData.body)` threw → caught by the card's `try/catch` → `parsedCard`
  became `null` for *every* message → each row fell through to the plain-chat branch.
- The plain-chat branch read `String(modelData.body || "")` → `""`. Blank rows.

Result: the room opened to an empty-looking thread. The reported symptom was "there is
no room priming — nothing happens after the room is opened," but priming was firing
fine; the card just rendered to nothing.

## The fix

Declare **every** context property the delegate uses, once any is required:

```qml
delegate: Item {
    required property int index
    required property var modelData      // <-- the missing half
}
```

## The rule

If a view delegate declares one `required property`, it must declare **all** of the
context values it touches — `modelData`, `index`, `model`, and each model role. Adding
a single `required property int index` to reorder or dedup is enough to break an
otherwise-working delegate that reads `modelData`. There is no compile-time or lint
signal; the only witness is the running UI. When you add a required property to a
delegate that already uses `modelData`, add `required property var modelData` in the
same edit.

Same root cause as the SDK-skew and QML-invisibility notes: the shipping surface is
proven by running it, not by building it.
