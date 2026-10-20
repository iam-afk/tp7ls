#!/usr/bin/env python3
"""
tp7parse.py - tolerant, lossless parser (concrete syntax tree) for Turbo Pascal 7, milestone M1.
Scope: Turbo Pascal 7 including `object` types (ancestor, fields, constructors / destructors / methods, `virtual`,
`private` / `public` sections, `Type.Method` implementations, `inherited`).  Methods are also accepted inside `record`
(an extension, parsed exactly like the methods of an object).

Guarantees
  * never raises and always terminates (any token soup yields a tree + diagnostics)
  * LOSSLESS: every significant token of the active code appears in the tree exactly once, in source
    order; every other character lives in Token.leading (trivia) of the next significant token
    (or of EOF).  reconstruct(result) == source.
  * errors become Error nodes holding the skipped tokens; the rest of the tree is still built

Conditional compilation ({$IFDEF X} {$IFNDEF X} {$IFOPT R+} {$ELSE} {$ENDIF} {$DEFINE X} {$UNDEF X})
  The parser sees ONE configuration: tokens of inactive branches are not parsed; they are kept as
  trivia (Token.active == False) so the formatter can copy them verbatim, and the begin/end balance
  of the active branch is what the parser checks.  Predefined symbols: VER70, MSDOS, CPU86
  (CPU87 is not predefined; pass defines=... to change it).  Switch state for {$IFOPT} starts from the
  TP7 defaults and follows {$X+}/{$X-} directives.  {$I file} is recorded in result.includes and kept
  as an opaque directive unless parse(..., include=resolver) is given: then the significant tokens of the file are
  spliced in at the directive (Token.file / Token.via), result.doc_sig is what is written in the text itself.

Node kinds (kids are Nodes or Tokens, in source order)
  File Program Unit Interface Implementation InitSection UsesClause
  LabelSection ConstSection ConstDecl TypeSection TypeDecl VarSection VarDecl Absolute
  Routine Params ParamGroup Directives Block Compound Asm Inline
  NamedType PointerType ArrayType RecordType FieldList FieldDecl VariantPart Variant SetType FileType
  StringType ProcType EnumType SubrangeType PackedType ObjectType Heritage Section
  Empty Assign ProcCall Inherited If While Repeat For Case CaseBranch CaseElse With Goto Labeled
  Binary Unary Paren SetCtor Literal StringLit Designator Name Field Index Deref Args Arg Aggregate
  DeclName Error

Shapes worth knowing
  RecordType  = record FieldList end            ObjectType = object [Heritage] FieldList end     Heritage = ( Name )
  FieldList   = FieldDecl | ; | VariantPart | Routine (a method declaration, no body) | Section (private / public)
  Routine     = keyword DeclName ...            for `procedure T.M` : keyword Name(T) . DeclName(M) ...  (see routine_names)
  Inherited   = inherited [Designator]          statement and expression alike
"""
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, Iterator, List, Optional, Set

from tp7lex import Token, lex, TRIVIA

DEFAULT_DEFINES = ('VER70', 'MSDOS', 'CPU86')
DEFAULT_SWITCHES = dict(A='+', B='-', D='+', E='+', F='-', G='-', I='+', L='+', N='-', O='-', P='-',
                        Q='-', R='-', S='+', T='-', V='+', X='+', Y='+')


# ---------------------------------------------------------------------------------------------------
class Node:
    __slots__ = ('kind', 'kids')

    def __init__(self, kind: str, kids=None):
        self.kind = kind
        self.kids = [k for k in (kids or []) if k is not None]

    def tokens(self) -> Iterator[Token]:
        for k in self.kids:
            if isinstance(k, Node):
                yield from k.tokens()
            else:
                yield k

    def walk(self) -> Iterator['Node']:
        """Every node of the subtree, this one first, depth first in source order (no recursion: trees are deep)."""
        stack = [self]
        pop, push = stack.pop, stack.append
        while stack:
            n = pop()
            yield n
            kids = n.kids
            for i in range(len(kids) - 1, -1, -1):
                k = kids[i]
                if k.__class__ is Node:
                    push(k)

    def nodes(self, kind: str) -> List['Node']:
        return [n for n in self.walk() if n.kind == kind]

    def first(self, kind: str) -> Optional['Node']:
        for n in self.walk():
            if n.kind == kind:
                return n
        return None

    def text(self) -> str:
        return ' '.join(t.text for t in self.tokens())

    def sexp(self) -> str:
        parts = [self.kind]
        for k in self.kids:
            parts.append(k.sexp() if isinstance(k, Node) else repr(k.text) if k.kind in ('STRING',) else k.text)
        return '(' + ' '.join(parts) + ')'

    def dump(self, depth=0) -> str:
        pad = '  ' * depth
        out = [pad + self.kind]
        for k in self.kids:
            if isinstance(k, Node):
                out.append(k.dump(depth + 1))
            else:
                out.append('%s  %s %r' % (pad, k.kind, k.text))
        return '\n'.join(out)


@dataclass
class Result:
    tree: Node
    tokens: List[Token]          # every lexer token (trivia included)
    sig: List[Token]             # significant active tokens, EOF last
    diags: list                  # [(Token, message)]
    includes: list               # [(directive Token, name)] unresolved, [(directive Token, name, path)] spliced in
    source: str

    @property
    def doc_sig(self) -> List[Token]:
        """`sig` without the tokens of {$I} include files: what is really written in this text."""
        got = self.__dict__.get('_doc_sig')
        if got is None:
            got = self.sig if not self.includes else [t for t in self.sig if t.via is None]
            self.__dict__['_doc_sig'] = got
        return got


# ---------------------------------------------------------------------------------------------------
_dir_re = re.compile(r'\s*([A-Za-z]+)(.*)', re.S)
_switch_re = re.compile(r'([A-Za-z])([+-])')


def parse_directive(text: str):
    """-> (kind, arg).  kind: IFDEF IFNDEF IFOPT ELSE ENDIF DEFINE UNDEF INCLUDE LINK SWITCH OTHER."""
    inner = text[2:-1] if text.startswith('{') else text[3:-2]
    m = _dir_re.match(inner)
    if not m:
        return 'OTHER', ''
    name, rest = m.group(1).upper(), m.group(2).strip()
    if name in ('IFDEF', 'IFNDEF', 'DEFINE', 'UNDEF'):
        return name, rest.split()[0].upper() if rest.split() else ''
    if name == 'IFOPT':
        return 'IFOPT', rest.replace(' ', '').upper()
    if name in ('ELSE', 'ENDIF'):
        return name, ''
    if name == 'INCLUDE' or (name == 'I' and rest and rest[0] not in '+-'):
        return 'INCLUDE', rest
    if name == 'L' and rest and rest[0] not in '+-':
        return 'LINK', rest
    if len(name) == 1 and re.fullmatch(r'[A-Za-z][+-](?:\s*,\s*[A-Za-z][+-])*', (name + rest).strip()):
        return 'SWITCH', name + rest
    return 'OTHER', rest


MAX_INCLUDE_DEPTH = 8


def prepare(tokens: List[Token], defines=None, include=None, path=None):
    """Evaluate conditional compilation, mark Token.active, attach trivia to the next significant token.
    -> (sig tokens incl. EOF last, diags, includes)

    include(name, from_path) -> (path, text) | None resolves a `{$I name}` directive.  When it is given, the significant
    tokens of the include file are spliced into `sig` at the directive (they carry .file and .via; the file's own trivia
    and directives are dropped), so the parser sees what the compiler sees.  Conditional state is shared with the main
    file.  A name that cannot be resolved stays in `includes` as (token, name) with no splice; the ones that were
    spliced are in `includes` as (token, name, path)."""
    defs: Set[str] = {d.upper() for d in (DEFAULT_DEFINES if defines is None else defines)}
    sw = dict(DEFAULT_SWITCHES)
    stack: list = []                      # [parent_active, branch_taken, branch_active, opener]
    active = True
    diags, includes, sig = [], [], []
    pending: list = []

    def feed(toks, chain, via):
        """chain: paths being included (cycle guard); via: the directive token of the include, None for the main file"""
        nonlocal active, pending
        own = via is None
        for t in toks:
            t.leading = []
            if not own:
                t.via = via
                t.file = chain[-1]
            if t.kind == 'DIRECTIVE':
                kind, arg = parse_directive(t.text)
                if kind in ('IFDEF', 'IFNDEF', 'IFOPT'):
                    t.active = active
                    if kind == 'IFDEF':
                        cond = arg in defs
                    elif kind == 'IFNDEF':
                        cond = arg not in defs
                    else:
                        cond = len(arg) == 2 and sw.get(arg[0]) == arg[1]
                    new = active and cond
                    stack.append([active, new, new, t])
                    active = new
                elif kind == 'ELSE':
                    if not stack:
                        diags.append((t, '{$ELSE} without {$IFDEF}'))
                        t.active = active
                    else:
                        top = stack[-1]
                        t.active = top[0]
                        new = top[0] and not top[1]
                        top[1] = top[1] or new
                        top[2] = new
                        active = new
                elif kind == 'ENDIF':
                    if not stack:
                        diags.append((t, '{$ENDIF} without {$IFDEF}'))
                        t.active = active
                    else:
                        top = stack.pop()
                        t.active = top[0]
                        active = top[0]
                else:
                    t.active = active
                    if active:
                        if kind == 'DEFINE':
                            defs.add(arg)
                        elif kind == 'UNDEF':
                            defs.discard(arg)
                        elif kind == 'INCLUDE':
                            got = include(arg, chain[-1]) if include is not None and own_or_ok(chain) else None
                            if got is not None and os.path.normcase(os.path.abspath(got[0])) in \
                                    [os.path.normcase(os.path.abspath(c)) for c in chain if c]:
                                got = None                  # an include file that includes itself
                            if got is None:
                                includes.append((t if own else via, arg))
                            else:
                                ipath, itext = got
                                includes.append((t if own else via, arg, ipath))
                                sub = lex(itext)
                                for i, x in enumerate(sub):
                                    x.idx = i
                                if own:
                                    pending.append(t)
                                feed([x for x in sub if x.kind != 'EOF'], chain + [ipath], t if own else via)
                                continue
                        elif kind == 'SWITCH':
                            for letter, val in _switch_re.findall(arg):
                                sw[letter.upper()] = val
                if own:
                    pending.append(t)
                continue
            t.active = active
            if t.kind != 'EOF' and (t.kind in TRIVIA or not active):
                if own:
                    pending.append(t)         # trivia, or any token of an inactive branch
            else:
                if own:
                    t.leading = pending       # significant token (EOF included) takes the trivia before it
                    pending = []
                sig.append(t)

    def own_or_ok(chain):                     # depth limit and cycles: the include is left unresolved
        return len(chain) <= MAX_INCLUDE_DEPTH

    feed(tokens, [path], None)
    for top in stack:
        diags.append((top[3], 'conditional directive is never closed with {$ENDIF}'))
    return sig, diags, includes


def routine_names(r: Node):
    """(owner Name node or None, DeclName node) of a Routine: `procedure T.M` -> (Name T, DeclName M)."""
    k = r.kids
    if len(k) > 3 and isinstance(k[1], Node) and k[1].kind == 'Name' and isinstance(k[2], Token) and k[2].text == '.':
        return k[1], k[3]
    return None, (k[1] if len(k) > 1 else None)


def fieldlist_of(t: Node) -> Optional[Node]:
    """The FieldList of a RecordType / ObjectType node."""
    return next((x for x in t.kids if isinstance(x, Node) and x.kind == 'FieldList'), None)


# ---------------------------------------------------------------------------------------------------
DECL_KW = frozenset('const type var label procedure function constructor destructor implementation '
                    'interface unit program uses'.split())
ROUTINE_DIRECTIVES = frozenset('forward external far near interrupt assembler export virtual override'.split())
REL_OPS = frozenset(['=', '<>', '<', '>', '<=', '>='])
ADD_OPS = frozenset(['+', '-'])
MUL_OPS = frozenset(['*', '/'])


class Parser:
    def __init__(self, sig: List[Token], diags: list):
        self.t = sig
        self.i = 0
        self.diags = diags

    # -- token access ---------------------------------------------------------------------------
    @property
    def cur(self) -> Token:
        return self.t[self.i]

    def la(self, k=1) -> Token:
        return self.t[min(self.i + k, len(self.t) - 1)]

    def take(self) -> Token:
        t = self.t[self.i]
        if t.kind != 'EOF':
            self.i += 1
        return t

    def eof(self) -> bool:
        return self.cur.kind == 'EOF'

    def kw(self, *names, k=0) -> bool:
        t = self.la(k) if k else self.cur
        return t.kind == 'KW' and t.text.lower() in names

    def sym(self, *s, k=0) -> bool:
        t = self.la(k) if k else self.cur
        return t.kind == 'SYM' and t.text in s

    def ident(self, k=0) -> bool:
        return (self.la(k) if k else self.cur).kind == 'IDENT'

    def idn(self, *names, k=0) -> bool:
        t = self.la(k) if k else self.cur
        return t.kind == 'IDENT' and t.text.lower() in names

    def lbr(self, k=0) -> bool:
        return self.sym('[', '(.', k=k)

    def rbr(self, k=0) -> bool:
        return self.sym(']', '.)', k=k)

    def diag(self, msg: str):
        self.diags.append((self.cur, msg))

    def want_kw(self, kids, name) -> bool:
        if self.kw(name):
            kids.append(self.take())
            return True
        self.diag("expected '%s'" % name)
        return False

    def want_sym(self, kids, *s) -> bool:
        if self.sym(*s):
            kids.append(self.take())
            return True
        self.diag("expected '%s'" % s[0])
        return False

    def semi(self, kids):
        """A ';' that is allowed to be missing (diagnosed, not fatal)."""
        if self.sym(';'):
            kids.append(self.take())
        else:
            self.diag("expected ';'")

    def error_skip(self, stop=None, at_least_one=True) -> Node:
        """Wrap tokens up to a synchronisation point into an Error node."""
        kids = []
        while not self.eof() and not (stop and stop()):
            kids.append(self.take())
            at_least_one = False
        if at_least_one and not self.eof():
            kids.append(self.take())
        return Node('Error', kids)

    # -- names ----------------------------------------------------------------------------------
    def decl_name(self) -> Node:
        if self.ident():
            return Node('DeclName', [self.take()])
        self.diag('identifier expected')
        return Node('Error')

    def name(self) -> Node:
        if self.ident():
            return Node('Name', [self.take()])
        self.diag('identifier expected')
        return Node('Error')

    def qualified_name(self) -> Node:
        kids = [self.name()]
        while self.sym('.') and self.ident(1):
            kids.append(self.take())
            kids.append(self.take())
        return Node('Name', [k for kk in kids for k in (kk.kids if isinstance(kk, Node) else [kk])])

    # -- file structure -------------------------------------------------------------------------
    def file(self) -> Node:
        kids = []
        if self.kw('unit'):
            kids.append(self.unit())
        else:
            kids.append(self.program())
        if not self.eof():
            self.diag('unexpected text after the end of the file')
            kids.append(self.error_skip(stop=lambda: False, at_least_one=False))
        return Node('File', kids)

    def program(self) -> Node:
        kids = []
        if self.kw('program'):
            hk = [self.take(), self.decl_name()]
            if self.sym('('):
                hk.append(self.take())
                while not self.eof() and not self.sym(')') and not self.sym(';'):
                    hk.append(self.take())
                self.want_sym(hk, ')')
            self.semi(hk)
            kids.append(Node('ProgramHeader', hk))
        if self.kw('uses'):
            kids.append(self.uses())
        kids.append(self.block())
        k2 = []
        self.want_sym(k2, '.')
        return Node('Program', kids + k2)

    def uses(self) -> Node:
        kids = [self.take()]
        while True:
            kids.append(self.name())
            if self.sym(','):
                kids.append(self.take())
                continue
            break
        self.semi(kids)
        return Node('UsesClause', kids)

    def unit(self) -> Node:
        kids = [self.take(), self.decl_name()]
        self.semi(kids)
        ik = []
        self.want_kw(ik, 'interface')
        if self.kw('uses'):
            ik.append(self.uses())
        self.declarations(ik, interface=True)
        kids.append(Node('Interface', ik))
        mk = []
        self.want_kw(mk, 'implementation')
        if self.kw('uses'):
            mk.append(self.uses())
        self.declarations(mk, interface=False)
        kids.append(Node('Implementation', mk))
        if self.kw('begin'):
            kids.append(Node('InitSection', [self.compound()]))
        else:
            ek = []
            self.want_kw(ek, 'end')
            kids.append(Node('InitSection', ek))
        k2 = []
        self.want_sym(k2, '.')
        return Node('Unit', kids + k2)

    # -- declarations ---------------------------------------------------------------------------
    def declarations(self, kids: list, interface: bool):
        while True:
            p = self.i
            if self.kw('label'):
                kids.append(self.label_section())
            elif self.kw('const'):
                kids.append(self.const_section())
            elif self.kw('type'):
                kids.append(self.type_section())
            elif self.kw('var'):
                kids.append(self.var_section())
            elif self.kw('procedure', 'function', 'constructor', 'destructor'):
                kids.append(self.routine(interface))
            else:
                if not (self.kw('begin', 'end', 'asm', 'implementation', 'interface') or self.eof()):
                    self.diag('declaration expected')
                    kids.append(self.error_skip(stop=lambda: self.kw('begin', 'end', 'asm', 'const', 'type', 'var',
                                                                       'label', 'procedure', 'function',
                                                                       'implementation', 'constructor',
                                                                       'destructor')))
                    if self.i == p:
                        break
                    continue
                break
            if self.i == p:
                break

    def label_section(self) -> Node:
        kids = [self.take()]
        while self.cur.kind in ('INT', 'IDENT'):
            kids.append(self.take())
            if self.sym(','):
                kids.append(self.take())
            else:
                break
        self.semi(kids)
        return Node('LabelSection', kids)

    def const_section(self) -> Node:
        kids = [self.take()]
        while self.ident():
            dk = [self.decl_name()]
            if self.sym(':'):
                dk.append(self.take())
                dk.append(self.type_())
                self.want_sym(dk, '=')
                dk.append(self.const_value())
            else:
                self.want_sym(dk, '=')
                dk.append(self.expr())
            self.semi(dk)
            kids.append(Node('ConstDecl', dk))
        return Node('ConstSection', kids)

    def type_section(self) -> Node:
        kids = [self.take()]
        while self.ident():
            dk = [self.decl_name()]
            self.want_sym(dk, '=')
            dk.append(self.type_())
            self.semi(dk)
            kids.append(Node('TypeDecl', dk))
        return Node('TypeSection', kids)

    def var_section(self) -> Node:
        kids = [self.take()]
        while self.ident():
            dk = [self.decl_name()]
            while self.sym(','):
                dk.append(self.take())
                dk.append(self.decl_name())
            self.want_sym(dk, ':')
            dk.append(self.type_())
            if self.idn('absolute'):
                ak = [self.take(), self.expr()]
                if self.sym(':'):
                    ak.append(self.take())
                    ak.append(self.expr())
                dk.append(Node('Absolute', ak))
            self.semi(dk)
            kids.append(Node('VarDecl', dk))
        return Node('VarSection', kids)

    def const_value(self) -> Node:
        """Typed-constant initialiser: expression or (nested) aggregate  (1,2) / (a: 1; b: 2)."""
        if self.sym('(') and self.looks_like_aggregate():
            return self.aggregate()
        return self.expr()

    def looks_like_aggregate(self) -> bool:
        depth, j = 0, self.i
        while j < len(self.t):
            t = self.t[j]
            if t.kind == 'EOF':
                return False
            if t.kind == 'SYM':
                if t.text == '(':
                    depth += 1
                elif t.text == ')':
                    depth -= 1
                    if depth == 0:
                        return False
                elif depth == 1 and t.text in (',', ';'):
                    return True
                elif depth == 1 and t.text == ':':
                    return True
            j += 1
        return False

    def aggregate(self) -> Node:
        kids = [self.take()]
        while not self.eof() and not self.sym(')'):
            p = self.i
            if self.ident() and self.sym(':', k=1):
                kids += [self.take(), self.take()]
            kids.append(self.const_value())
            if self.sym(',', ';'):
                kids.append(self.take())
            elif not self.sym(')'):
                self.diag("expected ',' or ')'")
                if self.i == p:
                    kids.append(self.error_skip(stop=lambda: self.sym(')', ';')))
        self.want_sym(kids, ')')
        return Node('Aggregate', kids)

    # -- routines -------------------------------------------------------------------------------
    def params(self) -> Node:
        kids = [self.take()]                                  # '('
        while not self.eof() and not self.sym(')'):
            p = self.i
            gk = []
            if self.kw('var', 'const'):
                gk.append(self.take())
            gk.append(self.decl_name())
            while self.sym(','):
                gk.append(self.take())
                gk.append(self.decl_name())
            if self.sym(':'):
                gk.append(self.take())
                gk.append(self.type_())
            kids.append(Node('ParamGroup', gk))
            if self.sym(';'):
                kids.append(self.take())
            elif not self.sym(')'):
                self.diag("expected ';' or ')'")
                kids.append(self.error_skip(stop=lambda: self.sym(')', ';') or self.kw('begin', 'var')))
            if self.i == p:
                kids.append(self.error_skip())
        self.want_sym(kids, ')')
        return Node('Params', kids)

    def routine(self, interface: bool) -> Node:
        kids = [self.take()]
        first = self.decl_name()
        if first.kind == 'DeclName' and self.sym('.') and self.ident(1):      # Type.Method: Name(Type) . DeclName(Method)
            kids += [Node('Name', first.kids), self.take(), self.decl_name()]
        else:
            kids.append(first)
        if self.sym('('):
            kids.append(self.params())
        if self.sym(':'):
            kids.append(self.take())
            kids.append(self.type_())
        self.semi(kids)
        dk, forward = [], False
        while True:
            if self.idn(*ROUTINE_DIRECTIVES):
                name = self.cur.text.lower()
                dk.append(self.take())
                if name in ('forward', 'external'):
                    forward = True
                if name == 'external':
                    while not self.eof() and not self.sym(';') and not self.kw('begin'):
                        dk.append(self.take())
                self.semi(dk)
            elif self.kw('inline'):
                dk.append(self.inline_())
                self.semi(dk)
                forward = True
            else:
                break
        if dk:
            kids.append(Node('Directives', dk))
        if not interface and not forward:
            kids.append(self.block())
            self.semi(kids)
        return Node('Routine', kids)

    def inline_(self) -> Node:
        kids = [self.take()]
        if self.sym('('):
            depth = 0
            while not self.eof():
                t = self.take()
                kids.append(t)
                if t.kind == 'SYM' and t.text == '(':
                    depth += 1
                elif t.kind == 'SYM' and t.text == ')':
                    depth -= 1
                    if depth == 0:
                        break
        return Node('Inline', kids)

    def block(self) -> Node:
        kids = []
        self.declarations(kids, interface=False)
        if self.kw('begin'):
            kids.append(self.compound())
        elif self.kw('asm'):
            kids.append(self.asm())
        else:
            self.diag("'begin' expected")
        return Node('Block', kids)

    # -- types ----------------------------------------------------------------------------------
    def type_(self) -> Node:
        if self.kw('packed'):
            return Node('PackedType', [self.take(), self.type_()])
        if self.sym('^'):
            caret = self.take()
            if self.kw('string'):                                 # ^String: the only reserved word that is also a type name
                return Node('PointerType', [caret, Node('Name', [self.take()])])
            return Node('PointerType', [caret, self.qualified_name()])
        if self.kw('array'):
            kids = [self.take()]
            if self.lbr():
                kids.append(self.take())
                while True:
                    kids.append(self.type_())
                    if self.sym(','):
                        kids.append(self.take())
                        continue
                    break
                if self.rbr():
                    kids.append(self.take())
                else:
                    self.diag("expected ']'")
            elif not self.kw('of'):                               # `array of T` (no bounds): an open array parameter
                self.diag("expected '['")
            self.want_kw(kids, 'of')
            kids.append(self.type_())
            return Node('ArrayType', kids)
        if self.kw('record'):
            kids = [self.take(), self.field_list(methods=True)]
            self.want_kw(kids, 'end')
            return Node('RecordType', kids)
        if self.kw('set'):
            kids = [self.take()]
            self.want_kw(kids, 'of')
            kids.append(self.type_())
            return Node('SetType', kids)
        if self.kw('file'):
            kids = [self.take()]
            if self.kw('of'):
                kids += [self.take(), self.type_()]
            return Node('FileType', kids)
        if self.kw('string'):
            kids = [self.take()]
            if self.lbr():
                kids += [self.take(), self.expr()]
                if self.rbr():
                    kids.append(self.take())
                else:
                    self.diag("expected ']'")
            return Node('StringType', kids)
        if self.kw('object'):
            return self.object_type()
        if self.kw('procedure', 'function'):
            kids = [self.take()]
            if self.sym('('):
                kids.append(self.params())
            if self.sym(':'):
                kids += [self.take(), self.type_()]
            return Node('ProcType', kids)
        if self.sym('(') and self.looks_like_enum():
            kids = [self.take(), self.decl_name()]
            while self.sym(','):
                kids += [self.take(), self.decl_name()]
            self.want_sym(kids, ')')
            return Node('EnumType', kids)
        if self.ident() and not self.sym('..', k=1):
            return self.qualified_name_type()
        if self.cur.kind in ('INT', 'HEX', 'REAL', 'STRING', 'CHARCODE', 'IDENT') or self.sym('+', '-', '('):
            lo = self.simple_expr()
            kids = [lo]
            self.want_sym(kids, '..')
            kids.append(self.simple_expr())
            return Node('SubrangeType', kids)
        self.diag('type expected')
        return Node('Error')

    def qualified_name_type(self) -> Node:
        return Node('NamedType', [self.qualified_name()])

    def looks_like_enum(self) -> bool:
        j = min(self.i + 1, len(self.t) - 1)
        if self.t[j].kind != 'IDENT':
            return False
        nxt = self.t[min(j + 1, len(self.t) - 1)]
        return nxt.kind == 'SYM' and nxt.text in (',', ')')

    def object_type(self) -> Node:
        """object [(Ancestor)] fields and methods [private / public sections] end"""
        kids = [self.take()]
        if self.sym('('):
            hk = [self.take(), self.qualified_name()]
            self.want_sym(hk, ')')
            kids.append(Node('Heritage', hk))
        kids.append(self.field_list(methods=True))
        self.want_kw(kids, 'end')
        return Node('ObjectType', kids)

    def field_list(self, methods: bool = False) -> Node:
        """Fields (`a, b: T;`), a variant part, and - with methods=True (record / object) - method declarations and
        `private` / `public` section markers."""
        kids = []
        while True:
            p = self.i
            if self.kw('case'):
                kids.append(self.variant_part())
                break
            elif methods and self.kw('procedure', 'function', 'constructor', 'destructor'):
                kids.append(self.routine(interface=True))
            elif methods and self.idn('private', 'public') and not self.sym(':', ',', k=1):
                kids.append(Node('Section', [self.take()]))
            elif self.ident():
                fk = [self.decl_name()]
                while self.sym(','):
                    fk += [self.take(), self.decl_name()]
                self.want_sym(fk, ':')
                fk.append(self.type_())
                kids.append(Node('FieldDecl', fk))
                if self.sym(';'):
                    kids.append(self.take())
            elif self.sym(';'):
                kids.append(self.take())
            else:
                break
            if self.i == p:
                break
        return Node('FieldList', kids)

    def variant_part(self) -> Node:
        kids = [self.take()]                                       # case
        if self.ident() and self.sym(':', k=1):
            kids += [self.decl_name(), self.take()]
        kids.append(self.type_())
        self.want_kw(kids, 'of')
        while not self.eof() and not self.kw('end') and not self.sym(')'):
            p = self.i
            vk = [self.label_list()]
            self.want_sym(vk, ':')
            self.want_sym(vk, '(')
            vk.append(self.field_list())
            self.want_sym(vk, ')')
            kids.append(Node('Variant', vk))
            if self.sym(';'):
                kids.append(self.take())
            if self.i == p:
                kids.append(self.error_skip())
        return Node('VariantPart', kids)

    def label_list(self) -> Node:
        kids = []
        while True:
            kids.append(self.expr())
            if self.sym('..'):
                kids += [self.take(), self.expr()]
            if self.sym(','):
                kids.append(self.take())
                continue
            break
        return Node('Labels', kids)

    # -- statements -----------------------------------------------------------------------------
    def compound(self) -> Node:
        kids = [self.take()]
        kids.append(self.stmt_list(('end',)))
        self.want_kw(kids, 'end')
        return Node('Compound', kids)

    def asm(self) -> Node:
        kids = [self.take()]
        while not self.eof() and not self.kw('end'):
            kids.append(self.take())
        self.want_kw(kids, 'end')
        return Node('Asm', kids)

    def at_stop(self, stops) -> bool:
        return self.eof() or self.kw(*stops) or self.kw(*DECL_KW)

    def stmt_list(self, stops) -> Node:
        kids = []
        while not self.at_stop(stops):
            p = self.i
            kids.append(self.statement())
            last = kids[-1]
            if last.kind == 'Error' and len(last.kids) == 1 and getattr(last.kids[0], 'text', '').lower() == 'else':
                continue                                      # a stray else was reported: the statement after it follows
            if self.sym(';'):
                kids.append(self.take())
            elif self.at_stop(stops):
                break
            elif self.i == p:
                self.diag('statement expected')
                kids.append(self.error_skip())
            else:
                self.diag("expected ';'")
        if self.kw(*DECL_KW) and not self.eof():
            self.diag("unexpected '%s' inside a statement list (missing 'end'?)" % self.cur.text)
        return Node('StmtList', kids)

    def statement(self) -> Node:
        t = self.cur
        if t.kind in ('INT', 'IDENT') and self.sym(':', k=1):
            return Node('Labeled', [self.take(), self.take(), self.statement()])
        if t.kind == 'KW':
            w = t.text.lower()
            if w == 'begin':
                return self.compound()
            if w == 'if':
                kids = [self.take(), self.expr()]
                self.want_kw(kids, 'then')
                kids.append(Node('Empty') if self.kw('else') else self.statement())     # `if c then else x` is legal
                if self.kw('else'):
                    kids += [self.take(), self.statement()]
                return Node('If', kids)
            if w == 'while':
                kids = [self.take(), self.expr()]
                self.want_kw(kids, 'do')
                kids.append(self.statement())
                return Node('While', kids)
            if w == 'repeat':
                kids = [self.take(), self.stmt_list(('until',))]
                self.want_kw(kids, 'until')
                kids.append(self.expr())
                return Node('Repeat', kids)
            if w == 'for':
                kids = [self.take(), self.name()]
                self.want_sym(kids, ':=')
                kids.append(self.expr())
                if self.kw('to', 'downto'):
                    kids.append(self.take())
                else:
                    self.diag("expected 'to' or 'downto'")
                kids.append(self.expr())
                self.want_kw(kids, 'do')
                kids.append(self.statement())
                return Node('For', kids)
            if w == 'case':
                return self.case_stmt()
            if w == 'with':
                kids = [self.take(), self.designator()]
                while self.sym(','):
                    kids += [self.take(), self.designator()]
                self.want_kw(kids, 'do')
                kids.append(self.statement())
                return Node('With', kids)
            if w == 'goto':
                kids = [self.take()]
                if self.cur.kind in ('INT', 'IDENT'):
                    kids.append(self.take())
                else:
                    self.diag('label expected')
                return Node('Goto', kids)
            if w == 'asm':
                return self.asm()
            if w == 'inline':
                return self.inline_()
            if w == 'inherited':
                return self.inherited()
            if w in ('end', 'until', 'else'):
                if w == 'else':                              # stray else: swallow it, keep going
                    after_semi = self.i > 0 and self.t[self.i - 1].text == ';'
                    self.diag("unexpected 'else'" + (" (the ';' before 'else' ended the if statement: remove it)"
                                                      if after_semi else ''))
                    return Node('Error', [self.take()])
                return Node('Empty')
            self.diag('statement expected')
            return Node('Error', [self.take()]) if not self.kw(*DECL_KW) else Node('Empty')
        if t.kind == 'IDENT':
            d = self.designator()
            if self.sym(':='):
                return Node('Assign', [d, self.take(), self.expr()])
            return Node('ProcCall', [d])
        if t.kind == 'SYM' and t.text == ';':
            return Node('Empty')
        if t.kind == 'EOF':
            return Node('Empty')
        self.diag('statement expected')
        return Node('Error', [self.take()])

    def inherited(self) -> Node:
        """`inherited` alone (the same method of the ancestor, same arguments) or `inherited Name(args)`."""
        kids = [self.take()]
        if self.ident():
            kids.append(self.designator())
        return Node('Inherited', kids)

    def case_stmt(self) -> Node:
        kids = [self.take(), self.expr()]
        self.want_kw(kids, 'of')
        while not self.eof() and not self.kw('end', 'else') and not self.kw(*DECL_KW):
            p = self.i
            bk = [self.label_list()]
            self.want_sym(bk, ':')
            bk.append(self.statement())
            kids.append(Node('CaseBranch', bk))
            if self.sym(';'):
                kids.append(self.take())
            elif not self.kw('end', 'else'):
                self.diag("expected ';'")
            if self.i == p:
                kids.append(self.error_skip())
        if self.kw('else'):
            ek = [self.take(), self.stmt_list(('end',))]
            kids.append(Node('CaseElse', ek))
        self.want_kw(kids, 'end')
        return Node('Case', kids)

    # -- expressions ----------------------------------------------------------------------------
    def expr(self) -> Node:
        left = self.simple_expr()
        while self.kw('in') or self.sym(*REL_OPS):
            op = self.take()
            left = Node('Binary', [left, op, self.simple_expr()])
        return left

    def simple_expr(self) -> Node:
        if self.sym('+', '-'):
            left = Node('Unary', [self.take(), self.term()])
        else:
            left = self.term()
        while self.sym(*ADD_OPS) or self.kw('or', 'xor'):
            op = self.take()
            left = Node('Binary', [left, op, self.term()])
        return left

    def term(self) -> Node:
        left = self.factor()
        while self.sym(*MUL_OPS) or self.kw('div', 'mod', 'and', 'shl', 'shr'):
            op = self.take()
            left = Node('Binary', [left, op, self.factor()])
        return left

    def factor(self) -> Node:
        t = self.cur
        if t.kind == 'KW':
            w = t.text.lower()
            if w == 'not':
                return Node('Unary', [self.take(), self.factor()])
            if w == 'nil':
                return Node('Literal', [self.take()])
            if w == 'inherited':
                return self.inherited()
        elif t.kind == 'SYM':
            if t.text in ('@', '+', '-'):
                return Node('Unary', [self.take(), self.factor()])
            if t.text == '(':
                kids = [self.take(), self.expr()]
                self.want_sym(kids, ')')
                return Node('Paren', kids)
            if t.text in ('[', '(.'):
                return self.set_ctor()
        elif t.kind in ('INT', 'HEX', 'REAL'):
            return Node('Literal', [self.take()])
        elif t.kind in ('STRING', 'CHARCODE'):
            kids = [self.take()]
            while self.cur.kind in ('STRING', 'CHARCODE') and not self.cur.leading:
                kids.append(self.take())
            return Node('StringLit', kids)
        elif t.kind == 'IDENT':
            return self.designator()
        self.diag('expression expected')
        return Node('Error')

    def set_ctor(self) -> Node:
        kids = [self.take()]
        while not self.eof() and not self.rbr():
            p = self.i
            kids.append(self.expr())
            if self.sym('..'):
                kids += [self.take(), self.expr()]
            if self.sym(','):
                kids.append(self.take())
            elif not self.rbr():
                self.diag("expected ',' or ']'")
                kids.append(self.error_skip(stop=lambda: self.rbr() or self.sym(';')))
            if self.i == p:
                kids.append(self.error_skip())
        if self.rbr():
            kids.append(self.take())
        else:
            self.diag("expected ']'")
        return Node('SetCtor', kids)

    def designator(self) -> Node:
        kids = [self.name()]
        while True:
            if self.sym('.') and self.ident(1):
                kids.append(Node('Field', [self.take(), self.take()]))
            elif self.lbr():
                ik = [self.take()]
                while not self.eof() and not self.rbr():
                    p = self.i
                    ik.append(self.expr())
                    if self.sym(','):
                        ik.append(self.take())
                    elif not self.rbr():
                        self.diag("expected ',' or ']'")
                        ik.append(self.error_skip(stop=lambda: self.rbr() or self.sym(';')))
                    if self.i == p:
                        ik.append(self.error_skip())
                if self.rbr():
                    ik.append(self.take())
                else:
                    self.diag("expected ']'")
                kids.append(Node('Index', ik))
            elif self.sym('^'):
                kids.append(Node('Deref', [self.take()]))
            elif self.sym('('):
                ak = [self.take()]
                while not self.eof() and not self.sym(')'):
                    p = self.i
                    gk = [self.expr()]
                    while self.sym(':'):                        # Write(x:8:2)
                        gk += [self.take(), self.expr()]
                    ak.append(Node('Arg', gk))
                    if self.sym(','):
                        ak.append(self.take())
                    elif not self.sym(')'):
                        self.diag("expected ',' or ')'")
                        ak.append(self.error_skip(stop=lambda: self.sym(')', ';')))
                    if self.i == p:
                        ak.append(self.error_skip())
                self.want_sym(ak, ')')
                kids.append(Node('Args', ak))
            else:
                break
        return Node('Designator', kids)


# ---------------------------------------------------------------------------------------------------
def parse(src: str, defines=None, include=None, path=None) -> Result:
    tokens = lex(src)
    for i, t in enumerate(tokens):
        t.idx = i
    sig, diags, includes = prepare(tokens, defines, include, path)
    try:
        p = Parser(sig, diags)
        tree = p.file()
    except RecursionError:                                  # absurdly nested input: keep everything, as one error
        diags.append((sig[0], 'nesting too deep'))
        tree = Node('File', [Node('Error', sig[:-1])])
    return Result(tree, tokens, sig, diags, includes, src)


def reconstruct(res: Result) -> str:
    """Rebuild the source from the tree (leading trivia + token text, in order)."""
    out = []
    for t in list(res.tree.tokens()) + [res.sig[-1]]:
        out.extend(x.text for x in t.leading)
        out.append(t.text)
    return ''.join(out)


def main(argv):
    if len(argv) < 2:
        print('usage: tp7parse.py FILE.PAS [--dump|--sexp|--check] [-D SYMBOL ...] [--enc cp866]')
        return 1
    enc = argv[argv.index('--enc') + 1] if '--enc' in argv else 'cp866'
    defines = list(DEFAULT_DEFINES) + [argv[i + 1] for i, a in enumerate(argv) if a == '-D']
    with open(argv[1], 'rb') as f:
        src = f.read().decode(enc)
    res = parse(src, defines)
    mode = next((a for a in argv[2:] if a in ('--dump', '--sexp', '--check')), '--check')
    if mode == '--dump':
        print(res.tree.dump())
    elif mode == '--sexp':
        print(res.tree.sexp())
    else:
        print('%d significant tokens, %d diagnostics, roundtrip %s' % (
            len(res.sig) - 1, len(res.diags), 'OK' if reconstruct(res) == src else 'BROKEN'))
    for tok, msg in res.diags[:30]:
        print('  %d:%d %s' % (tok.line, tok.col, msg))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
