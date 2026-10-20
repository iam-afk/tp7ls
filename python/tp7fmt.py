#!/usr/bin/env python3
"""
tp7fmt.py - fixed-style formatter for Turbo Pascal 7 (prototype, milestone M2: layout only).

NO options.  The style comes from the user's reference pairs (polsk.pas -> polsk_formatted.pas,
option.pas -> option_formatted.pas).  Rules that the two samples do not decide are marked [guess].

Safety
  * refuses (FormatError) to touch a file that has parse diagnostics, or a conditional directive / inactive branch
    inside a statement or declaration
  * changes layout only, plus: a missing ';' after the LAST statement of a statement list is added (the reference
    does this before `until`); empty statements (stray ';') are dropped.  Identifier case is NOT touched (M5).
  * every comment and directive survives (checked at the end of each run); text of inactive {$IFDEF} branches is
    copied verbatim

Layout
  unit X;<blank>interface<blank>[uses<nl>  a, b;<blank>]items<blank>implementation<blank>items<blank>end.
  top-level items (uses / label / const / type / var / routine) are separated by exactly one blank line, interface
  routine headers included.  A {$...} directive that directly follows an item hugs it (`external;` + `{$L x.obj}`).
  sections: keyword line, one declaration per line, indented by 2, blank lines inside removed
  routine: header (directives on the same line), then sections at the routine's column without blank lines
  [guess: nested routines get a blank line before them], `begin` at the same column, body +2, `end;`
  simple statement: one line, wrapped only when longer than MAX_WIDTH (see wrap_line; TP7 rejects lines over 126)
  if/while/for/with: header ends with then/do; compound body: `begin` on its own line at the column of the keyword;
  other body: next line, +2.  `else` on its own line at the `if` column, same body rules; `else if` stays on ONE line
  and the chain is not indented further (owner's rule)
  records: one field declaration per line (`a, b: T;` counts as one), also inside variants: `0: (x: T);` for a single
  plain field, otherwise `0: (` / fields +2 / `);` (a single field: no `;` inside the parentheses, several: `;` after every one) (owner's rule)
  object (and a record with methods): `T = object(Ancestor)` - no blank before `(` - then fields and method headers, all
  at +2, one per line, no blank lines between them, `end;` at the column of the type name; `private` / `public` sit at the
  column of the type name.  A method header is one line, `procedure Draw; virtual;`; an implementation header keeps
  `T.M`.  `inherited` is a statement / expression like any other: `inherited Init(x)` (owner's rules, not options)
  repeat ... until: `until` at the column of `repeat`
  case: labels +2, `label: stmt`, `label: begin` (begin stays on the label line, body +2, `end;` at the label column),
  `else stmt;` at label level; other structured statements in a branch go on the next line, +2 [guess]
  spacing: binary operators and `:=` between blanks, `..` tight, `, ` after commas, `name: type`, `array [1..8] of`,
  `string[33]`, `^node`, `x:8:2` [guess], unary minus tight, `not x`
  line wrapping [guess]: a code line longer than MAX_WIDTH (120) is cut where the bracket nesting is shallowest: after a
  comma or a ';' inside brackets, before a binary operator (and or xor + - * / div mod shl shr in), after `:=` only as a last resort; the
  continuation is indented 4 more than the line it continues.  Comments, directives and inactive text are never
  wrapped, a single string literal is never split; what cannot be wrapped is reported in `warnings`.
  trivia: an own-line comment/directive gets the indentation of the NEXT token; a comment on the code's line stays at the
  end of that line; at most one blank line is kept between statements (none at block start/end)
"""
import re
import sys
from typing import List, Optional

from tp7parse import Node, Result, parse, parse_directive, routine_names, fieldlist_of
from tp7lex import Token

INDENT = 2
MAX_WIDTH = 120          # [guess] code lines longer than this are wrapped
TP_LINE_LIMIT = 126      # Turbo Pascal 7: "Error 11: Line too long" above this
WRAP_INDENT = 4
SIMPLE = frozenset(['Assign', 'ProcCall', 'Goto', 'Inline', 'Inherited'])
SECTIONS = ('ConstSection', 'TypeSection', 'VarSection', 'LabelSection')
NL_RE = re.compile(r'\r\n|\r|\n')


class FormatError(Exception):
    pass


_OP_RE = re.compile(r'(?:and|or|xor|div|mod|shl|shr|in|[-+*/]) ', re.I)


def _cuts(s: str, depth: int = 0):
    """Places where line `s` may be broken: [(cut, depth, rank)].  The first part is s[:cut].rstrip(), the second starts
    at the next non-blank.  rank 1 = after `:=` (worst), 0 = after a comma / before a binary operator.  `depth`: the
    bracket depth the line starts at (a continuation line starts inside the brackets of the line before it)."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":                                            # string literal, '' is an escaped apostrophe
            i += 1
            while i < n:
                if s[i] == "'":
                    if i + 1 < n and s[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            continue
        if c == '{':
            j = s.find('}', i)
            i = n if j < 0 else j + 1
            continue
        if c == '(' and s.startswith('(*', i):
            j = s.find('*)', i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
        elif c == ',' and i + 1 < n and s[i + 1] == ' ':
            out.append((i + 1, depth, 0))
        elif c == ';' and depth > 0 and i + 1 < n and s[i + 1] == ' ':      # between parameters / aggregate fields
            out.append((i + 1, depth, 0))
        elif c == ':' and s.startswith(':= ', i):
            out.append((i + 2, depth, 1))
            i += 2
            continue
        elif c == ' ' and i > 0 and s[i - 1] != ' ' and _OP_RE.match(s, i + 1):
            out.append((i, depth, 0))
        i += 1
    return out


def wrap_line(line: str, width: int = MAX_WIDTH, step: int = WRAP_INDENT) -> List[str]:
    """Break one rendered code line into pieces of at most `width` characters where that is possible."""
    out, cur, d0 = [], line, 0
    base = len(line) - len(line.lstrip(' '))
    while len(cur) > width:
        ind = len(cur) - len(cur.lstrip(' '))
        cuts = [c for c in _cuts(cur, d0) if c[0] > ind]
        fit = [c for c in cuts if c[0] <= width
               and (c[2] == 0 or base + step + len(cur[c[0]:].lstrip(' ')) <= width)]   # `:=` only if that settles it
        good = [c for c in fit if c[0] >= ind + 24]               # no stub lines
        pick = None
        for pool in (good, fit):
            if pool:
                pick = min(pool, key=lambda c: (c[1], c[2], -c[0]))
                break
        if pick is None:
            cuts = [c for c in cuts if c[2] == 0]                 # nothing fits: the smallest overflow (never after :=)
            if not cuts:
                break
            pick = min(cuts, key=lambda c: c[0])
        nxt = ' ' * (base + step) + cur[pick[0]:].lstrip(' ')
        if len(nxt) >= len(cur):
            break
        out.append(cur[:pick[0]].rstrip(' '))
        cur, d0 = nxt, pick[1]
    out.append(cur)
    return out


def first_tok(node) -> Optional[Token]:
    if isinstance(node, Token):
        return node
    return next(node.tokens(), None)


def is_tok(x, *texts) -> bool:
    return isinstance(x, Token) and (not texts or x.text in texts or x.text.lower() in texts)


def cond_kind(t: Token):
    """'open' for {$IFDEF/IFNDEF/IFOPT}, 'else', 'end' for {$ENDIF}, None for anything else."""
    if t.kind != 'DIRECTIVE':
        return None
    k = parse_directive(t.text)[0]
    return 'open' if k in ('IFDEF', 'IFNDEF', 'IFOPT') else 'else' if k == 'ELSE' else 'end' if k == 'ENDIF' else None


class Trivia:
    """Leading trivia of one token, split into: comments on the previous token's line (`trailing`) and own-line items."""

    def __init__(self, leading: List[Token]):
        self.trailing: List[str] = []
        self.own: list = []              # ('c', text, is_directive, cond_kind) | ('blank',) | ('verbatim', text)
        self.blank_before_token = False
        seen_nl, run, i, n = False, 0, 0, len(leading)
        while i < n:
            t = leading[i]
            if not t.active:             # text of an inactive branch: one verbatim chunk
                j, buf = i, []
                while j < n and not leading[j].active:
                    buf.append(leading[j].text)
                    j += 1
                text = re.sub(r'(\r\n|\r|\n)?[ \t]*$', '', re.sub(r'^(\r\n|\r|\n)', '', ''.join(buf)))
                if text != '':
                    self.own.append(('verbatim', text))
                seen_nl, run, i = True, 1, j
                continue
            if t.kind in ('WS', 'CTRLZ'):
                i += 1
            elif t.kind == 'NL':
                seen_nl = True
                run += 1
                i += 1
            elif t.kind in ('COMMENT', 'DIRECTIVE'):
                if not seen_nl:
                    self.trailing.append(t.text)
                else:
                    if run >= 2:
                        self.own.append(('blank',))
                    self.own.append(('c', t.text, t.kind == 'DIRECTIVE', cond_kind(t)))
                    run = 0
                i += 1
            else:
                raise FormatError('unexpected trivia %s at line %d' % (t.kind, t.line))
        self.blank_before_token = seen_nl and run >= 2


class Formatter:
    def __init__(self, res: Result, width: Optional[int] = MAX_WIDTH, warnings: Optional[list] = None):
        self.res = res
        self.width = width
        self.warnings = warnings
        self.code = set()                # indexes of self.lines that are code (the only lines that may be wrapped)
        self.lines: List[str] = []
        self.eol = '\r\n' if '\r\n' in res.source else '\n'
        self.used = set()                # ids of tokens whose leading trivia has been emitted

    # -- output ---------------------------------------------------------------------------------------
    def line(self, indent: int, text: str):
        self.code.add(len(self.lines))
        self.lines.append(' ' * indent + text)

    def blank(self):
        if self.lines and self.lines[-1] != '':
            self.lines.append('')

    def trailing(self, texts):
        if texts:
            add = ' '.join(texts)
            if self.lines and self.lines[-1] != '':
                self.lines[-1] += ' ' + add
            else:
                self.lines.append(add)

    def comment(self, indent: int, text: str):
        parts = NL_RE.split(text)
        self.lines.append(' ' * indent + parts[0])
        self.lines.extend(parts[1:])

    def lead(self, tok, indent: int, blanks: str = 'keep', sep: bool = False, own_trailing: bool = False):
        """Flush the trivia in front of a token that starts an output line (idempotent).  own_trailing: comments that sat on
        the previous token's line become own-line comments (there is no previous line to hang them on)."""
        tok = first_tok(tok) if not isinstance(tok, Token) else tok
        if tok is None or id(tok) in self.used:
            return
        self.used.add(id(tok))
        tv = Trivia(tok.leading)
        own = tv.own
        if own_trailing:
            own = [('c', t, False, None) for t in tv.trailing] + own
        else:
            self.trailing(tv.trailing)
        if sep:
            own = [x for x in own if x[0] != 'blank']
            k = 0
            # plain directives, {$ELSE}/{$ENDIF} (and the inactive text between them) stay glued to the previous item;
            # an {$IFDEF} opens a new guarded region, so it goes below the blank line together with what follows
            while k < len(own) and (own[k][0] == 'verbatim' or (own[k][0] == 'c' and own[k][2] and own[k][3] != 'open')):
                if own[k][0] == 'verbatim':
                    self.lines.extend(x.rstrip() for x in NL_RE.split(own[k][1]))
                else:
                    self.comment(0 if own[k][3] else indent, own[k][1])
                k += 1
            own = own[k:]
            self.blank()
        for item in own:
            if item[0] == 'blank':
                if blanks == 'keep' and not sep:
                    self.blank()
            elif item[0] == 'verbatim':
                self.lines.extend(x.rstrip() for x in NL_RE.split(item[1]))
            else:
                self.comment(0 if item[3] else indent, item[1])
        if tv.blank_before_token and blanks == 'keep' and not sep:
            self.blank()

    # -- one-line rendering ----------------------------------------------------------------------------
    def inline(self, tok: Token) -> List[str]:
        out = []
        for t in tok.leading:
            if not t.active:
                raise FormatError('inactive conditional code inside a statement or declaration (line %d)' % t.line)
            if t.kind == 'DIRECTIVE':
                if parse_directive(t.text)[0] in ('IFDEF', 'IFNDEF', 'IFOPT', 'ELSE', 'ENDIF'):
                    raise FormatError('conditional directive inside a statement or expression (line %d)' % t.line)
                out.append(t.text)
            elif t.kind == 'COMMENT':
                out.append(t.text)
        return out

    def T(self, tok: Token, first: bool = False) -> str:
        """Token text.  first=True: the caller already flushed its trivia (via lead)."""
        if first:
            return tok.text
        if id(tok) in self.used:
            raise AssertionError('token emitted twice: %r' % tok)
        self.used.add(id(tok))
        c = self.inline(tok)
        if tok.text in (';', ',', ')', ']', '.', '.)'):
            return tok.text + (' ' + ' '.join(c) if c else '')
        return ' '.join(c + [tok.text])

    def R(self, node, first: bool = False) -> str:
        if isinstance(node, Token):
            return self.T(node, first)
        f = getattr(self, 'r_' + node.kind, None)
        if f is None:
            raise FormatError('no layout rule for %s' % node.kind)
        return f(node, first)

    def seq(self, kids, first: bool = False) -> str:
        """Elements joined by blanks; , ; : stick to the previous element (and are followed by a blank); '..' is tight."""
        out: List[str] = []
        glue = False
        for i, k in enumerate(kids):
            if is_tok(k, ',', ';', ':'):
                s = self.T(k, False)
                if out:
                    out[-1] += s
                else:
                    out.append(s)
            elif is_tok(k, '..'):
                out[-1] += self.T(k, False)
                glue = True
            else:
                s = self.R(k, first and not out and not glue)
                if glue and out:
                    out[-1] += s
                    glue = False
                else:
                    out.append(s)
        return ' '.join(out)

    def bracketed(self, n: Node, first: bool) -> str:
        """( ... ) / [ ... ] with comma-separated content"""
        kids = n.kids
        close = is_tok(kids[-1], ')', ']', '.)')
        inner = kids[1:-1] if close else kids[1:]
        return self.T(kids[0], first) + self.seq(inner) + (self.T(kids[-1], False) if close else '')

    # expressions ---------------------------------------------------------------------------------------
    def r_Name(self, n, first):
        return ''.join(self.T(t, first and i == 0) for i, t in enumerate(n.kids))

    r_DeclName = r_Literal = r_Name

    def r_StringLit(self, n, first):
        return ''.join(self.T(t, first and i == 0) for i, t in enumerate(n.kids))

    def r_Paren(self, n, first):
        return self.bracketed(n, first)

    def r_Unary(self, n, first):
        op = n.kids[0]
        return self.T(op, first) + (' ' if op.kind == 'KW' else '') + self.R(n.kids[1], False)

    def r_Binary(self, n, first):
        return self.R(n.kids[0], first) + ' ' + self.T(n.kids[1]) + ' ' + self.R(n.kids[2])

    def r_Designator(self, n, first):
        return ''.join(self.R(k, first and i == 0) for i, k in enumerate(n.kids))

    def r_Field(self, n, first):
        return ''.join(self.T(t) for t in n.kids)

    def r_Deref(self, n, first):
        return self.T(n.kids[0])

    r_Index = r_Args = r_SetCtor = r_Aggregate = r_Params = r_EnumType = r_Paren

    def r_Arg(self, n, first):
        return ''.join(self.R(k, first and i == 0) for i, k in enumerate(n.kids))

    def r_Labels(self, n, first):
        return self.seq(n.kids, first)

    def r_Inline(self, n, first):
        return ''.join(self.T(t, first and i == 0) for i, t in enumerate(n.tokens()))

    # types (one line) ----------------------------------------------------------------------------------
    def r_NamedType(self, n, first):
        return self.R(n.kids[0], first)

    def r_PointerType(self, n, first):
        return self.T(n.kids[0], first) + self.R(n.kids[1])

    def r_StringType(self, n, first):
        k = n.kids
        s = self.T(k[0], first)
        if len(k) > 1:
            s += self.T(k[1]) + self.R(k[2]) + (self.T(k[3]) if len(k) > 3 else '')
        return s

    def r_SubrangeType(self, n, first):
        return self.seq(n.kids, first)

    def r_SetType(self, n, first):
        return self.T(n.kids[0], first) + ' ' + self.T(n.kids[1]) + ' ' + self.R(n.kids[2])

    def r_FileType(self, n, first):
        k = n.kids
        return self.T(k[0], first) + (' ' + self.T(k[1]) + ' ' + self.R(k[2]) if len(k) > 1 else '')

    def r_PackedType(self, n, first):
        return self.T(n.kids[0], first) + ' ' + self.R(n.kids[1])

    def array_parts(self, ty: Node, first: bool):
        k = ty.kids
        i_of = next(i for i in range(len(k) - 1, 0, -1) if is_tok(k[i], 'of'))
        if i_of == 1:                                               # `array of T`: an open array parameter, no bounds
            return self.T(k[0], first) + ' ' + self.T(k[1]) + ' ', k[2]
        head = self.T(k[0], first) + ' ' + self.T(k[1]) + self.seq(k[2:i_of - 1]) + self.T(k[i_of - 1]) + ' ' + \
            self.T(k[i_of]) + ' '
        return head, k[i_of + 1]

    def r_ArrayType(self, n, first):
        head, elem = self.array_parts(n, first)
        return head + self.R(elem)

    def r_ProcType(self, n, first):
        k = n.kids
        s = self.T(k[0], first)
        i = 1
        if i < len(k) and isinstance(k[i], Node) and k[i].kind == 'Params':
            s += self.R(k[i])
            i += 1
        if i < len(k) and is_tok(k[i], ':'):
            s += self.T(k[i]) + ' ' + self.R(k[i + 1])
        return s

    def r_ParamGroup(self, n, first):
        return self.seq(n.kids, first)

    r_FieldDecl = r_FieldList = r_VariantPart = r_ParamGroup

    def r_RecordType(self, n, first):                               # inline form (inside variants only)
        k = n.kids
        body = self.seq(k[1].kids)
        return self.T(k[0], first) + (' ' + body if body else '') + ' ' + (self.T(k[2]) if len(k) > 2 else 'end')

    r_Heritage = r_Paren

    def r_Inherited(self, n, first):
        return self.T(n.kids[0], first) + ''.join(' ' + self.R(k) for k in n.kids[1:])

    def r_Variant(self, n, first):
        k = n.kids
        s = self.R(k[0], first) + self.T(k[1]) + ' ' + self.T(k[2]) + self.R(k[3])
        return s + (self.T(k[4]) if len(k) > 4 else '')

    def r_Absolute(self, n, first):
        k = n.kids
        s = self.T(k[0], first) + ' ' + self.R(k[1])
        return s + (self.T(k[2]) + self.R(k[3]) if len(k) > 3 else '')

    # -- types as lines -------------------------------------------------------------------------------
    def has_record(self, ty) -> bool:
        return any(isinstance(x, Node) and x.kind in ('RecordType', 'ObjectType') for x in ty.walk())

    def emit_type(self, prefix: str, ty: Node, indent: int, suffix: str, first: bool = True):
        """prefix is already on the line (first token's trivia flushed); records continue on the next lines."""
        if ty.kind == 'PackedType' and self.has_record(ty):
            return self.emit_type(prefix + self.T(ty.kids[0], False) + ' ', ty.kids[1], indent, suffix)
        if ty.kind == 'ArrayType' and self.has_record(ty):
            head, elem = self.array_parts(ty, False)
            return self.emit_type(prefix + head, elem, indent, suffix)
        if ty.kind in ('RecordType', 'ObjectType'):
            head = prefix + self.T(ty.kids[0], False)
            her = next((x for x in ty.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
            if her is not None:
                head += self.R(her)
            self.line(indent, head)
            self.emit_fields(fieldlist_of(ty), indent + INDENT)
            if is_tok(ty.kids[-1], 'end'):
                self.lead(ty.kids[-1], indent, 'none')
                self.line(indent, ty.kids[-1].text + suffix)
            return
        self.line(indent, prefix + self.R(ty, False) + suffix)

    def emit_fields(self, fl: Node, indent: int, last_semi: bool = True):
        """One declaration per line, every field gets a ';' (last_semi=False: not the last one - a variant that has a
        single field).  Method headers are lines of their own; `private` / `public` stand at the column of the type."""
        kids_ = fl.kids
        nodes = [i for i, x in enumerate(kids_) if isinstance(x, Node)]
        last = nodes[-1] if nodes else -1
        for i, k in enumerate(kids_):
            if isinstance(k, Token):
                self.lead(k, indent, 'none')               # stray ';'
            elif k.kind == 'FieldDecl':
                self.lead(k, indent, 'none')
                kids = k.kids
                colon = max(i for i, x in enumerate(kids) if is_tok(x, ':'))
                names = self.seq(kids[:colon + 1], True)
                suffix = '' if not last_semi and i == last else ';'
                self.emit_type(names + ' ', kids[colon + 1], indent, suffix)
            elif k.kind == 'VariantPart':
                self.emit_variant(k, indent)
            elif k.kind == 'Routine':
                self.lead(k, indent, 'none')
                text, _ = self.routine_header(k)
                self.line(indent, text)
            elif k.kind == 'Section':
                self.lead(k, indent - INDENT, 'none')
                self.line(indent - INDENT, self.T(k.kids[0], True))
            else:
                raise FormatError('unexpected %s in a field list' % k.kind)

    def emit_variant(self, vp: Node, indent: int):
        kids = vp.kids
        i_of = next(i for i, x in enumerate(kids) if is_tok(x, 'of'))
        self.lead(kids[0], indent, 'none')
        self.line(indent, self.seq(kids[:i_of + 1], True))
        for k in kids[i_of + 1:]:
            if isinstance(k, Token):
                self.lead(k, indent + INDENT, 'none')
            elif k.kind == 'Variant':
                self.lead(k, indent + INDENT, 'none')
                self.emit_variant_entry(k, indent + INDENT)
            else:
                raise FormatError('unexpected %s in a variant part' % k.kind)

    def emit_variant_entry(self, v: Node, indent: int):
        """A variant with exactly one plain field (or none) stays on one line, `0: (x: Integer);`, without a ';' inside
        the parentheses.  Otherwise every declaration gets its own line, `0: (` / fields +2 / `);`, and ALL of them end
        with ';' - except a single field that is a record (or a nested variant part)."""
        kids = v.kids
        fl = kids[3]
        decls = [x for x in fl.kids if isinstance(x, Node)]
        multi = len(decls) > 1 or (len(decls) == 1 and (decls[0].kind != 'FieldDecl' or self.has_record(decls[0])))
        head = self.R(kids[0], True) + self.T(kids[1]) + ' ' + self.T(kids[2])
        if not multi:
            parts = []
            for x in fl.kids:
                if isinstance(x, Node):
                    parts.append(self.R(x))
                else:                                                  # a ';' is dropped, comments on it are kept
                    parts.extend(c for c in [self.T(x)[1:].strip()] if c)
            if len(kids) > 4:                                          # comments before ')' stay before it
                parts.extend(c for c in [self.T(kids[4])[1:].strip()] if c)
            return self.line(indent, head + ' '.join(parts) + ')' + ';')
        self.line(indent, head)
        self.emit_fields(fl, indent + INDENT, last_semi=len(decls) > 1)
        if len(kids) > 4:
            self.lead(kids[4], indent, 'none')
            self.line(indent, kids[4].text + ';')
        else:
            self.lines[-1] += ';'

    # -- declarations ---------------------------------------------------------------------------------
    def emit_section(self, sec: Node, indent: int, sep: bool):
        kw = sec.kids[0]
        self.lead(kw, indent, 'none', sep)
        self.line(indent, kw.text)
        di = indent + INDENT
        if sec.kind == 'LabelSection':
            body = sec.kids[1:]
            self.lead(body[0], di, 'none')
            self.line(di, self.seq(body, True))
            return
        for d in sec.kids[1:]:
            self.lead(d, di, 'none')
            self.emit_decl(sec.kind, d, di)

    def emit_decl(self, kind: str, d: Node, indent: int):
        kids = d.kids
        semi = kids[-1] if is_tok(kids[-1], ';') else None
        body = kids[:-1] if semi is not None else kids
        if kind == 'ConstSection':
            name = self.R(body[0], True)
            if is_tok(body[1], '='):
                self.line(indent, name + ' ' + self.T(body[1]) + ' ' + self.R(body[2]) + ';')
            else:                                                    # typed constant: name: type = value
                eq = next(i for i, x in enumerate(body) if is_tok(x, '='))
                head = name + self.T(body[1]) + ' '
                ty = body[2]
                tail = ' ' + self.T(body[eq]) + ' ' + self.R(body[eq + 1]) + ';'
                self.emit_type(head, ty, indent, tail)
        elif kind == 'TypeSection':
            self.emit_type(self.R(body[0], True) + ' ' + self.T(body[1]) + ' ', body[2], indent, ';')
        else:                                                        # VarSection
            colon = next(i for i, x in enumerate(body) if is_tok(x, ':'))
            names = self.seq(body[:colon + 1], True)
            rest = body[colon + 2:]
            tail = ''.join(' ' + self.R(x) for x in rest) + ';'
            self.emit_type(names + ' ', body[colon + 1], indent, tail)
        if semi is not None:
            self.trailing(self.after_semicolon(semi))

    def after_semicolon(self, semi: Token) -> List[str]:
        self.used.add(id(semi))
        return self.inline(semi)

    def emit_uses(self, u: Node, sep: bool):
        self.lead(u.kids[0], 0, 'none', sep)
        self.line(0, 'uses')
        self.line(INDENT, self.seq(u.kids[1:]))

    def routine_header(self, r: Node):
        k = r.kids
        s = self.T(k[0], True) + ' ' + self.R(k[1])
        i = 2
        if routine_names(r)[0] is not None:                       # procedure Type.Method
            s += self.T(k[2]) + self.R(k[3])
            i = 4
        if i < len(k) and isinstance(k[i], Node) and k[i].kind == 'Params':
            s += self.R(k[i])
            i += 1
        if i < len(k) and is_tok(k[i], ':'):
            s += self.T(k[i]) + ' ' + self.R(k[i + 1])
            i += 2
        if i < len(k) and is_tok(k[i], ';'):
            s += self.T(k[i])
            i += 1
        if i < len(k) and isinstance(k[i], Node) and k[i].kind == 'Directives':
            for d in k[i].kids:
                s += (self.T(d) if is_tok(d, ';') else ' ' + self.R(d))
            i += 1
        return s, i

    def emit_routine(self, r: Node, indent: int, sep: bool):
        self.lead(r.kids[0], indent, 'none', sep)
        text, i = self.routine_header(r)
        self.line(indent, text)
        if i < len(r.kids) and isinstance(r.kids[i], Node) and r.kids[i].kind == 'Block':
            self.emit_block(r.kids[i], indent)
            i += 1
            if i < len(r.kids) and is_tok(r.kids[i], ';'):
                self.lines[-1] += ';'
                self.trailing(self.after_semicolon(r.kids[i]))

    def emit_block(self, b: Node, indent: int, term: str = ''):
        for k in b.kids:
            if k.kind in SECTIONS:
                self.emit_section(k, indent, sep=False)
            elif k.kind == 'Routine':
                self.emit_routine(k, indent, sep=True)
            elif k.kind == 'Compound':
                self.lead(k, indent, 'none')
                self.emit_compound(k, indent, ';' if term == ';' else term)
            elif k.kind == 'Asm':
                self.lead(k, indent, 'none')
                self.emit_asm(k, indent, term)
            else:
                raise FormatError('unexpected %s in a block' % k.kind)

    # -- statements -----------------------------------------------------------------------------------
    def emit_compound(self, c: Node, indent: int, term: str):
        self.line(indent, c.kids[0].text)
        self.emit_stmt_list(c.kids[1], indent + INDENT)
        if len(c.kids) > 2:
            self.lead(c.kids[2], indent, 'none')
            self.line(indent, c.kids[2].text + term)

    def emit_asm(self, a: Node, indent: int, term: str):
        toks = list(a.tokens())
        asm_tok, end_tok = toks[0], toks[-1]
        start = asm_tok.pos + len(asm_tok.text)
        raw = self.res.source[start:end_tok.pos] if end_tok.text.lower() == 'end' else self.res.source[start:]
        for t in toks[1:]:
            self.used.add(id(t))
        parts = NL_RE.split(raw)
        self.line(indent, asm_tok.text + (' ' + parts[0].strip() if parts[0].strip() else ''))
        for ln in parts[1:]:
            self.lines.append(ln.rstrip())
        if end_tok.text.lower() == 'end':
            if self.lines and self.lines[-1].strip() == '':
                self.lines.pop()
            self.line(indent, end_tok.text + term)

    def emit_stmt_list(self, lst: Node, indent: int):
        first = True
        for k in lst.kids:
            if isinstance(k, Token):                        # ';' separator: keeps only its trivia
                self.lead(k, indent, 'none')
            elif k.kind == 'Empty':
                continue
            elif k.kind == 'Error':
                raise FormatError('syntax error')
            else:
                self.lead(k, indent, 'none' if first else 'keep')
                first = False
                self.emit_stmt(k, indent, ';')

    def emit_branch(self, stmt: Node, indent: int, term: str):
        if stmt.kind == 'Empty':
            if term and self.lines:                         # `if x then;` - the empty statement must stay
                self.lines[-1] += term
            return
        if stmt.kind == 'Compound':
            self.lead(stmt, indent, 'none')
            self.emit_stmt(stmt, indent, term)
        else:
            self.lead(stmt, indent + INDENT, 'none')
            self.emit_stmt(stmt, indent + INDENT, term)

    def simple(self, s: Node, first: bool) -> str:
        k = s.kind
        if k == 'Assign':
            return self.R(s.kids[0], first) + ' ' + self.T(s.kids[1]) + ' ' + self.R(s.kids[2])
        if k == 'ProcCall':
            return self.R(s.kids[0], first)
        if k == 'Goto':
            return self.T(s.kids[0], first) + (' ' + self.T(s.kids[1]) if len(s.kids) > 1 else '')
        return self.R(s, first)

    def emit_if(self, s: Node, indent: int, term: str, prefix: str):
        """`prefix` is 'else ' when this `if` is the else branch of another one: `else if` stays on one line and the
        chain is not indented any further."""
        kids = s.kids
        self.line(indent, prefix + kids[0].text + ' ' + self.R(kids[1]) + ' ' + self.T(kids[2]))
        has_else = len(kids) > 4
        self.emit_branch(kids[3], indent, '' if has_else else term)
        if has_else:
            self.lead(kids[4], indent, 'none')
            if kids[5].kind == 'If':
                self.lead(kids[5], indent, 'none', own_trailing=True)    # `else {c} if`: {c} has no line to stay on
                return self.emit_if(kids[5], indent, term, kids[4].text + ' ')
            self.line(indent, kids[4].text)
            self.emit_branch(kids[5], indent, term)

    def emit_stmt(self, s: Node, indent: int, term: str):
        k = s.kind
        if k == 'Compound':
            return self.emit_compound(s, indent, term)
        if k in SIMPLE:
            return self.line(indent, self.simple(s, True) + term)
        if k == 'Asm':
            return self.emit_asm(s, indent, term)
        if k == 'Labeled':
            lab, colon, inner = s.kids
            head = lab.text + self.T(colon)
            where = max(indent - INDENT, 0)                    # a label stands alone, two columns to the left of the code
            if inner.kind == 'Empty':                          # `m: end`, `m: ;`
                return self.line(where, head + term)
            self.line(where, head)
            self.lead(inner, indent, 'none')
            return self.emit_stmt(inner, indent, term)
        if k == 'If':
            return self.emit_if(s, indent, term, '')
        if k in ('While', 'With', 'For'):
            kids = s.kids
            if k == 'While':
                head, body = kids[0].text + ' ' + self.R(kids[1]) + ' ' + self.T(kids[2]), kids[3]
            elif k == 'With':
                head = kids[0].text + ' ' + self.seq(kids[1:-2]) + ' ' + self.T(kids[-2])
                body = kids[-1]
            else:
                _, var, assign, start, to, end, do, body = kids
                head = (kids[0].text + ' ' + self.R(var) + ' ' + self.T(assign) + ' ' + self.R(start) + ' ' +
                        self.T(to) + ' ' + self.R(end) + ' ' + self.T(do))
            self.line(indent, head)
            return self.emit_branch(body, indent, term)
        if k == 'Repeat':
            rep, lst, until, cond = s.kids
            self.line(indent, rep.text)
            self.emit_stmt_list(lst, indent + INDENT)
            self.lead(until, indent, 'none')
            return self.line(indent, until.text + ' ' + self.R(cond) + term)
        if k == 'Case':
            return self.emit_case(s, indent, term)
        if k == 'Empty':
            return
        raise FormatError('no layout rule for statement %s' % k)

    def emit_case(self, s: Node, indent: int, term: str):
        kids = s.kids
        self.line(indent, kids[0].text + ' ' + self.R(kids[1]) + ' ' + self.T(kids[2]))
        bi = indent + INDENT
        end_tok = None
        for k in kids[3:]:
            if isinstance(k, Token):
                if k.text.lower() == 'end':
                    end_tok = k
                else:
                    self.lead(k, bi, 'none')
            elif k.kind == 'CaseBranch':
                labels, colon, stmt = k.kids
                self.lead(labels, bi, 'none')
                self.case_body(self.R(labels, True) + self.T(colon), stmt, bi)
            elif k.kind == 'CaseElse':
                self.lead(k.kids[0], bi, 'none')
                lst = k.kids[1]
                stmts = [x for x in lst.kids if isinstance(x, Node) and x.kind != 'Empty']
                if len(stmts) == 1 and (stmts[0].kind in SIMPLE or stmts[0].kind == 'Compound'):
                    self.case_body(k.kids[0].text, stmts[0], bi)
                    for x in lst.kids:
                        if isinstance(x, Token):
                            self.lead(x, bi, 'none')
                else:
                    self.line(bi, k.kids[0].text)
                    self.emit_stmt_list(lst, bi + INDENT)
            else:
                raise FormatError('syntax error in case')
        if end_tok is not None:
            self.lead(end_tok, indent, 'none')
            self.line(indent, end_tok.text + term)

    def case_body(self, head: str, stmt: Node, indent: int):
        if stmt.kind == 'Compound':
            self.line(indent, head + ' ' + self.T(stmt.kids[0]))
            self.emit_stmt_list(stmt.kids[1], indent + INDENT)
            if len(stmt.kids) > 2:
                self.lead(stmt.kids[2], indent, 'none')
                self.line(indent, stmt.kids[2].text + ';')
        elif stmt.kind in SIMPLE:
            self.line(indent, head + ' ' + self.simple(stmt, False) + ';')
        elif stmt.kind == 'Empty':
            self.line(indent, head + ' ;')
        else:
            self.line(indent, head)
            self.lead(stmt, indent + INDENT, 'none')
            self.emit_stmt(stmt, indent + INDENT, ';')

    # -- file -----------------------------------------------------------------------------------------
    def run(self) -> str:
        tree = self.res.tree
        root = tree.kids[0] if tree.kids else None
        if root is None:
            return self.res.source
        if root.kind == 'Unit':
            self.emit_unit(root)
        elif root.kind == 'Program':
            self.emit_program(root)
        else:
            raise FormatError('unsupported file structure')
        eof = self.res.sig[-1]
        self.lead(eof, 0, 'none')
        out = self.eol.join(self.wrapped())
        src = self.res.source
        body = src.rstrip('\x1a')
        if NL_RE.search(body[-2:] if body else '') and not out.endswith(self.eol):
            out += self.eol
        if src.endswith('\x1a'):
            out += '\x1a'
        self.check_conservation()
        return out

    def wrapped(self) -> List[str]:
        out = []
        for i, text in enumerate(self.lines):
            if self.width and i in self.code and len(text) > self.width and '\n' not in text and '\r' not in text:
                out.extend(wrap_line(text, self.width))
            else:
                out.append(text)
        if self.warnings is not None:
            for n, text in enumerate(out, 1):
                if len(text) > TP_LINE_LIMIT:
                    self.warnings.append('line %d: %d characters, Turbo Pascal 7 accepts at most %d'
                                         % (n, len(text), TP_LINE_LIMIT))
        return out

    def check_conservation(self):
        """Every comment / directive / inactive text of the source must have been emitted."""
        for t in self.res.sig:
            if any(x.kind in ('COMMENT', 'DIRECTIVE') or not x.active for x in t.leading) and id(t) not in self.used:
                raise AssertionError('trivia lost in front of %r (line %d)' % (t.text, t.line))

    def emit_unit(self, u: Node):
        kids = u.kids
        self.lead(kids[0], 0, 'none')
        self.line(0, kids[0].text + ' ' + self.R(kids[1]) + self.T(kids[2]))
        for k in kids[3:]:
            if isinstance(k, Token):
                continue
            if k.kind in ('Interface', 'Implementation'):
                self.emit_part(k)
            elif k.kind == 'InitSection':
                self.emit_init(k)
            elif k.kind == 'Error':
                raise FormatError('syntax error')
        if is_tok(kids[-1], '.'):
            self.lines[-1] += self.T(kids[-1])

    def emit_part(self, part: Node):
        kw = part.kids[0]
        self.lead(kw, 0, 'none', True)
        self.line(0, kw.text)
        for k in part.kids[1:]:
            if k.kind == 'UsesClause':
                self.emit_uses(k, True)
            elif k.kind in SECTIONS:
                self.emit_section(k, 0, True)
            elif k.kind == 'Routine':
                self.emit_routine(k, 0, True)
            else:
                raise FormatError('syntax error')

    def emit_init(self, init: Node):
        first = init.kids[0]
        if isinstance(first, Node) and first.kind == 'Compound':
            self.lead(first, 0, 'none', True)
            self.emit_compound(first, 0, '')
        else:
            self.lead(first, 0, 'none', True)
            self.line(0, first.text)

    def emit_program(self, p: Node):
        for k in p.kids:
            if isinstance(k, Token):
                self.lines[-1] += self.T(k)                    # final '.'
            elif k.kind == 'ProgramHeader':
                self.lead(k.kids[0], 0, 'none')
                s = k.kids[0].text + ' ' + self.R(k.kids[1])
                for t in k.kids[2:]:
                    s += self.T(t) if isinstance(t, Token) else self.R(t)
                self.line(0, s)
            elif k.kind == 'UsesClause':
                self.emit_uses(k, True)
            elif k.kind == 'Block':
                for b in k.kids:
                    if b.kind in SECTIONS:
                        self.emit_section(b, 0, True)
                    elif b.kind == 'Routine':
                        self.emit_routine(b, 0, True)
                    elif b.kind == 'Compound':
                        self.lead(b, 0, 'none', True)
                        self.emit_compound(b, 0, '')
                    elif b.kind == 'Asm':
                        self.lead(b, 0, 'none', True)
                        self.emit_asm(b, 0, '')
                    else:
                        raise FormatError('syntax error')
            else:
                raise FormatError('syntax error')


# ---------------------------------------------------------------------------------------------------
def format_source(src: str, defines=None, normalize: bool = False, provider=None, report=None,
                  width: Optional[int] = MAX_WIDTH, warnings: Optional[list] = None) -> str:
    """normalize=True also puts identifiers into the spelling of their declarations and keywords into lower case
    (tp7sema); `provider` (tp7sema.Provider) supplies other units and System.  `report`: optional list that receives
    the tp7sema.Report.  `width`: wrap code lines longer than this (None: never); `warnings`: optional list that receives
    a message for every output line that is still longer than the compiler's limit (126)."""
    res = parse(src, defines)
    if res.diags:
        tok, msg = res.diags[0]
        raise FormatError('not formatting a file with syntax problems (%d:%d: %s)' % (tok.line, tok.col, msg))
    if normalize:
        from tp7sema import normalize_case
        rep = normalize_case(res, provider)
        if report is not None:
            report.append(rep)
    return Formatter(res, width, warnings).run()


def main(argv):
    if len(argv) < 2:
        print('usage: tp7fmt.py FILE.PAS [-o OUT] [--enc cp866] [-D SYMBOL ...] [--normalize [--path DIR]... [--tpl TURBO.TPL]]')
        return 1
    enc = argv[argv.index('--enc') + 1] if '--enc' in argv else 'cp866'
    defines = None
    ds = [argv[i + 1] for i, a in enumerate(argv) if a == '-D']
    if ds:
        from tp7parse import DEFAULT_DEFINES
        defines = list(DEFAULT_DEFINES) + ds
    with open(argv[1], 'rb') as f:
        src = f.read().decode(enc)
    provider = None
    if '--normalize' in argv:
        import os
        from tp7sema import Provider
        dirs = [argv[i + 1] for i, a in enumerate(argv) if a == '--path'] or [os.path.dirname(os.path.abspath(argv[1]))]
        provider = Provider(dirs, argv[argv.index('--tpl') + 1] if '--tpl' in argv else None)
    try:
        warnings = []
        out = format_source(src, defines, normalize='--normalize' in argv, provider=provider, warnings=warnings)
        for w in warnings:
            print('warning:', w, file=sys.stderr)
    except FormatError as e:
        print('error:', e, file=sys.stderr)
        return 2
    data = out.encode(enc)
    if '-o' in argv:
        with open(argv[argv.index('-o') + 1], 'wb') as f:
            f.write(data)
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
