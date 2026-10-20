#!/usr/bin/env python3
"""
tp7stub.py - readable interface stubs for units that exist only as a TPU / TURBO.TPL (System, Crt, Dos, Graph, ...).

A stub is a generated Pascal text: `unit Crt; interface ... implementation end.` with every constant, type (records with
their fields, enumerations with their members), variable and routine of the unit.  The language server writes it to a
file and lets "go to definition" jump there, so a name from the standard library has a place to go to.

What a TPU does NOT contain, and what the stub therefore cannot show:
  * names of parameters, unless the unit was compiled with debug information ({$D+,L+}, the default); without it
    P1, P2, ... are placeholders (the types and var / value kinds are real)
  * the text of the units, bodies, comments, the original constant expressions (constants are shown as their values)
  * variant parts of records (the fields are listed flat, in declaration order)
  * the signature of procedural types and the element type of sets
  * the built-in procedures and functions of System (WriteLn, Inc, Copy, ...) have no declaration at all, the
    compiler knows them; the signatures printed for them come from the Turbo Pascal 7 manual and are informal

render(unit) -> Stub; Stub.find(kind, name, owner=None) -> (line, column, length) of the declaring identifier, 0-based.
Index keys: ('unit',) ('const'|'type'|'var'|'routine'|'builtin', name) ('field', type name, field name), names lower case.
"""
import re
import sys
from typing import Dict, List, Optional, Tuple

from tpu_dump import Loader, Unit

STUB_VERSION = 2                     # bump when the layout changes: stored stubs are rewritten
WIDTH = 100                          # enumerations and parameter lists are wrapped beyond this
EOL = '\r\n'

# informal signatures of the built-in procedures and functions of System (Turbo Pascal 7 Programmer's Reference)
BUILTIN_SIGS = {
    'Abs': 'function Abs(X: integer or real type): same type',
    'Addr': 'function Addr(var X): Pointer',
    'Append': 'procedure Append(var F: Text)',
    'ArcTan': 'function ArcTan(X: Real): Real',
    'Assign': 'procedure Assign(var F; Name: string)',
    'Assigned': 'function Assigned(P: Pointer): Boolean',
    'BlockRead': 'procedure BlockRead(var F: file; var Buf; Count: Word [; var Result: Word])',
    'BlockWrite': 'procedure BlockWrite(var F: file; var Buf; Count: Word [; var Result: Word])',
    'Break': 'procedure Break',
    'ChDir': 'procedure ChDir(S: string)',
    'Chr': 'function Chr(X: Byte): Char',
    'Close': 'procedure Close(var F)',
    'Concat': 'function Concat(S1, S2 [, ..., Sn]: string): string',
    'Continue': 'procedure Continue',
    'Copy': 'function Copy(S: string; Index, Count: Integer): string',
    'Cos': 'function Cos(X: Real): Real',
    'CSeg': 'function CSeg: Word',
    'Dec': 'procedure Dec(var X: ordinal type [; N: Longint])',
    'Delete': 'procedure Delete(var S: string; Index, Count: Integer)',
    'Dispose': 'procedure Dispose(var P: pointer [, Destructor(...)])',
    'DSeg': 'function DSeg: Word',
    'Eof': 'function Eof([var F]): Boolean',
    'Eoln': 'function Eoln([var F: Text]): Boolean',
    'Erase': 'procedure Erase(var F)',
    'Exclude': 'procedure Exclude(var S: set; E: element)',
    'Exit': 'procedure Exit',
    'Exp': 'function Exp(X: Real): Real',
    'Fail': 'procedure Fail',
    'FilePos': 'function FilePos(var F): Longint',
    'FileSize': 'function FileSize(var F): Longint',
    'FillChar': 'procedure FillChar(var X; Count: Word; Value: Byte or Char)',
    'Flush': 'procedure Flush(var F: Text)',
    'Frac': 'function Frac(X: Real): Real',
    'FreeMem': 'procedure FreeMem(var P: Pointer; Size: Word)',
    'GetDir': 'procedure GetDir(D: Byte; var S: string)',
    'GetMem': 'procedure GetMem(var P: Pointer; Size: Word)',
    'Halt': 'procedure Halt([Code: Word])',
    'Hi': 'function Hi(X: Integer or Word): Byte',
    'High': 'function High(X: ordinal type or array): ordinal value',
    'Inc': 'procedure Inc(var X: ordinal type [; N: Longint])',
    'Include': 'procedure Include(var S: set; E: element)',
    'Insert': 'procedure Insert(Source: string; var S: string; Index: Integer)',
    'Int': 'function Int(X: Real): Real',
    'IOResult': 'function IOResult: Word',
    'Length': 'function Length(S: string): Integer',
    'Ln': 'function Ln(X: Real): Real',
    'Lo': 'function Lo(X: Integer or Word): Byte',
    'Low': 'function Low(X: ordinal type or array): ordinal value',
    'Mark': 'procedure Mark(var P: Pointer)',
    'MaxAvail': 'function MaxAvail: Longint',
    'Mem': 'Mem: array of Byte           { Mem[Segment:Offset] }',
    'MemAvail': 'function MemAvail: Longint',
    'MemL': 'MemL: array of Longint        { MemL[Segment:Offset] }',
    'MemW': 'MemW: array of Word           { MemW[Segment:Offset] }',
    'MkDir': 'procedure MkDir(S: string)',
    'Move': 'procedure Move(var Source, Dest; Count: Word)',
    'New': 'procedure New(var P: pointer [, Constructor(...)])',
    'Odd': 'function Odd(X: Longint): Boolean',
    'Ofs': 'function Ofs(var X): Word',
    'Ord': 'function Ord(X: ordinal type): Longint',
    'ParamCount': 'function ParamCount: Word',
    'ParamStr': 'function ParamStr(Index: Word): string',
    'Pi': 'function Pi: Real',
    'Port': 'Port: array of Byte           { Port[Number] }',
    'PortW': 'PortW: array of Word          { PortW[Number] }',
    'Pos': 'function Pos(Substr, S: string): Byte',
    'Pred': 'function Pred(X: ordinal type): same type',
    'Ptr': 'function Ptr(Seg, Ofs: Word): Pointer',
    'Random': 'function Random[(Range: Word)]: Word or Real',
    'Randomize': 'procedure Randomize',
    'Read': 'procedure Read([var F: Text;] V1 [, V2, ..., Vn])',
    'ReadLn': 'procedure ReadLn([var F: Text;] [V1 [, V2, ..., Vn]])',
    'Release': 'procedure Release(var P: Pointer)',
    'Rename': 'procedure Rename(var F; NewName: string)',
    'Reset': 'procedure Reset(var F [; RecSize: Word])',
    'Rewrite': 'procedure Rewrite(var F [; RecSize: Word])',
    'RmDir': 'procedure RmDir(S: string)',
    'Round': 'function Round(X: Real): Longint',
    'RunError': 'procedure RunError([Code: Word])',
    'Seek': 'procedure Seek(var F; N: Longint)',
    'SeekEof': 'function SeekEof([var F: Text]): Boolean',
    'SeekEoln': 'function SeekEoln([var F: Text]): Boolean',
    'Seg': 'function Seg(var X): Word',
    'SetTextBuf': 'procedure SetTextBuf(var F: Text; var Buf [; Size: Word])',
    'Sin': 'function Sin(X: Real): Real',
    'SizeOf': 'function SizeOf(X): Word',
    'SPtr': 'function SPtr: Word',
    'Sqr': 'function Sqr(X: integer or real type): same type',
    'Sqrt': 'function Sqrt(X: Real): Real',
    'SSeg': 'function SSeg: Word',
    'Str': 'procedure Str(X [: Width [: Decimals]]; var S: string)',
    'Succ': 'function Succ(X: ordinal type): same type',
    'Swap': 'function Swap(X: Integer or Word): same type',
    'Trunc': 'function Trunc(X: Real): Longint',
    'Truncate': 'procedure Truncate(var F)',
    'TypeOf': 'function TypeOf(X: object type): Pointer',
    'UpCase': 'function UpCase(Ch: Char): Char',
    'Val': 'procedure Val(S: string; var V; var Code: Integer)',
    'Write': 'procedure Write([var F: Text;] P1 [, P2, ..., Pn])',
    'WriteLn': 'procedure WriteLn([var F: Text;] [P1 [, P2, ..., Pn]])',
}
BUILTIN_SIGS = {k.lower(): v for k, v in BUILTIN_SIGS.items()}


class Stub:
    """Text of a stub and where every name is declared in it."""

    def __init__(self, unit_name: str, lines: List[str], index: Dict[tuple, Tuple[int, int, int]]):
        self.unit_name = unit_name
        self.lines = lines
        self.index = index
        self.text = EOL.join(lines) + EOL

    def find(self, kind: str, name: str, owner: Optional[str] = None) -> Optional[Tuple[int, int, int]]:
        if kind == 'unit':
            return self.index.get(('unit',))
        if kind == 'field':
            return self.index.get(('field', (owner or '').lower(), name.lower()))
        if kind == 'routine' and owner:                          # a method of an object
            return self.index.get(('method', owner.lower(), name.lower()))
        return self.index.get((kind, name.lower()))

    def block(self, kind: str, name: str, owner: Optional[str] = None) -> Optional[List[str]]:
        """The lines of a declaration: one line, or for a record type everything up to its `end;`."""
        pos = self.find(kind, name, owner)
        if pos is None:
            return None
        out = [self.lines[pos[0]]]
        if kind == 'type' and re.search(r'= (record|object(\(\w+\))?)$', out[0].rstrip()):
            for ln in self.lines[pos[0] + 1:]:
                out.append(ln)
                if ln.strip() == 'end;':
                    break
        return out

    def declaration(self, kind: str, name: str, owner: Optional[str] = None) -> Optional[str]:
        """The line (or, for a record type, its first line) that declares the name, without the trailing comment."""
        pos = self.find(kind, name, owner)
        if pos is None:
            return None
        text = self.lines[pos[0]].strip()
        text = re.sub(r'\s*\{[^{}]*\}\s*$', '', text)
        return text


class _Writer:
    def __init__(self):
        self.lines: List[str] = []
        self.index: Dict[tuple, Tuple[int, int, int]] = {}

    def line(self, text: str = '', *marks):
        """marks: (key, column, length) of the names declared on this line."""
        n = len(self.lines)
        self.lines.append(text)
        for key, col, ln in marks:
            self.index.setdefault(key, (n, col, ln))

    def wrapped(self, head: str, items: List[Tuple[str, Optional[tuple]]], tail: str, indent: str = '    '):
        """head + comma separated items + tail, wrapped at WIDTH; items are (text, index key or None)."""
        cur, marks = head, []
        for i, (text, key) in enumerate(items):
            piece = text + (', ' if i < len(items) - 1 else '')
            if len(cur) + len(piece.rstrip()) > WIDTH and cur.strip() and cur != head:
                self.line(cur.rstrip(), *marks)
                cur, marks = indent, []
            if key is not None:
                marks.append((key, len(cur), len(text)))
            cur += piece
        self.line(cur + tail, *marks)


def _type_text(t: str) -> str:
    """Spelling of a type as the dump prints it -> as it is written in a declaration."""
    t = re.sub(r'\barray\[', 'array [', t)
    t = re.sub(r'\?(\w+)@0x[0-9a-f]+', r'\1.?', t)               # a type of a unit that is not available
    t = t.replace('?other', 'procedure')
    return t


def _param_groups(params) -> List[str]:
    """['var P1, P2: Integer', 'P3: string'] - neighbours of the same kind and type share a declaration."""
    out, run = [], []
    for i, p in enumerate(params, 1):
        untyped = p.kind == 'var' and p.type == 'file' and not p.open
        key = (p.kind, p.open, None if untyped else _type_text(p.type))
        name = p.name or 'P%d' % i
        if run and run[-1][0] == key:
            run[-1][1].append(name)
        else:
            run.append((key, [name]))
    for (kind, opn, typ), names in run:
        text = ', '.join(names)
        if typ is not None:
            text += ': ' + ('array of ' if opn else '') + typ
        out.append({'var': 'var ', 'const': 'const '}.get(kind, '') + text)
    return out


def render(u: Unit, origin: Optional[str] = None) -> Stub:
    w = _Writer()
    w.line('{ tp7ls stub (version %d): the interface of unit %s.' % (STUB_VERSION, u.name))
    w.line('  Generated from %s.' % (origin or 'a TPU file'))
    w.line('  There is no source for this unit. Generated files are read only: changes are lost.')
    w.line('  A TPU stores no bodies, comments or constant expressions; parameter names only with debug info')
    w.line('  (otherwise P1, P2, ... stand in), so only declarations and their types are shown. }')
    w.line('unit %s;' % u.name, (('unit',), len('unit '), len(u.name)))
    w.line()
    w.line('interface')
    w.line()
    uses = [x for x in u.used if x.lower() not in (u.name.lower(), 'system')]          # System is always there
    if uses:
        w.line('uses')
        w.line('  ' + ', '.join(uses) + ';')
        w.line()

    syms = u.symbols
    types = [s for s in syms if s.kind == 'type']
    members_of: Dict[str, list] = {}                     # type name -> constants that belong to it (enumerations, Boolean)
    for t in types:
        if t.shape == 'enum' and t.members:
            members_of[t.name] = [c for c in syms if c.kind == 'const' and c.name in t.members]
    for c in (x for x in syms if x.kind == 'const'):     # False / True: constants whose type is a primitive of this unit
        td = c.tdesc or {}
        owner = next((t for t in types if t.name == td.get('named') and td.get('unit') == u.name
                      and t.shape == 'primitive'), None)
        if owner is not None:
            members_of.setdefault(owner.name, []).append(c)
    member_names = {c.name for cs in members_of.values() for c in cs}
    consts = [s for s in syms if s.kind == 'const' and s.name not in member_names]
    typed = [s for s in syms if s.kind == 'var' and s.typed_const]
    vars_ = [s for s in syms if s.kind == 'var' and not s.typed_const]
    routines = [s for s in syms if s.kind == 'routine']
    builtins = [s for s in syms if s.kind == 'builtin' and s.tag not in 'YZ']
    arrays = [s for s in syms if s.kind == 'builtin' and s.tag in 'YZ']      # Mem, MemW, MemL, Port, PortW: variables

    if consts or typed:
        w.line('const')
        for c in consts:
            td = c.tdesc or {}
            shown = c.display if c.display is not None else c.value
            extra = '' if td.get('named') in (None, 'Longint', 'string') or c.display is not None \
                else '  { %s }' % td.get('named')
            w.line('  %s = %s;%s' % (c.name, shown, extra), (('const', c.name.lower()), 2, len(c.name)))
        for v in typed:                                   # typed constants are variables with a start value in the TPU
            mark = (('var', v.name.lower()), 2, len(v.name))
            if v.init is not None:
                w.line('  %s: %s = %s;' % (v.name, _type_text(v.type or '?'), v.init), mark)
            else:
                w.line('  %s: %s;  { typed constant: the value is not decoded }' % (v.name, _type_text(v.type or '?')), mark)
        w.line()
    if types:
        w.line('type')
        for t in types:
            _type(w, u, t, sorted(members_of.get(t.name, []), key=lambda c: (c.value is None, c.value or 0)))
        w.line()
    if vars_ or arrays:
        w.line('var')
        for v in vars_:
            ab = ' absolute $%04X:$%04X' % v.absolute if v.absolute else ''
            w.line('  %s: %s%s;' % (v.name, _type_text(v.type or '?'), ab), (('var', v.name.lower()), 2, len(v.name)))
        for b in arrays:                                  # built-in arrays: `Mem: array of Byte;  { Mem[Segment:Offset] }`
            sig, _, note = BUILTIN_SIGS.get(b.name.lower(), b.name + ': array').partition('{')
            w.line('  %s;%s' % (sig.rstrip(), '  {' + note if note else ''), (('builtin', b.name.lower()), 2, len(b.name)))
        w.line()
    for r in routines:
        _routine(w, r)
    if routines:
        w.line()
    if builtins:
        w.line('{ Built-in procedures and functions: the compiler knows them, they have no declaration.')
        w.line('  The signatures below are informal (taken from the Turbo Pascal 7 manual). }')
        for b in builtins:
            sig = BUILTIN_SIGS.get(b.name.lower())
            if sig is None:
                sig = '%s %s' % ('function' if b.tag == 'W' else 'procedure', b.name)
            sig, _, note = sig.partition('{')                 # `Mem: array of Byte  { Mem[Segment:Offset] }`
            sig = sig.rstrip()
            m = re.search(r'\b%s\b' % re.escape(b.name), sig)
            w.line(sig + ';' + ('  {' + note if note else ''), (('builtin', b.name.lower()), m.start() if m else 0, len(b.name)))
        w.line()
    w.line('implementation')
    w.line()
    w.line('end.')
    return Stub(u.name, w.lines, w.index)


def _type(w: _Writer, u: Unit, t, members: list):
    key = ('type', t.name.lower())
    head = '  %s = ' % t.name
    mark = (key, 2, len(t.name))
    if t.shape in ('record', 'object'):
        anc = ''
        if t.shape == 'object':
            a = (t.ancestor or {}).get('named')
            anc = '(%s)' % a if a else ''
        w.line(head + t.shape + anc, mark)
        members = [('f', f) for f in t.fields or []] + [('m', m) for m in t.methods or []]
        members.sort(key=lambda x: x[1].get('seq', 0))                  # the order of the declaration
        private = False
        for what, x in members:
            if t.shape == 'object' and bool(x.get('private')) != private:
                private = bool(x.get('private'))
                w.line('  private' if private else '  public')
            if what == 'f':
                w.line('    %s: %s;  { @%d }' % (x['name'], _type_text(x['type']), x['offset']),
                       (('field', t.name.lower(), x['name'].lower()), 4, len(x['name'])))
            else:
                _method(w, t, x)
        w.line('  end;')
        return
    if members:                                          # enumeration, or Boolean-like
        items = [(c.name, ('const', c.name.lower())) for c in members]
        first = len(w.lines)
        w.wrapped(head + '(', items, ');' + ('' if t.shape == 'enum' else '  { built-in, size %s }' % t.size))
        w.index.setdefault(key, (first, 2, len(t.name)))
        return
    if t.shape == 'openstring':
        w.line(head + 'string;  { open string parameter type }', mark)
    elif t.shape == 'primitive':
        w.line(head + '%s;  { built-in, size %s }' % (t.name, t.size), mark)
    elif t.definition:
        d = _type_text(t.definition)
        if d == '^file':                                 # the untyped pointer: System's Pointer
            w.line(head + 'Pointer;  { built-in untyped pointer, size %s }' % t.size, mark)
        else:
            w.line(head + d + ';', mark)
    elif t.size == 4:
        w.line(head + 'procedure;  { procedural type: its signature is not decoded }', mark)
    else:
        w.line(head + '...;  { size %s: the kind of this type is not decoded }' % t.size, mark)


def _method(w: _Writer, t, m: dict):
    from tpu_dump import Loader
    groups = _param_groups(m['params'])
    res = m.get('result')
    result = ': ' + _type_text(Loader.tstr(res, False)) if res else ''
    head = '    %s ' % m['kind']
    text = head + m['name'] + ('(' + '; '.join(groups) + ')' if groups else '') + result + ';'
    if m.get('virtual'):
        text += ' virtual;'
    w.line(text, (('method', t.name.lower(), m['name'].lower()), len(head), len(m['name'])))


def _routine(w: _Writer, r):
    kw = 'function' if r.type else 'procedure'
    head = '%s ' % kw
    groups = _param_groups(r.params or [])
    result = ': ' + _type_text(r.type) if r.type else ''
    tail = {'interrupt': ' interrupt;', 'inline': '  { inline }'}.get(r.directive, '')
    one = head + r.name + ('(' + '; '.join(groups) + ')' if groups else '') + result + ';' + tail
    mark = (('routine', r.name.lower()), len(head), len(r.name))
    if len(one) <= WIDTH or len(groups) < 2:
        w.line(one, mark)
        return
    w.line(head + r.name + '(', mark)
    for i, g in enumerate(groups):
        w.line('    ' + g + (';' if i < len(groups) - 1 else ')' + result + ';' + tail))



def default_dir() -> str:
    """Where generated stubs go when nothing is configured: the user's cache directory."""
    import os
    import tempfile
    if os.name == 'nt':
        base = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~')
    else:
        base = os.environ.get('XDG_CACHE_HOME') or os.path.join(os.path.expanduser('~'), '.cache')
    path = os.path.join(base, 'tp7ls', 'stubs')
    try:
        os.makedirs(path, exist_ok=True)
        return path
    except OSError:
        return os.path.join(tempfile.gettempdir(), 'tp7ls-stubs')


class StubStore:
    """Writes the stubs of TPU units to files (one directory per source file, NAME.pas inside) and remembers them.
    The files are read only and are rewritten when the generated text differs from what is on disk."""

    def __init__(self, root: str):
        import os
        self.root = os.path.abspath(root)
        self._cache: Dict[tuple, Optional[tuple]] = {}

    def is_stub(self, path: Optional[str]) -> bool:
        import os
        if not path:
            return False
        a, r = os.path.normcase(os.path.abspath(path)), os.path.normcase(self.root)
        return a == r or a.startswith(r + os.sep)

    def get(self, info) -> Optional[tuple]:
        """(path of the stub file, Stub) for a UnitInfo that was decoded from a TPU / the library; None for sources."""
        import hashlib
        import os
        u = getattr(info, 'tpu', None)
        if u is None:
            return None
        origin = getattr(info, 'origin', None) or ''
        key = (os.path.normcase(os.path.abspath(origin)) if origin else '', u.name.lower())
        if key in self._cache:
            return self._cache[key]
        got = None
        try:
            stub = render(u, os.path.abspath(origin) if origin else None)
            folder = os.path.join(self.root, hashlib.sha1(key[0].encode('utf-8', 'replace')).hexdigest()[:8])
            path = os.path.join(folder, u.name + '.pas')
            data = stub.text.encode('cp866', 'replace')
            try:
                with open(path, 'rb') as f:
                    same = f.read() == data
            except OSError:
                same = False
            if not same:
                os.makedirs(folder, exist_ok=True)
                if os.path.exists(path):
                    os.chmod(path, 0o666)
                with open(path, 'wb') as f:
                    f.write(data)
                os.chmod(path, 0o444)
            got = (path, stub)
        except OSError:
            got = None
        self._cache[key] = got
        return got


def main(argv):
    import os
    from tpu_dump import split_images
    if len(argv) < 2:
        print('usage: tp7stub.py FILE.TPU|FILE.TPL [UNIT] [--lib LIB.TPL]   (prints the stub of the unit, or of all of them)')
        return 1
    path = argv[1]
    lib = argv[argv.index('--lib') + 1] if '--lib' in argv else None
    if lib is None:
        cand = os.path.join(os.path.dirname(os.path.abspath(path)), 'TURBO.TPL')
        lib = cand if os.path.exists(cand) and os.path.abspath(cand) != os.path.abspath(path) else None
    imgs = split_images(open(path, 'rb').read())
    n = len(imgs)
    if lib:
        imgs += split_images(open(lib, 'rb').read())
    from tp7sema import Provider
    prov = Provider(dirs=[os.path.dirname(os.path.abspath(path))])
    prov.lib_images = split_images(open(lib, 'rb').read()) if lib else []
    imgs += prov._tpu_dependencies(imgs, os.path.dirname(os.path.abspath(path)))
    ld = Loader(imgs, primary=n)
    only = next((a.lower() for a in argv[2:] if not a.startswith('--') and a != lib), None)
    for k in ld.primary:
        if only in (None, k):
            sys.stdout.write(render(ld.units[k], os.path.abspath(path)).text)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
