#!/usr/bin/env python3
"""Tests for tp7parse.py.  Run: python3 test_tp7parse.py [DIR_WITH_SAMPLES]"""
import os, random, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp7parse import parse, reconstruct, Node, fieldlist_of, routine_names

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'


def prog(body, decls=''):
    return 'program t;\n%s\nbegin\n%s\nend.\n' % (decls, body)


def stmt(body):
    """sexp of the statements of a one-block program"""
    r = parse(prog(body))
    assert not r.diags, [(t.line, m) for t, m in r.diags]
    return r.tree.first('Compound').first('StmtList')


def check_invariants(tc, src, defines=None):
    r = parse(src, defines)
    tc.assertEqual(reconstruct(r), src)
    tree_tokens = list(r.tree.tokens())
    tc.assertEqual([id(t) for t in tree_tokens], [id(t) for t in r.sig[:-1]])      # each token once, in order
    return r


class Samples(unittest.TestCase):
    def test_samples_parse_cleanly_and_losslessly(self):
        names = [n for n in os.listdir(D) if n.upper().endswith('.PAS')]
        self.assertTrue(names)
        for n in names:
            with open(os.path.join(D, n), 'rb') as f:
                src = f.read().decode('cp866')
            r = check_invariants(self, src)
            self.assertEqual([(t.line, m) for t, m in r.diags], [], n)

    def test_unit_structure_of_test_pas(self):
        with open(os.path.join(D, 'TEST.PAS'), 'rb') as f:
            r = parse(f.read().decode('cp866'))
        u = r.tree.first('Unit')
        self.assertEqual([k.kind for k in u.kids if isinstance(k, Node)], ['DeclName', 'Interface', 'Implementation', 'InitSection'])
        names = [n.kids[0].text for n in r.tree.nodes('DeclName')]
        for want in ('Ident', 'str_15', 'pZnach', 'tZnach', 'tNode', 'tMainVar', 'MainLex', 'cmProg'):
            self.assertIn(want, names)
        self.assertEqual([n.text() for n in u.first('UsesClause').nodes('Name')],
                         ['vesa', 'dos', 'objects', 'crt', 'polsk', 'option'])


class Declarations(unittest.TestCase):
    def test_types(self):
        src = prog('', '''type
  Color = (Red, Green, Blue);
  Small = 1..10;  Neg = -5..5;  Ch = 'a'..'z';  Rng = Low..High;
  P = ^Rec;
  Rec = record
    a, b: integer;
    case tag: byte of
      0: (x: word);
      1: (y: array[0..3] of char; z: record q: longint end);
      2: ();
  end;
  Arr = array [1..3, Color] of packed record f: boolean end;
  S = set of Color;  F = file of Rec;  U = file;  Str = string[20];  Str2 = string;
  Fn = function(a: integer; var b: real): boolean;
  Pr = procedure;
  Alt = array(. 1 .. 3 .) of byte;
  Q = Crt.Foo;''')
        r = check_invariants(self, src)
        self.assertEqual(r.diags, [])
        kinds = [n.kind for n in r.tree.walk()]
        for k in ('EnumType', 'SubrangeType', 'PointerType', 'RecordType', 'VariantPart', 'Variant', 'ArrayType',
                  'PackedType', 'SetType', 'FileType', 'StringType', 'ProcType'):
            self.assertIn(k, kinds)
        self.assertEqual(len(r.tree.nodes('Variant')), 3)

    def test_subrange_count_is_exact(self):
        r = parse(prog('', 'type A = 1..10; B = -5..5; C = \'a\'..\'z\'; D = Low..High; E = array[0..3] of byte;'))
        self.assertEqual(len(r.tree.nodes('SubrangeType')), 5)

    def test_consts_and_typed_consts(self):
        src = prog('', '''const
  N = 10;  M = N * 2 + 1;  S = 'it''s' + #13#10;  H = $FF;  R = 1.5e3;
  T: integer = 5;
  A: array[0..2] of byte = (1, 2, 3);
  Rc: record x, y: integer end = (x: 1; y: 2);
  Mx: array[0..1, 0..1] of byte = ((1, 2), (3, 4));
  P: (boolean) = (true);
  E = (3 + 4) * 2;
  Names: array[1..2] of string[3] = ('abc', 'def');''')
        r = check_invariants(self, src)
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('Aggregate')), 6)     # A, Rc, Mx + its 2 rows, Names; '(true)' is no aggregate
        self.assertEqual(len(r.tree.nodes('ConstDecl')), 12)

    def test_aggregates_exact(self):
        r = parse(prog('', 'const A: array[0..1,0..1] of byte = ((1,2),(3,4)); B = (1+2)*3; C: record x:integer end = (x: 1);'))
        self.assertEqual(len(r.tree.nodes('Aggregate')), 4)      # outer, two rows, record
        self.assertEqual(r.diags, [])

    def test_var_with_absolute_and_labels(self):
        r = check_invariants(self, prog('1: x := 1; goto 1;', 'label 1, Done;\nvar x, y: integer; Scr: array[0..1999] of word absolute $B800:0;'))
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('Absolute')), 1)
        self.assertEqual(len(r.tree.nodes('Labeled')), 1)

    def test_routines_and_directives(self):
        src = '''unit u;
interface
procedure A(x: integer; var y, z: real; const s: string); far;
function B: integer;
function C(n: word): longint; external;
procedure D; interrupt;
procedure Beep; inline($B0/$07/$CD/$29);
implementation
procedure A; begin end;
function B; var q: integer; begin B := q end;
function C; external 'foo' name 'bar';
procedure D; assembler; asm mov ax, 1; @@l: dec ax; jnz @@l end;
procedure Fwd; forward;
procedure Fwd; begin end;
end.'''
        r = check_invariants(self, src)
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('Routine')), 11)
        self.assertEqual(len(r.tree.nodes('Asm')), 1)
        asm = r.tree.first('Asm')
        self.assertEqual(asm.text(), 'asm mov ax , 1 ; @@l : dec ax ; jnz @@l end')

    def test_nested_routines(self):
        r = check_invariants(self, prog('Outer(1)', 'procedure Outer(n: integer);\n  procedure Inner; begin end;\nbegin Inner end;'))
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('Routine')), 2)

    def test_object_type_is_parsed(self):
        src = prog('x := 1', 'type T = object\n x: integer;\n procedure P; virtual;\n end;\nvar x: integer;')
        r = check_invariants(self, src)
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('ObjectType')), 1)
        self.assertEqual(len(r.tree.nodes('Assign')), 1)
        obj = r.tree.first('ObjectType')
        fl = fieldlist_of(obj)
        self.assertEqual([n.kind for n in fl.kids if isinstance(n, Node)], ['FieldDecl', 'Routine'])


class Statements(unittest.TestCase):
    def test_dangling_else_binds_to_nearest_if(self):
        s = stmt('if a then if b then x := 1 else x := 2')
        outer = s.first('If')
        self.assertEqual(len([k for k in outer.kids if isinstance(k, Node) and k.kind == 'If']), 1)
        inner = [k for k in outer.kids if isinstance(k, Node) and k.kind == 'If'][0]
        self.assertTrue(any(getattr(k, 'text', '') == 'else' for k in inner.kids if not isinstance(k, Node)))
        self.assertFalse(any(getattr(k, 'text', '') == 'else' for k in outer.kids if not isinstance(k, Node)))

    def test_control_flow(self):
        s = stmt('''for i := 1 to 10 do s := s + i;
for i := 10 downto 1 do begin end;
while x < 3 do inc(x);
repeat dec(x); inc(y) until x = 0;
with p^, q do begin a := b end;
case c of
  1, 2: x := 1;
  3..5: begin x := 2 end;
  7: ;
  else x := 0; y := 0
end;
case c of 1: x := 1 end;
goto 5;''')
        kinds = [k.kind for k in s.kids if isinstance(k, Node)]
        self.assertEqual(kinds, ['For', 'For', 'While', 'Repeat', 'With', 'Case', 'Case', 'Goto'])
        c = s.nodes('Case')[0]
        self.assertEqual(len(c.nodes('CaseBranch')), 3)
        self.assertEqual(len(c.first('CaseElse').first('StmtList').nodes('Assign')), 2)

    def test_empty_statements_and_semicolons(self):
        s = stmt(';;x := 1;;')
        self.assertEqual(len(s.nodes('Assign')), 1)
        self.assertEqual(stmt('').kids, [])

    def test_calls_and_designators(self):
        s = stmt("Writeln('x = ', x:8:2, y:3); p^.next^[3].f := q(1)[2]; Crt.Delay(10);")
        self.assertEqual(len(s.nodes('Arg')), 3 + 1 + 1)
        a = s.nodes('Assign')[0]
        d = a.kids[0]
        self.assertEqual([k.kind for k in d.kids], ['Name', 'Deref', 'Field', 'Deref', 'Index', 'Field'])
        self.assertEqual(len(s.nodes('ProcCall')), 2)

    def test_expression_precedence(self):
        s = stmt('x := a + b * c - d')
        self.assertEqual(s.first('Assign').kids[2].sexp(),
                         '(Binary (Binary (Designator (Name a)) + (Binary (Designator (Name b)) * (Designator (Name c)))) - (Designator (Name d)))')
        s = stmt('x := not a and b or c = d')
        top = s.first('Assign').kids[2]
        self.assertEqual(top.kind, 'Binary')
        self.assertEqual(top.kids[1].text, '=')            # relational binds weakest
        s = stmt('x := -a * 2; y := @z; b := i in [1, 3..5, c]; s := \'a\' + #13#10\'b\'')
        self.assertEqual(len(s.nodes('SetCtor')), 1)
        self.assertEqual(len(s.nodes('StringLit')), 2)          # 'a'  and  #13#10'b' (one literal)
        self.assertEqual(s.nodes('StringLit')[1].text(), "#13 #10 'b'")

    def test_inline_asm_statement_is_raw(self):
        s = stmt('asm mov ax, 3; int $10 end; x := 1')
        self.assertEqual(len(s.nodes('Asm')), 1)
        self.assertEqual(len(s.nodes('Assign')), 1)


class Conditional(unittest.TestCase):
    SRC = '''program t;
{$IFDEF DEBUG}
var dbg: integer;
{$ELSE}
var rel: integer;
{$ENDIF}
begin
{$IFNDEF DEBUG}
  rel := 1;
{$ENDIF}
end.
'''

    def test_branch_selection_by_define(self):
        r = check_invariants(self, self.SRC)
        names = [n.kids[0].text for n in r.tree.nodes('DeclName')]
        self.assertEqual(names, ['t', 'rel'])
        r2 = check_invariants(self, self.SRC, defines=['DEBUG'])
        names = [n.kids[0].text for n in r2.tree.nodes('DeclName')]
        self.assertEqual(names, ['t', 'dbg'])
        self.assertEqual(len(r2.tree.nodes('Assign')), 0)

    def test_inactive_text_is_kept_as_trivia(self):
        r = parse(self.SRC)
        inactive = [t.text for t in r.tokens if not t.active]
        self.assertIn('dbg', inactive)
        self.assertNotIn('rel', inactive)
        # directives themselves are never lost
        self.assertEqual(sum(1 for t in r.tokens if t.kind == 'DIRECTIVE'), 5)

    def test_unbalanced_begin_end_across_branches_is_fine(self):
        src = '''program t;
procedure P;
begin
{$IFDEF A}
  if x then begin
{$ELSE}
  if y then begin
{$ENDIF}
    z := 1;
  end;
end;
begin end.
'''
        for d in (None, ['A']):
            r = check_invariants(self, src, defines=d)
            self.assertEqual(r.diags, [], d)

    def test_nested_and_define_undef(self):
        src = '''{$DEFINE X}
program t;
{$IFDEF X}{$IFDEF Y}var a: integer;{$ELSE}var b: integer;{$ENDIF}{$ENDIF}
{$UNDEF X}
{$IFDEF X}var c: integer;{$ENDIF}
begin end.'''
        r = check_invariants(self, src)
        self.assertEqual([n.kids[0].text for n in r.tree.nodes('DeclName')], ['t', 'b'])

    def test_defines_are_case_insensitive_and_predefined(self):
        r = parse('{$ifdef msdos}var a: integer;{$endif}{$IFDEF VER70}var b: integer;{$ENDIF}{$IFDEF CPU87}var c: integer;{$ENDIF}\nbegin end.')
        self.assertEqual([n.kids[0].text for n in r.tree.nodes('DeclName')], ['a', 'b'])

    def test_ifopt_follows_switches(self):
        src = '{$IFOPT R+}var a: integer;{$ELSE}var b: integer;{$ENDIF}{$R+}{$IFOPT R+}var c: integer;{$ENDIF}\nbegin end.'
        r = parse(src)
        self.assertEqual([n.kids[0].text for n in r.tree.nodes('DeclName')], ['b', 'c'])

    def test_include_is_recorded_not_expanded(self):
        r = parse('program t;\n{$I defs.inc}\n{$I+}\nbegin end.')
        self.assertEqual([name for _, name in r.includes], ['defs.inc'])

    def test_diagnostics_for_broken_conditionals(self):
        r = parse('{$ENDIF}\n{$ELSE}\n{$IFDEF A}\nbegin end.')
        msgs = [m for _, m in r.diags]
        self.assertTrue(any('ENDIF' in m for m in msgs))
        self.assertTrue(any('ELSE' in m for m in msgs))
        self.assertTrue(any('never closed' in m for m in msgs))
        self.assertEqual(reconstruct(r), '{$ENDIF}\n{$ELSE}\n{$IFDEF A}\nbegin end.')


class Recovery(unittest.TestCase):
    def test_errors_do_not_destroy_the_rest(self):
        src = prog('x := ;\ny := 2;\nif then z := 3;\nw := 4', 'var x, y, z, w: integer;')
        r = check_invariants(self, src)
        self.assertTrue(r.diags)
        self.assertEqual(len(r.tree.nodes('Assign')), 4)

    def test_missing_end_stops_at_next_routine(self):
        src = 'program t;\nprocedure A;\nbegin\n x := 1;\nprocedure B;\nbegin end;\nbegin end.\n'
        r = check_invariants(self, src)
        self.assertTrue(any('missing' in m or "'end'" in m for _, m in r.diags))
        self.assertEqual(len(r.tree.nodes('Routine')), 2)

    def test_garbage_after_end(self):
        r = check_invariants(self, 'program t;\nbegin end.\nthis is junk "!"\n')
        self.assertTrue(r.diags)

    def test_empty_and_whitespace_only(self):
        for s in ('', '   \n', '{just a comment}', '\x1a'):
            r = check_invariants(self, s)

    def test_fuzz_never_raises_and_stays_lossless(self):
        rnd = random.Random(11)
        pieces = ['begin', 'end', 'if', 'then', 'else', 'while', 'do', 'repeat', 'until', 'for', 'to', 'case', 'of',
                  'with', 'goto', 'asm', 'record', 'array', 'set', 'file', 'string', 'procedure', 'function', 'var',
                  'const', 'type', 'label', 'unit', 'interface', 'implementation', 'uses', 'program', 'object',
                  'forward', 'external', 'inline', 'inherited', 'private', 'public', 'constructor', 'destructor',
                  'virtual', 'x', 'y', 'Foo', '1', '$F', '1.5', "'s'", '#13', ':=', ':', ';',
                  ',', '.', '..', '(', ')', '[', ']', '^', '@', '+', '-', '*', '/', '=', '<>', '{$IFDEF A}',
                  '{$ELSE}', '{$ENDIF}', '{c}', '(*c*)', '"', '\n', ' ']
        for _ in range(4000):
            src = ' '.join(rnd.choice(pieces) for _ in range(rnd.randint(0, 40)))
            check_invariants(self, src)
            check_invariants(self, src, defines=['A'])

    def test_deep_nesting_does_not_crash(self):
        check_invariants(self, prog('x := ' + '(' * 3000 + '1' + ')' * 3000))


class Objects(unittest.TestCase):
    OBJ = ('type\n  TShape = object(TBase)\n    x, y: Integer;\n  private\n    z: Byte;\n  public\n'
           '    constructor Init(AX: Integer);\n    destructor Done; virtual;\n    function Area: Integer; far;\n  end;\n')

    def test_ancestor_fields_sections_and_methods(self):
        r = check_invariants(self, prog('x := 1', self.OBJ))
        self.assertEqual(r.diags, [])
        obj = r.tree.first('ObjectType')
        self.assertEqual(obj.first('Heritage').text(), '( TBase )')
        fl = fieldlist_of(obj)
        kinds = [n.kind for n in fl.kids if isinstance(n, Node)]
        self.assertEqual(kinds, ['FieldDecl', 'Section', 'FieldDecl', 'Section', 'Routine', 'Routine', 'Routine'])
        self.assertEqual([n.kids[0].text for n in fl.kids if isinstance(n, Node) and n.kind == 'Routine'],
                         ['constructor', 'destructor', 'function'])
        self.assertEqual(obj.nodes('Directives')[0].text(), 'virtual ;')

    def test_empty_object_and_object_without_ancestor(self):
        r = check_invariants(self, prog('x := 1', 'type A = object end; B = object (A) end;'))
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.nodes('ObjectType')), 2)

    def test_a_field_may_be_called_private(self):
        r = check_invariants(self, prog('x := 1', 'type A = object\n private: Integer;\n public, c: Byte;\n end;'))
        self.assertEqual(r.diags, [])
        self.assertEqual(r.tree.nodes('Section'), [])
        self.assertEqual(len(r.tree.nodes('FieldDecl')), 2)

    def test_record_with_methods(self):
        r = check_invariants(self, prog('x := 1', 'type R = record\n a: Integer;\n procedure Move(d: Integer);\n end;'))
        self.assertEqual(r.diags, [])
        self.assertEqual(len(r.tree.first('RecordType').nodes('Routine')), 1)

    def test_variant_part_does_not_take_methods(self):
        r = check_invariants(self, prog('x := 1', 'type R = record\n case Byte of 0: (a: Integer; procedure P);\n end;'))
        self.assertTrue(r.diags)

    def test_method_implementation_names(self):
        src = prog('x := 1', 'procedure T.Draw(n: Integer); begin end;\nprocedure Plain; begin end;')
        r = check_invariants(self, src)
        self.assertEqual(r.diags, [])
        a, b = r.tree.nodes('Routine')
        owner, dn = routine_names(a)
        self.assertEqual((owner.kind, owner.kids[0].text, dn.kind, dn.kids[0].text), ('Name', 'T', 'DeclName', 'Draw'))
        self.assertEqual(routine_names(b)[0], None)
        self.assertEqual(routine_names(b)[1].kids[0].text, 'Plain')

    def test_inherited_as_statement_and_in_an_expression(self):
        r = check_invariants(self, prog('', 'procedure T.P; begin\n inherited P(1);\n inherited;\n x := inherited F + 1;\nend;'))
        self.assertEqual(r.diags, [])
        inh = r.tree.nodes('Inherited')
        self.assertEqual([len(n.kids) for n in inh], [2, 1, 2])
        self.assertEqual(r.tree.nodes('Binary')[0].kids[0].kind, 'Inherited')

    def test_new_with_a_constructor_call_is_an_ordinary_call(self):
        r = check_invariants(self, prog('New(P, Init(1, 2)); Dispose(P, Done);'))
        self.assertEqual(r.diags, [])

    def test_broken_object_still_gives_a_tree(self):
        r = check_invariants(self, prog('x := 1', 'type T = object\n x: ;\n procedure ;\n end;\nvar y: Integer;'))
        self.assertTrue(r.diags)
        self.assertEqual(len(r.tree.nodes('Assign')), 1)


class PointerToString(unittest.TestCase):
    def test_pointer_to_the_reserved_word_string(self):
        for src in ('unit u; interface type T = object S: ^String; N: Byte; end; var P: ^string; implementation end.',
                    'program p; type PS = ^String; var Q: ^String; begin end.'):
            self.assertEqual(parse(src).diags, [], src)


class StrayElse(unittest.TestCase):
    def test_semicolon_before_else_is_one_error_with_a_hint(self):
        res = parse('program a;\nbegin\n  if x then\n    y := 1;\n  else\n    y := 2;\n  z := 3;\nend.\n')
        self.assertEqual([m for _, m in res.diags],
                         ["unexpected 'else' (the ';' before 'else' ended the if statement: remove it)"])   # no follow-up errors

    def test_else_without_semicolon_is_fine(self):
        self.assertEqual(parse('program a;\nbegin\n  if x then\n    y := 1\n  else\n    y := 2;\nend.\n').diags, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
