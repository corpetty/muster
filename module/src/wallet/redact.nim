## A configured endpoint, as it may be shown (invariant 8, exo-14f.1).
##
## Every RPC endpoint muster calls is the user's own, untrusted infrastructure, and a hosted
## one often carries its credentials in the URL: a key in the path
## (https://mainnet.infura.io/v3/<key>) or the query (?apikey=<key>), or userinfo
## (http://user:pass@host). So a configured URL is never copied whole into text that leaves
## the module — a hosted call's reply, a card's detail, the MUSTER-LP debug log. It is shown
## as its scheme, host and port, with "***" where userinfo or a path, query or fragment
## stood. settings.json keeps the URL whole: it is the user's own file, and the module reads
## it back to dial the endpoint.

import std/[uri, strutils]

const
  HostChars = Letters + Digits + {'.', '-', '_', ':', '%'}   ## a name, IPv4, or IPv6 (zone)
  Hidden = "***"

proc redactUrl*(url: string): string =
  ## `url` as it may be shown: scheme://host[:port], with "***@" in place of any userinfo and
  ## "/***" in place of any path, query or fragment. Anything that does not parse as a URL
  ## with a plain host and a numeric port is shown as "***" whole. No URL ("") stays "".
  if url.strip().len == 0: return ""
  var u: Uri
  try: u = parseUri(url.strip())
  except CatchableError: return Hidden
  if u.scheme.len == 0 or u.hostname.len == 0 or not u.scheme.allCharsInSet(Letters) or
     not u.hostname.allCharsInSet(HostChars) or not u.port.allCharsInSet(Digits):
    return Hidden
  result = u.scheme & "://"
  if u.username.len > 0 or u.password.len > 0: result.add Hidden & "@"
  result.add(if ':' in u.hostname: "[" & u.hostname & "]" else: u.hostname)
  if u.port.len > 0: result.add ":" & u.port
  if u.path.strip(chars = {'/'}).len > 0 or u.query.len > 0 or u.anchor.len > 0:
    result.add "/" & Hidden
