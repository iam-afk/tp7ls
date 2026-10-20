#!/usr/bin/env python3
"""Tests for tp7fmt.py.  Run: python3 test_tp7fmt.py [DIR_WITH_SAMPLES]
The directory must contain polsk.pas/polsk_formatted.pas, option.pas/option_formatted.pas, TEST.PAS (cp866)."""
import os, random, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp7fmt import format_source, FormatError, wrap_line, MAX_WIDTH, TP_LINE_LIMIT
from tp7lex import lex, significant
from tp7parse import parse

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'


def rd(name):
    with open(os.path.join(D, name), 'rb') as f:
        return f.read().decode('cp866')


def sig_texts(src):
    return [t.text for t in significant(lex(src))]


def comments(src):
    return sorted(t.text for t in lex(src) if t.kind in ('COMMENT', 'DIRECTIVE'))


def fmt_body(body, decls=''):
    """format a one-routine program and return only the lines of the statement part"""
    out = format_source('program t;\n%s\nbegin\n%s\nend.\n' % (decls, body))
    lines = out.split('\n')
    i = lines.index('begin')
    return '\n'.join(lines[i + 1:-2]) if lines[-1] == '' else '\n'.join(lines[i + 1:-1])


class Golden(unittest.TestCase):
    def test_reference_pairs_are_reproduced_exactly(self):
        for src, ref in (('polsk.pas', 'polsk_formatted.pas'), ('option.pas', 'option_formatted.pas')):
            self.assertEqual(format_source(rd(src)), rd(ref), src)

    def test_idempotent_on_references_and_on_test_pas(self):
        for name in ('polsk.pas', 'option.pas', 'TEST.PAS'):
            once = format_source(rd(name))
            self.assertEqual(format_source(once), once, name)

    def test_semicolon_before_until_is_the_only_added_token(self):
        src = rd('option.pas')
        a, b = sig_texts(src), sig_texts(format_source(src))
        self.assertEqual(len(b) - len(a), 1)
        j, added = 0, []
        for y in b:                                      # a must be a subsequence of b; the leftovers are the additions
            if j < len(a) and a[j] == y:
                j += 1
            else:
                added.append(y)
        self.assertEqual((j, added), (len(a), [';']))

    def test_formatted_output_reparses_cleanly_with_the_same_tree(self):
        for name in ('polsk.pas', 'option.pas', 'TEST.PAS'):
            src = rd(name)
            out = format_source(src)
            r1, r2 = parse(src), parse(out)
            self.assertEqual(r2.diags, [], name)
            k1 = [n.kind for n in r1.tree.walk() if n.kind != 'Empty']
            k2 = [n.kind for n in r2.tree.walk() if n.kind != 'Empty']
            self.assertEqual(k1, k2, name)

    def test_whitespace_mutations_do_not_change_the_result(self):
        rnd = random.Random(5)
        for name in ('polsk.pas', 'TEST.PAS'):
            src = rd(name)
            want = format_source(src)
            for _ in range(15):
                out = []
                for t in lex(src):
                    if t.kind == 'WS':
                        out.append(rnd.choice([' ', '  ', '\t', ' ']))
                    elif t.kind == 'NL':
                        out.append(rnd.choice(['\n', '\r\n', ' ', '\n']))
                    else:
                        out.append(t.text)
                mutated = ''.join(out)
                # keep tokens apart: two significant tokens must not glue together
                if sig_texts(mutated) != sig_texts(src):
                    continue
                self.assertEqual(format_source(mutated).replace('\r\n', '\n').rstrip('\n'),
                                 want.replace('\r\n', '\n').rstrip('\n'), name)


class Layout(unittest.TestCase):
    def test_if_else_chain_and_dangling(self):
        self.assertEqual(fmt_body('if a then x:=1 else if b then x:=2 else x:=3'),
                         '  if a then\n    x := 1\n  else if b then\n    x := 2\n  else\n    x := 3;')

    def test_compound_bodies(self):
        self.assertEqual(fmt_body('while a do begin x:=1; y:=2 end'),
                         '  while a do\n  begin\n    x := 1;\n    y := 2;\n  end;')
        self.assertEqual(fmt_body('for i:=1 to 3 do x:=x+i'), '  for i := 1 to 3 do\n    x := x + i;')
        self.assertEqual(fmt_body('with p^ do begin a:=1 end'), '  with p^ do\n  begin\n    a := 1;\n  end;')

    def test_repeat_and_case(self):
        self.assertEqual(fmt_body('repeat x:=x+1 until x>3'), '  repeat\n    x := x + 1;\n  until x > 3;')
        self.assertEqual(fmt_body('case c of 1,2:x:=1; 3..5:begin x:=2 end; 7:; else x:=0 end'),
                         '  case c of\n    1, 2: x := 1;\n    3..5: begin\n      x := 2;\n    end;\n    7: ;\n    else x := 0;\n  end;')

    def test_case_branch_with_structured_statement_and_multi_else(self):
        self.assertEqual(fmt_body('case c of 1: if a then x:=1 else x:=2; else x:=0; y:=0 end'),
                         '  case c of\n    1:\n      if a then\n        x := 1\n      else\n        x := 2;\n    else\n      x := 0;\n      y := 0;\n  end;')

    def test_expressions(self):
        self.assertEqual(fmt_body("x:=-a*2+b div 3; y:=not(a)or b; s:='a'+#13#10'b'; w:=@p; z:=[1,3..5,c]; q:=a[i,j].f^.n"),
                         "  x := -a * 2 + b div 3;\n  y := not (a) or b;\n  s := 'a' + #13#10'b';\n  w := @p;\n"
                         "  z := [1, 3..5, c];\n  q := a[i, j].f^.n;")
        self.assertEqual(fmt_body('Writeln(x:8:2,y)'), '  Writeln(x:8:2, y);')

    def test_missing_last_semicolon_and_stray_semicolons(self):
        self.assertEqual(fmt_body(';;x:=1;;;y:=2'), '  x := 1;\n  y := 2;')

    def test_labels_and_goto(self):
        out = format_source('program t;\nlabel 1,Done;\nbegin\n1: x:=1; goto Done; Done: end.')
        self.assertIn('label\n  1, Done;', out)
        self.assertIn('\n1:\n  x := 1;\n', out)                 # a label: alone on its line, two columns left of the code

    def test_label_on_its_own_line_two_columns_left(self):
        src = 'label\r\n  m;\r\nbegin\r\n  goto m;\r\nm:\r\n  exit;\r\nend.\r\n'
        out = format_source(src)
        self.assertEqual(out, 'label\r\n  m;\r\n\r\nbegin\r\n  goto m;\r\nm:\r\n  exit;\r\nend.\r\n')
        self.assertEqual(format_source(out), out)

    def test_label_in_nested_blocks_and_with_comments(self):
        out = format_source('begin\n  if a then begin\n  q: x := 1;\n  m: while b do y := 2;\n  end;\n  { c } 2: { d } z := 3;\nend.\n')
        self.assertEqual(out, 'begin\n  if a then\n  begin\n  q:\n    x := 1;\n  m:\n    while b do\n      y := 2;\n  end;\n'
                              '  { c }\n2: { d }\n  z := 3;\nend.\n')
        self.assertEqual(format_source(out), out)

    def test_label_before_end_or_semicolon(self):
        out = format_source('begin\n  repeat\n  L: Inc(i);\n  until i > 3;\n  M: ;\nend.\n')
        self.assertEqual(out, 'begin\n  repeat\n  L:\n    Inc(i);\n  until i > 3;\nM:;\nend.\n')

    def test_declarations(self):
        src = '''program t;
type A=1..10;B=(Red,Green);C=array[1..3,B]of ^A;D=record x,y:integer;case tag:byte of 0:(p:word);1:(q:char;r:string[3]) end;
E=array[1..2]of record f:integer end;F=set of B;G=file of A;H=function(a:integer;var b:real):boolean;
const N=10;S='it''s';T:array[0..2]of byte=(1,2,3);R:record x,y:integer end=(x:1;y:2);
var a,b:integer;Scr:array[0..1999]of word absolute $B800:0;
begin end.'''
        out = format_source(src)
        for want in ('  A = 1..10;', '  B = (Red, Green);', '  C = array [1..3, B] of ^A;', '  D = record',
                     '    x, y: integer;', '    case tag: byte of', '      0: (p: word);', '      1: (', '        q: char;', '        r: string[3];', '      );',
                     '  end;', '  E = array [1..2] of record', '    f: integer;', '  F = set of B;', '  G = file of A;',
                     '  H = function(a: integer; var b: real): boolean;', '  N = 10;', "  S = 'it''s';",
                     '  T: array [0..2] of byte = (1, 2, 3);', '  R: record', '  end = (x: 1; y: 2);',
                     '  a, b: integer;', '  Scr: array [0..1999] of word absolute $B800:0;'):
            self.assertIn(want, out.split('\n'), want)

    def test_routines_and_directives(self):
        src = '''unit u;
interface
procedure A(x:integer;var y,z:real;const s:string);far;
function C(n:word):longint;external;
implementation
procedure A;
 procedure Inner;begin end;
begin Inner end;
procedure D;assembler;
asm
   mov ax,1   ;  keep   me
@@l: dec ax
     jnz @@l
end;
function C;external 'foo' name 'bar';
end.'''
        out = format_source(src)
        self.assertIn('procedure A(x: integer; var y, z: real; const s: string); far;', out)
        self.assertIn('function C(n: word): longint; external;', out)
        self.assertIn('procedure D; assembler;\nasm\n   mov ax,1   ;  keep   me\n@@l: dec ax\n     jnz @@l\nend;', out)
        self.assertEqual(format_source(out), out)

    def test_unit_with_init_section(self):
        out = format_source('unit u;interface implementation var x:integer;begin x:=1 end.')
        self.assertEqual(out, 'unit u;\n\ninterface\n\nimplementation\n\nvar\n  x: integer;\n\nbegin\n  x := 1;\nend.')


class Trivia(unittest.TestCase):
    def test_trailing_and_own_line_comments(self):
        body = 'x := 1; { note }\n{ own line }\ny := 2;\n{ before end }'
        self.assertEqual(fmt_body(body), '  x := 1; { note }\n  { own line }\n  y := 2;\n{ before end }')

    def test_blank_lines_between_statements_are_kept_once(self):
        self.assertEqual(fmt_body('x:=1;\n\n\n\ny:=2;'), '  x := 1;\n\n  y := 2;')
        self.assertEqual(fmt_body('\n\nx:=1;\n\n'), '  x := 1;')

    def test_inline_comments_survive(self):
        out = fmt_body('x := {c1} 1 + {c2} 2 ; if a {c3} then y := 1')
        for c in ('{c1}', '{c2}', '{c3}'):
            self.assertIn(c, out)

    def test_multiline_comment_is_kept_verbatim(self):
        out = fmt_body('{ one\n   two\n three }\nx := 1')
        self.assertIn('  { one\n   two\n three }\n  x := 1;', out)

    def test_every_comment_in_every_sample_survives(self):
        for name in ('polsk.pas', 'option.pas', 'TEST.PAS'):
            src = rd(name)
            self.assertEqual(comments(format_source(src)), comments(src), name)

    def test_directive_hugs_previous_item(self):
        out = format_source('unit u;\ninterface\nimplementation\nfunction F(n:word):word;external;\n{$L f.obj}\nprocedure P;begin end;\nend.')
        self.assertIn('function F(n: word): word; external;\n{$L f.obj}\n\nprocedure P;', out)


class EmptyStatements(unittest.TestCase):
    """`if c then;` is not the same program as `if c then` + the next statement: the empty statement stays."""

    def test_empty_body_keeps_its_semicolon(self):
        out = format_source('program a;\nbegin\n  if x then;\n  while y do;\n  for i := 1 to 2 do;\n  with q do;\n'
                            '  if x then else;\nend.\n')
        self.assertIn('  if x then;\n  while y do;\n  for i := 1 to 2 do;\n  with q do;\n  if x then\n  else;\n', out)
        self.assertEqual(format_source(out), out)

    def test_comment_after_the_empty_statement(self):
        out = format_source('program a;\nbegin\n  if z then ; { c }\nend.\n')
        self.assertIn('  if z then; { c }\n', out)

    def test_empty_then_before_else_is_legal(self):
        out = format_source('program a;\nbegin\n  if x then else y;\nend.\n')
        self.assertIn('  if x then\n  else\n    y;\n', out)
        self.assertEqual(format_source(out), out)

    def test_inactive_text_has_no_trailing_blanks(self):
        out = format_source('program a;\nvar x: integer;\n  {$IFDEF DEBUG}\n  y: integer;   \n  {$ENDIF}\nbegin\nend.\n')
        self.assertTrue(all(ln == ln.rstrip() for ln in out.split('\n')), out)
        self.assertIn('  y: integer;\n{$ENDIF}\n', out)
        self.assertEqual(format_source(out), out)


class Conditional(unittest.TestCase):
    SRC = '''program t;
var a: integer;
{$IFDEF DEBUG}
var   dbg  :  integer;   { not formatted }
{$ELSE}
var rel:integer;
{$ENDIF}
begin
a:=1;
end.
'''

    def test_inactive_branch_is_verbatim(self):
        out = format_source(self.SRC)
        self.assertIn('  a: integer;\n\n{$IFDEF DEBUG}\nvar   dbg  :  integer;   { not formatted }\n{$ELSE}\nvar\n  rel: integer;\n{$ENDIF}\n\nbegin', out)
        out2 = format_source(self.SRC, defines=['DEBUG'])
        self.assertIn('{$IFDEF DEBUG}\nvar\n  dbg: integer; { not formatted }\n{$ELSE}\nvar rel:integer;\n{$ENDIF}\n\nbegin', out2)

    def test_idempotent_for_both_configurations(self):
        for d in (None, ['DEBUG']):
            once = format_source(self.SRC, defines=d)
            self.assertEqual(format_source(once, defines=d), once)

    def test_unbalanced_begin_end_in_branches(self):
        src = 'program t;\nbegin\n{$IFDEF A}\nif x then begin\n{$ELSE}\nif y then begin\n{$ENDIF}\nz:=1;\nend;\nend.\n'
        out = format_source(src)
        self.assertIn('{$IFDEF A}\nif x then begin\n{$ELSE}\n  if y then\n  begin\n{$ENDIF}\n    z := 1;', out)


class Wrapping(unittest.TestCase):
    A, B, C = 'FirstVariable', 'SecondVariable', 'ThirdVariable'

    def prog(self, body, decls=''):
        return 'program p;\n%sbegin\n%s\nend.\n' % (decls, body)

    def fmt(self, src, **kw):
        w = []
        out = format_source(src, warnings=w, **kw)
        return out, w

    def test_call_arguments_wrap_at_commas(self):
        src = self.prog("WriteLn('first argument ', %s, ' second argument ', %s, ' third argument ', %s, ' fourth ', %s);"
                        % (self.A, self.B, self.C, self.A))
        out, w = self.fmt(src)
        lines = out.split('\n')
        self.assertEqual(w, [])
        self.assertTrue(all(len(x) <= MAX_WIDTH for x in lines), [len(x) for x in lines])
        b = lines.index('begin')
        self.assertTrue(lines[b + 1].endswith(','))
        self.assertTrue(lines[b + 2].startswith('      '))             # +4 from the statement (indent 2)
        self.assertFalse(lines[b + 2].startswith('       '))

    def test_if_condition_breaks_before_and_or_at_the_shallowest_level(self):
        cond = ' and '.join('(%s > %d)' % (self.A, i) for i in range(1, 8)) + ' or (%s = 0)' % self.B
        out, _ = self.fmt(self.prog('if %s then Halt;' % cond))
        lines = out.split('\n')
        self.assertTrue(all(len(x) <= MAX_WIDTH for x in lines))
        b = lines.index('begin')
        self.assertTrue(lines[b + 2].lstrip().startswith(('and ', 'or ')), lines[b + 2])
        self.assertEqual(sum(1 for x in lines if x.strip() == 'Halt;'), 1)           # the body stays on its own line
        self.assertTrue(any(x.endswith(' then') for x in lines))

    def test_declaration_lists_and_uses(self):
        names = ', '.join('Variable%d' % i for i in range(1, 16))
        out, _ = self.fmt('program p;\nuses Crt, Dos;\nvar %s: Integer;\nbegin\nend.\n' % names)
        lines = out.split('\n')
        self.assertTrue(all(len(x) <= MAX_WIDTH for x in lines))
        self.assertTrue(any(x.endswith('Integer;') for x in lines))
        self.assertTrue(any(x.startswith('      Variable') for x in lines))          # `var` items are indented by 2

    def test_case_label_line(self):
        body = ('case %s of\n1, 2, 3: PutImage(11 + (%s - 1) * 32, 11 + (%s - 1) * 32, pic[pole[%s, %s]], NormalPut, 1, 2, 3);\n'
                'end;' % (self.A, self.B, self.C, self.A, self.B))
        out, _ = self.fmt(self.prog(body))
        lines = out.split('\n')
        self.assertTrue(all(len(x) <= MAX_WIDTH for x in lines))
        self.assertTrue(any(x.startswith('        ') and not x.startswith('         ') for x in lines))   # label indent 4 + 4

    def test_assignment_prefers_operators_over_the_assign(self):
        expr = ' + '.join('%s * %s' % (self.A, self.B) for _ in range(6))
        out, _ = self.fmt(self.prog('Result := %s;' % expr))
        lines = out.split('\n')
        b = lines.index('begin')
        self.assertTrue(lines[b + 1].startswith('  Result := '))
        self.assertTrue(lines[b + 2].lstrip().startswith('+ '))

    def test_tokens_and_comments_survive_and_it_is_idempotent(self):
        body = ("WriteLn('first argument ', %s, ' second argument ', %s, { keep me } ' third argument ', %s, ' x ', %s); "
                "{ trailing }" % (self.A, self.B, self.C, self.A))
        out, _ = self.fmt(self.prog(body))
        flat, _ = self.fmt(self.prog(body), width=None)
        self.assertEqual(''.join(out.split()), ''.join(flat.split()))
        self.assertEqual(format_source(out), out)
        self.assertIn('{ keep me }', out)
        self.assertIn('{ trailing }', out)

    def test_unbreakable_line_is_left_alone_and_reported(self):
        out, w = self.fmt(self.prog("Msg := '%s';" % ('x' * 150)))
        self.assertIn("'" + 'x' * 150 + "'", out)
        self.assertEqual(out.count('\n'), 5)                          # not even broken after :=
        self.assertEqual(len(w), 1)
        self.assertIn('line 4', w[0])

    def test_strings_with_commas_and_braces_are_not_cut(self):
        s = "'a, b, {c}, (d, e), ''q, r'' ' + '%s'" % ('y' * 60)
        out, _ = self.fmt(self.prog('Msg := %s + %s;' % (s, s)))
        self.assertEqual(out.count("'a, b, {c}, (d, e), ''q, r'' '"), 2)

    def test_comments_and_short_lines_are_untouched(self):
        long_comment = '{ ' + 'word ' * 40 + '}'
        out, _ = self.fmt(self.prog('%s\nWriteLn;' % long_comment))
        self.assertIn('  ' + long_comment, out.split('\n'))
        self.assertEqual(format_source(self.prog('WriteLn(1, 2);')), 'program p;\n\nbegin\n  WriteLn(1, 2);\nend.\n')

    def test_wrap_line_directly(self):
        line = '  ' + ', '.join(['alpha'] * 40) + ';'
        parts = wrap_line(line, 60)
        self.assertTrue(all(len(x) <= 60 for x in parts))
        self.assertEqual(' '.join(x.strip() for x in parts), line.strip())
        self.assertEqual(wrap_line('  short;', 60), ['  short;'])
        self.assertEqual(wrap_line('x' * 100, 60), ['x' * 100])

    def test_the_reference_files_are_not_touched(self):
        for name in ('option_formatted.pas', 'polsk_formatted.pas'):
            src = rd(name)
            self.assertLessEqual(max(len(x) for x in src.split('\n')), MAX_WIDTH)

    def test_real_sample_with_a_narrow_width(self):
        src = rd('option.pas')
        wide = format_source(src, width=None)
        narrow = format_source(src, width=70)
        self.assertEqual(''.join(narrow.split()), ''.join(wide.split()))
        self.assertEqual(format_source(narrow, width=70), narrow)


class ElseIfAndVariants(unittest.TestCase):
    def test_else_if_chain_is_flat(self):
        self.assertEqual(
            fmt_body('if a then x:=1 else if b then x:=2 else if c then begin x:=3 end else x:=4'),
            '  if a then\n    x := 1\n  else if b then\n    x := 2\n  else if c then\n  begin\n    x := 3;\n  end\n'
            '  else\n    x := 4;')

    def test_else_if_without_final_else_and_if_inside_compound_else(self):
        self.assertEqual(fmt_body('if a then x:=1 else if b then x:=2'),
                         '  if a then\n    x := 1\n  else if b then\n    x := 2;')
        self.assertEqual(fmt_body('if a then x:=1 else begin if b then x:=2 end'),
                         '  if a then\n    x := 1\n  else\n  begin\n    if b then\n      x := 2;\n  end;')

    def test_else_if_in_a_case_branch(self):
        self.assertEqual(fmt_body('case c of 1: if a then x:=1 else if b then x:=2 else x:=3 end'),
                         '  case c of\n    1:\n      if a then\n        x := 1\n      else if b then\n        x := 2\n'
                         '      else\n        x := 3;\n  end;')

    def test_comments_around_else_if_survive(self):
        out = fmt_body('if a then x:=1 { one }\n{ two }\nelse { three }\n{ four }\nif b then x:=2')
        for c in ('{ one }', '{ two }', '{ three }', '{ four }'):
            self.assertIn(c, out)
        self.assertEqual(format_source('program p;\nbegin\n' + out + '\nend.\n'),
                         'program p;\n\nbegin\n' + out + '\nend.\n')

    REC = ('program p;\ntype R = record a, b: Integer; case Tag: Byte of 0: (p: Word); 1: (q: Char; r: string[3]); '
           '2: (x: Integer; y: Integer;); 3: (n: record u, v: Integer end); 4: (case Sub: Boolean of True: (m: Byte; k: Byte); '
           'False: ()); 5: (); end;\nbegin\nend.\n')

    def test_every_variant_declaration_has_its_own_line(self):
        out = format_source(self.REC)
        self.assertEqual(out.split('\n')[2:30], [
            'type', '  R = record', '    a, b: Integer;', '    case Tag: Byte of', '      0: (p: Word);',
            '      1: (', '        q: Char;', '        r: string[3];', '      );',
            '      2: (', '        x: Integer;', '        y: Integer;', '      );',
            '      3: (', '        n: record', '          u, v: Integer;', '        end', '      );',
            '      4: (', '        case Sub: Boolean of', '          True: (', '            m: Byte;', '            k: Byte;',
            '          );', '          False: ();', '      );', '      5: ();', '  end;'])

    def test_variants_are_stable_and_keep_the_same_tokens(self):
        out = format_source(self.REC)
        self.assertEqual(format_source(out), out)
        self.assertFalse(parse(out).diags)
        a = [t for t in sig_texts(self.REC) if t != ';']
        b = [t for t in sig_texts(out) if t != ';']
        self.assertEqual(a, b)                                      # only semicolons may be added or dropped

    def test_semicolon_inside_a_variant_one_field_none_several_all(self):
        def fmt(v):
            return format_source('program p;\ntype R = record case Byte of %s end;\nbegin end.\n' % v)
        # several fields: ';' after every one of them, whatever the source had
        for v in ('0: (a: Byte; b: Byte);', '0: (a: Byte; b: Byte;);'):
            self.assertIn('      0: (\n        a: Byte;\n        b: Byte;\n      );\n', fmt(v))
        # one field: no ';' inside the parentheses, whatever the source had
        for v in ('0: (a: Byte);', '0: (a: Byte;);'):
            self.assertIn('      0: (a: Byte);\n', fmt(v))
        # one field that is a record: multi-line, still no ';' after it
        self.assertIn('      0: (\n        n: record\n          u: Byte;\n        end\n      );\n',
                      fmt('0: (n: record u: Byte end;);'))
        # no field at all
        self.assertIn('      0: ();\n', fmt('0: ();'))

    def test_comment_on_a_dropped_semicolon_is_kept(self):
        out = format_source('program p;\ntype R = record case Byte of 0: (z: Word; { c } ); 1: ({ d } w: Word); end;\n'
                            'begin end.\n')
        self.assertIn('      0: (z: Word { c });', out)
        self.assertIn('      1: ({ d } w: Word);', out)
        self.assertEqual(format_source(out), out)

    def test_comments_between_variant_fields_survive(self):
        src = ('program p;\ntype R = record case Byte of\n0: ( { first }\na: Byte; { after a }\n{ before b }\nb: Byte\n'
               '{ last } ); end;\nbegin end.\n')
        out = format_source(src)
        for c in ('{ first }', '{ after a }', '{ before b }', '{ last }'):
            self.assertIn(c, out)
        self.assertEqual(format_source(out), out)
        self.assertEqual(sorted(comments(src)), sorted(comments(out)))

    def test_plain_records_still_one_field_group_per_line(self):
        out = format_source('program p;\ntype R = record a, b: Integer; c: Byte; end;\nbegin end.\n')
        self.assertIn('    a, b: Integer;\n    c: Byte;\n  end;', out)


class Objects(unittest.TestCase):
    SRC = ('unit u;interface\ntype\n  PShape=^TShape;\n  TShape  =  object (TBase)\n    x,y:Integer;   { pos }\n  private\n   z:Byte;\n'
           '  public\n\n    constructor Init(AX,AY:Integer);\n    destructor Done;virtual;   { bye }\n    procedure Draw ;virtual;\n'
           '    function Area:Integer;far;\n  end;\n  TPt=record a,b:Integer;procedure Move(d:Integer);end;\n  TE=object end;\n'
           'implementation\nconstructor TShape.Init(AX,AY:Integer);\nbegin\ninherited Init(AX,AY);\n  inherited;\n'
           '  x:=inherited Area+1;\n  if x>0 then inherited Draw else inherited Done;\nend;\nend.\n')
    WANT = ('unit u;\n\ninterface\n\ntype\n  PShape = ^TShape;\n  TShape = object(TBase)\n    x, y: Integer; { pos }\n  private\n'
            '    z: Byte;\n  public\n    constructor Init(AX, AY: Integer);\n    destructor Done; virtual; { bye }\n'
            '    procedure Draw; virtual;\n    function Area: Integer; far;\n  end;\n  TPt = record\n    a, b: Integer;\n'
            '    procedure Move(d: Integer);\n  end;\n  TE = object\n  end;\n\nimplementation\n\n'
            'constructor TShape.Init(AX, AY: Integer);\nbegin\n  inherited Init(AX, AY);\n  inherited;\n  x := inherited Area + 1;\n'
            '  if x > 0 then\n    inherited Draw\n  else\n    inherited Done;\nend;\n\nend.\n')

    def test_layout(self):
        self.assertEqual(format_source(self.SRC), self.WANT)

    def test_idempotent(self):
        self.assertEqual(format_source(self.WANT), self.WANT)

    def test_section_markers_become_lower_case_when_normalising(self):
        out = format_source('program t;\ntype T = object\n  x: Integer;\n  PRIVATE\n  y: Byte;\nend;\nbegin end.\n', normalize=True)
        self.assertIn('\n  private\n', out)

    def test_comments_and_tokens_survive(self):
        out = format_source(self.SRC)
        self.assertEqual(comments(out), comments(self.SRC))
        self.assertEqual([t.lower() for t in sig_texts(out)], [t.lower() for t in sig_texts(self.SRC)])

    def test_object_inside_an_inactive_branch_is_copied(self):
        src = 'program t;\ntype\n  T = object\n    x: Integer;\n{$IFDEF NOPE}\n    y:integer;\n{$ENDIF}\n  end;\nbegin\nend.\n'
        out = format_source(src)                                # the text of the inactive branch is kept as it is
        self.assertIn('{$IFDEF NOPE}\n    y:integer;\n{$ENDIF}', out)
        self.assertIn('  T = object\n    x: Integer;', out)

    def test_lines_stay_in_the_limit(self):
        out = format_source('program t;\ntype T = object\n procedure P(' + '; '.join('a%d: Integer' % i for i in range(1, 20))
                            + ');\n end;\nbegin end.\n')
        self.assertTrue(all(len(x) <= TP_LINE_LIMIT for x in out.split('\n')))


class Refusals(unittest.TestCase):
    def test_syntax_errors_are_not_formatted(self):
        for bad in ('program t; begin x := ; end.', 'program t; begin if then x := 1; end.',
                    'program t; begin x := 1 end'):
            with self.assertRaises(FormatError):
                format_source(bad)

    def test_conditional_directive_inside_a_statement_is_refused(self):
        with self.assertRaises(FormatError):
            format_source('program t; begin x := {$IFDEF A}1{$ELSE}2{$ENDIF}; end.')


if __name__ == '__main__':
    unittest.main(verbosity=2)
