"""Types of Turbo Pascal 7 and the rules about them: what an expression is, what may be assigned to what.

The names are resolved already (tp7sema.Binder keeps, for every identifier token, the symbol it stands for); this module
adds the types of those symbols and of the expressions built from them, and reports what the compiler would reject:
  * `x := e` with types that do not fit, constants out of range, assignment to a constant;
  * a non-Boolean condition in if / while / repeat; a non-ordinal `for` variable or `case` selector;
  * operators applied to operands they do not accept, comparisons of unrelated types;
  * calls: too many or too few arguments, arguments that do not fit, a non-variable passed to a `var` parameter.
Whatever is not understood has the type UNKNOWN, and UNKNOWN is compatible with everything: a missing rule means a
missing report, never a false one.  The rules follow the Turbo Pascal 7.0 language guide (ch. 3 "Expressions").
"""
from typing import Dict, List, Optional

from tp7parse import Node
from tp7lex import Token


# ---------------------------------------------------------------------------------------------------
class Ty:
    """A type.  kind: unknown void int real bool char string enum set array record object pointer file proc nil.
    Types are compared by identity (`is`): a declaration makes one Ty, and an alias is the same Ty as what it names."""

    def __init__(self, kind, name=None, **kw):
        self.kind = kind
        self.name = name
        self.sym = None              # the declaring type symbol (named types)
        self.builtin = False
        self.lo = self.hi = None     # int: the range;  enum: unused
        self.value = None            # int constant: its value
        self.host = None             # enum subrange: the enumeration; char: unused
        self.elem = None             # array / file / set: element (base) type
        self.index = None            # array: [index types]
        self.maxlen = None           # string
        self.open = False            # open array parameter
        self.text = False            # Text file
        self.params = None           # proc: [Spec]
        self.result = None           # proc: Ty or None
        self.strlit = None           # string literal: its length
        self._target = None
        self._anc = None
        self.__dict__.update(kw)

    @property
    def target(self) -> Optional['Ty']:
        t = self._target
        if callable(t):
            self._target = t = t()
        return t

    @property
    def ancestor(self) -> Optional['Ty']:
        t = self._anc
        if callable(t):
            self._anc = t = t()
        return t

    def __repr__(self):
        return 'Ty(%s)' % show(self)


def _b(kind, name, **kw) -> Ty:
    t = Ty(kind, name, **kw)
    t.builtin = True
    return t


UNKNOWN = _b('unknown', '?')
VOID = _b('void', 'procedure')
NIL = _b('nil', 'nil')
BYTE = _b('int', 'Byte', lo=0, hi=255)
SHORTINT = _b('int', 'ShortInt', lo=-128, hi=127)
INTEGER = _b('int', 'Integer', lo=-32768, hi=32767)
WORD = _b('int', 'Word', lo=0, hi=65535)
LONGINT = _b('int', 'Longint', lo=-2 ** 31, hi=2 ** 31 - 1)
REAL = _b('real', 'Real')
SINGLE = _b('real', 'Single')
DOUBLE = _b('real', 'Double')
EXTENDED = _b('real', 'Extended')
COMP = _b('real', 'Comp', comp=True)
BOOLEAN = _b('bool', 'Boolean')
BYTEBOOL = _b('bool', 'ByteBool')
WORDBOOL = _b('bool', 'WordBool')
LONGBOOL = _b('bool', 'LongBool')
CHAR = _b('char', 'Char')
STRING = _b('string', 'string', maxlen=255)
POINTER = _b('pointer', 'Pointer', _target=None)
TEXT = _b('file', 'Text', text=True)
UNTYPED_FILE = _b('file', 'file')
FLOAT = Ty('real', None)         # a computed real: Real in {$N-} code, Extended in {$N+} code (the 8087 computes in Extended)

BUILTIN = {t.name.lower(): t for t in (BYTE, SHORTINT, INTEGER, WORD, LONGINT, REAL, SINGLE, DOUBLE, EXTENDED, COMP,
                                       BOOLEAN, BYTEBOOL, WORDBOOL, LONGBOOL, CHAR, STRING, POINTER, TEXT)}
ORDINAL = ('int', 'bool', 'char', 'enum')


def show(t: Optional[Ty]) -> str:
    """The type as a message names it."""
    if t is None:
        return '?'
    if t.name and not (t.kind == 'int' and t.value is not None):
        return t.name
    k = t.kind
    if k == 'int':
        return 'integer constant' if t.value is not None else 'integer'
    if k == 'string':
        return 'string constant' if t.strlit is not None else 'string'
    if k == 'pointer':
        tg = t.target
        return '^' + show(tg) if tg is not None else 'Pointer'
    if k == 'set':
        return 'set of ' + show(t.elem) if t.elem is not None else 'set'
    if k == 'array':
        return 'array'
    if k == 'proc':
        return 'function' if t.result is not None else 'procedure'
    return {'enum': 'enumeration', 'record': 'record', 'object': 'object', 'file': 'file', 'real': 'Real',
            'char': 'Char', 'bool': 'Boolean', 'nil': 'nil'}.get(k, k)


def int_const(v: int) -> Ty:
    return Ty('int', None, lo=v, hi=v, value=v)


def common_int(a: Ty, b: Ty) -> Ty:
    """Type of a binary operation on two integers (language guide, "Integer types"): both operands are converted to their
    common type, the predefined integer type with the smallest range that includes all possible values of both types, and
    the result is of that type (Integer and Byte -> Integer, Integer and Word -> Longint).  A constant counts with its
    value (`W + 1` is a Word).  Only predefined types and constants are understood (a subrange gives an anonymous
    integer); so is a byte-sized result, because byte-sized operands are widened to a word before the operation."""
    for t in (a, b):
        if not (t.builtin or t.value is not None) or t.lo is None or t.hi is None:
            return Ty('int', None)
    lo, hi = min(a.lo, b.lo), max(a.hi, b.hi)
    for t in (SHORTINT, BYTE, INTEGER, WORD, LONGINT):
        if t.lo <= lo and hi <= t.hi:
            return Ty('int', None) if t is SHORTINT or t is BYTE else t
    return Ty('int', None)


class Spec:
    """A formal parameter: kind 'value' / 'var' / 'const', its type (None = untyped var), and `open` for array of T."""

    def __init__(self, kind, ty, name=None, open=False):
        self.kind, self.ty, self.name, self.open = kind, ty, name, open


class R:
    """What a designator or an expression came to: its type, whether it names a variable, and the symbol it is when it is
    nothing but a name."""

    def __init__(self, ty=UNKNOWN, lvalue=False, sym=None, tok=None):
        self.ty, self.lvalue, self.sym, self.tok = ty, lvalue, sym, tok


def first_tok(x) -> Optional[Token]:
    if isinstance(x, Token):
        return x
    return next(x.tokens(), None) if x is not None else None


def ordinal_host(t: Ty):
    """The identity two ordinal types must share to be compatible: all integers are one family."""
    if t.kind == 'int':
        return 'int'
    if t.kind == 'bool':
        return 'bool'
    if t.kind == 'char':
        return 'char'
    if t.kind == 'enum':
        return t.host or t
    return None


def is_char_array(t: Ty) -> bool:
    return t.kind == 'array' and t.elem is not None and t.elem.kind == 'char'


def derives(t: Ty, anc: Ty) -> bool:
    n = 0
    while t is not None and n < 50:
        if t is anc:
            return True
        t = t.ancestor
        n += 1
    return False


def assign_error(dst: Ty, src: Ty) -> Optional[str]:
    """None when a value of type src may be assigned to dst (or when we cannot tell), otherwise the reason."""
    if dst is src or dst.kind in ('unknown', 'void') or src.kind in ('unknown', 'void'):
        return None
    dk, sk = dst.kind, src.kind
    bad = 'cannot assign %s to %s' % (show(src), show(dst))
    if dk == 'int':
        if sk != 'int':
            return bad
        if src.value is not None and dst.lo is not None and not dst.lo <= src.value <= dst.hi:
            return 'constant %d is out of range for %s (%d..%d)' % (src.value, show(dst), dst.lo, dst.hi)
        return None
    if dk == 'real':
        return None if sk in ('int', 'real') else bad
    if dk == 'bool':
        return None if sk == 'bool' else bad
    if dk == 'char':
        if sk == 'char':
            if src.value is not None and dst.lo is not None and not dst.lo <= src.value <= dst.hi:
                return 'constant is out of range for %s' % show(dst)
            return None
        return bad
    if dk == 'string':
        if sk in ('string', 'char') or is_char_array(src) or sk == 'pointer':
            return None
        return bad
    if dk == 'enum':
        if sk != 'enum':
            return bad
        return None if ordinal_host(dst) is ordinal_host(src) else bad
    if dk == 'set':
        if sk != 'set':
            return bad
        a, b = dst.elem, src.elem
        if a is None or b is None or a.kind == 'unknown' or b.kind == 'unknown':
            return None
        ha, hb = ordinal_host(a), ordinal_host(b)
        return None if ha is None or hb is None or ha is hb or ha == hb else bad
    if dk == 'pointer':
        if sk == 'nil':
            return None
        if sk in ('string', 'array'):
            return None if (dst.target is not None and dst.target.kind == 'char') or sk == 'array' else bad
        if sk != 'pointer':
            return bad
        a, b = dst.target, src.target
        if a is None or b is None or a is b or a.kind == 'unknown' or b.kind == 'unknown':
            return None
        if a.kind != b.kind:
            return bad
        if a.kind == 'object' and (derives(b, a) or derives(a, b)):
            return None
        if a.kind in ('record', 'object') and a.sym is not None and b.sym is not None:
            return bad
        return None
    if dk == 'proc':
        return None if sk in ('nil', 'proc', 'pointer') else bad
    if dk == 'object':
        if sk != 'object':
            return bad
        return None if derives(src, dst) or dst.sym is None or src.sym is None else bad
    if dk == 'record':
        if sk != 'record':
            return bad
        return None if dst.sym is None or src.sym is None else bad
    if dk == 'array':
        if sk == 'string' and is_char_array(dst):
            return None
        if sk != 'array':
            return bad
        return None if dst.sym is None or src.sym is None else bad
    if dk == 'file':
        return None if sk == 'file' else bad
    return None


def var_param_error(spec_ty: Ty, arg: Ty) -> Optional[str]:
    """A var parameter takes exactly its own type.  Only the differences that are certain are reported."""
    if spec_ty.kind == 'unknown' or arg.kind == 'unknown' or spec_ty is arg:
        return None
    a, b = spec_ty, arg
    bad = 'a variable of type %s is required, not %s' % (show(a), show(b))
    if a.kind != b.kind:
        if a.kind == 'string' and b.kind in ('char', 'array'):
            return None
        return bad if b.kind in ('int', 'real', 'bool', 'char', 'string', 'enum', 'set', 'record', 'object') \
            and a.kind in ('int', 'real', 'bool', 'char', 'string', 'enum', 'set', 'record', 'object') else None
    if a.kind in ('int', 'real', 'bool', 'char') and a.builtin and b.builtin:
        return bad if a is not b else None
    if a.kind in ('record', 'enum') and a.sym is not None and b.sym is not None:
        return bad
    if a.kind == 'object' and a.sym is not None and b.sym is not None and not derives(b, a):
        return bad
    return None


# ---------------------------------------------------------------------------------------------------
class Types:
    """Builds Ty objects for the symbols of a Provider's units (TPU descriptions) and of source (type nodes)."""

    def __init__(self, provider):
        self.provider = provider
        self._sym: Dict[int, tuple] = {}         # id(sym) -> (sym, Ty): value type of a symbol
        self._tsym: Dict[int, tuple] = {}        # id(type sym) -> (sym, Ty)
        self._node: Dict[int, tuple] = {}        # id(type node) -> (node, Ty)
        self._td: Dict[int, tuple] = {}          # id(tdesc) -> (tdesc, Ty)
        self._busy = set()

    # -- symbols ----------------------------------------------------------------------------------------
    def of_sym(self, sym) -> Ty:
        """Type of the value a symbol stands for (of a function: its result)."""
        got = self._sym.get(id(sym))
        if got is not None:
            return got[1]
        if id(sym) in self._busy:
            return UNKNOWN
        self._busy.add(id(sym))
        try:
            t = self._of_sym(sym)
        except RecursionError:
            t = UNKNOWN
        finally:
            self._busy.discard(id(sym))
        self._sym[id(sym)] = (sym, t)
        return t

    def _of_sym(self, sym) -> Ty:
        k = sym.kind
        if k in ('var', 'param', 'field'):
            if sym.lib:
                return self.of_tdesc(sym.tdesc, sym.home)
            if sym.implicit and sym.owner is not None:
                return self.of_type_sym(sym.owner)
            if sym.tnode is None:
                return UNKNOWN
            return self.of_tnode(sym.tnode, sym.scope, sym.binder)
        if k == 'const':
            return self._const(sym)
        if k == 'enum':
            return self.of_tnode(sym.tnode, sym.scope, sym.binder) if sym.tnode is not None else UNKNOWN
        if k == 'routine':
            if sym.lib:
                return self.of_tdesc(sym.tdesc, sym.home) if sym.tdesc else VOID
            if sym.tnode is None:
                return VOID
            return self.of_tnode(sym.tnode, sym.scope, sym.binder)
        return UNKNOWN

    def _const(self, sym) -> Ty:
        if sym.lib:
            t = self.of_tdesc(sym.tdesc, sym.home)
            v = sym.cvalue[0] if sym.cvalue else None
            if t.kind == 'int' and isinstance(v, int):
                return int_const(v)
            if t.kind == 'char' and isinstance(v, int):
                return Ty('char', None, lo=v, hi=v, value=v)
            return t
        if sym.tnode is not None:
            return self.of_tnode(sym.tnode, sym.scope, sym.binder)
        d = sym.node
        if d is None or len(d.kids) < 3 or not isinstance(d.kids[2], Node):
            return UNKNOWN
        scope = sym.scope

        def ref_of(tok):
            s = scope.lookup(tok.text.lower()) if scope is not None else None
            return s if s is not None and not isinstance(s, str) and hasattr(s, 'kind') else None
        return Typer(self, ref_of, None).expr(d.kids[2]).ty

    def of_type_sym(self, sym) -> Ty:
        got = self._tsym.get(id(sym))
        if got is not None:
            return got[1]
        if id(sym) in self._busy:
            return UNKNOWN
        self._busy.add(id(sym))
        try:
            if sym.lib:
                if sym.home and sym.home.lower() == 'system' and sym.name.lower() in BUILTIN:
                    t = BUILTIN[sym.name.lower()]
                else:
                    t = self.of_tdesc(sym.tdesc, sym.home) if sym.tdesc is not None else UNKNOWN
            elif sym.tnode is not None:
                t = self.of_tnode(sym.tnode, sym.scope, sym.binder)
            else:
                t = UNKNOWN
        except RecursionError:
            t = UNKNOWN
        finally:
            self._busy.discard(id(sym))
        if t.sym is None and not t.builtin and t.kind != 'unknown':
            t.sym, t.name = sym, sym.name
        self._tsym[id(sym)] = (sym, t)
        return t

    # -- source type nodes --------------------------------------------------------------------------------
    def of_tnode(self, node, scope, binder) -> Ty:
        if not isinstance(node, Node) or binder is None:
            return UNKNOWN
        got = self._node.get(id(node))
        if got is not None:
            return got[1]
        self._node[id(node)] = (node, UNKNOWN)                 # a cycle sees UNKNOWN
        try:
            t = self._of_tnode(node, scope, binder)
        except RecursionError:
            t = UNKNOWN
        except (IndexError, AttributeError, TypeError, ValueError):
            t = UNKNOWN                                        # a half-typed declaration
        self._node[id(node)] = (node, t)
        return t

    def _of_tnode(self, node, scope, binder) -> Ty:
        k = node.kind
        if k == 'NamedType':
            toks = [x for x in node.kids[0].kids if isinstance(x, Token) and x.kind == 'IDENT']
            sym = binder.type_sym(node.kids[0], scope)
            if sym is not None and sym.kind == 'type':
                return self.of_type_sym(sym)
            return UNKNOWN
        if k == 'PackedType':
            return self.of_tnode(node.kids[1], scope, binder)
        if k == 'StringType':
            t = Ty('string', None, maxlen=255)
            if len(node.kids) > 2 and isinstance(node.kids[2], Node):
                v = Typer(self, lambda tok: self._lookup(scope, tok), None).expr(node.kids[2]).ty
                if v.kind == 'int' and v.value is not None:
                    t.maxlen = v.value
                    return t
                return t
            return STRING
        if k == 'EnumType':
            t = Ty('enum', None)
            owner = binder.owners.get(id(node))             # named now: its constants reach it without the type name
            if owner is not None:
                t.sym, t.name = owner, owner.name
            return t
        if k == 'SubrangeType':
            lo = Typer(self, lambda tok: self._lookup(scope, tok), None).expr(node.kids[0]).ty
            hi = Typer(self, lambda tok: self._lookup(scope, tok), None).expr(node.kids[2]).ty
            if lo.kind == 'enum':
                return Ty('enum', None, host=lo.host or lo)
            if lo.kind == 'char' or hi.kind == 'char':
                return Ty('char', None, lo=lo.value, hi=hi.value)
            if lo.kind == 'int':
                return Ty('int', None, lo=lo.value, hi=hi.value if hi.kind == 'int' else None)
            if lo.kind == 'bool':
                return Ty('bool', None)
            return UNKNOWN
        if k == 'ArrayType':
            kids = node.kids
            i_of = next((i for i in range(len(kids) - 1, 0, -1)
                         if isinstance(kids[i], Token) and kids[i].text.lower() == 'of'), None)
            if i_of is None:
                return UNKNOWN
            idx = [self.of_tnode(x, scope, binder) for x in kids[2:i_of - 1] if isinstance(x, Node)]
            elem = self.of_tnode(kids[i_of + 1], scope, binder)
            return Ty('array', None, elem=elem, index=idx, open=not idx)
        if k == 'SetType':
            return Ty('set', None, elem=self.of_tnode(node.kids[-1], scope, binder))
        if k == 'FileType':
            if len(node.kids) > 2:
                return Ty('file', None, elem=self.of_tnode(node.kids[-1], scope, binder))
            return Ty('file', None)
        if k == 'PointerType':
            nm = node.kids[1]
            sym = binder.type_sym(nm, scope) if isinstance(nm, Node) else None
            if nm.kids and isinstance(nm.kids[0], Token) and nm.kids[0].text.lower() == 'string':
                return Ty('pointer', None, _target=STRING)
            return Ty('pointer', None, _target=(lambda sym=sym: self.of_type_sym(sym)
                                                if sym is not None and sym.kind == 'type' else UNKNOWN))
        if k in ('RecordType', 'ObjectType'):
            t = Ty('object' if k == 'ObjectType' else 'record', None)
            owner = binder.owners.get(id(node))
            her = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
            if her is not None and len(her.kids) > 1 and isinstance(her.kids[1], Node):
                def anc(her=her):
                    s = binder.type_sym(her.kids[1], scope)
                    return self.of_type_sym(s) if s is not None and s.kind == 'type' else UNKNOWN
                t._anc = anc
            return t
        if k == 'ProcType':
            params = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Params'), None)
            res = None
            if any(isinstance(x, Token) and x.text == ':' for x in node.kids) and isinstance(node.kids[-1], Node):
                res = self.of_tnode(node.kids[-1], scope, binder)
            return Ty('proc', None, params=self.specs_of_params(params, scope, binder), result=res)
        return UNKNOWN

    def _lookup(self, scope, tok):
        s = scope.lookup(tok.text.lower()) if scope is not None else None
        return s if s is not None and hasattr(s, 'kind') else None

    def specs_of_params(self, params, scope, binder) -> List[Spec]:
        """[Spec] of a `(a, b: T; var c; const d: array of X)` list."""
        out: List[Spec] = []
        if params is None:
            return out
        for g in params.kids:
            if not isinstance(g, Node) or g.kind != 'ParamGroup':
                continue
            kids = g.kids
            kind = 'value'
            if kids and isinstance(kids[0], Token) and kids[0].text.lower() in ('var', 'const'):
                kind = kids[0].text.lower()
            names = [x for x in kids if isinstance(x, Node) and x.kind == 'DeclName']
            has_type = any(isinstance(x, Token) and x.text == ':' for x in kids)
            tn = kids[-1] if has_type and isinstance(kids[-1], Node) else None
            ty, opn = None, False
            if tn is not None:
                ty = self.of_tnode(tn, scope, binder)
                if ty.kind == 'array' and ty.open:
                    ty, opn = ty.elem, True
            for nm in names:
                out.append(Spec(kind, ty, nm.kids[0].text if nm.kids else None, opn))
        return out

    # -- TPU descriptions -----------------------------------------------------------------------------------
    def of_tdesc(self, td, home) -> Ty:
        if not isinstance(td, dict):
            return UNKNOWN
        got = self._td.get(id(td))
        if got is not None:
            return got[1]
        self._td[id(td)] = (td, UNKNOWN)
        try:
            t = self._of_tdesc(td, home)
        except RecursionError:
            t = UNKNOWN
        self._td[id(td)] = (td, t)
        return t

    def _of_tdesc(self, td, home) -> Ty:
        if 'named' in td:
            n = td['named']
            unit = td.get('unit') or home
            if unit and unit.lower() == 'system' and n.lower() in BUILTIN:
                return BUILTIN[n.lower()]
            if n == 'string':
                return STRING
            if n == 'file' and (unit or '').lower() == 'system':
                return UNTYPED_FILE
            u = self.provider.get(unit) if unit else None
            sym = u.exports.get(n.lower()) if u is not None else None
            if sym is not None and sym.kind == 'type':
                return self.of_type_sym(sym)
            return UNKNOWN
        if 'unresolved' in td:
            return UNKNOWN
        k = td.get('kind')
        sub = lambda x: self.of_tdesc(x, home)
        if k == 'subrange':
            if td.get('chars'):
                return Ty('char', None, lo=td['lo'], hi=td['hi'])
            return Ty('int', None, lo=td['lo'], hi=td['hi'])
        if k == 'array':
            idx = sub(td['index'])
            elem = sub(td['elem'])
            if elem.kind == 'array' and not elem.open and elem.sym is None and elem.index:
                return Ty('array', None, elem=elem.elem, index=[idx] + elem.index)      # array[a] of array[b] = array[a, b]
            return Ty('array', None, elem=elem, index=[idx])
        if k == 'record':
            return Ty('record', None)
        if k == 'object':
            t = Ty('object', None)
            if td.get('ancestor'):
                t._anc = lambda a=td['ancestor']: sub(a)
            return t
        if k == 'pointer':
            return Ty('pointer', None, _target=lambda x=td['to']: sub(x))
        if k == 'string':
            return Ty('string', None, maxlen=td.get('max', 255))
        if k == 'set':
            return Ty('set', None, elem=sub(td['base']))
        if k == 'file':
            return Ty('file', None, elem=sub(td['elem']))
        if k == 'proc':
            specs = [Spec(p.kind if p.kind in ('var', 'const') else 'value', sub(p.tdesc) if p.tdesc else None, p.name,
                          p.open) for p in td.get('params', [])]
            return Ty('proc', None, params=specs, result=sub(td['result']) if td.get('result') else None)
        if k == 'enum':
            return Ty('enum', None)
        return UNKNOWN

    def specs_of_sym(self, sym) -> Optional[List[Spec]]:
        """The formal parameters of a routine or method symbol; None when they are not known (builtins)."""
        if sym.lib:
            if sym.kind == 'builtin' or sym.lparams is None:
                return None
            out = []
            for p in sym.lparams:
                ty = self.of_tdesc(p.tdesc, sym.home) if p.tdesc else None
                out.append(Spec(p.kind if p.kind in ('var', 'const') else 'value', ty, p.name, p.open))
            return out
        if sym.node is None or sym.binder is None:
            return None
        return self.specs_of_params(getattr(sym, 'header_params', None), sym.scope, sym.binder)


# ---------------------------------------------------------------------------------------------------
# Functions of the compiler that no declaration describes: the argument list is not checked, the result type is
# what the language guide says.
MAGIC_RESULT = {
    'length': BYTE, 'pos': BYTE, 'copy': STRING, 'concat': STRING, 'upcase': CHAR, 'chr': CHAR, 'ord': LONGINT,
    'odd': BOOLEAN, 'eof': BOOLEAN, 'eoln': BOOLEAN, 'seekeof': BOOLEAN, 'seekeoln': BOOLEAN, 'round': LONGINT,
    'trunc': LONGINT, 'sizeof': WORD, 'seg': WORD, 'ofs': WORD, 'hi': BYTE, 'lo': BYTE, 'addr': POINTER, 'ptr': POINTER,
    'sqrt': FLOAT, 'sin': FLOAT, 'cos': FLOAT, 'arctan': FLOAT, 'exp': FLOAT, 'ln': FLOAT,
    'frac': FLOAT, 'int': FLOAT, 'pi': FLOAT, 'cseg': WORD, 'dseg': WORD, 'sseg': WORD, 'sptr': WORD,
    'filepos': LONGINT, 'filesize': LONGINT, 'paramcount': INTEGER, 'ioresult': INTEGER, 'memavail': LONGINT,
    'maxavail': LONGINT, 'keypressed': BOOLEAN, 'readkey': CHAR,
}
MAGIC_ARRAYS = {'mem': BYTE, 'memw': WORD, 'meml': LONGINT, 'port': BYTE, 'portw': WORD}
MAGIC_SAME = ('abs', 'sqr', 'succ', 'pred', 'swap')                 # the result has the type of the argument


class Typer:
    """Types the expressions of one file.  ref_of(token) -> the symbol an identifier token stands for (or None);
    report(token, message) is called for every problem found (None: silent)."""

    def __init__(self, types: Types, ref_of, report):
        self.types = types
        self.ref_of = ref_of
        self.report = report
        self.done = set()
        self.on_call = None                       # on_call(routine name, specs, [Arg nodes]) for every call with known parameters

    def rep(self, where, msg):
        if self.report is None:
            return
        tok = first_tok(where)
        if tok is None or id(tok) in self.done:
            return
        self.done.add(id(tok))
        self.report(tok, msg)

    # -- expressions ------------------------------------------------------------------------------------------
    def expr(self, e, procval: bool = False) -> R:
        """procval: the expression is given where a procedural value is wanted (the right side of an assignment to a
        procedural variable, an argument for a procedural parameter): a bare routine name is then the routine, not a call."""
        if isinstance(e, Token) or e is None:
            return R()
        k = e.kind
        try:
            if procval and k == 'Designator':
                return self.designator(e, procval=True)
            if k == 'Literal':
                t = e.kids[0]
                if t.kind == 'INT':
                    return R(int_const(int(t.text)))
                if t.kind == 'HEX':                                  # $FFFF, $FFFFFFFF: wraps into the type, no range check
                    return R(Ty('int', None))
                if t.kind == 'REAL':
                    return R(FLOAT)
                if t.text.lower() == 'nil':
                    return R(NIL)
                return R()
            if k == 'StringLit':
                return R(self.string_lit(e))
            if k == 'Paren':
                r = self.expr(e.kids[1])
                return R(r.ty)
            if k == 'Unary':
                return self.unary(e)
            if k == 'Binary':
                return self.binary(e)
            if k == 'Designator':
                return self.designator(e)
            if k == 'SetCtor':
                return R(self.set_ctor(e))
            if k == 'Inherited':
                return R()
        except (IndexError, AttributeError, TypeError, ValueError):
            return R()                                               # a half-typed expression
        return R()

    def string_lit(self, e) -> Ty:
        n, code = 0, None
        for t in e.kids:
            if t.kind == 'STRING':
                body = t.text[1:-1].replace("''", "'")
                n += len(body)
                if len(body) == 1:
                    code = ord(body.encode('cp866', 'replace').decode('cp866')[0])
            else:
                v = t.text[1:]
                code = int(v[1:], 16) if v.startswith('$') else int(v)
                n += 1
        if n == 1:
            return Ty('char', None, lo=code, hi=code, value=code)
        return Ty('string', None, maxlen=n, strlit=n)

    def set_ctor(self, e) -> Ty:
        base = None
        for x in e.kids:
            if isinstance(x, Node):
                t = self.expr(x).ty
                if base is None and t.kind != 'unknown':
                    base = t
                elif base is not None and t.kind != 'unknown' and base.kind == 'int' and t.kind == 'int':
                    pass
        elem = None
        if base is not None:
            elem = Ty('int', None, lo=None, hi=None) if base.kind == 'int' else (CHAR if base.kind == 'char' else base)
        return Ty('set', None, elem=elem)

    def unary(self, e) -> R:
        op = e.kids[0].text.lower()
        r = self.expr(e.kids[1])
        t = r.ty
        if op == '@':
            if t.kind == 'unknown':
                return R(POINTER)
            return R(POINTER)
        if t.kind == 'unknown':
            return R()
        if op == 'not':
            if t.kind in ('bool', 'int'):
                return R(t if t.kind == 'bool' else Ty('int', None))
            self.rep(e.kids[0], "operator 'not' cannot be applied to %s" % show(t))
            return R()
        if t.kind in ('int', 'real'):
            if op == '-' and t.kind == 'int' and t.value is not None:
                return R(int_const(-t.value))
            return R(t if t.value is not None or t.kind == 'real' else Ty('int', None))
        self.rep(e.kids[0], "operator '%s' cannot be applied to %s" % (op, show(t)))
        return R()

    def binary(self, e) -> R:
        a, optok, b = e.kids[0], e.kids[1], e.kids[2]
        op = optok.text.lower()
        ta, tb = self.expr(a).ty, self.expr(b).ty
        if ta.kind == 'unknown' or tb.kind == 'unknown':
            return R(BOOLEAN if op in ('=', '<>', '<', '>', '<=', '>=', 'in') else UNKNOWN)
        ka, kb = ta.kind, tb.kind
        bad = lambda: self.rep(optok, "operator '%s' cannot be applied to %s and %s" % (op, show(ta), show(tb)))
        if op in ('=', '<>', '<', '>', '<=', '>='):
            if not self.comparable(op, ta, tb):
                self.rep(optok, "cannot compare %s with %s" % (show(ta), show(tb)))
            return R(BOOLEAN)
        if op == 'in':
            if ka not in ORDINAL or kb != 'set':
                bad()
            return R(BOOLEAN)
        num = ('int', 'real')
        if op in ('+', '-', '*'):
            if ka in num and kb in num:
                if ka == 'int' and kb == 'int':
                    if ta.value is not None and tb.value is not None:
                        v = {'+': ta.value + tb.value, '-': ta.value - tb.value, '*': ta.value * tb.value}[op]
                        return R(int_const(v) if -2 ** 31 <= v < 2 ** 32 else Ty('int', None))
                    return R(common_int(ta, tb))
                return R(FLOAT)
            if op == '+' and ka in ('string', 'char') and kb in ('string', 'char'):
                return R(STRING)
            if op == '+' and is_char_array(ta) or op == '+' and is_char_array(tb):
                return R(STRING)
            if ka == 'set' and kb == 'set':
                return R(ta if ta.elem is not None else tb)
            bad()
            return R()
        if op == '/':
            if ka in num and kb in num:
                return R(FLOAT)
            bad()
            return R()
        if op in ('div', 'mod', 'shl', 'shr'):
            if ka == 'int' and kb == 'int':
                if ta.value is not None and tb.value is not None and op in ('div', 'mod') and tb.value != 0:
                    q = abs(ta.value) // abs(tb.value)
                    q = q if (ta.value >= 0) == (tb.value >= 0) else -q
                    return R(int_const(q if op == 'div' else ta.value - q * tb.value))
                return R(common_int(ta, tb))
            bad()
            return R()
        if op in ('and', 'or', 'xor'):
            if ka == 'bool' and kb == 'bool':
                return R(ta)
            if ka == 'int' and kb == 'int':
                return R(common_int(ta, tb))
            bad()
            return R()
        return R()

    @staticmethod
    def comparable(op, a: Ty, b: Ty) -> bool:
        ka, kb = a.kind, b.kind
        if ka in ('int', 'real') and kb in ('int', 'real'):
            return True
        if ka in ('string', 'char') and kb in ('string', 'char'):
            return True
        if (ka in ('string', 'char') and kb == 'array') or (kb in ('string', 'char') and ka == 'array'):
            return True
        if ka == 'array' and kb == 'array':
            return True
        if ka in ORDINAL and kb == ka:
            return ordinal_host(a) is ordinal_host(b) or ordinal_host(a) == ordinal_host(b)
        if ka == 'pointer' or kb == 'pointer' or ka == 'nil' or kb == 'nil':
            return op in ('=', '<>') and ka in ('pointer', 'nil', 'proc') and kb in ('pointer', 'nil', 'proc') \
                or ka in ('array', 'string') or kb in ('array', 'string')
        if ka == 'set' and kb == 'set':
            return op != '<' and op != '>'
        if ka == 'proc' and kb == 'proc':
            return op in ('=', '<>')
        if ka == kb == 'file':
            return True
        return False

    # -- designators ------------------------------------------------------------------------------------------
    def designator(self, d, lhs: bool = False, procval: bool = False) -> R:
        kids = d.kids
        head = kids[0]
        tok = head.kids[0] if head.kids and isinstance(head.kids[0], Token) else None
        steps = list(kids[1:])
        if tok is None:
            return self.inner(steps)
        sym = self.ref_of(tok)
        if sym is not None and sym.kind == 'unit':
            if steps and steps[0].kind == 'Field':
                tok = steps[0].kids[1]
                sym = self.ref_of(tok)
                steps = steps[1:]
            else:
                return R()
        if sym is None:
            return self.inner(steps)
        state = self.start(sym, tok)
        i = 0
        while i < len(steps):
            st = steps[i]
            pk = st.kind
            if state[0] == 'routine':
                if pk == 'Args':
                    state = self.call(state[1], st, tok)
                    i += 1
                    continue
                state = self.call(state[1], None, tok)
                continue
            if state[0] == 'type':
                if pk == 'Args':
                    args = [a for a in st.kids if isinstance(a, Node)]
                    r = None
                    for a in args:
                        r = self.expr(a.kids[0]) if a.kids else R()
                    ty = self.types.of_type_sym(state[1])
                    state = ('value', ty, bool(r is not None and len(args) == 1 and r.lvalue))
                    i += 1
                    continue
                return self.inner(steps[i:])
            if state[0] == 'builtin':
                if pk == 'Index' and state[1].name.lower() in MAGIC_ARRAYS:
                    self.index_exprs(st)
                    state = ('value', MAGIC_ARRAYS[state[1].name.lower()], True)
                    i += 1
                    continue
                if pk == 'Args':
                    state = self.magic(state[1], st)
                    i += 1
                    continue
                state = self.magic(state[1], None)
                continue
            if state[0] == 'unknown':
                return self.inner(steps[i:])
            # a value
            ty, lv = state[1], state[2]
            if pk == 'Field':
                s2 = self.ref_of(st.kids[1])
                if s2 is None:
                    return self.inner(steps[i + 1:])
                tok = st.kids[1]
                state = self.start(s2, tok)
                i += 1
                continue
            if pk == 'Index':
                state = ('value', self.index(ty, st, d), True)
                i += 1
                continue
            if pk == 'Deref':
                if ty.kind == 'pointer':
                    tg = ty.target
                    state = ('value', tg if tg is not None else UNKNOWN, True)
                elif ty.kind in ('int', 'real', 'bool', 'char', 'string', 'enum', 'record', 'set', 'array', 'object'):
                    self.rep(st.kids[0], "'^' needs a pointer, not %s" % show(ty))
                    state = ('unknown',)
                else:
                    state = ('value', UNKNOWN, True)
                i += 1
                continue
            if pk == 'Args':
                state = self.call_value(ty, st, tok)
                i += 1
                continue
            i += 1
        if state[0] == 'routine':                                     # `F` or `Obj.Method` without parentheses
            if lhs:
                return R(self.types.of_sym(state[1]), True, state[1], tok)
            if procval and state[1].kind == 'routine':                # `fn := Sq`: the routine itself, not a call
                specs = self.types.specs_of_sym(state[1])
                res = self.types.of_sym(state[1])
                return R(Ty('proc', None, params=specs, result=None if res.kind == 'void' else res))
            state = self.call(state[1], None, tok)
        if state[0] == 'type':
            return R(UNKNOWN, False, state[1], tok)
        if state[0] == 'builtin':
            state = self.magic(state[1], None)
        if state[0] == 'value':
            return R(state[1], state[2], sym if not steps else None, tok)
        return R()

    def inner(self, steps) -> R:
        """Type the expressions inside what follows a name we know nothing about, so errors there still show."""
        for st in steps:
            if st.kind == 'Args':
                for a in st.kids:
                    if isinstance(a, Node):
                        for x in a.kids:
                            if isinstance(x, Node):
                                self.expr(x)
            elif st.kind == 'Index':
                self.index_exprs(st)
        return R()

    def index_exprs(self, st) -> List[R]:
        return [self.expr(x) for x in st.kids if isinstance(x, Node)]

    def start(self, sym, tok):
        k = sym.kind
        if k in ('var', 'param', 'field'):
            return ('value', self.types.of_sym(sym), True)
        if k == 'const':
            typed = (sym.lib and sym.typed_const) or (not sym.lib and sym.tnode is not None)
            return ('value', self.types.of_sym(sym), typed)
        if k == 'enum':
            return ('value', self.types.of_sym(sym), False)
        if k == 'routine':
            return ('routine', sym)
        if k == 'type':
            return ('type', sym)
        if k == 'builtin':
            return ('builtin', sym)
        return ('unknown',)

    # -- pieces -------------------------------------------------------------------------------------------
    def index(self, ty: Ty, st, d) -> Ty:
        rs = self.index_exprs(st)
        n = max(len(rs), 1)
        k = ty.kind
        if k == 'unknown':
            return UNKNOWN
        if k == 'string':
            if n > 1:
                self.rep(st, 'a string has only one index')
            return CHAR
        if k == 'pointer':
            tg = ty.target
            if tg is not None and tg.kind == 'char':
                return CHAR
            return UNKNOWN
        if k == 'array':
            idx = ty.index or []
            cur = ty
            if ty.open:
                idx = [INTEGER]
            used = 0
            elem = ty.elem if ty.elem is not None else UNKNOWN
            for j, r in enumerate(rs):
                if j < len(idx):
                    self.index_check(idx[j], r, st)
            while used < n and True:
                if used >= len(idx):
                    # more indexes than dimensions: the element must be indexable
                    rest = n - used
                    if rest > 0:
                        return self.index_more(elem, rs[used:], st)
                    break
                used += 1
            if n < len(idx):
                return Ty('array', None, elem=elem, index=idx[n:])
            return elem
        if k in ('int', 'real', 'bool', 'char', 'enum', 'record', 'object', 'set', 'proc'):
            self.rep(st.kids[0], '%s cannot be indexed' % show(ty))
        return UNKNOWN

    def index_more(self, elem, rs, st) -> Ty:
        t = elem
        for r in rs:
            if t.kind == 'array':
                t = t.elem or UNKNOWN
            elif t.kind == 'string':
                t = CHAR
            else:
                if t.kind != 'unknown':
                    self.rep(st, 'too many indexes: %s cannot be indexed' % show(t))
                return UNKNOWN
        return t

    def index_check(self, want: Ty, r: R, st):
        t = r.ty
        if want.kind == 'unknown' or t.kind == 'unknown':
            return
        if want.kind in ORDINAL and t.kind in ORDINAL:
            if ordinal_host(want) is not ordinal_host(t) and ordinal_host(want) != ordinal_host(t):
                self.rep(st, 'index of type %s does not fit %s' % (show(t), show(want)))
            elif want.kind == 'int' and t.value is not None and want.lo is not None and want.hi is not None \
                    and not want.lo <= t.value <= want.hi:
                self.rep(st, 'index %d is out of range %d..%d' % (t.value, want.lo, want.hi))
        elif t.kind in ('real', 'string', 'record', 'set', 'pointer') and want.kind in ORDINAL:
            self.rep(st, 'index of type %s does not fit %s' % (show(t), show(want)))

    # -- calls ----------------------------------------------------------------------------------------------
    def call(self, sym, args_node, tok):
        specs = self.types.specs_of_sym(sym)
        res = self.types.of_sym(sym)
        r = self.check_args(sym.name, specs, args_node, tok)
        return ('value', res, False)

    def call_value(self, ty: Ty, st, tok):
        if ty.kind == 'proc':
            self.check_args(tok.text if tok else 'procedure', ty.params, st, tok)
            return ('value', ty.result if ty.result is not None else VOID, False)
        if ty.kind == 'unknown':
            self.check_args(None, None, st, tok)
            return ('value', UNKNOWN, False)
        if ty.kind in ('int', 'real', 'bool', 'char', 'string', 'enum', 'record', 'set'):
            self.rep(tok, '%s is not a routine and cannot be called' % (tok.text if tok else show(ty)))
        self.check_args(None, None, st, tok)
        return ('value', UNKNOWN, False)

    def magic(self, sym, args_node):
        name = sym.name.lower()
        rs = []
        if args_node is not None:
            for a in args_node.kids:
                if isinstance(a, Node):
                    rs.append(self.expr(a.kids[0]) if a.kids else R())
                    for x in a.kids[2::2]:
                        self.expr(x)
        if name in MAGIC_RESULT:
            return ('value', MAGIC_RESULT[name], False)
        if name in MAGIC_SAME and rs and rs[0].ty.kind in ('int', 'real', 'enum', 'char', 'bool'):
            t = rs[0].ty
            return ('value', Ty('int', None) if t.kind == 'int' else t, False)
        return ('value', UNKNOWN, False)

    def check_args(self, name, specs, args_node, tok):
        """Type the arguments; with a known parameter list also count them and match them against it."""
        args = [a for a in args_node.kids if isinstance(a, Node)] if args_node is not None else []
        rs = []
        for j, a in enumerate(args):
            want_proc = specs is not None and j < len(specs) and specs[j].ty is not None and specs[j].ty.kind == 'proc'
            rs.append(self.expr(a.kids[0], procval=want_proc) if a.kids else R())
            for x in a.kids[2::2]:
                self.expr(x)
        if specs is None:
            return
        if self.on_call is not None:
            self.on_call(name, specs, args)
        n, m = len(args), len(specs)
        if n > m:
            self.rep(args[m], "too many arguments in the call of '%s' (it takes %d)" % (name, m))
            return
        if n < m:
            where = args_node.kids[-1] if args_node is not None and args_node.kids else tok
            if args_node is not None and isinstance(where, Token) and where.text != ')':
                where = tok
            self.rep(where if where is not None else tok,
                     "not enough arguments in the call of '%s': %d given, %d expected" % (name, n, m))
            return
        for i, (sp, r, a) in enumerate(zip(specs, rs, args)):
            self.check_arg(name, i + 1, sp, r, a)

    def check_arg(self, name, i, sp: Spec, r: R, a):
        where = a.kids[0] if a.kids else a
        pre = "argument %d of '%s': " % (i, name)
        t = r.ty
        if sp.kind == 'var':
            if not r.lvalue and (self.is_value_expr(a) or (r.sym is not None and r.sym.kind in ('const', 'enum'))):
                self.rep(where, pre + 'a variable is required for a var parameter')
                return
            if sp.ty is not None and not sp.open:
                m = var_param_error(sp.ty, t)
                if m:
                    self.rep(where, pre + m)
            elif sp.open and t.kind in ('int', 'real', 'bool', 'char', 'enum', 'record', 'object', 'set'):
                self.rep(where, pre + 'an array is required, not %s' % show(t))
            return
        if sp.open:
            if t.kind in ('int', 'real', 'bool', 'char', 'enum', 'record', 'object', 'set', 'nil'):
                self.rep(where, pre + 'an array is required, not %s' % show(t))
            return
        if sp.ty is None:
            return
        m = assign_error(sp.ty, t)
        if m:
            self.rep(where, pre + m.replace('cannot assign', 'cannot pass', 1))

    @staticmethod
    def is_value_expr(a) -> bool:
        """Is the argument certainly not a variable (a literal or an operator expression)?  A designator is decided by
        its own R.lvalue, but only when it is a plain constant or a call; unresolved things stay silent."""
        e = a.kids[0] if a.kids else None
        return isinstance(e, Node) and e.kind in ('Literal', 'StringLit', 'Binary', 'Unary', 'SetCtor') and not (
            e.kind == 'Unary' and e.kids and isinstance(e.kids[0], Token) and e.kids[0].text == '@')


# ---------------------------------------------------------------------------------------------------
class Checker:
    """Walks the statements of a bound file and reports type errors through report(token, message)."""

    def __init__(self, res, binder, provider, report):
        self.res = res
        self.binder = binder
        self.types = Types(provider)
        self.t = Typer(self.types, lambda tok: binder.refs.get(id(tok)), report)

    def run(self):
        for n in self.res.tree.walk():
            try:
                h = getattr(self, 'st_' + n.kind, None)
                if h is not None:
                    h(n)
            except RecursionError:
                pass

    # -- statements -------------------------------------------------------------------------------------------
    def st_Assign(self, n):
        d, e = n.kids[0], n.kids[2]
        lr = self.t.designator(d, lhs=True)
        rr = self.t.expr(e, procval=lr.ty.kind == 'proc')
        if lr.sym is not None and lr.sym.kind in ('const', 'enum') and not lr.lvalue:
            self.t.rep(d, "cannot assign to the constant '%s'" % lr.sym.name)
            return
        m = assign_error(lr.ty, rr.ty)
        if m:
            self.t.rep(e, 'type mismatch: ' + m if m.startswith('cannot') else m)

    def st_ProcCall(self, n):
        self.t.designator(n.kids[0])

    def condition(self, e):
        r = self.t.expr(e)
        if r.ty.kind not in ('bool', 'unknown', 'void'):
            self.t.rep(e, 'Boolean expression expected, found %s' % show(r.ty))

    def st_If(self, n):
        self.condition(n.kids[1])

    def st_While(self, n):
        self.condition(n.kids[1])

    def st_Repeat(self, n):
        self.condition(n.kids[-1])

    def st_For(self, n):
        kids = n.kids
        name = kids[1]
        tok = name.kids[0] if isinstance(name, Node) and name.kids else None
        sym = self.binder.refs.get(id(tok)) if tok is not None else None
        vt = self.types.of_sym(sym) if sym is not None and sym.kind in ('var', 'param') else UNKNOWN
        if vt.kind not in ORDINAL and vt.kind not in ('unknown', 'void'):
            self.t.rep(name, 'the control variable of a for loop must be ordinal, not %s' % show(vt))
            vt = UNKNOWN
        exprs = [x for x in kids[2:] if isinstance(x, Node) and x.kind not in ('Empty',) and x is not kids[-1]]
        for e in exprs[:2]:
            r = self.t.expr(e)
            m = assign_error(vt, r.ty)
            if m:
                self.t.rep(e, 'type mismatch: ' + m if m.startswith('cannot') else m)

    def st_Case(self, n):
        sel = self.t.expr(n.kids[1]).ty
        if sel.kind not in ORDINAL and sel.kind not in ('unknown', 'void'):
            self.t.rep(n.kids[1], 'the selector of a case must be ordinal, not %s' % show(sel))
            sel = UNKNOWN
        for b in n.kids:
            if isinstance(b, Node) and b.kind == 'CaseBranch' and b.kids and isinstance(b.kids[0], Node):
                for e in b.kids[0].kids:
                    if isinstance(e, Node):
                        lt = self.t.expr(e).ty
                        if sel.kind in ORDINAL and lt.kind in ORDINAL and ordinal_host(sel) is not ordinal_host(lt) \
                                and ordinal_host(sel) != ordinal_host(lt):
                            self.t.rep(e, 'case label of type %s does not fit the selector %s' % (show(lt), show(sel)))


def check_types(res, binder, provider, report):
    """Report the type errors of a bound file: report(token, message)."""
    Checker(res, binder, provider, report).run()


# ---------------------------------------------------------------------------------------------------
def const_type_name(t: Ty) -> Optional[str]:
    """How the type of a constant declared without a type is written in a hint."""
    k = t.kind
    if k == 'int':
        if t.value is None:
            return t.name
        return 'Integer' if -32768 <= t.value <= 32767 else 'Word' if 0 <= t.value <= 65535 else 'Longint'
    if k == 'char':
        return 'Char'
    if k == 'string':
        return 'string[%d]' % t.strlit if t.strlit else 'string'
    if k == 'unknown' or k == 'void' or k == 'nil':
        return None
    return t.name or show(t)


def inlay_data(res, binder, provider):
    """What the editor may show between the characters of the file:
    params: [(token of the first word of an argument, 'Name:')]   consts: [(name token, ': Type')]
    ends:   [(token `end` of a routine body, 'Name', number of lines of the body)]"""
    out = {'params': [], 'consts': [], 'ends': []}
    ch = Checker(res, binder, provider, None)

    def on_call(name, specs, args):
        for sp, a in zip(specs, args):
            if not sp.name or not a.kids:
                continue
            e = a.kids[0]
            tok = first_tok(e)
            if tok is None or tok.via is not None or tok.file:
                continue
            if isinstance(e, Node) and e.kind == 'Designator' and len(e.kids) == 1 and tok.text.lower() == sp.name.lower():
                continue                                          # `Width` for a parameter `Width`: nothing to add
            out['params'].append((tok, sp.name + ':'))
    ch.t.on_call = on_call
    ch.run()
    seen = set()
    for tid, sym in binder.decls.items():
        if sym.kind != 'const' or sym.tnode is not None or sym.tok is None or id(sym) in seen or sym.tok.via is not None \
                or sym.tok.file or id(sym.tok) != tid:
            continue
        seen.add(id(sym))
        name = const_type_name(ch.types.of_sym(sym))
        if name:
            out['consts'].append((sym.tok, ': ' + name))
    for n in res.tree.walk():
        if n.kind != 'Routine':
            continue
        block = next((x for x in n.kids if isinstance(x, Node) and x.kind == 'Block'), None)
        comp = next((x for x in block.kids if isinstance(x, Node) and x.kind == 'Compound'), None) if block else None
        if comp is None:
            continue
        toks = list(comp.tokens())
        if len(toks) < 2 or toks[-1].text.lower() != 'end' or toks[-1].via is not None or toks[-1].file:
            continue
        owner, name = routine_names_of(n)
        out['ends'].append((toks[-1], (owner + '.' if owner else '') + name, toks[-1].line - toks[0].line + 1))
    return out


def routine_names_of(r):
    """(owner name or '', routine name) of a Routine node."""
    from tp7parse import routine_names
    own, nm = routine_names(r)
    ot = own.kids[0].text if own is not None and getattr(own, 'kids', None) else ''
    nt = nm.kids[0].text if nm is not None and getattr(nm, 'kids', None) else (nm.text if isinstance(nm, Token) else '')
    return ot, nt


# ---------------------------------------------------------------------------------------------------
def type_text(t: Ty, depth: int = 0) -> str:
    """The type as a hover writes it: a named type by its name, anything else spelled out like a declaration would."""
    if t.name and not (t.kind == 'int' and t.value is not None) or depth > 4:
        return show(t)
    k = t.kind
    if k == 'int' and t.value is None and t.lo is not None and t.hi is not None:
        return '%d..%d' % (t.lo, t.hi)
    if k == 'string' and t.strlit is None and t.maxlen is not None and t.maxlen != 255:
        return 'string[%d]' % t.maxlen
    if k == 'pointer':
        tg = t.target
        return '^' + type_text(tg, depth + 1) if tg is not None and tg.kind != 'unknown' else 'Pointer'
    if k == 'set' and t.elem is not None and t.elem.kind != 'unknown':
        return 'set of ' + type_text(t.elem, depth + 1)
    if k == 'file' and t.elem is not None and t.elem.kind != 'unknown':
        return 'file of ' + type_text(t.elem, depth + 1)
    if k == 'array':
        elem = type_text(t.elem, depth + 1) if t.elem is not None and t.elem.kind != 'unknown' else '?'
        idx = t.index or []
        if t.open or not idx:
            return 'array of ' + elem
        if all(x.kind != 'unknown' for x in idx):
            return 'array [%s] of %s' % (', '.join(type_text(x, depth + 1) for x in idx), elem)
        return 'array of ' + elem
    if k == 'proc':
        ps = '; '.join('%s%s' % ({'var': 'var ', 'const': 'const '}.get(p.kind, ''),
                                 type_text(p.ty, depth + 1) if p.ty is not None else 'untyped') for p in t.params or [])
        ps = '(%s)' % ps if ps else ''
        if t.result is not None:
            return 'function%s: %s' % (ps, type_text(t.result, depth + 1))
        return 'procedure' + ps
    return show(t)


_EXPR_BRACKETS = ('(', ')', '[', ']', '(.', '.)')


def expr_at(tree, ref_of, provider, tok):
    """The expression that the operator, parenthesis, bracket or `^` token `tok` makes, and its type: (node, Ty), or None
    when the token makes no expression or its type is not known.  `a + b` for the `+`, `(a + b)` for its parentheses,
    `[1, 2]` for the brackets of a set; in a designator the part that ends there: `A[i]` for the brackets of the index,
    `P^` for the `^`, `F(x)` / `Integer(x)` for the parentheses of a call or a typecast.  ref_of as for Typer."""
    parent = {}
    hit = None
    for n in tree.walk():
        for k in n.kids:
            if k is tok:
                hit = n
                break
            if k.__class__ is Node:
                parent[id(k)] = n
        if hit is not None:
            break
    if hit is None:
        return None
    k, text = hit.kind, tok.text.lower()
    if k == 'Binary' and len(hit.kids) > 2 and hit.kids[1] is tok or k == 'Unary' and hit.kids[0] is tok \
            or k in ('Paren', 'SetCtor') and text in _EXPR_BRACKETS:
        node = hit
    elif k in ('Index', 'Args') and text in _EXPR_BRACKETS or k == 'Deref':
        d = parent.get(id(hit))
        if d is None or d.kind != 'Designator':
            return None
        i = next(i for i, x in enumerate(d.kids) if x is hit)
        node = Node('Designator', d.kids[:i + 1])
    else:
        return None
    t = Typer(Types(provider), ref_of, None).expr(node).ty
    if t.kind in ('unknown', 'void'):
        return None
    return node, t
