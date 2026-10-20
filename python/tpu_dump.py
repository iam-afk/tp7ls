#!/usr/bin/env python3
"""
tpu_dump.py - prototype extractor of interface symbols from Turbo Pascal 7 .TPU / .TPL files.

Scope (deliberately limited): the non-OOP subset. `object` types are not decoded.
Goal: recover the *declared spelling* of every interface identifier (and record
field), plus enough type information to resolve `Var.Field` chains.

Format knowledge below was reverse-engineered from TURBO.TPL, GRAPH.TPU and
POLSK.TPU (+ POLSK.PAS). It is NOT an official specification. Every rule marked
[verified] was checked against those samples, [guess] was not.

File layout (little-endian):
  unit image := 'TPUQ' + 92 header bytes (header is 0x60 bytes in total)
  image+96   : interface hash table: word SIZE, then SIZE/2+1 word slots   [verified]
               each slot = absolute (image-relative) offset of first record
               in a chain, or 0
  record     := next:word  tag:byte  len:byte  name[len]  body...          [verified]
               `next` = next record of the same hash chain (0 = end)
  A .TPL file is simply several unit images one after another, each
  starting with 'TPUQ' (offsets inside an image are image-relative).      [verified]

Record tags seen in interface tables:
  S unit reference (first S = the unit itself)   R routine     Q variable
  P type                                         O constant    U label (impl. only)
  System only: V builtin procedure, W builtin function, X New, Y Port/PortW, Z Mem*,
               '[' OpenString
Type reference := (descriptor offset: word, unit id: word)
  descriptor offset of a named type = first word of the body of its P record [verified]
  unit id = image offset of the body of the S record naming that unit [verified]
"""
import json
import struct
import sys
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional

SIG = b'TPUQ'
ENC = 'cp866'

# anonymous System types that are not P records (observed through usage) [verified by usage]
SYSTEM_ANON = {0xba: 'string', 0x82: 'file', 0x8a: 'file'}

PARAM_KIND = {0x02: 'value', 0x06: 'var', 0x42: 'const'}      # [verified on Dos, POLSK, SAMPLES]
# the kind byte of a parameter: 0x02 value, 0x06 var, 0x42 const; | 0xa0 for an open array (0xa2 / 0xa6 / 0xe2) [SAMPLES]

# sizes of the System types a typed constant or a set can be made of: name -> (bytes, signed)
SCALAR = {'Byte': (1, False), 'Shortint': (1, True), 'Integer': (2, True), 'Word': (2, False), 'Longint': (4, True),
          'Char': (1, False), 'Boolean': (1, False), 'Bytebool': (1, False), 'Wordbool': (2, False),
          'Longbool': (4, False), 'Comp': (8, True)}
REALS = {'Real': 6, 'Single': 4, 'Double': 8, 'Extended': 10}
BOOLS = ('Boolean', 'Bytebool', 'Wordbool', 'Longbool')


def real_text(raw: bytes, name: str) -> str:
    """Pascal spelling of a floating point constant stored as `name` (Real 6 bytes, Single 4, Double 8, Extended 10)."""
    import math
    if name == 'Extended':
        mant, se = int.from_bytes(raw[:8], 'little'), int.from_bytes(raw[8:10], 'little')
        v = math.ldexp(mant, (se & 0x7fff) - 16383 - 63) if mant else 0.0
        v = -v if se & 0x8000 else v
    elif name == 'Double':
        v = struct.unpack('<d', raw[:8])[0]
    elif name == 'Single':
        v = struct.unpack('<f', raw[:4])[0]
    else:                                             # the 6-byte Real: exponent, then 39 bits of mantissa and the sign
        e = raw[0]
        m = int.from_bytes(raw[1:6], 'little')
        v = 0.0 if e == 0 else (1 + (m & (2 ** 39 - 1)) / 2 ** 39) * 2.0 ** (e - 129)
        v = -v if m >> 39 & 1 else v
    s = '%.15g' % v
    if 'e' in s:
        m, e = s.split('e')
        return '%sE%d' % (m, int(e))
    return s if '.' in s else s + '.0'


def char_text(code: int) -> str:
    """'A', #13, 'Ж' for a character code."""
    return pas_literal(bytes([code & 255]).decode(ENC, 'replace'))


def set_text(bits: bytes, base_names, lo_hint: int = 0) -> str:
    """[1, 3, 5..7] / ['0'..'9'] / [clRed, clBlue] for the bitmap of a set constant.  base_names: a list of the names
    of an enumeration, 'Char', or None (numbers)."""
    on = [i for i in range(len(bits) * 8) if bits[i // 8] >> (i % 8) & 1]
    def one(i):
        if isinstance(base_names, list):
            return base_names[i] if i < len(base_names) else str(i)
        return char_text(i) if base_names == 'Char' else str(i)
    out, i = [], 0
    while i < len(on):
        j = i
        while j + 1 < len(on) and on[j + 1] == on[j] + 1:
            j += 1
        if j - i >= 2:
            out.append('%s..%s' % (one(on[i]), one(on[j])))
        else:
            out.extend(one(on[k]) for k in range(i, j + 1))
        i = j + 1
    return '[%s]' % ', '.join(out)


def pas_literal(text: str) -> str:
    """Pascal spelling of a string constant: 'abc', #1#1#2, 'it''s'#13#10 ..."""
    out, run = [], ''
    for ch in text:
        if ord(ch) < 32 or ord(ch) == 127:
            if run:
                out.append("'%s'" % run.replace("'", "''"))
                run = ''
            out.append('#%d' % ord(ch))
        else:
            run += ch
    if run or not out:
        out.append("'%s'" % run.replace("'", "''"))
    return ''.join(out)


@dataclass
class Param:
    kind: str
    type: str
    name: Optional[str] = None      # only when the unit was compiled with debug information (see Loader._param_names)
    open: bool = False              # an open array parameter: `type` is the type of the elements
    tdesc: Optional[dict] = None    # structured type of the parameter (see Loader.tdesc)


@dataclass
class Sym:
    kind: str                  # unit|const|type|var|routine|builtin
    name: str                  # declared spelling
    tag: str
    offset: int
    type: Optional[str] = None            # var / const / function result
    params: Optional[List[Param]] = None  # routine
    fields: Optional[List[dict]] = None   # record type: [{name,type,offset}]
    value: Optional[object] = None        # integer const, or the Pascal text of a string const
    size: Optional[int] = None            # type size in bytes
    shape: Optional[str] = None           # record|array|string|pointer|enum|subrange|alias|...
    definition: Optional[str] = None      # right-hand side of a type declaration, as text
    members: Optional[List[str]] = None   # enumeration members (from the constants of that type)
    methods: Optional[List[dict]] = None  # object type: own methods (see Loader._members)
    ancestor: Optional[dict] = None       # object type: tdesc of the ancestor (a named type), None for a root object
    tdesc: Optional[dict] = None          # structured type of a var/const/result (see Loader.tdesc)
    note: Optional[str] = None
    display: Optional[str] = None         # const: its value spelled as in a declaration (set, real, char, enum member...)
    typed_const: bool = False             # a `var` record of a typed constant (`const X: Integer = 5`)
    init: Optional[str] = None            # typed constant: the initial value, as text
    absolute: Optional[tuple] = None      # var declared `absolute Seg:Ofs`: (segment, offset)
    directive: Optional[str] = None       # routine: 'interrupt' or 'inline'


@dataclass
class Unit:
    name: str
    used: List[str]
    symbols: List[Sym] = field(default_factory=list)


class Image:
    def __init__(self, data: bytes):
        if data[:4] != SIG:
            raise ValueError('not a TPU image')
        self.d = data

    def w(self, o):
        return struct.unpack_from('<H', self.d, o)[0]

    def records(self) -> Dict[int, dict]:
        d, w = self.d, self.w
        size = w(96)
        if size % 2 or size > 0x400:
            raise ValueError('unexpected hash table size %#x' % size)
        recs = {}
        for i in range(size // 2 + 1):
            o = w(98 + 2 * i)
            while o and o not in recs:
                ln = d[o + 3]
                recs[o] = dict(tag=chr(d[o + 2]), name=d[o + 4:o + 4 + ln].decode(ENC),
                               next=w(o), body=o + 4 + ln, off=o)
                o = w(o)
        return recs


def split_images(blob: bytes) -> List[Image]:
    """A .TPU holds one image, a .TPL several."""
    offs, i = [], 0
    while True:
        i = blob.find(SIG, i)
        if i < 0:
            break
        offs.append(i)
        i += 4
    offs.append(len(blob))
    out = []
    for a, b in zip(offs, offs[1:]):
        try:
            im = Image(blob[a:b])
            im.records()                # sanity check; skips false 'TPUQ' hits
            out.append(im)
        except Exception:
            pass
    return out


class Loader:
    """Decodes images; resolves cross-unit type references by name.

    Type descriptor (found at the offset of a type reference), low byte of the first word = kind
    [verified on System, Dos, Graph, TEST.TPU]:
      0x01 array    : kind:2 size:2 ?:4 elem-ref:4 index-ref:4
      0x02 record   : kind:2 size:2 ?:4 ?:2 first-field:2 ...
                      field := next:2 'Q' len name  8  offset:2  owner:2  next-field:2  type-ref:4
                      fields are chained by next-field (variant parts are simply continued)
      0x08 pointer  : kind:2 size:2 ?:4 target-ref:4
      0x09 string   : kind:2 size:2 ?:4 char-ref:4 index-ref:4        (size = max length + 1)
      0x0c subrange : kind:2 size:2 ?:4 low:int32 high:int32 host-ref:4  (also Byte/Word/Integer/... in System)
      0x0d boolean-like, 0x0e char-like, 0x0f enumeration, 0x05 text/file, 0x0a/0x0b reals
    """

    def __init__(self, images: List[Image], primary: Optional[int] = None):
        """`images[:primary]` are the files being dumped, the rest are only used to
        resolve references (typically System from TURBO.TPL)."""
        self.primary: List[str] = []
        self.units: Dict[str, Unit] = {}
        self._img: Dict[str, Image] = {}
        self._recs: Dict[str, dict] = {}
        self._tmap: Dict[str, Dict[int, str]] = {}
        self._ids: Dict[str, Dict[int, str]] = {}
        self._enum_lists: Dict[tuple, list] = {}
        self._enum_named: Dict[tuple, list] = {}       # (unit key, enumeration type name) -> member names
        for n_im, im in enumerate(images):
            recs = im.records()
            s = sorted((r for r in recs.values() if r['tag'] == 'S'), key=lambda r: r['off'])
            name = s[0]['name'] if s else 'System'
            if primary is None or n_im < primary:
                self.primary.append(name.lower())
            self._img[name.lower()] = im
            self._recs[name.lower()] = recs
            self._tmap[name.lower()] = {im.w(r['body']): r['name'] for r in recs.values()
                                        if r['tag'] in 'P['}
            self._ids[name.lower()] = {r['body']: r['name'] for r in s}   # see _unit_ids note
        for key in self._img:
            self.units[key] = self._decode(key)

    # [verified on System, Dos, POLSK, Graph, TEST.TPU (6 used units)]
    # a unit id inside a type reference is the image offset of the *body* of the S record
    # that names the unit (offset + 4 + len(name)): 0xe9 for 'Dos' at 226 in Dos, 0xea for
    # 'test' in TEST.TPU, 0xfc for the 'System' record at 242, 0x7f2 for System itself.

    # -- structured types -------------------------------------------------
    def tdesc(self, unit: str, ofs: int, uid: int, depth: int = 0, named: bool = True) -> dict:
        """Structured description of a type reference.
        {'named': 'Word', 'unit': 'System'} | {'kind': 'array', 'index': T, 'elem': T} |
        {'kind': 'record', 'size': n, 'fields': [{'name','offset','type': T}]} |
        {'kind': 'pointer', 'to': T} | {'kind': 'string', 'max': n} | {'kind': 'subrange', 'lo','hi'} |
        {'kind': 'enum'} | {'kind': 'other', 'code': k} | {'unresolved': unit-name, 'ofs': n}"""
        uname = self._ids[unit].get(uid)
        if uname is None:
            return {'unresolved': '?', 'ofs': ofs}
        key = uname.lower()
        if key == 'system' and ofs in SYSTEM_ANON:
            return {'named': SYSTEM_ANON[ofs], 'unit': 'System'}
        if key not in self._img:
            return {'unresolved': uname, 'ofs': ofs}
        if named and ofs in self._tmap[key]:
            return {'named': self._tmap[key][ofs], 'unit': uname}
        if depth > 8:
            return {'kind': 'other', 'code': 'too deep'}
        im = self._img[key]
        k, size = im.d[ofs], im.w(ofs + 2)
        sub = lambda o: self.tdesc(key, im.w(o), im.w(o + 2), depth + 1)
        if k == 1:
            return {'kind': 'array', 'size': size, 'elem': sub(ofs + 8), 'index': sub(ofs + 12)}
        if k == 2:
            return {'kind': 'record', 'size': size, 'fields': self._fields(key, im, ofs, depth)}
        if k == 3:
            fields, methods = self._members(key, im, ofs, depth)
            anc = im.w(ofs + 12)
            return {'kind': 'object', 'size': size, 'fields': fields, 'methods': methods,
                    'ancestor': self.tdesc(key, anc, im.w(ofs + 14), depth + 1) if anc else None}
        if k == 8:
            return {'kind': 'pointer', 'to': sub(ofs + 8)}
        if k == 9:
            return {'kind': 'string', 'max': size - 1}
        if k == 0x0c:
            return {'kind': 'subrange', 'size': size, 'lo': struct.unpack_from('<i', im.d, ofs + 8)[0],
                    'hi': struct.unpack_from('<i', im.d, ofs + 12)[0]}
        if k == 7:                                  # set of: base type at +8 [verified: SAMPLES]
            return {'kind': 'set', 'size': size, 'base': sub(ofs + 8)}
        if k == 4:                                  # typed file: the element type at +8 [verified: SAMPLES]
            return {'kind': 'file', 'size': size, 'elem': sub(ofs + 8)}
        if k == 6:                                  # procedural type: result ref, count, (ref + kind)* [verified: SAMPLES]
            n = im.w(ofs + 12)
            return {'kind': 'proc', 'size': size, 'result': sub(ofs + 8) if im.w(ofs + 8) else None,
                    'params': [self._param(key, im, ofs + 14 + 5 * i) for i in range(n)]}
        if k == 0x0e:                               # Char itself is 0..255; anything else is a subrange of Char
            lo, hi = struct.unpack_from('<ii', im.d, ofs + 8)
            if (lo, hi) != (0, 255):
                return {'kind': 'subrange', 'size': size, 'lo': lo, 'hi': hi, 'chars': True}
            return {'kind': 'primitive', 'code': k, 'size': size}
        if k == 0x0f:
            lst = self._enum_lists.setdefault((key, ofs), [])      # filled by _decode from the constants of the type
            return {'kind': 'enum', 'size': size, 'unit': key, 'ofs': ofs, 'members': lst}
        if k in (0x05, 0x0a, 0x0b, 0x0d):           # text, reals, boolean-like
            return {'kind': 'primitive', 'code': k, 'size': size}
        return {'kind': 'other', 'code': '%#x' % im.w(ofs), 'size': size}

    def _fields(self, key, im, desc, depth) -> List[dict]:
        out, f, seen = [], im.w(desc + 10), set()
        while f and f not in seen and im.d[f + 2] == 0x51:      # follow the declaration-order chain
            seen.add(f)
            ln = im.d[f + 3]
            q = f + 4 + ln
            out.append(dict(name=im.d[f + 4:q].decode(ENC), offset=im.w(q + 1),
                            type=self.tdesc(key, im.w(q + 7), im.w(q + 9), depth + 1)))
            f = im.w(q + 5)
        return out

    # Object type (kind 3) [verified on WINXP.TPU]:
    #   kind:2 size:2 owner-P-record:2 ?:2 hash-table:2 first-member:2 ancestor-ref:4 ?:2 ordinal:2 data-size:2 ffff
    #   previous-object-type-of-the-unit:2 ...  (data-size = offset of the VMT pointer, = size - 2)
    #   members (own ones only, ancestors' are not repeated) form ONE chain in declaration order: first the fields
    #   (the 'Q' records of a record), then the methods; the last field points at the first method
    #   method := next:2 'R' len name flags:1 ?:1 ordinal:2 owner:2 locals:2 vmt-offset:2 ?:2 ?:2 ?:2 next-member:2
    #             result-ref:4 nparams:2 (type-ref:4 kind:1)*          (the same body as a plain routine)
    #   flags: 0x11 procedure / function, 0x31 constructor, [guess] 0x51 destructor; vmt-offset <> 0: virtual
    def _members(self, key, im, desc, depth):
        fields, methods, f, seen = [], [], im.w(desc + 10), set()
        seq = 0                                                  # position in the chain = order of declaration
        d = im.d
        while f and f not in seen and (d[f + 2] & 0x7f) in (0x51, 0x52):
            seen.add(f)
            ln = d[f + 3]
            b = f + 4 + ln
            name = d[f + 4:b].decode(ENC)
            private = bool(d[f + 2] & 0x80)          # the tag of a member of a `private` section has bit 7 set [SAMPLES]
            if d[f + 2] & 0x7f == 0x51:
                seq += 1
                fields.append(dict(name=name, offset=im.w(b + 1), private=private, seq=seq,
                                   type=self.tdesc(key, im.w(b + 7), im.w(b + 9), depth + 1)))
                f = im.w(b + 5)
                continue
            flags = d[b]
            ret, params = self._signature(key, im, f, b)
            kind = {0x30: 'constructor', 0x50: 'destructor'}.get(flags & 0xF0, 'function' if ret else 'procedure')
            seq += 1
            methods.append(dict(name=name, kind=kind, virtual=im.w(b + 8) != 0, vmt=im.w(b + 8), params=params,
                                result=ret, private=private, seq=seq))
            f = im.w(b + 16)
        return fields, methods

    def _param(self, key, im, p) -> 'Param':
        """The parameter whose 5 bytes (type reference, kind) are at p."""
        kb = im.d[p + 4]
        kind = PARAM_KIND.get(kb & 0x47, 'kind%#x' % kb)
        t = self.ref(key, im, p)
        return Param(kind, self.tstr(t), open=bool(kb & 0x80), tdesc=t)

    def _signature(self, key, im, rec, b):
        """(result type description or None, [Param]) of the routine record `rec` whose body starts at b."""
        d = im.d
        ret = self.ref(key, im, b + 18)
        n = im.w(b + 22)
        params, p = [], b + 24
        for _ in range(n):
            params.append(self._param(key, im, p))
            p += 5
        names = self._param_names(im, rec, im.w(b + 6), n)
        if names:
            for prm, nm in zip(params, names):
                prm.name = nm
        return (ret if im.w(b + 18) != 0 else None), params

    # Debug information [verified on WINXP.TPU]: a unit compiled with {$D+,L+} keeps, for every routine with a body, a
    # table of its local symbols: the routine record points at it (word 6 of its body).  The table is a hash table
    # (size:2, size/2+1 slots) of chained records
    #   next:2 'Q' len name flag:1 offset:2 owner-routine:2 next:2 type-ref:4
    # flag & 0x20: a parameter (0x22 value, 0x26 var); `Self` and the local variables have no such bit.  The records
    # lie in declaration order, so sorting by address gives the order of the parameters.  Units compiled without
    # debug information have 0 there: the names are unknown (P1, P2... in the stub).
    @staticmethod
    def _param_names(im, rec, ptr, n) -> Optional[List[str]]:
        d = im.d
        try:
            if n == 0 or ptr == 0 or ptr + 4 > len(d):
                return None
            size = im.w(ptr)
            if size % 2 or size > 0x400:
                return None
            found = {}
            for i in range(size // 2 + 1):
                o = im.w(ptr + 2 + 2 * i)
                while o and o not in found and o + 4 < len(d):
                    found[o] = im.w(o)
                    o = found[o]
            out = []
            for o in sorted(found):
                if d[o + 2] != 0x51:
                    continue
                b = o + 4 + d[o + 3]
                if d[b] & 0x20 and im.w(b + 3) == rec:
                    out.append(d[o + 4:b].decode(ENC))
            return out if len(out) == n else None
        except IndexError:
            return None

    @staticmethod
    def tstr(t: dict, top: bool = True) -> str:
        if 'named' in t:
            return t['named']
        if 'unresolved' in t:
            return '?%s@%#x' % (t['unresolved'], t['ofs'])
        k = t['kind']
        if k == 'string':
            return 'string[%d]' % t['max']
        if k == 'array':
            idx, e = [Loader.tstr(t['index'], False)], t['elem']
            while 'named' not in e and e.get('kind') == 'array':          # array[1..3] of array[1..3] -> array[1..3, 1..3]
                idx.append(Loader.tstr(e['index'], False))
                e = e['elem']
            return 'array[%s] of %s' % (', '.join(idx), Loader.tstr(e, False))
        if k == 'set':
            return 'set of ' + Loader.tstr(t['base'], False)
        if k == 'file':
            return 'file of ' + Loader.tstr(t['elem'], False)
        if k == 'proc':
            ps = param_text(t['params'], 'A')
            res = Loader.tstr(t['result'], False) if t['result'] else None
            return '%s%s%s' % ('function' if res else 'procedure', '(%s)' % ps if ps else '', ': ' + res if res else '')
        if k == 'pointer':
            return '^' + Loader.tstr(t['to'], False)
        if k == 'subrange':
            if t.get('chars'):
                return '%s..%s' % (char_text(t['lo']), char_text(t['hi']))
            return '%d..%d' % (t['lo'], t['hi'])
        if k == 'primitive':
            return 'primitive%#x' % t['code']
        if k == 'record':
            return 'record %s end' % ' '.join('%s: %s;' % (f['name'], Loader.tstr(f['type'], False))
                                              for f in t['fields'])
        if k == 'object':
            anc = '(%s)' % Loader.tstr(t['ancestor'], False) if t.get('ancestor') else ''
            return 'object%s %s end' % (anc, ' '.join('%s: %s;' % (f['name'], Loader.tstr(f['type'], False))
                                                     for f in t['fields']))
        if k == 'enum':                         # an unnamed enumeration: the members are the constants of that type
            if t.get('members'):
                return '(%s)' % ', '.join(t['members'])
            return 'Byte' if t.get('size', 1) == 1 else 'Word'
        return '?%s' % k

    def struct_of(self, key, t, ofs, uid) -> dict:
        """The structure behind a type reference even when the type has a name (tdesc stops at the name)."""
        if 'named' not in t:
            return t
        if ofs:
            return self.tdesc(key, ofs, uid, named=False)
        uk = (t.get('unit') or '').lower()                  # a named type met inside another type: find it by its name
        for o, nm in self._tmap.get(uk, {}).items():
            if nm == t['named']:
                me = next((i for i, v in self._ids[uk].items() if v.lower() == uk), None)
                if me is not None:
                    return self.tdesc(uk, o, me, named=False)
        return t

    def _sizeof(self, key, t, ofs, uid) -> Optional[int]:
        n = t.get('named')
        if n in SCALAR:
            return SCALAR[n][0]
        if n in REALS:
            return REALS[n]
        if n == 'Pointer':
            return 4
        st = self.struct_of(key, t, ofs, uid)
        k = st.get('kind')
        if k == 'string':
            return st['max'] + 1
        if k == 'pointer':
            return 4
        return st.get('size')

    def _value_text(self, key, im, t, ofs, uid, pos, depth=0) -> Optional[str]:
        """Text of the value of type t stored at image offset pos (a typed constant), or None when it cannot be read."""
        d = im.d
        n = t.get('named')
        try:
            if n in SCALAR:
                size, signed = SCALAR[n]
                v = int.from_bytes(d[pos:pos + size], 'little', signed=signed)
                if n == 'Char':
                    return char_text(v)
                if n in BOOLS:
                    return 'True' if v else 'False'
                return str(v)
            if n in REALS:
                return real_text(bytes(d[pos:pos + REALS[n]]), n)
            if n == 'string':
                return pas_literal(bytes(d[pos + 1:pos + 1 + d[pos]]).decode(ENC, 'replace'))
            if n == 'Pointer':
                return 'nil' if not any(d[pos:pos + 4]) else None
            if depth > 6:
                return None
            st = self.struct_of(key, t, ofs, uid)
            k = st.get('kind')
            if k == 'string':
                return pas_literal(bytes(d[pos + 1:pos + 1 + d[pos]]).decode(ENC, 'replace'))
            if k == 'pointer':
                return 'nil' if not any(d[pos:pos + 4]) else None
            if k == 'subrange':
                size = st.get('size') or 2
                v = int.from_bytes(d[pos:pos + size], 'little', signed=st['lo'] < 0)
                return char_text(v) if st.get('chars') else str(v)
            if k == 'enum':
                v = int.from_bytes(d[pos:pos + (st.get('size') or 1)], 'little')
                names = st.get('members') or self._enum_named.get(((t.get('unit') or '').lower(), t.get('named')))
                return names[v] if names and v < len(names) else str(v)
            if k == 'set':
                names = self._set_base_names(key, st['base'])
                return set_text(bytes(d[pos:pos + st['size']]), names)
            if k == 'array':
                esize = self._sizeof(key, st['elem'], 0, 0) if 'named' in st['elem'] else \
                    self._sizeof(key, st['elem'], 0, 0)
                if not esize:
                    return None
                count = st['size'] // esize
                vals = []
                for i in range(min(count, 64)):
                    v = self._value_text(key, im, st['elem'], 0, 0, pos + i * esize, depth + 1)
                    if v is None:
                        return None
                    vals.append(v)
                return '(%s%s)' % (', '.join(vals), ', ...' if count > 64 else '')
            if k == 'record':
                parts = []
                for f in st['fields']:
                    v = self._value_text(key, im, f['type'], 0, 0, pos + f['offset'], depth + 1)
                    if v is None:
                        return None
                    parts.append('%s: %s' % (f['name'], v))
                return '(%s)' % '; '.join(parts)
        except (IndexError, struct.error):
            return None
        return None

    def _set_base_names(self, key, base):
        n = base.get('named')
        if n == 'Char' or (base.get('kind') == 'subrange' and base.get('chars')):
            return 'Char'
        if base.get('kind') == 'enum':
            return base.get('members') or None
        return self._enum_named.get(((base.get('unit') or '').lower(), n)) or None

    def ref(self, unit, im, o):
        return self.tdesc(unit, im.w(o), im.w(o + 2))

    # -- decoding ----------------------------------------------------------
    def _decode(self, key) -> Unit:
        im, recs = self._img[key], self._recs[key]
        ordered = sorted(recs.values(), key=lambda r: r['off'])
        s = [r for r in ordered if r['tag'] == 'S']
        u = Unit(name=(s[0]['name'] if s else 'System'), used=[r['name'] for r in s[1:]])
        for pass_no in (1, 2):
            u.symbols = []
            for r in ordered:
                sym = self._sym(key, im, r)
                if sym:
                    u.symbols.append(sym)
            if pass_no == 1:                                     # unnamed enumerations: members are known only after
                anon: Dict[int, list] = {}                       # all constants are read, so the unit is decoded again
                for c in u.symbols:
                    if c.kind == 'const' and c.tdesc and c.tdesc.get('kind') == 'enum' and c.tdesc.get('unit') == key:
                        anon.setdefault(c.tdesc['ofs'], []).append(c)
                for o, cs in anon.items():
                    self._enum_lists.setdefault((key, o), [])[:] = [c.name for c in sorted(cs, key=lambda c: c.value)]
                if not anon:
                    break
        # enumeration members = the constants of that type that directly follow it, with the values 0, 1, 2...  A constant
        # of the enumeration type declared later (`const Def = clGreen`) has the type but is not a member.
        consts = [c for c in u.symbols if c.kind == 'const']
        enums = {x.name: x for x in u.symbols if x.shape == 'enum'}
        for x in enums.values():
            run = []
            for c in sorted((c for c in consts if c.tdesc.get('named') == x.name and c.tdesc.get('unit') == u.name),
                            key=lambda c: c.offset):
                if c.value != len(run):
                    break
                run.append(c)
            x.members = [c.name for c in run]
            x.definition = '(%s)' % ', '.join(x.members)
            self._enum_named[(key, x.name)] = x.members
        for c in consts:                                         # values that are not plain numbers
            if c.display is None:
                td = c.tdesc or {}
                names = self._enum_named.get(((td.get('unit') or '').lower(), td.get('named')))
                if names and 0 <= c.value < len(names):
                    c.display = names[c.value]
                elif getattr(c, '_set', None):
                    st, bits = c._set
                    c.display = set_text(bits, self._set_base_names(key, st['base']))
        data = self._data_start(im)
        for v in u.symbols:                                      # typed constants: their initial values
            if v.typed_const and data is not None:
                ofs, uid, pos = v._data
                v.init = self._value_text(key, im, v.tdesc, ofs, uid, data + pos)
        return u

    @staticmethod
    def _data_start(im) -> Optional[int]:
        """Image offset of the initialized data (the typed constants): it follows the code, on a paragraph boundary.
        Header words: +30 start of the code, +34 its size [verified: SAMPLES; the values of kInt, kStr... come out right]."""
        at = (im.w(30) + im.w(34) + 15) & ~15
        return at if at < len(im.d) else None

    def _sym(self, key, im, r) -> Optional[Sym]:
        tag, name, b, off = r['tag'], r['name'], r['body'], r['off']
        d = im.d
        if tag == 'S':
            return None
        if tag == 'R':                                   # [verified: Dos, POLSK, Graph]
            # 18 header bytes, result type ref, param count, then (type ref + kind byte)*
            ret, params = self._signature(key, im, off, b)
            return Sym('routine', name, tag, off, type=self.tstr(ret) if ret else None, tdesc=ret, params=params,
                       directive={0x02: 'inline', 0x04: 'interrupt'}.get(d[b]))
        if tag == 'Q':                                   # 7 unknown bytes + type ref [verified]
            t = self.ref(key, im, b + 7)
            sym = Sym('var', name, tag, off, type=self.tstr(t), tdesc=t)
            # the first byte: 0 variable, 1 typed constant (word 1 = offset of its value in the data segment),
            # 3 absolute (word 1 = offset, word 3 = segment)                                 [verified: SAMPLES]
            if d[b] == 1:
                sym.typed_const = True
                sym._data = (im.w(b + 7), im.w(b + 9), im.w(b + 1))
            elif d[b] == 3:
                sym.absolute = (im.w(b + 3), im.w(b + 1))
            return sym
        if tag == 'O':                                   # type ref + int32 [verified for ints]
            t = self.ref(key, im, b)
            if t.get('named') == 'string':               # a string constant: length byte + the characters [verified: Views]
                n = d[b + 4]
                return Sym('const', name, tag, off, type='string', tdesc=t,
                           value=pas_literal(bytes(d[b + 5:b + 5 + n]).decode(ENC, 'replace')))
            sym = Sym('const', name, tag, off, type=self.tstr(t), tdesc=t,
                      value=struct.unpack_from('<i', d, b + 4)[0])
            nm = t.get('named')
            if nm == 'Char':
                sym.display = char_text(d[b + 4])
            elif nm in BOOLS:
                sym.display = 'True' if sym.value else 'False'
            elif nm in REALS:
                sym.display = real_text(bytes(d[b + 4:b + 4 + REALS[nm]]), nm)
            else:
                st = self.struct_of(key, t, im.w(b), im.w(b + 2))
                if st.get('kind') == 'set':
                    sym._set = (st, bytes(d[b + 4:b + 4 + st['size']]))
            return sym
        if tag == 'P':
            t = self.tdesc(key, im.w(b), im.w(b + 2), named=False)      # the type's own definition
            sym = Sym('type', name, tag, off, shape=t.get('kind', 'other'), size=im.w(im.w(b) + 2), tdesc=t)
            if t.get('kind') == 'record':
                sym.fields = [dict(name=f['name'], offset=f['offset'], type=self.tstr(f['type']),
                                   tdesc=f['type']) for f in t['fields']]
            if t.get('kind') == 'object':
                sym.fields = [dict(name=f['name'], offset=f['offset'], type=self.tstr(f['type']),
                                   tdesc=f['type'], private=f.get('private', False), seq=f.get('seq', 0)) for f in t['fields']]
                sym.methods, sym.ancestor = t['methods'], t.get('ancestor')
            sym.definition = self.tstr(t) if t.get('kind') not in ('enum', 'primitive') else None
            sym.tdesc = t
            return sym
        if tag == '[':                                   # System: OpenString [verified by name]
            return Sym('type', name, tag, off, shape='openstring')
        if tag in 'VWXYZ':                               # System built-ins only
            return Sym('builtin', name, tag, off,
                       note={'V': 'procedure', 'W': 'function', 'X': 'procedure (New)',
                             'Y': 'port array', 'Z': 'memory array'}[tag])
        return Sym('other', name, tag, off, note='tag %r not decoded' % tag)


# --------------------------------------------------------------------------
def param_text(params, prefix: str = 'P') -> str:
    """'var E: tEvent; X, Y: Integer' with the real names when the unit has debug information, else P1, P2..."""
    out = []
    for i, p in enumerate(params):
        kw = {'var': 'var ', 'const': 'const '}.get(p.kind, '')
        name = p.name or '%s%d' % (prefix, i + 1)
        if p.kind == 'var' and p.type == 'file' and not p.open:           # untyped var parameter
            out.append('var ' + name)
        else:
            out.append('%s%s: %s%s' % (kw, name, 'array of ' if p.open else '', p.type))
    return '; '.join(out)


def method_text(m: dict) -> str:
    ps = param_text(m['params'])
    res = ': ' + Loader.tstr(m['result'], False) if m['result'] else ''
    return '%s %s%s%s;%s' % (m['kind'], m['name'], '(%s)' % ps if ps else '', res, ' virtual;' if m['virtual'] else '')


def render_pas(u: Unit) -> str:
    """Pseudo interface text. Parameter names are not stored in a TPU interface,
    so P1..Pn are placeholders; they never occur at call sites in TP7.
    Typed constants and variables share one record kind in a TPU, both print as `var`."""
    L = ['unit %s;' % u.name, '', 'interface', '']
    if u.used:
        L += ['uses ' + ', '.join(u.used) + ';', '']
    enum_names = {m for t in u.symbols if t.members for m in t.members}
    cons = [s for s in u.symbols if s.kind == 'const' and s.name not in enum_names]
    types = [s for s in u.symbols if s.kind == 'type']
    vars_ = [s for s in u.symbols if s.kind == 'var']
    rout = [s for s in u.symbols if s.kind == 'routine']
    bi = [s for s in u.symbols if s.kind == 'builtin']
    if cons:
        L.append('const')
        L += ['  %s = %s;  { %s }' % (c.name, c.value, c.type) for c in cons]
        L.append('')
    if types:
        L.append('type')
        for t in types:
            if t.shape == 'record':
                L.append('  %s = record  { size %s }' % (t.name, t.size))
                L += ['    %s: %s;  { @%d }' % (f['name'], f['type'], f['offset']) for f in t.fields]
                L.append('  end;')
            elif t.shape == 'object':
                anc = '(%s)' % Loader.tstr(t.ancestor, False) if t.ancestor else ''
                L.append('  %s = object%s  { size %s }' % (t.name, anc, t.size))
                L += ['    %s: %s;  { @%d }' % (f['name'], f['type'], f['offset']) for f in t.fields]
                for m in t.methods:
                    L.append('    ' + method_text(m))
                L.append('  end;')
            elif t.definition:
                L.append('  %s = %s;  { size %s }' % (t.name, t.definition, t.size))
            else:
                L.append('  %s = ...;  { %s, size %s }' % (t.name, t.shape, t.size))
        L.append('')
    if vars_:
        L.append('var')
        L += ['  %s: %s;' % (v.name, v.type) for v in vars_]
        L.append('')
    for r in rout:
        ps = param_text(r.params)
        ps = '(%s)' % ps if ps else ''
        if r.type:
            L.append('function %s%s: %s;' % (r.name, ps, r.type))
        else:
            L.append('procedure %s%s;' % (r.name, ps))
    if bi:
        L += ['', '{ compiler built-ins: ' + ', '.join(b.name for b in bi) + ' }']
    return '\n'.join(L) + '\n'


def main(argv):
    args = argv[1:]
    if not args or '-h' in args or '--help' in args:
        print('usage: tpu_dump.py FILE.TPU|FILE.TPL [--lib LIB.TPL] [--json|--pas|--names] [UNIT]\n'
              '  --lib  extra file used only to resolve type references (default: TURBO.TPL next to FILE)')
        return 1
    path = args[0]
    lib = None
    if '--lib' in args:
        lib = args[args.index('--lib') + 1]
    else:
        import os
        cand = os.path.join(os.path.dirname(os.path.abspath(path)), 'TURBO.TPL')
        if os.path.exists(cand) and os.path.abspath(cand) != os.path.abspath(path):
            lib = cand
    imgs = split_images(open(path, 'rb').read())
    n_primary = len(imgs)
    if lib:
        imgs += split_images(open(lib, 'rb').read())
    ld = Loader(imgs, primary=n_primary)
    rest = [a for a in args[1:] if a != '--lib' and a != lib]
    mode = next((a for a in rest if a.startswith('--')), '--pas')
    only = next((a.lower() for a in rest if not a.startswith('--')), None)
    units = [ld.units[k] for k in ld.primary if only in (None, k)]
    if mode == '--json':
        print(json.dumps([asdict(u) for u in units], ensure_ascii=False, indent=1))
    elif mode == '--names':               # flat spelling dictionary: what the formatter needs
        def walk(t):                      # field names of (possibly anonymous, nested) records
            if not isinstance(t, dict):
                return
            for f in t.get('fields', []):
                yield f['name']
                yield from walk(f['type'])
            for k in ('elem', 'to'):
                yield from walk(t.get(k))
        for u in units:
            for s in u.symbols:
                print('%s\t%s\t%s' % (u.name, s.kind, s.name))
                for m in (s.members or []):
                    print('%s\tenum\t%s' % (u.name, m))
                seen = set()
                for fn in walk(s.tdesc):
                    if fn not in seen:
                        seen.add(fn)
                        print('%s\tfield\t%s.%s' % (u.name, s.name, fn))
    else:
        for u in units:
            print(render_pas(u))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
