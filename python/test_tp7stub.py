#!/usr/bin/env python3
"""Tests of tp7stub.py (generated interface stubs of TPU units) and of how tp7lsp.py uses them.
Run: python3 test_tp7stub.py [DIR_WITH_SAMPLES]   (DIR must contain TURBO.TPL and GRAPH.TPU, like test_tp7lsp.py)"""
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_tp7lsp                                                       # noqa: E402
from test_tp7lsp import Base, uri, D                                     # noqa: E402
from tp7parse import parse                                               # noqa: E402
from tp7sema import Provider                                             # noqa: E402
from tp7stub import StubStore, render                                    # noqa: E402

TPL = os.path.join(D, 'TURBO.TPL')
GRAPH = os.path.join(D, 'GRAPH.TPU')


def stub_of(unit, tpu=None):
    prov = Provider([os.path.dirname(GRAPH)] if tpu else [], TPL)
    info = prov.get(unit)
    return info, render(info.tpu, info.origin)


class Rendering(unittest.TestCase):
    def test_every_indexed_name_is_where_the_index_says(self):
        for unit in ('System', 'Crt', 'Dos', 'Overlay', 'Printer', 'Graph'):
            info, st = stub_of(unit, tpu=True)
            self.assertGreater(len(st.index), 1, unit)
            for key, (ln, col, length) in st.index.items():
                if key[0] != 'unit':
                    self.assertEqual(st.lines[ln][col:col + length].lower(), key[-1], (unit, key))

    def test_stub_is_a_unit_with_an_interface(self):
        info, st = stub_of('Crt')
        res = parse(st.text)
        self.assertEqual(res.diags, [])
        self.assertIn('unit Crt;', st.lines)
        self.assertIn('interface', st.lines)
        self.assertEqual(st.lines[-1], 'end.')

    def test_routines_constants_variables(self):
        info, st = stub_of('Crt')
        self.assertIn('procedure GotoXY(P1, P2: Byte);', st.lines)
        self.assertIn('function ReadKey: Char;', st.lines)
        self.assertIn('  Blue = 1;', st.lines)
        self.assertIn('  TextAttr: Byte;', st.lines)
        self.assertIn('procedure AssignCrt(var P1: Text);', st.lines)

    def test_records_show_their_fields(self):
        info, st = stub_of('Dos')
        self.assertIn('  Registers = record', st.lines)
        self.assertIn('    AX: Word;  { @0 }', st.lines)
        pos = st.find('field', 'ah', 'Registers')
        self.assertEqual(st.lines[pos[0]].strip(), 'AH: Byte;  { @1 }')
        self.assertEqual(st.block('type', 'DateTime')[-1].strip(), 'end;')
        self.assertIn('  PathStr = string[79];', st.lines)

    def test_system_primitives_booleans_and_builtins(self):
        info, st = stub_of('System')
        self.assertIn('  Boolean = (False, True);  { built-in, size 1 }', st.lines)
        self.assertIsNotNone(st.find('const', 'True'))
        self.assertIn('  Byte = 0..255;', st.lines)
        self.assertIn('  Pointer = Pointer;  { built-in untyped pointer, size 4 }', st.lines)
        self.assertIn('function Copy(S: string; Index, Count: Integer): string;', st.lines)
        self.assertIn('  Mem: array of Byte;  { Mem[Segment:Offset] }', st.lines)        # a variable, not among the routines
        i = st.lines.index('  Mem: array of Byte;  { Mem[Segment:Offset] }')
        self.assertEqual(st.lines[st.lines.index('var'):i].count(''), 0)
        self.assertFalse(any(x.startswith(('Mem', 'Port')) for x in st.lines))
        self.assertTrue(all(st.find('builtin', n) for n in ('WriteLn', 'Inc', 'Dispose', 'Str', 'Val')))

    def test_untyped_var_parameters_and_wrapping(self):
        info, st = stub_of('Graph', tpu=True)
        self.assertIn('procedure GetImage(P1, P2, P3, P4: Integer; var P5);', st.lines)
        self.assertTrue(all(len(x) <= 100 for x in st.lines[3:]), max(st.lines[3:], key=len))

    def test_enumeration_members_are_indexed(self):
        info, st = stub_of('Graph', tpu=True)
        self.assertIsNotNone(st.find('const', 'VGA'))


class Store(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='stubs_')

    def test_file_is_written_read_only_and_reused(self):
        info, _ = stub_of('Crt')
        store = StubStore(self.dir)
        path, st = store.get(info)
        self.assertTrue(store.is_stub(path))
        self.assertFalse(store.is_stub(os.path.join(self.dir, '..', 'x.pas')))
        self.assertEqual(os.path.basename(path), 'Crt.pas')
        with open(path, 'rb') as f:
            self.assertEqual(f.read(), st.text.encode('cp866'))
        self.assertFalse(os.stat(path).st_mode & stat.S_IWUSR)
        self.assertIs(store.get(info)[1], st)                                  # cached

    def test_a_stale_file_is_replaced(self):
        info, _ = stub_of('Crt')
        path, st = StubStore(self.dir).get(info)
        os.chmod(path, 0o666)
        with open(path, 'wb') as f:
            f.write(b'old')
        path2, st2 = StubStore(self.dir).get(info)
        with open(path2, 'rb') as f:
            self.assertEqual(f.read(), st2.text.encode('cp866'))

    def test_units_with_a_source_have_no_stub(self):
        class Src:
            tpu = None
        self.assertIsNone(StubStore(self.dir).get(Src()))

    def test_same_unit_name_from_different_files_does_not_collide(self):
        a, _ = stub_of('Crt')
        b, _ = stub_of('Crt')
        b.origin = os.path.join(self.dir, 'OTHER.TPL')
        store = StubStore(self.dir)
        self.assertNotEqual(store.get(a)[0], store.get(b)[0])


class Protocol(Base):
    SRC = ('program a;\n'
           'uses Crt, Dos, Graph;\n'
           'var Regs: Registers;\n'
           '    N: Word;\n'
           'begin\n'
           '  ClrScr;\n'
           '  GotoXY(1, 2);\n'
           '  Regs.AX := N;\n'
           '  TextColor(Red);\n'
           '  InitGraph(N, N, \'\');\n'
           '  WriteLn(Regs.AH);\n'
           'end.\n')

    def setUp(self):
        super().setUp()
        self.c = self.start()
        self.u = self.c.open(os.path.join(self.ws, 'a.pas'), self.SRC)

    def pos(self, needle, nth=0, off=0):
        return test_tp7lsp.Definition.pos(self.SRC, needle, nth, off)

    def ask(self, method, needle, nth=0, off=0, **extra):
        params = {'textDocument': {'uri': self.u}, 'position': self.pos(needle, nth, off)}
        params.update(extra)
        return self.c.request('textDocument/' + method, params)['result']

    def stub_text(self, loc):
        from tp7lsp import uri_to_path
        with open(uri_to_path(loc['uri']), 'rb') as f:
            return f.read().decode('cp866').split('\r\n')

    def at(self, loc):
        r = loc['range']
        return self.stub_text(loc)[r['start']['line']][r['start']['character']:r['end']['character']]

    def test_definition_lands_on_the_name_in_the_stub(self):
        for needle, name in (('ClrScr', 'ClrScr'), ('GotoXY', 'GotoXY'), ('Red', 'Red'), ('Registers', 'Registers'),
                             ('InitGraph', 'InitGraph'), ('WriteLn', 'WriteLn'), ('Word', 'Word')):
            loc = self.ask('definition', needle)
            self.assertEqual(self.at(loc), name, needle)
            self.assertEqual(self.ask('declaration', needle), loc)
            self.assertTrue(loc['uri'].startswith(uri(self.stubs)))

    def test_fields_of_a_library_record(self):
        loc = self.ask('definition', 'AX :=')
        self.assertEqual(self.at(loc), 'AX')
        self.assertEqual(self.stub_text(loc)[loc['range']['start']['line']].strip(), 'AX: Word;  { @0 }')
        loc = self.ask('definition', 'AH)')
        self.assertEqual(self.stub_text(loc)[loc['range']['start']['line']].strip(), 'AH: Byte;  { @1 }')

    def test_unit_name_goes_to_the_top_of_its_stub(self):
        loc = self.ask('definition', 'Dos')
        self.assertEqual((os.path.basename(loc['uri']), self.at(loc)), ('Dos.pas', 'Dos'))
        self.assertEqual(loc['range']['start']['line'], 5)

    def test_type_definition(self):
        loc = self.ask('typeDefinition', 'Regs.AX')
        self.assertEqual(self.at(loc), 'Registers')
        loc = self.ask('typeDefinition', 'N: Word')
        self.assertEqual((os.path.basename(loc['uri']), self.at(loc)), ('System.pas', 'Word'))

    def test_hover_shows_the_declaration(self):
        h = self.ask('hover', 'GotoXY')['contents']['value']
        self.assertIn('procedure GotoXY(P1, P2: Byte)', h)
        self.assertIn('*unit Crt*', h)
        self.assertIn('placeholders', h)
        h = self.ask('hover', 'Red')['contents']['value']
        self.assertIn('const Red = 4', h)
        h = self.ask('hover', 'AX :=')['contents']['value']
        self.assertIn('AX: Word', h)
        self.assertIn('*field of Registers*', h)
        h = self.ask('hover', 'Registers')['contents']['value']
        self.assertIn('Registers = record', h)
        self.assertIn('AL: Byte', h)
        h = self.ask('hover', 'WriteLn')['contents']['value']
        self.assertIn('procedure WriteLn(', h)
        self.assertIn('built-in', h)

    def test_rename_of_a_library_name_is_still_refused(self):
        r = self.c.request('textDocument/rename', {'textDocument': {'uri': self.u}, 'position': self.pos('ClrScr'),
                                                    'newName': 'Clear'})
        self.assertIn('error', r)

    def test_an_open_stub_has_no_diagnostics_and_is_not_formatted(self):
        loc = self.ask('definition', 'WriteLn')
        from tp7lsp import uri_to_path
        p = uri_to_path(loc['uri'])
        with open(p, 'rb') as f:
            text = f.read().decode('cp866')
        u = self.c.open(p, text)
        m = self.c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual(m['params']['diagnostics'], [])
        r = self.c.request('textDocument/formatting', {'textDocument': {'uri': u}, 'options': {}})
        self.assertEqual(r['result'], [])
        syms = self.c.request('textDocument/documentSymbol', {'textDocument': {'uri': u}})['result']
        self.assertTrue(syms)

    def test_inside_a_stub_names_still_lead_to_stubs(self):
        loc = self.ask('definition', 'Registers')
        from tp7lsp import uri_to_path
        p = uri_to_path(loc['uri'])
        text = self.stub_text(loc)
        u = self.c.open(p, '\r\n'.join(text))
        i = next(n for n, x in enumerate(text) if x.strip().startswith('AX: Word'))
        r = self.c.request('textDocument/definition', {'textDocument': {'uri': u},
                                                        'position': {'line': i, 'character': text[i].index('Word')}})['result']
        self.assertEqual(os.path.basename(r['uri']), 'System.pas')

    def test_references_do_not_report_stub_files(self):
        loc = self.ask('definition', 'Word')
        from tp7lsp import uri_to_path
        p = uri_to_path(loc['uri'])
        self.c.open(p, '\r\n'.join(self.stub_text(loc)))
        refs = self.ask('references', 'N: Word', 0, 3, context={'includeDeclaration': True})
        self.assertTrue(refs)
        self.assertTrue(all(not r['uri'].startswith(uri(self.stubs)) for r in refs), refs)


class TpuWithoutSource(Base):
    def test_a_tpu_unit_in_the_search_path_gets_a_stub(self):
        src = 'program a;\nuses Graph;\nvar D, M: Integer;\nbegin\n  InitGraph(D, M, \'\');\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        r = c.request('textDocument/definition', {'textDocument': {'uri': u},
                                                   'position': test_tp7lsp.Definition.pos(src, 'InitGraph')})['result']
        self.assertEqual(os.path.basename(r['uri']), 'Graph.pas')
        self.assertTrue(r['uri'].startswith(uri(self.stubs)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
