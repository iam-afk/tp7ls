#!/usr/bin/env python3
"""
tp7sema.py - name resolution and identifier-case normalisation for Turbo Pascal 7 (objects included).

Rule (from the project owner): every identifier is rewritten to the spelling of its DECLARATION;
reserved words are lower case.  Identifiers that cannot be resolved are left untouched and reported.

What is resolved
  * scopes: routine (params, locals, nested routines) -> implementation -> interface -> units of the
    implementation `uses` (last wins) -> units of the interface `uses` (last wins) -> System
  * a routine header repeated in `implementation` takes the spelling of its interface declaration, and a header
    without a parameter list (`function NextChar;`) sees the parameters of the interface declaration
  * `Unit.Name`, record fields (`a.b`, `p^.next^[i].f`, function results, type casts), `with`,
    enumeration members, labels, typed-constant aggregates `(x: 1; y: 2)`, forward pointer types
  * `object` types (and records with methods): fields and methods of the type and of all its ancestors; inside a method
    body (`procedure T.M`) they are in scope after the parameters and locals, `Self` is the instance, `inherited Name`
    looks in the ancestor; `New(P, Init(..))` / `Dispose(P, Done)` look the constructor / destructor up in the object
    that P points to; the `T.M` header is linked to the declaration inside the type
  * a `with` whose expression type is unknown makes every identifier inside it "uncertain": it is not rewritten
Declarations come from: this file; other units' source (`NAME.PAS` in the search path); TPU files and the standard
library TURBO.TPL (via tpu_dump).  Not handled: object types that come from a TPU (only their name is known), text of
inactive {$IFDEF} branches.  {$I} files are expanded when the Provider resolves them (Token.file).
"""
import os
import re
import sys
from typing import Dict, List, Optional

from tp7parse import Node, Result, parse, ROUTINE_DIRECTIVES, routine_names, fieldlist_of
from tp7lex import Token


# ---------------------------------------------------------------------------------------------------
class Sym:
    def __init__(self, name, kind, tok=None, tnode=None, scope=None, node=None):
        self.name = name            # declared spelling
        self.kind = kind            # var const type routine param field enum label unit builtin
        self.tok = tok
        self.tnode = tnode          # type node (source symbols): declared type / aliased type / result type
        self.scope = scope
        self.node = node            # routine: the Routine node
        self.unit = None            # kind == 'unit': UnitInfo
        self.tfn = None             # callable -> TInfo (TPU symbols)
        self.params = None          # routine: list of param Sym
        self.params_scope = None
        self.home = None            # lib symbols: name of the unit (System, Crt...) they come from
        self.type_tok = None        # enumeration member: name token of the type that declares it (if it has a name)
        self.lib = False            # declared in a TPU / the standard library (System, Crt, ...): no source
        self.stub_owner = None      # lib field: name of the record type that declares it (to find it in the stub)
        self.type_ref = None        # lib var / const / field / routine: (unit, name) of its named type
        self.file = None            # source symbols of OTHER units: path of the .pas file the token belongs to
        self.impl_tok = None        # interface routine / method: name token of its implementation header
        self.tdesc = None           # lib symbols: structured type (tpu_dump tdesc) of a var / const / field / result
        self.lparams = None         # lib routine / method: [tpu_dump.Param]
        self.cvalue = None          # lib const: (value, display)
        self.typed_const = False    # a typed constant (assignable, unlike a plain const)
        self.binder = None          # source symbols: the Binder that made it (to find scopes when typing its declaration)
        self.method_kind = None     # lib method of an object from a TPU: 'procedure' 'function' 'constructor' 'destructor'
        self.owner = None           # field / method: the type symbol that declares it (None for anonymous records)
        self.implicit = False       # `Self`: no declaring token
        self._t = None
        self._busy = False

    def __repr__(self):
        return 'Sym(%s %s)' % (self.kind, self.name)


class TInfo:
    def __init__(self, kind, **kw):
        self.kind = kind            # record array pointer string prim unknown
        self.__dict__.update(kw)

    def get_fields(self) -> Dict[str, Sym]:
        f = getattr(self, 'fields_fn', None)
        if f is None:
            return {}
        if not hasattr(self, '_fields'):
            self._fields = {}
            self._fields = f()
        return self._fields

    def get_own(self) -> Dict[str, Sym]:
        """Members declared by the type itself (records, objects), without the ancestors'."""
        f = getattr(self, 'own_fn', None)
        if f is None:
            return self.get_fields()
        if not hasattr(self, '_own'):
            self._own = {}
            self._own = f()
        return self._own

    def get_ancestor(self) -> Optional['TInfo']:
        f = getattr(self, 'ancestor_fn', None)
        return f() if f else None

    def get_target(self) -> Optional['TInfo']:
        f = getattr(self, 'target_fn', None)
        return f() if f else None


UNKNOWN = TInfo('unknown')
PRIM = TInfo('prim')
STRING = TInfo('string')
UNCERTAIN = object()


class Scope:
    def __init__(self, table=None, parent=None, units=None):
        self.table: Dict[str, Sym] = table if table is not None else {}
        self.parent = parent
        self.units = units           # list of UnitInfo searched last-to-first (uses scopes)

    def lookup(self, key: str) -> Optional[Sym]:
        s = self
        while s is not None:
            if s.units is not None:
                for u in reversed(s.units):
                    sym = u.exports.get(key)
                    if sym is not None:
                        return sym
            sym = s.table.get(key)
            if sym is not None:
                return sym
            s = s.parent
        return None


_LIBRARY_CACHE: Dict[tuple, tuple] = {}


def load_library(tpl: str):
    """(images, Loader) of a TURBO.TPL; decoding takes ~0.1 s, so it is done once per file version.  The result is
    plain data and may be shared between providers."""
    from tpu_dump import split_images, Loader
    st = os.stat(tpl)
    key = (os.path.abspath(tpl), st.st_mtime_ns, st.st_size)
    got = _LIBRARY_CACHE.get(key)
    if got is None:
        with open(tpl, 'rb') as f:
            images = split_images(f.read())
        got = (images, Loader(images))
        _LIBRARY_CACHE.clear()
        _LIBRARY_CACHE[key] = got
    return got


def _ci_join(base: str, rel: str) -> Optional[str]:
    """base/rel with every part matched without regard to case; None if it does not exist."""
    cur = base
    for part in rel.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            cur = os.path.dirname(cur)
            continue
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        hit = next((n for n in names if n.lower() == part.lower()), None)
        if hit is None:
            return None
        cur = os.path.join(cur, hit)
    return cur if os.path.isfile(cur) else None


class UnitInfo:
    def __init__(self, name: str, exports: Dict[str, Sym], path: Optional[str] = None):
        self.name = name
        self.exports = exports
        self.path = path             # .pas file (None for TPU / standard library units)
        self.tpu = None              # TPU / standard library units: the decoded tpu_dump.Unit (for the stub)
        self.origin = None           # ... and the .TPU / TURBO.TPL file it was read from


# ---------------------------------------------------------------------------------------------------
class Provider:
    """Finds units: NAME.PAS (source) or NAME.TPU in `dirs`, the standard library from `tpl` (TURBO.TPL)."""

    def __init__(self, dirs=(), tpl: Optional[str] = None, index=None):
        self.dirs = list(dirs)
        self.near = None                        # the file that is being worked on: the nearest unit of that name wins
        self.index = index                      # tp7index.ProjectIndex: units of the whole project tree, last resort
        if index is not None:
            index.refresh()
        self.index_gen = index.generation if index is not None else 0
        self.cache: Dict[str, Optional[UnitInfo]] = {}
        self.overlay: Dict[str, str] = {}      # normcase(abspath) -> text of an open editor buffer (wins over the disk)
        self._loading = set()
        self.errors: List[str] = []             # units that failed to load (damaged files), for diagnostics/logging
        self.warnings: List[str] = []           # not errors: why a unit came out as it did (logged only)
        self.lib_images = []
        self.std = None
        self.std_names = set()
        self.tpl_path = tpl
        self.stamps: Dict[str, tuple] = {}      # files this provider read -> (size, mtime): what the cached units rest on
        self.dir_stamps = {d: self._stamp(d) for d in self.dirs}
        if tpl:
            self.stamps[tpl] = self._stamp(tpl)
        if tpl:
            self.lib_images, self.std = load_library(tpl)
            self.std_names = set(self.std.units)

    @staticmethod
    def _stamp(path: str):
        try:
            st = os.stat(path)
            return (st.st_size, st.st_mtime_ns)
        except OSError:
            return None

    def still_valid(self) -> bool:
        """Is everything the cached units were made from still as it was?  (Files read, the folders that were searched.)"""
        if self.index is not None:
            self.index.refresh()
            if self.index.generation != self.index_gen:
                return False
        return all(self._stamp(p) == st for p, st in self.stamps.items()) and \
            all(self._stamp(d) == st for d, st in self.dir_stamps.items())

    # -- public ---------------------------------------------------------------------------------------
    def system(self) -> Optional[UnitInfo]:
        return self.get('System')

    def unit_names(self) -> List[str]:
        """Names of the units that `uses` could name: the standard library, NAME.PAS / NAME.TPU of the search path, and the
        open editor buffers."""
        out = {}
        for n in self.std_names:
            u = self.std.units[n]
            out[n] = getattr(u, 'name', None) or n
        for d in self.dirs:
            try:
                names = os.listdir(d)
            except OSError:
                continue
            for fn in names:
                base, ext = os.path.splitext(fn)
                if ext.lower() in ('.pas', '.tpu') and base.lower() not in out:
                    out[base.lower()] = base
        if self.index is not None:
            for base in self.index.unit_names():
                out.setdefault(base.lower(), base)
        for k in self.overlay:
            base, ext = os.path.splitext(os.path.basename(k))
            if ext.lower() == '.pas' and base.lower() not in out:
                out[base.lower()] = base
        return sorted(out.values(), key=str.lower)

    def get(self, name: str) -> Optional[UnitInfo]:
        key = name.lower()
        if key in self.cache:
            return self.cache[key]
        if key in self._loading:
            return None
        self._loading.add(key)
        try:
            info = None
            try:
                if key in self.std_names:
                    info = self._from_tpu_unit(self.std.units[key], self.tpl_path)
                if info is None:
                    info = self._from_source(key) or self._from_tpu_file(key)
            except Exception as e:                      # a damaged .TPU / unreadable file must not break formatting
                info = None
                self.errors.append('%s: %s: %s' % (name, type(e).__name__, e))
            self.cache[key] = info
            return info
        finally:
            self._loading.discard(key)

    # -- sources --------------------------------------------------------------------------------------
    def _find(self, key, ext, first=None, deep=False, near=None):
        for d in ([first] if first else []) + list(self.dirs):
            try:
                for fn in os.listdir(d):
                    if fn.lower() == key + ext:
                        return os.path.join(d, fn)
            except OSError:
                pass
        if deep and self.index is not None:                        # the folders of the project below the search path
            allp = self.index.find_unit_all(key, ext, near)
            if allp:
                if len(allp) > 1:
                    self.warnings.append('unit %s: %d files of that name in the project, using %s'
                                         % (key, len(allp), allp[0]))
                return allp[0]
        return None

    def include_resolver(self, base_path: Optional[str] = None):
        """-> include(name, from_path) for tp7parse.parse: finds the file of a `{$I name}` directive (next to the file that
        includes it, then in the search path; no extension means .PAS; the case of names and `\\` do not matter, as on
        DOS) and returns (path, text), the text of an open buffer winning over the disk."""
        def include(name: str, from_path: Optional[str]):
            rel = name.strip().strip('\'"').split()[0] if name.strip() else ''
            if not rel:
                return None
            rel = rel.replace('\\', '/')
            if not os.path.splitext(rel)[1]:
                rel += '.pas'
            bases = []
            for p in (from_path, base_path):
                if p:
                    bases.append(os.path.dirname(os.path.abspath(p)))
            bases += self.dirs
            for d in bases:
                path = _ci_join(d, rel)
                if path:
                    try:
                        return path, self.read_text(path)
                    except OSError:
                        continue
            if self.index is not None:                  # somewhere else in the project
                path = self.index.find_file(rel, from_path or base_path)
                if path:
                    try:
                        return path, self.read_text(path)
                    except OSError:
                        pass
            return None
        return include

    def read_text(self, path: str) -> str:
        """Text of a source file: the open editor buffer if there is one, otherwise the disk (cp866)."""
        src = self.overlay.get(os.path.normcase(os.path.abspath(path)))
        if src is None:
            self.stamps[path] = self._stamp(path)
            with open(path, 'rb') as f:
                src = f.read().decode('cp866')
        return src

    def _from_source(self, key) -> Optional[UnitInfo]:
        path = self._find(key, '.pas', deep=True, near=self.near)
        if not path:
            return None
        src = self.read_text(path)
        res = parse(src, include=self.include_resolver(path), path=path)
        root = res.tree.kids[0] if res.tree.kids else None
        if root is None or root.kind != 'Unit':
            return None
        b = Binder(res, self, export_only=True)
        b.path = path
        b.run()
        name = root.kids[1].kids[0].text
        return UnitInfo(name, b.iface_table, path)

    def _from_tpu_file(self, key) -> Optional[UnitInfo]:
        path = self._find(key, '.tpu', deep=True, near=self.near)
        if not path:
            return None
        from tpu_dump import split_images, Loader
        self.stamps[path] = self._stamp(path)
        with open(path, 'rb') as f:
            imgs = split_images(f.read())
        if not imgs:
            return None
        n = len(imgs)
        ld = None
        try:
            ld = Loader(imgs + self._tpu_dependencies(imgs, os.path.dirname(path)) + self.lib_images, primary=n)
        except Exception as e:                      # a dependency we cannot decode must not hide the unit itself
            self.warnings.append('%s: dependencies skipped: %s: %s' % (key, type(e).__name__, e))
            ld = None
        if ld is None:
            ld = Loader(imgs + self.lib_images, primary=n)
        u = ld.units.get(key)
        if u is None:
            self.warnings.append('%s: %s holds the units %s' % (key, path, ', '.join(sorted(ld.units))))
        return self._from_tpu_unit(u, path) if u else None

    def _tpu_dependencies(self, imgs, home=None) -> list:
        """Images of the .TPU files the given images use (transitively), so that types declared in them
        (Objects.TPoint in Views.TPU) are decoded instead of printed as 'Objects.?'.  Units that live in
        the library (TURBO.TPL) are already there."""
        from tpu_dump import split_images
        have = set()
        for im in list(imgs) + list(self.lib_images):
            own = sorted((r for r in im.records().values() if r['tag'] == 'S'), key=lambda r: r['off'])
            if own:
                have.add(own[0]['name'].lower())
        out, todo = [], [(im, home) for im in imgs]
        while todo:
            im, where = todo.pop()
            for r in im.records().values():
                if r['tag'] != 'S':
                    continue
                k = r['name'].lower()
                if k in have:
                    continue
                have.add(k)
                # a unit used by a TPU is looked for next to that TPU first: the project may have its own,
                # different Objects.TPU, and the one Views.TPU was compiled against is the library's
                path = self._find(k, '.tpu', where)
                if not path:
                    continue
                self.stamps[path] = self._stamp(path)
                try:
                    with open(path, 'rb') as f:
                        sub = split_images(f.read())
                except OSError:
                    continue
                out += sub
                todo += [(x, os.path.dirname(path)) for x in sub]
        return out

    def _from_tpu_unit(self, u, origin: Optional[str] = None) -> UnitInfo:
        exports: Dict[str, Sym] = {}
        info = UnitInfo(u.name, exports)
        info.tpu, info.origin = u, origin
        kinds = {'routine': 'routine', 'var': 'var', 'const': 'const', 'type': 'type', 'builtin': 'builtin'}
        for s in u.symbols:
            kind = kinds.get(s.kind, 'builtin')
            sym = Sym(s.name, kind)
            sym.lib = True
            sym.home = u.name
            td = s.tdesc
            sym.tdesc, sym.lparams = td, s.params
            sym.typed_const = bool(s.typed_const)
            if kind == 'const':
                sym.cvalue = (s.value, s.display)
            if kind == 'type':
                sym.tdesc = td
            if kind == 'const':
                sym.tfn = lambda: PRIM
            elif td is not None:
                if kind == 'type':                      # the fields of a record type know where they are declared
                    sym.tfn = (lambda td=td, h=u.name, o=s.name: self.tinfo_from_tdesc(td, 0, h, o))
                else:
                    sym.tfn = (lambda td=td: self.tinfo_from_tdesc(td))
            if kind in ('var', 'const', 'routine') and isinstance(td, dict) and td.get('named') and td.get('unit'):
                sym.type_ref = (td['unit'], td['named'])
            exports[s.name.lower()] = sym
        return info

    def tinfo_from_tdesc(self, td: dict, depth=0, home: Optional[str] = None, owner: Optional[str] = None) -> TInfo:
        if depth > 12 or not isinstance(td, dict):
            return UNKNOWN
        if 'named' in td:
            n = td['named']
            if td.get('unit'):
                u = self.get(td['unit'])
                sym = u.exports.get(n.lower()) if u else None
                if sym is not None and sym.kind == 'type':
                    return ti_of_sym(sym)
            return STRING if n == 'string' else PRIM
        if 'unresolved' in td:
            return UNKNOWN
        k = td.get('kind')
        if k == 'record':
            def fields(td=td):
                out = {}
                for f in td['fields']:
                    s = Sym(f['name'], 'field')
                    s.lib = True
                    s.tdesc = f.get('type')
                    s.home, s.stub_owner = home, owner
                    ft = f.get('type')
                    if isinstance(ft, dict) and ft.get('named') and ft.get('unit'):
                        s.type_ref = (ft['unit'], ft['named'])
                    s.tfn = (lambda t=f['type']: self.tinfo_from_tdesc(t, depth + 1))
                    out[f['name'].lower()] = s
                return out
            return TInfo('record', fields_fn=fields)
        if k == 'object':                               # an object type of a TPU: fields and methods, ancestors apart
            def own(td=td):
                out = {}
                for f in td['fields']:
                    if f.get('private'):                  # private members of a unit are invisible outside it
                        continue
                    s = Sym(f['name'], 'field')
                    s.lib = True
                    s.tdesc = f.get('type')
                    s.home, s.stub_owner = home, owner
                    ft = f.get('type')
                    if isinstance(ft, dict) and ft.get('named') and ft.get('unit'):
                        s.type_ref = (ft['unit'], ft['named'])
                    s.tfn = (lambda t=f['type']: self.tinfo_from_tdesc(t, depth + 1))
                    out[f['name'].lower()] = s
                for m in td['methods']:
                    if m.get('private'):
                        continue
                    s = Sym(m['name'], 'routine')
                    s.lib = True
                    s.tdesc, s.lparams = m.get('result'), m.get('params')
                    s.home, s.stub_owner, s.method_kind = home, owner, m['kind']
                    rt = m.get('result')
                    if isinstance(rt, dict):
                        if rt.get('named') and rt.get('unit'):
                            s.type_ref = (rt['unit'], rt['named'])
                        s.tfn = (lambda t=rt: self.tinfo_from_tdesc(t, depth + 1))
                    else:
                        s.tfn = (lambda: UNKNOWN)
                    out[m['name'].lower()] = s
                return out
            t = TInfo('record', obj=True, own_fn=own)
            anc = td.get('ancestor')
            if isinstance(anc, dict) and anc.get('named'):
                def ancestor(anc=anc):
                    a = self.tinfo_from_tdesc(anc, depth + 1)
                    return a if a is not None and a.kind == 'record' else None
                t.ancestor_fn = ancestor

            def merged(t=t):
                out = dict(t.get_own())
                a = t.get_ancestor()
                if a is not None:
                    for key, m in a.get_fields().items():
                        out.setdefault(key, m)
                return out
            t.fields_fn = merged
            return t
        if k == 'array':
            return TInfo('array', dims=1, elem_fn=(lambda: self.tinfo_from_tdesc(td['elem'], depth + 1)))
        if k == 'pointer':
            return TInfo('pointer', target_fn=(lambda: self.tinfo_from_tdesc(td['to'], depth + 1)))
        if k == 'string':
            return STRING
        return PRIM


def ti_of_sym(sym: Sym) -> TInfo:
    """Type of a variable/field/param/constant, or the type a type symbol stands for, or a routine's result."""
    if sym._t is not None:
        return sym._t
    if sym._busy:
        return UNKNOWN
    sym._busy = True
    try:
        t = sym.tfn() if sym.tfn is not None else UNKNOWN
        sym._t = t
        return t
    finally:
        sym._busy = False


# ---------------------------------------------------------------------------------------------------
SECTION_KINDS = ('ConstSection', 'TypeSection', 'VarSection', 'LabelSection')


# What a half-typed declaration can do to code that expects a well-formed tree: such a declaration is skipped.
BROKEN = (IndexError, StopIteration, AttributeError, ValueError, TypeError)


def label_key(text: str) -> str:
    """Scope key of a label: a number is the same label however it is written (1, 01); a name is case-insensitive."""
    return str(int(text)) if text.isdigit() else text.lower()


def is_tok(x, *texts):
    return isinstance(x, Token) and x.text.lower() in texts


class Binder:
    def __init__(self, res: Result, provider: Optional[Provider], export_only: bool = False):
        self.res = res
        self.provider = provider
        self.export_only = export_only
        self.unresolved: List[Token] = []
        self.uncertain: List[Token] = []
        self.missing_units: List[Token] = []
        self.renamed = 0
        self.iface_table: Dict[str, Sym] = {}
        self._ti_cache: Dict[int, TInfo] = {}
        self.links: Dict[int, Sym] = {}                 # id(Routine node in implementation) -> interface Sym
        self.path: Optional[str] = None                 # file of this source (set for units loaded from disk)
        self.refs: Dict[int, Sym] = {}                  # id(identifier token) -> declaration it refers to
        self.decls: Dict[int, Sym] = {}                 # id(declaring token) -> its symbol
        self.owners: Dict[int, Sym] = {}                # id(RecordType / ObjectType / EnumType node) -> the type symbol that names it
        self.node_scopes: List[tuple] = []              # (node, scope): where completion looks names up
        self.dups: List[tuple] = []                     # (token of the second declaration, first Sym): same scope, same name
        self.cur_ti: Optional[TInfo] = None             # inside a method body: the type the method belongs to

    # -- helpers --------------------------------------------------------------------------------------
    def rewrite(self, tok: Token, sym: Sym):
        if self.export_only or sym is None or tok.kind not in ('IDENT', 'INT'):
            return
        self.refs[id(tok)] = sym                        # for go-to-definition
        if tok.kind == 'INT':                           # a numeric label: nothing to normalize
            return
        if tok.text != sym.name:
            tok.text = sym.name
            self.renamed += 1

    def system_scope(self) -> Scope:
        sysu = self.provider.system() if self.provider else None
        return Scope(units=[sysu] if sysu else [])

    def uses_scope(self, uses: Optional[Node], parent: Scope) -> Scope:
        units, table = [], {}
        if uses is not None:
            for nm in uses.kids:
                if not isinstance(nm, Node) or nm.kind != 'Name':
                    continue
                tok = nm.kids[0]
                info = self.provider.get(tok.text) if self.provider else None
                if info is None:
                    self.missing_units.append(tok)
                    continue
                s = Sym(info.name, 'unit')
                s.unit = info
                s.file = info.path
                s.lib = info.path is None
                self.rewrite(tok, s)
                units.append(info)
                table[info.name.lower()] = s
        sc = Scope(table=table, parent=parent, units=units)
        return sc

    # -- types ----------------------------------------------------------------------------------------
    def ti_node(self, node, scope: Scope) -> TInfo:
        if node is None:
            return UNKNOWN
        key = id(node)
        if key in self._ti_cache:
            return self._ti_cache[key]
        self._ti_cache[key] = UNKNOWN                      # cycle guard
        t = self._ti_node(node, scope)
        self._ti_cache[key] = t
        return t

    def _ti_node(self, node, scope):
        k = node.kind
        if k == 'NamedType':
            sym = self.type_sym(node.kids[0], scope)
            return ti_of_sym(sym) if sym is not None and sym.kind == 'type' else UNKNOWN
        if k == 'PackedType':
            return self.ti_node(node.kids[1], scope)
        if k == 'PointerType':
            return TInfo('pointer', target_fn=lambda: self._ptr_target(node.kids[1], scope))
        if k == 'ArrayType':
            kids = node.kids
            i_of = next((i for i in range(len(kids) - 1, 0, -1) if is_tok(kids[i], 'of')), None)
            if i_of is None:
                return UNKNOWN
            dims = max(1, sum(1 for x in kids[2:i_of - 1] if isinstance(x, Node)))
            elem = kids[i_of + 1]
            return TInfo('array', dims=dims, elem_fn=lambda: self.ti_node(elem, scope))
        if k in ('RecordType', 'ObjectType'):
            return self.record_ti(node, scope)
        if k == 'StringType':
            return STRING
        return PRIM

    def record_ti(self, node: Node, scope: Scope) -> TInfo:
        """Type of a record / object: `fields_fn` gives all members including the ancestors' (child wins), `own_fn` only
        the type's own, `ancestor_fn` the type of the ancestor."""
        her = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
        t = TInfo('record', obj=node.kind == 'ObjectType', node=node, own_fn=lambda: self.build_members(node, scope))
        if her is not None and len(her.kids) > 1 and isinstance(her.kids[1], Node):
            def ancestor():
                sym = self.type_sym(her.kids[1], scope)
                a = ti_of_sym(sym) if sym is not None and sym.kind == 'type' else None
                return a if a is not None and a.kind == 'record' else None
            t.ancestor_fn = ancestor

        def merged():
            out = dict(t.get_own())
            anc = t.get_ancestor()
            if anc is not None:
                for key, m in anc.get_fields().items():
                    out.setdefault(key, m)
            return out
        t.fields_fn = merged
        return t

    def type_ti(self, sym: Optional[Sym]) -> Optional[TInfo]:
        """TInfo of the record / object that a TYPE symbol declares directly (aliases are not followed: this is also
        used while declarations are still being collected)."""
        if sym is None or sym.kind != 'type' or sym.tnode is None:
            return None
        inner = sym.tnode
        while isinstance(inner, Node) and inner.kind == 'PackedType' and len(inner.kids) > 1:
            inner = inner.kids[1]
        if not isinstance(inner, Node) or inner.kind not in ('RecordType', 'ObjectType'):
            return None
        return self.ti_node(inner, sym.scope)

    def _ptr_target(self, name_node, scope):
        sym = self.type_sym(name_node, scope)
        return ti_of_sym(sym) if sym is not None and sym.kind == 'type' else UNKNOWN

    def type_sym(self, name_node: Node, scope: Scope, rewrite: bool = False) -> Optional[Sym]:
        toks = [t for t in name_node.kids if isinstance(t, Token) and t.kind == 'IDENT']
        if not toks:
            return None
        sym = scope.lookup(toks[0].text.lower())
        if rewrite:
            self.note(toks[0], sym)
        if sym is not None and sym.kind == 'unit' and len(toks) > 1:
            sym = sym.unit.exports.get(toks[1].text.lower())
            if rewrite:
                self.note(toks[1], sym)
        return sym

    def note(self, tok: Token, sym: Optional[Sym]):
        if sym is None:
            self.unresolved.append(tok)
        else:
            self.rewrite(tok, sym)

    def build_members(self, rec: Node, scope: Scope) -> Dict[str, Sym]:
        """Own fields and methods of a record / object, in declaration order."""
        out: Dict[str, Sym] = {}
        owner = self.owners.get(id(rec))

        def field(tok, tn):
            s = Sym(tok.text, 'field', tok=tok, tnode=tn, scope=scope)
            s.binder = self
            s.file = tok.file or self.path
            s.owner = owner
            self.note_decl(tok, s)
            s.tfn = (lambda tn=tn: self.ti_node(tn, scope))
            old = out.setdefault(tok.text.lower(), s)
            if old is not s and not self.export_only:
                self.dups.append((tok, old))

        def fl(node):
            for k in node.kids:
                if isinstance(k, Token):
                    continue
                if k.kind == 'FieldDecl':
                    kids = k.kids
                    colon = max((i for i, x in enumerate(kids) if is_tok(x, ':')), default=None)
                    if colon is None or colon + 1 >= len(kids):          # `a, b` without a type: broken source
                        continue
                    tn = kids[colon + 1]
                    for x in kids[:colon]:
                        if isinstance(x, Node) and x.kind == 'DeclName' and x.kids:
                            field(x.kids[0], tn)
                elif k.kind == 'Routine':
                    name_tok, params, res = self.routine_parts(k)
                    m = self.make_sym(name_tok, 'routine', res, scope, k)
                    m.owner = owner
                    m.has_body = False
                    m.header_params = params
                    old = out.setdefault(name_tok.text.lower(), m)
                    if old is not m and not self.export_only:
                        self.dups.append((name_tok, old))
                elif k.kind == 'VariantPart':
                    kids = k.kids
                    if len(kids) > 3 and isinstance(kids[1], Node) and kids[1].kind == 'DeclName' and is_tok(kids[2], ':'):
                        field(kids[1].kids[0], kids[3])
                    for v in kids:
                        if isinstance(v, Node) and v.kind == 'Variant':
                            for x in v.kids:
                                if isinstance(x, Node) and x.kind == 'FieldList':
                                    fl(x)
        body = fieldlist_of(rec)
        if body is not None:
            fl(body)
        return out

    # -- phase 1: declare -----------------------------------------------------------------------------
    def note_decl(self, tok: Token, sym: Sym):
        if not self.export_only:
            self.decls[id(tok)] = sym

    def make_sym(self, tok: Token, kind: str, tnode, scope: Scope, node=None) -> Sym:
        s = Sym(tok.text, kind, tok=tok, tnode=tnode, scope=scope, node=node)
        s.binder = self
        s.file = tok.file or self.path
        self.note_decl(tok, s)
        if kind in ('var', 'param', 'field'):
            s.tfn = (lambda: self.ti_node(tnode, scope)) if tnode is not None else (lambda: UNKNOWN)
        elif kind == 'type':
            s.tfn = lambda: self.ti_node(tnode, scope)
        elif kind == 'const':
            s.tfn = (lambda: self.ti_node(tnode, scope)) if tnode is not None else (lambda: PRIM)
        elif kind == 'enum':
            s.tfn = lambda: PRIM
        elif kind == 'routine':
            s.tfn = lambda: self._result_ti(s)
        return s

    def _result_ti(self, rsym: Sym) -> TInfo:
        return self.ti_node(rsym.tnode, rsym.scope) if rsym.tnode is not None else UNKNOWN

    def declare(self, scope: Scope, sym: Sym):
        old = scope.table.setdefault(label_key(sym.name) if sym.kind == 'label' else sym.name.lower(), sym)
        if old is not sym and sym.tok is not None and not self.export_only:
            self.dups.append((sym.tok, old))

    def collect(self, items, scope: Scope, link_table: Optional[Dict[str, Sym]] = None):
        for sec in items:
            if not isinstance(sec, Node):
                continue
            k = sec.kind
            if k == 'Routine':
                try:
                    self.collect_routine(sec, scope, link_table)
                except BROKEN:
                    pass
            elif k == 'LabelSection':
                for t in sec.kids[1:]:
                    if isinstance(t, Token) and t.kind in ('IDENT', 'INT'):
                        lab = Sym(t.text, 'label', tok=t)
                        lab.file = t.file or self.path
                        self.note_decl(t, lab)
                        self.declare(scope, lab)
            elif k in ('ConstSection', 'TypeSection', 'VarSection'):
                for d in sec.kids[1:]:
                    if not isinstance(d, Node):
                        continue
                    try:
                        self.collect_decl(k, d, scope)
                    except BROKEN:
                        pass

    def collect_decl(self, k: str, d: Node, scope: Scope):
        if k == 'ConstSection':
            kids = d.kids
            tn = kids[2] if len(kids) > 2 and is_tok(kids[1], ':') else None
            self.declare(scope, self.make_sym(kids[0].kids[0], 'const', tn, scope, d))
            if isinstance(tn, Node):
                self.declare_enums(tn, scope)
        elif k == 'TypeSection':
            tn = d.kids[2]
            if not isinstance(tn, Node):
                return
            tsym = self.make_sym(d.kids[0].kids[0], 'type', tn, scope, d)
            self.declare(scope, tsym)
            inner = tn
            while isinstance(inner, Node) and inner.kind == 'PackedType' and len(inner.kids) > 1:
                inner = inner.kids[1]
            if isinstance(inner, Node) and inner.kind in ('RecordType', 'ObjectType', 'EnumType'):
                self.owners[id(inner)] = tsym
            self.declare_enums(tn, scope, d.kids[0].kids[0])
        else:                                                      # VarSection
            kids = d.kids
            colon = next(i for i, x in enumerate(kids) if is_tok(x, ':'))
            tn = kids[colon + 1]
            if not isinstance(tn, Node):
                return
            for x in kids[:colon]:
                if isinstance(x, Node) and x.kind == 'DeclName' and x.kids:
                    self.declare(scope, self.make_sym(x.kids[0], 'var', tn, scope, d))
            self.declare_enums(tn, scope)

    def declare_enums(self, tn: Node, scope: Scope, owner: Optional[Token] = None):
        for n in tn.walk():
            if n.kind == 'EnumType':
                for m in n.kids:
                    if isinstance(m, Node) and m.kind == 'DeclName':
                        sym = self.make_sym(m.kids[0], 'enum', n, scope)
                        if n is tn:
                            sym.type_tok = owner                   # `type E = (A, B)`: E
                        self.declare(scope, sym)

    def routine_parts(self, r: Node):
        """-> (name token, Params node or None, result type node or None); for `T.M` the name token is M's"""
        kids = r.kids
        owner, dn = routine_names(r)
        name_tok = dn.kids[0]
        i = 4 if owner is not None else 2
        params = kids[i] if i < len(kids) and isinstance(kids[i], Node) and kids[i].kind == 'Params' else None
        if params is not None:
            i += 1
        res = kids[i + 1] if i + 1 < len(kids) and is_tok(kids[i], ':') and isinstance(kids[i + 1], Node) else None
        return name_tok, params, res

    def method_of(self, r: Node, scope: Scope, link_table=None):
        """(owner type Sym, method Sym or None) for a routine written as `T.M`; (None, None) for an ordinary routine."""
        owner, _ = routine_names(r)
        if owner is None or not owner.kids or not isinstance(owner.kids[0], Token):
            return None, None
        key = owner.kids[0].text.lower()
        tsym = scope.lookup(key)
        if tsym is None and link_table is not None:
            tsym = link_table.get(key)
        ti = self.type_ti(tsym)
        if ti is None:
            return tsym, None
        name_tok = routine_names(r)[1].kids[0]
        m = ti.get_own().get(name_tok.text.lower())
        return tsym, (m if m is not None and m.kind == 'routine' else None)

    def collect_routine(self, r: Node, scope: Scope, link_table):
        name_tok, params, res = self.routine_parts(r)
        key = name_tok.text.lower()
        dirs = next((x for x in r.kids if isinstance(x, Node) and x.kind == 'Directives'), None)
        has_body = any(isinstance(x, Node) and x.kind == 'Block' for x in r.kids) \
            or dirs is not None and any(is_tok(t, 'external') for t in dirs.kids)    # the body is in an .OBJ
        if routine_names(r)[0] is not None:                  # procedure T.M: implements a method, declares nothing
            _, m = self.method_of(r, scope, link_table)
            if m is not None and has_body and not getattr(m, 'has_body', False):
                self.links[id(r)] = m
                m.has_body = True
                m.impl_tok = name_tok
                self.note_decl(name_tok, m)
            return
        existing = None
        if link_table is not None:
            existing = link_table.get(key)
        else:
            existing = scope.table.get(key)
        if existing is not None and existing.kind == 'routine' and has_body and not getattr(existing, 'has_body', False):
            self.links[id(r)] = existing
            existing.has_body = True
            existing.impl_tok = name_tok
            self.note_decl(name_tok, existing)
            return
        sym = self.make_sym(name_tok, 'routine', res, scope, r)
        sym.has_body = has_body
        sym.header_params = params
        self.declare(scope, sym)

    # -- phase 2: resolve -----------------------------------------------------------------------------
    def resolve_decls(self, items, scope: Scope):
        for sec in items:
            if not isinstance(sec, Node):
                continue
            k = sec.kind
            if k == 'Routine':
                try:
                    self.resolve_header(sec, scope)
                except BROKEN:
                    pass
            elif k in ('ConstSection', 'TypeSection', 'VarSection'):
                for d in sec.kids[1:]:
                    if not isinstance(d, Node):
                        continue
                    try:
                        self.resolve_decl(k, d, scope)
                    except BROKEN:
                        pass

    def resolve_decl(self, k: str, d: Node, scope: Scope):
        kids = d.kids
        if k == 'ConstSection':
            if is_tok(kids[1], ':'):
                self.resolve_type(kids[2], scope)
                eq = next(i for i, x in enumerate(kids) if is_tok(x, '='))
                self.resolve_value(kids[eq + 1], self.ti_node(kids[2], scope), scope, [])
            else:
                self.resolve_expr(kids[2], scope, [])
        elif k == 'TypeSection':
            self.resolve_type(kids[2], scope)
        else:
            colon = next(i for i, x in enumerate(kids) if is_tok(x, ':'))
            self.resolve_type(kids[colon + 1], scope)
            for x in kids[colon + 2:]:
                if isinstance(x, Node) and x.kind == 'Absolute':
                    for e in x.kids:
                        if isinstance(e, Node):
                            self.resolve_expr(e, scope, [])

    def resolve_header(self, r: Node, scope: Scope):
        name_tok, params, res = self.routine_parts(r)
        link = self.links.get(id(r))
        owner, _ = routine_names(r)
        if owner is not None:
            tsym, m = self.method_of(r, scope)
            self.note(owner.kids[0], tsym)
            if m is None:
                self.unresolved.append(name_tok)
        if link is not None:
            self.rewrite(name_tok, link)
        if params is not None:
            self.resolve_type(params, scope)
        if res is not None:
            self.resolve_type(res, scope)

    def bind_bodies(self, items, scope: Scope):
        for r in items:
            if isinstance(r, Node) and r.kind == 'Routine':
                try:
                    self.bind_routine(r, scope)
                except BROKEN:
                    pass

    def bind_routine(self, r: Node, scope: Scope):
        block = next((x for x in r.kids if isinstance(x, Node) and x.kind == 'Block'), None)
        if block is None:
            return
        name_tok, params, res = self.routine_parts(r)
        link = self.links.get(id(r))
        rs = Scope({}, parent=scope)
        self.node_scopes.append((r, rs))
        saved = self.cur_ti
        if routine_names(r)[0] is not None:                  # method body: members, then Self
            tsym, _ = self.method_of(r, scope)
            ti = self.type_ti(tsym)
            if ti is not None:
                rs = Scope({}, parent=Scope(table=ti.get_fields(), parent=scope))
                self.node_scopes[-1] = (r, rs)
                me = Sym('Self', 'param', scope=scope)
                me.implicit = True
                me.owner = tsym
                me.tfn = (lambda ti=ti: ti)
                rs.table['self'] = me
                self.cur_ti = ti
        try:
            if params is not None:
                self.declare_params(params, rs, scope)
            elif link is not None and getattr(link, 'header_params', None) is not None:
                self.declare_params(link.header_params, rs, link.scope)
            items = [x for x in block.kids if isinstance(x, Node) and x.kind != 'Compound' and x.kind != 'Asm']
            self.collect(items, rs)
            self.resolve_decls(items, rs)
            self.bind_bodies(items, rs)
            for x in block.kids:
                if isinstance(x, Node) and x.kind == 'Compound':
                    self.resolve_stmt(x, rs, [])
        finally:
            self.cur_ti = saved

    def declare_params(self, params: Node, into: Scope, tscope: Scope):
        for g in params.kids:
            if isinstance(g, Node) and g.kind == 'ParamGroup':
                kids = g.kids
                tn = None
                if any(is_tok(x, ':') for x in kids):
                    tn = kids[-1] if isinstance(kids[-1], Node) else None
                for x in kids:
                    if isinstance(x, Node) and x.kind == 'DeclName':
                        self.declare(into, self.make_sym(x.kids[0], 'param', tn, tscope))

    # -- types (rewrite) -------------------------------------------------------------------------------
    def resolve_type(self, node, scope: Scope):
        if node is None or isinstance(node, Token):
            return
        k = node.kind
        if k == 'NamedType':
            self.type_sym(node.kids[0], scope, rewrite=True)
        elif k == 'PointerType':
            self.type_sym(node.kids[1], scope, rewrite=True)
        elif k in ('ArrayType', 'PackedType', 'SetType', 'FileType', 'ProcType', 'Params', 'ParamGroup',
                   'SubrangeType', 'StringType'):
            for x in node.kids:
                if isinstance(x, Node):
                    if k in ('SubrangeType', 'StringType'):
                        self.resolve_expr(x, scope, [])
                    else:
                        self.resolve_type(x, scope)
        elif k in ('RecordType', 'ObjectType'):
            self.ti_node(node, scope).get_own()              # creates the member symbols (and so their declarations)
            her = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
            if her is not None and len(her.kids) > 1 and isinstance(her.kids[1], Node):
                self.type_sym(her.kids[1], scope, rewrite=True)
            body = fieldlist_of(node)
            if body is not None:
                self.resolve_fieldlist(body, scope)

    def note_field_decl(self, name_node: Node):
        """Fields are only turned into symbols when somebody looks a field up; their declaring tokens must be known
        anyway (references, rename, highlighting)."""
        tok = name_node.kids[0] if name_node.kids else None
        if isinstance(tok, Token) and id(tok) not in self.decls:
            s = Sym(tok.text, 'field', tok=tok)
            s.file = tok.file or self.path
            self.note_decl(tok, s)

    def resolve_fieldlist(self, fl: Node, scope: Scope):
        for k in fl.kids:
            if isinstance(k, Node):
                if k.kind == 'Routine':                          # a method declaration: types of its parameters / result
                    _, params, res = self.routine_parts(k)
                    if params is not None:
                        self.resolve_type(params, scope)
                    if res is not None:
                        self.resolve_type(res, scope)
                elif k.kind == 'FieldDecl':
                    for x in k.kids:
                        if isinstance(x, Node) and x.kind == 'DeclName':
                            self.note_field_decl(x)
                    self.resolve_type(k.kids[-1], scope)
                elif k.kind == 'VariantPart':
                    for x in k.kids:
                        if isinstance(x, Node):
                            if x.kind == 'DeclName':
                                self.note_field_decl(x)
                            if x.kind == 'Variant':
                                for y in x.kids:
                                    if isinstance(y, Node):
                                        if y.kind == 'Labels':
                                            for e in y.kids:
                                                if isinstance(e, Node):
                                                    self.resolve_expr(e, scope, [])
                                        elif y.kind == 'FieldList':
                                            self.resolve_fieldlist(y, scope)
                            elif x.kind != 'DeclName':
                                self.resolve_type(x, scope)

    # -- statements ----------------------------------------------------------------------------------
    def resolve_stmt(self, s: Node, scope: Scope, withs: list):
        k = s.kind
        if k in ('Compound', 'StmtList'):
            for x in s.kids:
                if isinstance(x, Node):
                    self.resolve_stmt(x, scope, withs)
        elif k == 'Assign':
            self.resolve_expr(s.kids[0], scope, withs)
            self.resolve_expr(s.kids[2], scope, withs)
        elif k == 'ProcCall':
            self.resolve_expr(s.kids[0], scope, withs)
        elif k == 'Inherited':
            self.resolve_expr(s, scope, withs)
        elif k in ('If', 'While', 'Repeat'):
            for x in s.kids:
                if isinstance(x, Node):
                    if x.kind in ('Compound', 'StmtList', 'If', 'While', 'Repeat', 'For', 'Case', 'With', 'Assign',
                                  'ProcCall', 'Goto', 'Labeled', 'Empty', 'Asm', 'Inline', 'Inherited'):
                        self.resolve_stmt(x, scope, withs)
                    else:
                        self.resolve_expr(x, scope, withs)
        elif k == 'For':
            for x in s.kids[1:]:
                if isinstance(x, Node):
                    if x.kind == 'Name':
                        self.lookup_tokens(x.kids[0], scope, withs)
                    elif x.kind in ('Compound', 'If', 'While', 'Repeat', 'For', 'Case', 'With', 'Assign', 'ProcCall',
                                    'Goto', 'Labeled', 'Empty', 'Asm', 'Inline', 'Inherited'):
                        self.resolve_stmt(x, scope, withs)
                    else:
                        self.resolve_expr(x, scope, withs)
        elif k == 'Case':
            for x in s.kids:
                if isinstance(x, Node):
                    if x.kind == 'CaseBranch':
                        for y in x.kids:
                            if isinstance(y, Node):
                                if y.kind == 'Labels':
                                    for e in y.kids:
                                        if isinstance(e, Node):
                                            self.resolve_expr(e, scope, withs)
                                else:
                                    self.resolve_stmt(y, scope, withs)
                    elif x.kind == 'CaseElse':
                        for y in x.kids:
                            if isinstance(y, Node):
                                self.resolve_stmt(y, scope, withs)
                    else:
                        self.resolve_expr(x, scope, withs)
        elif k == 'With':
            kids = s.kids
            new = list(withs)
            for x in kids:
                if isinstance(x, Node) and x.kind == 'Designator':
                    t = self.resolve_expr(x, scope, new)
                    new.append(t if t is not None and t.kind == 'record' else None)
                elif isinstance(x, Node):
                    self.resolve_stmt(x, scope, new)
        elif k == 'Labeled':
            lab = s.kids[0]
            if lab.kind in ('IDENT', 'INT'):
                sym = self.lookup_tokens(lab, scope, [], want='label')
                if sym is not None and sym.kind == 'label' and sym.impl_tok is None:
                    sym.impl_tok = lab                            # the label itself: where `goto` lands (its definition)
            self.resolve_stmt(s.kids[2], scope, withs)
        elif k == 'Goto':
            if len(s.kids) > 1 and s.kids[1].kind in ('IDENT', 'INT'):
                self.lookup_tokens(s.kids[1], scope, [], want='label')

    def lookup_tokens(self, tok: Token, scope: Scope, withs: list, want=None):
        sym = self.find(label_key(tok.text) if tok.kind == 'INT' else tok.text.lower(), scope, withs)
        if sym is UNCERTAIN:
            self.uncertain.append(tok)
            return None
        if sym is None:
            self.unresolved.append(tok)
            return None
        self.rewrite(tok, sym)
        return sym

    def find(self, key: str, scope: Scope, withs: list):
        for w in reversed(withs):
            if w is None:
                return UNCERTAIN
            f = w.get_fields().get(key)
            if f is not None:
                return f
        return scope.lookup(key)

    # -- expressions ---------------------------------------------------------------------------------
    def resolve_expr(self, e, scope: Scope, withs: list) -> Optional[TInfo]:
        if isinstance(e, Token):
            return None
        k = e.kind
        if k == 'Designator':
            return self.designator(e, scope, withs)
        if k == 'Inherited':                                  # inherited [Name(args)]: Name is looked up in the ancestor
            d = next((x for x in e.kids if isinstance(x, Node) and x.kind == 'Designator'), None)
            if d is None:
                return None
            anc = self.cur_ti.get_ancestor() if self.cur_ti is not None else None
            return self.designator(d, scope, withs, members=anc.get_fields() if anc is not None else {})
        if k == 'Paren':
            return self.resolve_expr(e.kids[1], scope, withs)
        if k == 'Unary':
            self.resolve_expr(e.kids[1], scope, withs)
            return None
        if k == 'Binary':
            self.resolve_expr(e.kids[0], scope, withs)
            self.resolve_expr(e.kids[2], scope, withs)
            return None
        if k in ('SetCtor', 'Arg', 'Labels'):
            for x in e.kids:
                if isinstance(x, Node):
                    self.resolve_expr(x, scope, withs)
            return None
        if k == 'StringLit':
            return STRING
        if k == 'Aggregate':
            self.resolve_value(e, None, scope, withs)
        return None

    def value_type(self, sym: Optional[Sym], cur: Optional[TInfo]) -> Optional[TInfo]:
        if cur is not None:
            return cur
        if sym is None:
            return None
        if sym.kind in ('var', 'param', 'field', 'const', 'routine', 'enum'):
            return ti_of_sym(sym)
        return None

    @staticmethod
    def peel(t: Optional[TInfo], n: int) -> Optional[TInfo]:
        while t is not None and n > 0:
            if t.kind == 'array':
                if t.dims > n:
                    return TInfo('array', dims=t.dims - n, elem_fn=t.elem_fn)
                n -= t.dims
                t = t.elem_fn()
            elif t.kind == 'string':
                n -= 1
                t = PRIM
            else:
                return None
        return t

    def designator(self, d: Node, scope: Scope, withs: list, members: Optional[Dict[str, Sym]] = None) -> Optional[TInfo]:
        """members: the first name is looked up there instead of in the scopes (`inherited Name`, the constructor in
        `New(P, Init)`)."""
        kids = d.kids
        if not kids or not isinstance(kids[0], Node) or not kids[0].kids or not isinstance(kids[0].kids[0], Token):
            return None                                       # a syntax error left the designator without a name
        tok = kids[0].kids[0]
        sym = self.find(tok.text.lower(), scope, withs) if members is None else members.get(tok.text.lower())
        cur_sym: Optional[Sym] = None
        cur_t: Optional[TInfo] = None
        if sym is UNCERTAIN:
            self.uncertain.append(tok)
        elif sym is None:
            self.unresolved.append(tok)
        else:
            self.rewrite(tok, sym)
            cur_sym = sym
        for post in kids[1:]:
            pk = post.kind
            if pk == 'Field':
                ft = post.kids[1]
                if cur_sym is not None and cur_sym.kind == 'unit' and cur_t is None:
                    s2 = cur_sym.unit.exports.get(ft.text.lower())
                    self.note(ft, s2)
                    cur_sym, cur_t = s2, None
                else:
                    t = self.value_type(cur_sym, cur_t)
                    if t is not None and t.kind == 'record':
                        f = t.get_fields().get(ft.text.lower())
                        self.note(ft, f)
                        cur_sym, cur_t = f, None
                    else:
                        cur_sym, cur_t = None, None
            elif pk == 'Index':
                n = 0
                for x in post.kids:
                    if isinstance(x, Node):
                        self.resolve_expr(x, scope, withs)
                        n += 1
                t = self.value_type(cur_sym, cur_t)
                cur_t, cur_sym = self.peel(t, max(n, 1)), None
            elif pk == 'Deref':
                t = self.value_type(cur_sym, cur_t)
                cur_t = t.get_target() if t is not None and t.kind == 'pointer' else None
                cur_sym = None
            elif pk == 'Args':
                target = None
                if cur_sym is not None and cur_sym.kind in ('routine', 'builtin') and cur_sym.lib \
                        and cur_sym.name.lower() in ('new', 'dispose'):
                    target = self.pointee_members(post, scope, withs)
                nargs = 0
                for a in post.kids:
                    if isinstance(a, Node):
                        nargs += 1
                        if target is not None and nargs == 2 and a.kids and isinstance(a.kids[0], Node) \
                                and a.kids[0].kind == 'Designator':
                            self.designator(a.kids[0], scope, withs, members=target)   # New(P, Init(...)), Dispose(P, Done)
                        else:
                            self.resolve_expr(a, scope, withs)
                if cur_t is None and cur_sym is not None:
                    if cur_sym.kind == 'routine':
                        cur_t = ti_of_sym(cur_sym)
                    elif cur_sym.kind == 'type':
                        cur_t = ti_of_sym(cur_sym)
                    else:
                        cur_t = None
                else:
                    cur_t = None
                cur_sym = None
        return self.value_type(cur_sym, cur_t)

    def chain_type(self, chain: list, scope: Scope):
        """What an expression written as a chain evaluates to, for completion after a dot.  chain: [('name', text),
        ('index', n), ('deref',), ('call',)...].  -> a UnitInfo, a TInfo or None."""
        if not chain or chain[0][0] != 'name':
            return None
        sym = scope.lookup(chain[0][1].lower())
        if sym is None or sym is UNCERTAIN:
            return None
        cur_sym, cur_t = sym, None
        for step in chain[1:]:
            if cur_sym is not None and cur_sym.kind == 'unit' and cur_t is None:
                if step[0] != 'name':
                    return None
                cur_sym = cur_sym.unit.exports.get(step[1].lower())
                if cur_sym is None:
                    return None
                continue
            t = self.value_type(cur_sym, cur_t)
            if step[0] == 'name':
                f = t.get_fields().get(step[1].lower()) if t is not None and t.kind == 'record' else None
                cur_sym, cur_t = f, None
                if f is None:
                    return None
            elif step[0] == 'index':
                cur_t, cur_sym = self.peel(t, max(step[1], 1)), None
            elif step[0] == 'deref':
                cur_t = t.get_target() if t is not None and t.kind == 'pointer' else None
                cur_sym = None
            else:                                               # a call or a type cast
                if cur_t is None and cur_sym is not None and cur_sym.kind in ('routine', 'type'):
                    cur_t = ti_of_sym(cur_sym)
                else:
                    cur_t = None
                cur_sym = None
            if cur_sym is None and cur_t is None:
                return None
        if cur_sym is not None and cur_sym.kind == 'unit' and cur_t is None:
            return cur_sym.unit
        return self.value_type(cur_sym, cur_t)

    def pointee_members(self, args: Node, scope: Scope, withs: list) -> Optional[Dict[str, Sym]]:
        """Members of the object that the first argument of New / Dispose points to (a pointer variable, or - for the
        function form of New - a pointer type); None when there is no constructor argument or it is not an object."""
        a = [x for x in args.kids if isinstance(x, Node)]
        if len(a) < 2 or not a[0].kids or not isinstance(a[0].kids[0], Node) or a[0].kids[0].kind != 'Designator':
            return None
        d = a[0].kids[0]
        head = self.find(d.kids[0].kids[0].text.lower(), scope, withs)
        if head is None or head is UNCERTAIN:
            return None
        if len(d.kids) == 1 and head.kind == 'type':
            t = ti_of_sym(head)
        else:
            t = self.value_peek(d, scope, withs)
        tgt = t.get_target() if t is not None and t.kind == 'pointer' else None
        return tgt.get_fields() if tgt is not None and tgt.kind == 'record' else None

    def value_peek(self, d: Node, scope: Scope, withs: list) -> Optional[TInfo]:
        """Type of a designator without recording anything (no rewriting, no unresolved names)."""
        saved = (list(self.unresolved), list(self.uncertain), dict(self.refs), self.renamed)
        spell = [(t, t.text) for t in d.tokens() if t.kind == 'IDENT']
        try:
            return self.designator(d, scope, withs)
        finally:
            self.unresolved, self.uncertain, self.refs, self.renamed = saved[0], saved[1], saved[2], saved[3]
            for t, text in spell:
                t.text = text

    def resolve_value(self, v, t: Optional[TInfo], scope: Scope, withs: list):
        """Typed-constant initialiser: expression or (nested) aggregate, with the expected type `t`."""
        if isinstance(v, Token):
            return
        if v.kind != 'Aggregate':
            self.resolve_expr(v, scope, withs)
            return
        kids = v.kids
        i = 0
        while i < len(kids):
            x = kids[i]
            if isinstance(x, Token) and x.kind == 'IDENT' and i + 1 < len(kids) and is_tok(kids[i + 1], ':'):
                f = t.get_fields().get(x.text.lower()) if t is not None and t.kind == 'record' else None
                self.note(x, f) if f is not None else self.unresolved.append(x)
                sub = ti_of_sym(f) if f is not None else None
                if i + 2 < len(kids):
                    self.resolve_value(kids[i + 2], sub, scope, withs)
                i += 3
                continue
            if isinstance(x, Node):
                sub = self.peel(t, 1) if t is not None and t.kind == 'array' else None
                self.resolve_value(x, sub, scope, withs)
            i += 1

    # -- file level ----------------------------------------------------------------------------------
    def run(self):
        root = self.res.tree.kids[0] if self.res.tree.kids else None
        if root is None:
            return
        if root.kind == 'Unit':
            self.run_unit(root)
        elif root.kind == 'Program':
            self.run_program(root)

    def decl_items(self, part: Node):
        return [x for x in part.kids if isinstance(x, Node) and x.kind != 'UsesClause']

    def run_unit(self, u: Node):
        iface = next((x for x in u.kids if isinstance(x, Node) and x.kind == 'Interface'), None)
        impl = next((x for x in u.kids if isinstance(x, Node) and x.kind == 'Implementation'), None)
        if iface is None:
            return
        sys_scope = self.system_scope()
        iu = self.uses_scope(next((x for x in iface.kids if isinstance(x, Node) and x.kind == 'UsesClause'), None), sys_scope)
        ifs = Scope(table=self.iface_table, parent=iu)
        own = Sym(u.kids[1].kids[0].text, 'unit')
        own.unit = UnitInfo(own.name, self.iface_table)
        ifs.parent.table.setdefault(own.name.lower(), own)
        items = self.decl_items(iface)
        self.collect(items, ifs)
        if self.export_only:
            if impl is not None:                       # only to find where each interface routine is implemented
                self.collect(self.decl_items(impl), Scope({}), link_table=self.iface_table)
            return
        self.node_scopes.append((iface, ifs))
        self.resolve_decls(items, ifs)
        if impl is None:
            return
        mu = self.uses_scope(next((x for x in impl.kids if isinstance(x, Node) and x.kind == 'UsesClause'), None), iu)
        ifs2 = Scope(table=self.iface_table, parent=mu)
        ims = Scope({}, parent=ifs2)
        self.node_scopes.append((impl, ims))
        mitems = self.decl_items(impl)
        self.collect(mitems, ims, link_table=self.iface_table)
        self.resolve_decls(mitems, ims)
        self.bind_bodies(mitems, ims)
        init = next((x for x in u.kids if isinstance(x, Node) and x.kind == 'InitSection'), None)
        if init is not None:
            for x in init.kids:
                if isinstance(x, Node) and x.kind == 'Compound':
                    self.resolve_stmt(x, ims, [])

    def run_program(self, p: Node):
        sys_scope = self.system_scope()
        uses = next((x for x in p.kids if isinstance(x, Node) and x.kind == 'UsesClause'), None)
        us = self.uses_scope(uses, sys_scope)
        scope = Scope({}, parent=us)
        self.node_scopes.append((p, scope))
        block = next((x for x in p.kids if isinstance(x, Node) and x.kind == 'Block'), None)
        if block is None:
            return
        items = [x for x in block.kids if isinstance(x, Node) and x.kind not in ('Compound', 'Asm')]
        self.collect(items, scope)
        self.resolve_decls(items, scope)
        self.bind_bodies(items, scope)
        for x in block.kids:
            if isinstance(x, Node) and x.kind == 'Compound':
                self.resolve_stmt(x, scope, [])


# ---------------------------------------------------------------------------------------------------
class Report:
    def __init__(self, binder: Binder):
        self.renamed = binder.renamed
        self.unresolved = binder.unresolved
        self.uncertain = binder.uncertain
        self.missing_units = binder.missing_units


def normalize_case(res: Result, provider: Optional[Provider] = None) -> Report:
    """Rewrite token texts in place (case only, so offsets stay valid).  Inactive branches are untouched."""
    for t in res.sig:
        if t.kind == 'KW':
            t.text = t.text.lower()
    for n in res.tree.walk():
        if n.kind == 'Directives':
            for t in n.kids:
                if isinstance(t, Token) and t.kind == 'IDENT' and t.text.lower() in ROUTINE_DIRECTIVES:
                    t.text = t.text.lower()
        elif n.kind in ('Absolute', 'Section') and n.kids and isinstance(n.kids[0], Token):
            n.kids[0].text = n.kids[0].text.lower()
    b = Binder(res, provider)
    b.run()
    return Report(b)


def main(argv):
    if len(argv) < 2:
        print('usage: tp7sema.py FILE.PAS [--path DIR]... [--tpl TURBO.TPL]   (prints renamed/unresolved identifiers)')
        return 1
    dirs = [argv[i + 1] for i, a in enumerate(argv) if a == '--path']
    tpl = argv[argv.index('--tpl') + 1] if '--tpl' in argv else None
    with open(argv[1], 'rb') as f:
        src = f.read().decode('cp866')
    res = parse(src)
    before = [t.text for t in res.sig]
    rep = normalize_case(res, Provider(dirs or [os.path.dirname(os.path.abspath(argv[1]))], tpl))
    print('renamed %d identifiers; unresolved %d; uncertain %d; units not found: %s' % (
        rep.renamed, len(rep.unresolved), len(rep.uncertain), ', '.join(sorted({t.text for t in rep.missing_units})) or '-'))
    seen = sorted({t.text.lower() for t in rep.unresolved})
    print('unresolved names:', ' '.join(seen[:80]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
