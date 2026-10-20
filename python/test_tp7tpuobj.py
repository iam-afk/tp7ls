"""End-to-end tests: object types decoded from a .TPU (WINXP.TPU) and used from source."""
import os, shutil, sys, tempfile, unittest
sys.argv = [sys.argv[0]] + sys.argv[1:]
import test_tp7lsp as T
from test_tp7lsp import Base, uri

PROG = ('program P;\nuses WinXP;\nvar d: pDeskTop;\n    w: tWindow;\nbegin\n'
        '  d^.run;\n  d^.sizex := 1;\n  w.Show;\nend.\n')


HERE_SAMPLES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'samples')   # VIEWS.TPU, OBJECTS.TPU


class TpuObjects(Base):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        shutil.copy(os.path.join(T.D, 'WINXP.TPU'), os.path.join(cls.tp7, 'UNITS', 'WINXP.TPU'))

    def open(self, text, name='p.pas'):
        c = self.start()
        path = self.write(name, text)
        u = c.open(path, text)
        return c, u

    def test_no_diagnostics(self):
        c, u = self.open(PROG)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        msgs = [d['message'] for d in m['params']['diagnostics']]
        self.assertEqual(msgs, [], msgs)

    def test_format_normalizes_member_case(self):
        c, u = self.open(PROG)
        out = c.formatted(u, PROG)
        self.assertIn('d^.Run;', out)
        self.assertIn('d^.SizeX', out)
        self.assertIn('w.Show;', out)

    def test_hover_and_definition_on_method(self):
        c, u = self.open(PROG)
        pos = {'line': 5, 'character': 6}
        h = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': pos})['result']
        self.assertIsNotNone(h)
        self.assertIn('Run', str(h))
        d = c.request('textDocument/definition', {'textDocument': {'uri': u}, 'position': pos})['result']
        self.assertTrue(d)

    def test_completion_includes_inherited(self):
        c, u = self.open(PROG.replace('d^.run;', 'd^.;'))
        r = c.request('textDocument/completion', {'textDocument': {'uri': u},
                                                  'position': {'line': 5, 'character': 5}})['result']
        items = r['items'] if isinstance(r, dict) else r
        names = {i['label'] for i in items}
        self.assertTrue({'Run', 'SizeX'} <= names, sorted(names)[:40])

    def test_descendant_in_source(self):
        text = ('program P;\nuses WinXP;\ntype tMy = object(tWindow)\n  procedure Show; virtual;\nend;\n'
                'procedure tMy.Show;\nbegin\n  inherited Show;\nend;\nbegin\nend.\n')
        c, u = self.open(text)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual([d['message'] for d in m['params']['diagnostics']], [])

    def test_signature_help_names(self):
        text = 'program P;\nuses WinXP;\nvar w: tWindow;\nbegin\n  w.Init(\nend.\n'
        c, u = self.open(text)
        r = c.request('textDocument/signatureHelp', {'textDocument': {'uri': u},
                                                     'position': {'line': 4, 'character': 9}})['result']
        self.assertTrue(r and r['signatures'])
        self.assertNotIn('P1', r['signatures'][0]['label'])


class Dependencies(Base):
    """VIEWS.TPU uses OBJECTS.TPU (TPoint, TRect) and DRIVERS.TPU (not supplied: must not break the unit)."""
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for n in ('VIEWS.TPU', 'OBJECTS.TPU'):
            src = os.path.join(HERE_SAMPLES, n)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(cls.tp7, 'UNITS', n))

    def test_unit_found_and_types_from_objects_resolved(self):
        if not os.path.exists(os.path.join(self.tp7, 'UNITS', 'VIEWS.TPU')):
            self.skipTest('VIEWS.TPU not in the samples')
        text = 'program P;\nuses Views;\nvar v: PView;\nbegin\n  v^.Origin.X := 1;\nend.\n'
        c = self.start()
        path = self.write('p.pas', text)
        u = c.open(path, text)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual([d['message'] for d in m['params']['diagnostics']], [])


class LocalShadow(unittest.TestCase):
    def test_dependencies_come_from_the_dir_of_the_unit_that_uses_them(self):
        import tempfile
        from tp7sema import Provider
        from tp7stub import render
        tmp = tempfile.mkdtemp()
        try:
            lib, ws = os.path.join(tmp, 'UNITS'), os.path.join(tmp, 'ws')
            os.makedirs(lib), os.makedirs(ws)
            shutil.copy(os.path.join(HERE_SAMPLES, 'VIEWS.TPU'), lib)
            shutil.copy(os.path.join(HERE_SAMPLES, 'OBJECTS.TPU'), lib)
            with open(os.path.join(ws, 'OBJECTS.TPU'), 'wb') as f:         # the project's own, different Objects
                f.write(open(os.path.join(HERE_SAMPLES, 'OBJECTS.TPU'), 'rb').read()[:3000])
            p = Provider(dirs=[ws, lib], tpl=os.path.join(T.D, 'TURBO.TPL'))
            text = render(p.get('views').tpu, 'x').text
            self.assertIn('Origin: TPoint;', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AnonymousEnum(unittest.TestCase):
    def test_inline_enumeration_keeps_its_members(self):
        from tp7sema import Provider
        from tp7stub import render
        p = Provider(dirs=[HERE_SAMPLES], tpl=os.path.join(T.D, 'TURBO.TPL'))
        text = render(p.get('views').tpu, 'x').text
        self.assertIn('Phase: (phFocused, phPreProcess, phPostProcess);', text)


class StringConstants(unittest.TestCase):
    def test_string_constants_are_pascal_literals(self):
        from tp7sema import Provider
        from tp7stub import render
        from tpu_dump import pas_literal
        p = Provider(dirs=[HERE_SAMPLES], tpl=os.path.join(T.D, 'TURBO.TPL'))
        text = render(p.get('views').tpu, 'x').text
        self.assertIn('  CFrame = #1#1#2#2#3;\n', text.replace('\r\n', '\n'))
        self.assertIn('  CGrayWindow = #24#25#26#27#28#29#30#31;', text)
        self.assertEqual(pas_literal("it's\r\nok"), "'it''s'#13#10'ok'")
        self.assertEqual(pas_literal(''), "''")


class SamplesUnit(unittest.TestCase):
    """samples/SAMPLES.TPU is compiled from samples/SAMPLES.PAS with every kind of declaration."""
    @classmethod
    def setUpClass(cls):
        from tp7sema import Provider
        from tp7stub import render
        cls.tmp = tempfile.mkdtemp()                       # only the TPU: next to SAMPLES.PAS the source would win
        shutil.copy(os.path.join(HERE_SAMPLES, 'SAMPLES.TPU'), cls.tmp)
        cls.p = Provider(dirs=[cls.tmp], tpl=os.path.join(T.D, 'TURBO.TPL'))
        cls.text = render(cls.p.get('samples').tpu, 'x').text.replace('\r\n', '\n')

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def has(self, *lines):
        for x in lines:
            self.assertIn(x, self.text)

    def test_constants(self):
        self.has("  cChar = 'A';", '  cCtl = #13;', '  cBoolT = True;', '  cReal = 3.14159;',
                 "  cSetDigit = ['0'..'9'];", '  cSetSmall = [1, 3, 5..7];', '  cColor = clGreen;',
                 '  cDay = dFri;')

    def test_typed_constants_keep_their_values(self):
        self.has('  kInt: Integer = 5;', "  kStr: string[10] = 'abc';",
                 '  kTable2: array [0..1, 0..2] of Integer = ((1, 2, 3), (4, 5, 6));')

    def test_types(self):
        self.has('TColors = set of TColor;', "TLetter = 'A'..'Z';", 'TFileU = file;', 'TFileB = file of Byte;',
                 'TProcVar = procedure(var A1: Integer; A2: Word);', 'TMatrix = array [1..3, 1..3] of Real;')

    def test_absolute_variables_and_directives(self):
        self.has('absolute $B800:$0000;', 'gMonoSeg: Word absolute $0040:$0063;', '); interrupt;')

    def test_parameters(self):
        self.has('procedure POpen(const A: array of Integer; var B: array of Char);',
                 'procedure PUntyped(var Buf; Size: Word);')

    def test_private_sections_are_shown_in_the_stub_but_hidden_from_users(self):
        self.has('  private\n    Hidden: Integer;', '  public\n    Open2: Integer;')
        t = self.p.get('samples')
        names = set(t.exports['tsecret'].tfn().get_fields())
        self.assertIn('open1', names)
        self.assertNotIn('hidden', names)
        self.assertNotIn('internal', names)


if __name__ == '__main__':
    unittest.main()
