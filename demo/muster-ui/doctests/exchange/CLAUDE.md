# doctests/exchange — inherited from upstream, unmaintained here

Upstream `logos-co/logos-chat-ui`'s two-instance harness: it launches two app
instances offscreen, drives a real message exchange between them over the
inspector protocol, and captures the screenshots in `../../docs/images/exchange`.

Kept because a working two-peer driver is worth having and this one already
knows how to coordinate two instances. **Not adapted to Muster**: it drives the
chat surfaces it was written for and knows nothing about the wallet, the cards
or the visibility panel. Treat it as reference for how two peers are driven,
not as a test of this fork.

If it is ever adapted, the thing to preserve is its teardown: it stops both
instances on failure, which is what keeps a failed run from leaving processes
holding the delivery ports.
