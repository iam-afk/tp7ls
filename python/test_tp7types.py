#!/usr/bin/env python3
"""Tests of the type rules (tp7types): samples/TYPES_BAD.PAS holds one error per marked line, samples/TYPES_GOOD.PAS
holds valid Turbo Pascal that must not be reported.  Run: python3 test_tp7types.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp7parse import parse                                                # noqa: E402
from tp7sema import Provider, Binder                                      # noqa: E402
from tp7types import check_types, assign_error, var_param_error, show, BYTE, INTEGER, WORD, REAL, STRING, CHAR, \
    BOOLEAN, UNKNOWN, NIL, POINTER, int_const, Ty                         # noqa: E402
import test_tp7lsp as T                                                   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, 'samples')


def problems(path, extra_dirs=()):
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    prov = Provider([os.path.dirname(path)] + list(extra_dirs), os.path.join(T.D, 'TURBO.TPL'))
    res = parse(src, include=prov.include_resolver(path), path=path)
    b = Binder(res, prov)
    b.run()
    out = []
    check_types(res, b, prov, lambda t, m: out.append((t.line, m)))
    return src.split('\n'), out


class Rules(unittest.TestCase):
    def test_assignment_compatibility(self):
        ok = [(INTEGER, WORD), (INTEGER, int_const(5)), (REAL, INTEGER), (STRING, CHAR), (CHAR, Ty('char', None, value=65, lo=65, hi=65)),
              (POINTER, NIL), (UNKNOWN, STRING), (INTEGER, UNKNOWN), (BOOLEAN, BOOLEAN)]
        for d, s in ok:
            self.assertIsNone(assign_error(d, s), (d, s))
        bad = [(INTEGER, REAL), (INTEGER, STRING), (STRING, INTEGER), (BOOLEAN, INTEGER), (CHAR, INTEGER), (BYTE, int_const(300)),
               (WORD, int_const(-1)), (BYTE, int_const(-1))]
        for d, s in bad:
            self.assertIsNotNone(assign_error(d, s), (d, s))
        self.assertIn('out of range', assign_error(BYTE, int_const(256)))

    def test_var_parameters_need_the_same_type(self):
        self.assertIsNone(var_param_error(INTEGER, INTEGER))
        self.assertIsNotNone(var_param_error(INTEGER, WORD))
        self.assertIsNotNone(var_param_error(REAL, INTEGER))
        self.assertIsNone(var_param_error(UNKNOWN, WORD))

    def test_messages_name_the_types(self):
        self.assertEqual(show(INTEGER), 'Integer')
        self.assertEqual(show(int_const(3)), 'integer constant')
        self.assertEqual(show(Ty('pointer', None, _target=INTEGER)), '^Integer')


class Results(unittest.TestCase):
    def test_integer_operations_give_the_common_type(self):
        from tp7types import common_int, LONGINT, SHORTINT
        self.assertIs(common_int(INTEGER, BYTE), INTEGER)
        self.assertIs(common_int(INTEGER, WORD), LONGINT)
        self.assertIs(common_int(WORD, int_const(1)), WORD)
        self.assertIs(common_int(INTEGER, int_const(1)), INTEGER)
        self.assertIs(common_int(WORD, int_const(-1)), LONGINT)
        self.assertIs(common_int(BYTE, int_const(300)), INTEGER)
        for a, b in ((BYTE, BYTE), (SHORTINT, int_const(1)), (INTEGER, Ty('int', None, lo=1, hi=10)),
                     (INTEGER, Ty('int', None))):
            t = common_int(a, b)
            self.assertTrue(t.kind == 'int' and t.name is None and t.value is None, (a, b, t))

    def test_type_text(self):
        from tp7types import type_text
        self.assertEqual(type_text(Ty('array', None, elem=CHAR, index=[Ty('int', None, lo=0, hi=9)])), 'array [0..9] of Char')
        self.assertEqual(type_text(Ty('array', None, elem=INTEGER, index=[], open=True)), 'array of Integer')
        self.assertEqual(type_text(Ty('string', None, maxlen=10)), 'string[10]')
        self.assertEqual(type_text(Ty('pointer', None, _target=Ty('string', None, maxlen=5))), '^string[5]')
        self.assertEqual(type_text(Ty('set', None, elem=CHAR)), 'set of Char')
        self.assertEqual(type_text(Ty('int', None)), 'integer')


class Files(unittest.TestCase):
    def test_valid_code_is_not_reported(self):
        _, out = problems(os.path.join(SAMPLES, 'TYPES_GOOD.PAS'))
        self.assertEqual(out, [])

    def test_each_error_of_the_bad_file_is_found(self):
        lines, out = problems(os.path.join(SAMPLES, 'TYPES_BAD.PAS'))
        want = {}
        for i, l in enumerate(lines, 1):
            if '{' in l and l.split('{', 1)[1].strip()[:1].isdigit() and 'ok' not in l:
                want[i] = l
        got = {}
        for ln, m in out:
            got.setdefault(ln, []).append(m)
        missing = [i for i in want if i not in got and '?' not in want[i]]
        self.assertEqual(missing, [], [want[i] for i in missing])
        extra = [ln for ln in got if ln not in want]
        self.assertEqual(extra, [], [(ln, got[ln]) for ln in extra])

    def test_wording(self):
        _, out = problems(os.path.join(SAMPLES, 'TYPES_BAD.PAS'))
        text = '\n'.join(m for _, m in out)
        for frag in ('cannot assign string constant to Integer', 'constant 300 is out of range for Byte (0..255)',
                     "cannot assign to the constant 'Max'", 'Boolean expression expected, found Integer',
                     "too many arguments in the call of 'Take'", 'not enough arguments in the call of',
                     'a variable is required for a var parameter', 'must be ordinal', "operator '+' cannot be applied"):
            self.assertIn(frag, text)

    def test_more_valid_code_with_units_from_tpu(self):
        _, out = problems(os.path.join(SAMPLES, 'TYPES_GOOD2.PAS'), [T.D])
        self.assertEqual(out, [])

    def test_calls_of_routines_that_come_from_a_tpu(self):
        _, out = problems(os.path.join(SAMPLES, 'TYPES_NEG.PAS'), [T.D])
        got = {ln: m for ln, m in out}
        self.assertIn("argument 3 of 'Line': cannot pass Char to Integer", got[5])
        self.assertIn("not enough arguments in the call of 'Circle'", got[6])
        self.assertIn("argument 1 of 'SetColor'", got[7])
        self.assertEqual(len([1 for ln, _ in out if ln == 10]), 4)          # GetDate(var Word x4) given Integers
        self.assertIn('SearchRec is required, not DateTime', got[11])

    def test_real_programs_are_not_reported(self):
        up = T.D
        for name in ('WINXP.PAS', 'POLSK.PAS', 'TEST.PAS', 'option.pas'):
            p = os.path.join(up, name)
            if os.path.exists(p):
                self.assertEqual(problems(p)[1], [], name)


class Server(T.Base):
    def diags(self, c, text, name='t.pas'):
        u = c.open(os.path.join(self.ws, name), text)
        return c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)['params']['diagnostics']

    SRC = 'program t;\nvar i: Integer; s: string;\nbegin\n  i := s;\n  if i then i := 1;\nend.\n'

    def test_type_errors_are_published_as_errors(self):
        d = self.diags(self.start(), self.SRC)
        msgs = [(x['range']['start']['line'], x['severity'], x['message']) for x in d]
        self.assertIn((3, 1, 'type mismatch: cannot assign string to Integer'), msgs)
        self.assertIn((4, 1, 'Boolean expression expected, found Integer'), msgs)

    def test_switch_off_by_option(self):
        c = self.start(init=False)
        c.initialize(self.ws, self.tp7, options={'typeDiagnostics': False})
        self.assertEqual([x for x in self.diags(c, self.SRC) if 'mismatch' in x['message'] or 'expected' in x['message']], [])

class Inlay(T.Base):
    SRC = ('program t;\nconst Max = 100; Ch = \'x\'; Name = \'hello\'; Big = 70000; Typed: Integer = 3;\n'
           'var w, h: Integer;\n'
           'procedure Box(Left, Top: Integer; Width: Word; const Title: string);\nbegin\nend;\n'
           'procedure Long;\nbegin\n  w := 1;\n  w := 2;\n  w := 3;\nend;\n'
           'begin\n  Box(1, 2, w, \'x\');\n  Box(w, h, 10, Name);\nend.\n')

    def hints(self, c, text=None, rng=None, name='h.pas'):
        u = c.open(os.path.join(self.ws, name), text or self.SRC)
        c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        r = c.request('textDocument/inlayHint', {'textDocument': {'uri': u}, 'range': rng or
                      {'start': {'line': 0, 'character': 0}, 'end': {'line': 100, 'character': 0}}})
        return r['result']

    def test_parameter_names_in_calls(self):
        h = self.hints(self.start())
        labels = [(x['position']['line'], x['label']) for x in h if x.get('kind') == 2]
        for line in (13, 14):
            self.assertEqual([l for ln, l in labels if ln == line], ['Left:', 'Top:', 'Width:', 'Title:'])

    def test_a_name_the_same_as_the_parameter_gets_no_hint(self):
        text = 'program t;\nvar Left, Top: Integer;\nprocedure Go(Left, Top: Integer; N: Word);\nbegin\nend;\nbegin\n  Go(Left, Top, 5);\nend.\n'
        labels = [x['label'] for x in self.hints(self.start(), text, name='same.pas') if x.get('kind') == 2]
        self.assertEqual(labels, ['N:'])

    def test_constants_show_their_type(self):
        h = self.hints(self.start())
        got = {x['position']['character']: x['label'] for x in h if x['position']['line'] == 1 and x.get('kind') == 1}
        self.assertEqual(sorted(got.values()), [': Char', ': Integer', ': Longint', ': string[5]'])

    def test_end_label_only_for_long_routines(self):
        h = self.hints(self.start(), )
        ends = [x for x in h if 'kind' not in x]
        self.assertEqual(ends, [])
        c = self.start()
        body = ''.join('  w := %d;\n' % i for i in range(30))
        text = 'program t;\nvar w: Integer;\nprocedure Big;\nbegin\n' + body + 'end;\nbegin\nend.\n'
        ends = [x for x in self.hints(c, text, name='h2.pas') if 'kind' not in x]
        self.assertEqual([x['label'] for x in ends], [' { Big }'])
        self.assertEqual(ends[0]['position']['line'], 34)

    def test_range_limits_the_answer(self):
        c = self.start()
        h = self.hints(c, rng={'start': {'line': 14, 'character': 0}, 'end': {'line': 14, 'character': 5}}, name='h3.pas')
        self.assertTrue(h and all(x['position']['line'] == 14 for x in h))

    def test_options_switch_hints_off(self):
        c = self.start(init=False)
        c.initialize(self.ws, self.tp7, options={'inlayHints': {'parameters': False, 'constants': False, 'endLabels': 0}})
        self.assertEqual(self.hints(c, name='h4.pas'), [])

    def test_capability_is_announced(self):
        r = self.start(init=False).initialize(self.ws, self.tp7)
        self.assertTrue(r['result']['capabilities']['inlayHintProvider'])


if __name__ == '__main__':
    unittest.main()
