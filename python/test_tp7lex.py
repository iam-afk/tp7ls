#!/usr/bin/env python3
"""Tests for tp7lex.py.  Run: python3 test_tp7lex.py [DIR_WITH_SAMPLES]"""
import os, random, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp7lex import lex, significant, roundtrip_ok

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'


def kinds(src):
    return [(t.kind, t.text) for t in significant(lex(src))]


class Lexer(unittest.TestCase):
    def test_roundtrip_samples(self):
        names = [n for n in os.listdir(D) if n.upper().endswith('.PAS')]
        self.assertTrue(names)
        for n in names:
            with open(os.path.join(D, n), 'rb') as f:
                src = f.read().decode('cp866')
            toks = lex(src)
            self.assertEqual(''.join(t.text for t in toks), src, n)
            self.assertEqual([t for t in toks if t.kind == 'ERROR'], [], n)

    def test_roundtrip_random_garbage(self):
        rnd = random.Random(7)
        alphabet = "{}()*'#$@.:;,^<>=+-/ \t\r\n\x1aaZ09_\"!?\\%&~`|ёЖ"
        for _ in range(3000):
            s = ''.join(rnd.choice(alphabet) for _ in range(rnd.randint(0, 40)))
            self.assertTrue(roundtrip_ok(s), repr(s))

    def test_comments_do_not_nest_and_do_not_mix(self):
        self.assertEqual([t.kind for t in lex('{ { } x')], ['COMMENT', 'WS', 'IDENT', 'EOF'])
        self.assertEqual(kinds('{ (* } x'), [('IDENT', 'x')])
        self.assertEqual(kinds('(* { *) x'), [('IDENT', 'x')])
        self.assertEqual(kinds('(* } *) x'), [('IDENT', 'x')])

    def test_no_slash_slash_comments(self):
        self.assertEqual(kinds('a // b'), [('IDENT', 'a'), ('SYM', '/'), ('SYM', '/'), ('IDENT', 'b')])

    def test_directives(self):
        t = lex('{$IFDEF X}(*$I+*){ $notdirective}')
        self.assertEqual([x.kind for x in t if x.kind != 'EOF'], ['DIRECTIVE', 'DIRECTIVE', 'COMMENT'])
        t = lex('{$A+,B-,D+,E-}')
        self.assertEqual(t[0].kind, 'DIRECTIVE')

    def test_numbers(self):
        self.assertEqual(kinds('1..10'), [('INT', '1'), ('SYM', '..'), ('INT', '10')])
        self.assertEqual(kinds('1.5'), [('REAL', '1.5')])
        self.assertEqual(kinds('1.5e-3 2E+4 3e2'), [('REAL', '1.5e-3'), ('REAL', '2E+4'), ('REAL', '3e2')])
        self.assertEqual(kinds('$FF $0d'), [('HEX', '$FF'), ('HEX', '$0d')])
        self.assertEqual(kinds('a[1].x'), [('IDENT', 'a'), ('SYM', '['), ('INT', '1'), ('SYM', ']'),
                                           ('SYM', '.'), ('IDENT', 'x')])

    def test_strings(self):
        self.assertEqual(kinds("'it''s'"), [('STRING', "'it''s'")])
        self.assertEqual(kinds("''"), [('STRING', "''")])
        self.assertEqual(kinds("#39"), [('CHARCODE', '#39')])
        self.assertEqual(kinds("'a'#13#10'b'#$41"),
                         [('STRING', "'a'"), ('CHARCODE', '#13'), ('CHARCODE', '#10'),
                          ('STRING', "'b'"), ('CHARCODE', '#$41')])
        self.assertEqual(kinds("'ПРОГРАММА'"), [('STRING', "'ПРОГРАММА'")])
        t = lex("x := 'abc\nz")                       # a string cannot span lines
        self.assertEqual([x.kind for x in t][:5], ['IDENT', 'WS', 'SYM', 'WS', 'ERROR'])

    def test_symbols(self):
        self.assertEqual([x[1] for x in kinds(':= <= >= <> .. ^ @ (. .) : ;')],
                         [':=', '<=', '>=', '<>', '..', '^', '@', '(.', '.)', ':', ';'])
        self.assertEqual(kinds('a:=b'), [('IDENT', 'a'), ('SYM', ':='), ('IDENT', 'b')])
        self.assertEqual(kinds('(a)'), [('SYM', '('), ('IDENT', 'a'), ('SYM', ')')])
        self.assertEqual(kinds('(*)'), [('ERROR', '(*)')])   # "(*)" opens a comment that never closes

    def test_keywords_case_insensitive_and_directives_are_idents(self):
        self.assertEqual([k for k, _ in kinds('BEGIN Begin end String STRING')], ['KW'] * 5)
        self.assertEqual([k for k, _ in kinds('far near forward external absolute virtual interrupt')],
                         ['IDENT'] * 7)
        self.assertEqual(kinds('Nextchar'), [('IDENT', 'Nextchar')])         # spelling untouched

    def test_asm_labels(self):
        self.assertEqual(kinds('@@loop: jmp @@loop'),
                         [('ASMLABEL', '@@loop'), ('SYM', ':'), ('IDENT', 'jmp'), ('ASMLABEL', '@@loop')])
        self.assertEqual(kinds('@x'), [('SYM', '@'), ('IDENT', 'x')])

    def test_errors_are_tokens(self):
        self.assertEqual([k for k, _ in kinds('a " b ! c')], ['IDENT', 'ERROR', 'IDENT', 'ERROR', 'IDENT'])
        self.assertEqual(kinds('{never closed'), [('ERROR', '{never closed')])
        self.assertEqual(kinds('$'), [('ERROR', '$')])

    def test_newlines_and_positions(self):
        src = 'a\r\nb\rc\nd {x\ny} e'
        t = {x.text: x for x in lex(src) if x.kind == 'IDENT'}
        self.assertEqual([(t[k].line, t[k].col) for k in 'abcde'],
                         [(1, 1), (2, 1), (3, 1), (4, 1), (5, 4)])
        self.assertEqual(lex(src)[-1].line, 5)

    def test_ctrl_z(self):
        t = lex('end.\r\n\x1a')
        self.assertEqual([x.kind for x in t], ['KW', 'SYM', 'NL', 'CTRLZ', 'EOF'])
        t = lex('a\x1ab')                                    # in the middle it is just garbage
        self.assertEqual([x.kind for x in t], ['IDENT', 'ERROR', 'IDENT', 'EOF'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
