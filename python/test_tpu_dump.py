#!/usr/bin/env python3
"""Checks tpu_dump.py against facts that are known independently of the decoder:
POLSK.PAS (source of POLSK.TPU), the documented Dos/Crt declarations and the
spellings found by a naive scan of TURBO.TPL.  Run:  python3 test_tpu_dump.py DIR
where DIR contains POLSK.PAS POLSK.TPU GRAPH.TPU TURBO.TPL."""
import os, re, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tpu_dump as T

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'
def rd(n):
    with open(os.path.join(D, n), 'rb') as f:
        return f.read()


def load(name, lib=True):
    imgs = T.split_images(rd(name))
    n = len(imgs)
    if lib:
        imgs += T.split_images(rd('TURBO.TPL'))
    return T.Loader(imgs, primary=n)


class Tpu(unittest.TestCase):
    def test_polsk_interface_matches_source(self):
        src = rd('POLSK.PAS').decode('cp866')
        iface = src[src.lower().index('interface'):src.lower().index('implementation')]
        want = re.findall(r'(function|procedure)\s+(\w+)\s*(\(([^)]*)\))?\s*(:\s*(\w+))?\s*;', iface, re.I)
        u = load('POLSK.TPU').units['polsk']
        got = {s.name: s for s in u.symbols}
        self.assertEqual([w[1] for w in want], [s.name for s in u.symbols])   # names AND spelling
        for kw, nm, _, params, _, res in want:
            s = got[nm]
            self.assertEqual(s.type.lower() if s.type else None, res.lower() or None)
            nparams = len([p for p in params.split(';') if p.strip()]) if params else 0
            self.assertEqual(len(s.params), nparams)
        self.assertEqual(got['NextChar'].params[0].kind, 'var')

    def test_no_unresolved_types(self):
        # TEST.TPU is excluded on purpose: it refers to unit `option`, which we do not have
        for f in ('POLSK.TPU', 'GRAPH.TPU', 'TURBO.TPL'):
            ld = load(f)
            for k in ld.primary:
                text = T.render_pas(ld.units[k])
                # '?name@0x..' = unresolved reference; '?other' = a type kind not decoded yet
                # (known: Overlay.OvrReadFunc, a procedural type) and is allowed here
                self.assertIsNone(re.search(r'\?[\w]*@', text), (f, k))

    def test_dos_records(self):
        u = load('TURBO.TPL').units['dos']
        t = {s.name: s for s in u.symbols}
        self.assertEqual([f['name'] for f in t['Registers'].fields],
                         'AX BX CX DX BP SI DI DS ES Flags AL AH BL BH CL CH DL DH'.split())
        self.assertEqual({f['name']: f['type'] for f in t['SearchRec'].fields},
                         {'Fill': 'array[1..21] of Byte', 'Attr': 'Byte', 'Time': 'Longint',
                          'Size': 'Longint', 'Name': 'string[12]'})
        self.assertEqual(t['TextRec'].fields[6]['type'], '^TextBuf')
        self.assertEqual(t['DateTime'].size, 12)
        self.assertEqual(t['FileRec'].size, 128)

    def test_dos_routines(self):
        u = load('TURBO.TPL').units['dos']
        r = {s.name: s for s in u.symbols}
        self.assertEqual([(p.kind, p.type) for p in r['Intr'].params], [('value', 'Byte'), ('var', 'Registers')])
        self.assertEqual(r['DiskFree'].type, 'Longint')
        self.assertIsNone(r['MsDos'].type)

    def test_system_spelling(self):
        names = {s.name for s in load('TURBO.TPL').units['system'].symbols}
        for n in ('WriteLn', 'ReadLn', 'Inc', 'Dec', 'Exit', 'Halt', 'SizeOf', 'FillChar', 'Integer',
                  'Boolean', 'True', 'False', 'Bytebool', 'Longbool', 'Wordbool', 'OpenString', 'IOResult',
                  'Assign', 'Pos', 'HeapError'):
            self.assertIn(n, names)
        for bad in ('Writeln', 'TRUE', 'FALSE', 'Readln'):
            self.assertNotIn(bad, names)

    def test_every_naive_scan_name_is_found(self):
        blob = rd('TURBO.TPL')
        ld = load('TURBO.TPL')
        found = {s.name for u in ld.units.values() for s in u.symbols}
        found |= {f['name'] for u in ld.units.values() for s in u.symbols for f in (s.fields or [])}
        for n in ('Abs', 'Addr', 'Append', 'ParamStr', 'GetEnv', 'KeyPressed', 'ReadKey', 'Lst',
                  'FindFirst', 'GetIntVec', 'Delay', 'NoSound', 'OvrInit', 'DirectVideo', 'Flags'):
            self.assertIn(n.encode(), blob)
            self.assertIn(n, found)

    # ---- TEST.TPU / TEST.PAS: enumeration, pointers, variant records, array of record, 6 used units
    def test_test_unit(self):
        src = rd('TEST.PAS').decode('cp866')
        u = load('TEST.TPU').units['test']
        t = {s.name: s for s in u.symbols}
        self.assertEqual(u.used, ['System', 'vesa', 'dos', 'objects', 'crt', 'polsk', 'option'])
        # enumeration members in declaration order, spelled as declared
        decl = re.search(r'Ident=\((.*?)\);', src, re.S).group(1)
        self.assertEqual(t['Ident'].members, [x.strip() for x in decl.replace('\r', '').replace('\n', '').split(',')])
        self.assertEqual(t['str_15'].definition, 'string[15]')
        self.assertEqual(t['pZnach'].definition, '^tZnach')
        self.assertEqual([f['name'] for f in t['tZnach'].fields], ['typ', 'f', 'i', 's', 'c', 'p'])
        self.assertEqual({f['name']: f['offset'] for f in t['tZnach'].fields if f['name'] in 'ip'}, {'i': 2, 'p': 2})
        self.assertEqual([f['name'] for f in t['tNode'].fields],
                         'next typ where what NotPrep op1 op2 then_ else_ Operation whereW whatW NotPrepW '
                         'op1W op2W operationW bodyW ForI Body Name TypAss WhatAssign'.split())
        # anonymous record inside an array type: fields are reachable for `MainVar[i].name`
        arr = t['tMainVar'].tdesc
        self.assertEqual(arr['kind'], 'array')
        self.assertEqual([f['name'] for f in arr['elem']['fields']], ['name', 'typ', 'i', 's', 'c'])
        # variables: declared spelling, and the typed constant MainLex shows up as a variable
        v = {s.name: s for s in u.symbols if s.kind == 'var'}
        self.assertEqual(v['MainLex'].type, 'array[Ident] of str_15')
        self.assertEqual(v['PGoth'].type, 'Pointer')
        self.assertEqual(v['SBP'].type, 'Word')
        self.assertEqual(v['LexNum'].type, 'Integer')
        # every variable of the source is present with the same spelling (case-insensitive match)
        for name in re.findall(r'(\w+)\s*(?:,\s*\w+\s*)*:\s*(?:text|integer|boolean|byte|word|pointer|char|string|\w+)\s*;', 
                               src[src.lower().index('var prog'):src.lower().index('implementation')], re.I):
            self.assertIn(name.lower(), {k.lower() for k in v}, name)

    def test_reference_to_unloaded_unit_is_reported_not_guessed(self):
        # `tbeg` belongs to unit `option`, which is not loaded here
        u = load('TEST.TPU').units['test']
        cur = next(s for s in u.symbols if s.name == 'cursor')
        self.assertEqual(cur.tdesc.get('unresolved'), 'option')


if __name__ == '__main__':
    unittest.main(verbosity=2)
