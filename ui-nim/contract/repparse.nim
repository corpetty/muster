## A parser for the subset of Qt Remote Objects' `.rep` language muster's view
## contract uses (`ui/src/muster_ui.rep`): one `class` of `PROP`s and `SLOT`s. It
## runs at compile time (the `repContract` macro reads the file with `staticRead`)
## and at run time (the contract check). Anything outside the subset is an error
## naming the line, never a silent skip: the contract must be read whole or not at all.

import std/strutils

type
  RepParam* = object
    typ*, name*: string          ## the Qt type as written (`QString`) and the name

  RepProp* = object
    typ*, name*: string
    default*: string             ## the default value, unescaped ("" when none)
    modifier*: string            ## READONLY / READWRITE / … ("" when none)

  RepSlot* = object
    name*: string
    params*: seq[RepParam]

  RepClass* = object
    name*: string
    props*: seq[RepProp]         ## in declaration order: QtRO binds by index
    slots*: seq[RepSlot]         ## in declaration order: QtRO binds by index

  RepError* = object of ValueError

proc fail(line: int, msg: string) {.noreturn.} =
  raise newException(RepError, "rep line " & $line & ": " & msg)

proc stripComments(src: string): string =
  ## Drop `// …` comments, leaving string literals intact.
  var inStr = false
  var i = 0
  while i < src.len:
    let c = src[i]
    if inStr:
      result.add c
      if c == '\\' and i + 1 < src.len:
        result.add src[i + 1]
        inc i
      elif c == '"':
        inStr = false
    elif c == '"':
      inStr = true
      result.add c
    elif c == '/' and i + 1 < src.len and src[i + 1] == '/':
      while i < src.len and src[i] != '\n':
        inc i
      continue
    else:
      result.add c
    inc i

proc lineAt(src: string, pos: int): int =
  1 + src[0 ..< min(pos, src.len)].count('\n')

proc closingParen(src: string, open: int): int =
  ## Index of the `)` matching the `(` at `open`, skipping string literals.
  var depth = 0
  var inStr = false
  var i = open
  while i < src.len:
    let c = src[i]
    if inStr:
      if c == '\\':
        inc i
      elif c == '"':
        inStr = false
    elif c == '"':
      inStr = true
    elif c == '(':
      inc depth
    elif c == ')':
      dec depth
      if depth == 0:
        return i
    inc i
  fail(lineAt(src, open), "unbalanced parenthesis")

proc unescapeC(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      else: result.add s[i + 1]
      i += 2
    else:
      result.add s[i]
      inc i

proc parseTypeName(decl: string, line: int): (string, string) =
  ## "const QString &key" → ("QString", "key"); "QString health" → ("QString", "health").
  var d = decl.strip()
  if d.startsWith("const "):
    d = d[6 .. ^1].strip()
  let cut = max(d.rfind(' '), d.rfind('&'))
  if cut <= 0:
    fail(line, "cannot read a type and a name from '" & decl & "'")
  let typ = d[0 ..< cut].strip().strip(chars = {'&', ' '})
  let name = d[cut + 1 .. ^1].strip()
  if not name.validIdentifier:
    fail(line, "not an identifier: '" & name & "'")
  (typ, name)

proc parseProp(body: string, line: int): RepProp =
  # QString name="default" MODIFIER   (default and modifier optional)
  var rest = body.strip()
  var default = ""
  let eq = rest.find('=')
  var head = rest
  var tail = ""
  if eq >= 0:
    head = rest[0 ..< eq]
    tail = rest[eq + 1 .. ^1].strip()
    if tail.startsWith('"'):
      var j = 1
      while j < tail.len and tail[j] != '"':
        if tail[j] == '\\': inc j
        inc j
      if j >= tail.len:
        fail(line, "unterminated default string")
      default = unescapeC(tail[1 ..< j])
      tail = tail[j + 1 .. ^1].strip()
    else:
      let sp = tail.find(' ')
      default = if sp < 0: tail else: tail[0 ..< sp]
      tail = if sp < 0: "" else: tail[sp + 1 .. ^1].strip()
  else:
    let parts = rest.splitWhitespace()
    if parts.len == 3:
      head = parts[0] & " " & parts[1]
      tail = parts[2]
  let (typ, name) = parseTypeName(head, line)
  RepProp(typ: typ, name: name, default: default, modifier: tail)

proc parseSlot(body: string, line: int): RepSlot =
  # void name(const QString &a, const QString &b)
  let b = body.strip()
  if not b.startsWith("void "):
    fail(line, "only void SLOTs are supported: '" & b & "'")
  let open = b.find('(')
  if open < 0 or not b.endsWith(")"):
    fail(line, "malformed SLOT: '" & b & "'")
  result.name = b[5 ..< open].strip()
  if not result.name.validIdentifier:
    fail(line, "not an identifier: '" & result.name & "'")
  let inner = b[open + 1 ..< b.high].strip()
  if inner.len > 0:
    for p in inner.split(','):
      let (typ, name) = parseTypeName(p, line)
      result.params.add RepParam(typ: typ, name: name)

proc parseRep*(source: string): RepClass =
  ## Parse a `.rep` holding exactly one class of PROPs and SLOTs.
  let src = stripComments(source)
  let cls = src.find("class ")
  if cls < 0:
    fail(1, "no class")
  let brace = src.find('{', cls)
  result.name = src[cls + 6 ..< brace].strip()
  let close = src.rfind('}')
  var i = brace + 1
  while i < close:
    if src[i] in Whitespace:
      inc i
      continue
    let line = lineAt(src, i)
    var kw = ""
    while i < close and src[i] in IdentChars:
      kw.add src[i]
      inc i
    if kw.len == 0 or i >= close or src[i] != '(':
      fail(line, "expected PROP(…) or SLOT(…), found '" & src[i .. min(i + 20, close - 1)] & "'")
    let endp = closingParen(src, i)
    let body = src[i + 1 ..< endp]
    case kw
    of "PROP": result.props.add parseProp(body, line)
    of "SLOT": result.slots.add parseSlot(body, line)
    else: fail(line, "unsupported .rep entry " & kw & " (the contract uses only PROP and SLOT)")
    i = endp + 1
