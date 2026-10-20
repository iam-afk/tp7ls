#!/usr/bin/env python3
"""Tests for tp7sema.py.  Run: python3 test_tp7sema.py [DIR_WITH_SAMPLES]
DIR must contain TURBO.TPL, GRAPH.TPU, polsk.pas, option.pas, TEST.PAS."""
import os, shutil, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tp7fmt import format_source, FormatError
from tp7lex import lex, significant
from tp7parse import parse
from tp7sema import Provider, normalize_case

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'
TPL = os.path.join(D, 'TURBO.TPL')


def rd(name):
    with open(os.path.join(D, name), 'rb') as f:
        return f.read().decode('cp866')


def norm(src, dirs=(), tpl=True, report=None):
    """normalise and return the source text rebuilt from the tokens (layout untouched)"""
    from tp7parse import reconstruct
    res = parse(src)
    assert not res.diags, [(t.line, m) for t, m in res.diags]
    rep = normalize_case(res, Provider(dirs, TPL if tpl else None))
    if report is not None:
        report.append(rep)
    return reconstruct(res)


def prog(body, decls='', uses=''):
    return 'program t;\n%s\n%s\nbegin\n%s\nend.\n' % (('uses ' + uses + ';') if uses else '', decls, body)


class Basics(unittest.TestCase):
    def test_keywords_are_lower_case_and_system_names_take_their_declared_spelling(self):
        out = norm('PROGRAM T; VAR X: INTEGER; B: BOOLEAN; BEGIN WRITELN(X); X := ORD(TRUE); Inc(X); EXIT END.')
        self.assertEqual(out, 'program T; var X: Integer; B: Boolean; begin WriteLn(X); X := Ord(True); Inc(X); Exit end.')

    def test_declared_spelling_wins_over_use_spelling(self):
        out = norm(prog('count := COUNT + 1; Total := total', 'var Count, TOTAL: integer;'))
        self.assertIn('Count := Count + 1; TOTAL := TOTAL', out)

    def test_local_scope_shadows_and_params(self):
        src = prog('i := 1; P(2)', 'var I: integer;\nprocedure P(Index: integer);\nvar i: integer;\nbegin INDEX := 3; I := 4 end;')
        out = norm(src)
        self.assertIn('begin INDEX := 3', src)
        self.assertIn('begin Index := 3; i := 4 end;', out)         # local i / param Index
        self.assertIn('begin\nI := 1; P(2)\nend.', out)             # global I

    def test_unresolved_names_are_untouched_and_reported(self):
        rep = []
        out = norm(prog('FooBar(1); x := UNKNOWN', 'var X: integer;'), report=rep)
        self.assertIn('FooBar(1); X := UNKNOWN', out)
        self.assertEqual(sorted(t.text for t in rep[0].unresolved), ['FooBar', 'UNKNOWN'])

    def test_function_result_assignment(self):
        out = norm(prog('x := Fn(1)', 'var x: integer;\nfunction Fn(a: integer): integer;\nbegin FN := A + 1 end;'))
        self.assertIn('begin Fn := a + 1 end;', out)

    def test_forward_pointer_type_and_record_chain(self):
        src = prog('p := new_node; p^.NEXT^.value := 1; q := p^.next^.Value',
                   'type PNode = ^TNode; TNode = record Next: PNode; Value: integer end;\n'
                   'var P, Q: PNode; function new_node: pnode; begin end;')
        out = norm(src)
        self.assertIn('p := New_Node'.replace('New_Node', 'new_node').replace('p :=', 'P :='), out)
        self.assertIn('P^.Next^.Value := 1; Q := P^.Next^.Value', out)

    def test_arrays_of_records_and_multi_index(self):
        src = prog('a[1].NAME := 1; m[1, 2].Name := 2; m[1][2].NAME := 3',
                   'type R = record Name: integer end;\nvar a: array[1..3] of R; m: array[1..3, 1..3] of R;')
        out = norm(src)
        self.assertEqual(out.count('.Name'), 3)

    def test_with_statement(self):
        src = prog('with r do begin NAME := 1; outer := 2 end; with r, s do begin Other := Name end',
                   'type RR = record Name: integer end; SS = record Other: integer end;\nvar r: RR; s: SS; Outer: integer;')
        out = norm(src)
        self.assertIn('Name := 1; Outer := 2', out)
        self.assertIn('Other := Name', out)

    def test_with_of_unknown_type_makes_names_uncertain(self):
        rep = []
        out = norm(prog('with Unknown^ do begin value := 1 end; value := 2', 'var Value: integer;'), report=rep)
        self.assertIn('begin value := 1 end; Value := 2', out)       # inside the with: not rewritten
        self.assertEqual([t.text for t in rep[0].uncertain], ['value'])

    def test_enum_members_case_labels_and_typed_constants(self):
        src = prog('case c of cmaa: x := 1; CMBB: x := 2 end',
                   'type Cmd = (cmAa, cmBb);\nvar c: Cmd; x: integer;\n'
                   'const Names: array[Cmd] of string = (\'a\', \'b\');\n'
                   'type Rec = record Lo, Hi: integer end;\nconst Lim: Rec = (LO: 1; hi: 2);\n'
                   '      Grid: array[0..1] of Rec = ((lo: 1; hi: 2), (LO: 3; Hi: 4));\n'
                   '      G2: array[0..1, 0..1] of Rec = (((lo: 1; hi: 2), (LO: 3; hi: 4)), ((lo: 5; HI: 6), (lo: 7; hi: 8)));')
        out = norm(src)
        self.assertIn('cmAa: x := 1; cmBb: x := 2', out)
        self.assertIn('(Lo: 1; Hi: 2)', out)
        self.assertIn('((Lo: 1; Hi: 2), (Lo: 3; Hi: 4))', out)
        self.assertIn('(((Lo: 1; Hi: 2), (Lo: 3; Hi: 4)), ((Lo: 5; Hi: 6), (Lo: 7; Hi: 8)))', out)

    def test_labels(self):
        out = norm(prog('GOTO done; DONE: x := 1', 'label Done;\nvar x: integer;'))
        self.assertIn('goto Done; Done: x := 1', out)

    def test_inactive_branch_is_not_touched(self):
        src = prog('{$IFDEF NOPE}\nINTEGER_x := 1;\n{$ELSE}\nX := 1;\n{$ENDIF}', 'var x: integer;')
        out = norm(src)
        self.assertIn('INTEGER_x := 1;', out)
        self.assertIn('x := 1;', out)

    def test_idempotent(self):
        for name in ('polsk.pas', 'option.pas', 'TEST.PAS'):
            once = norm(rd(name), [D])
            self.assertEqual(norm(once, [D]), once, name)

    def test_only_case_changes(self):
        for name in ('polsk.pas', 'option.pas', 'TEST.PAS'):
            src = rd(name)
            out = norm(src, [D])
            a = [t.text for t in significant(lex(src))]
            b = [t.text for t in significant(lex(out))]
            self.assertEqual([x.lower() for x in a], [x.lower() for x in b], name)


class Units(unittest.TestCase):
    def test_standard_units_and_qualified_names(self):
        src = prog('clrscr; Crt.DELAY(10); r.ax := 1; r.AL := 2; intr($10, r); x := dosversion',
                   'var r: registers; x: word;', 'crt, DOS')
        out = norm(src)
        self.assertIn('uses Crt, Dos;', out)
        self.assertIn('ClrScr; Crt.Delay(10); r.AX := 1; r.AL := 2; Intr($10, r); x := DosVersion', out)
        self.assertIn('var r: Registers; x: Word;', out)

    def test_dos_record_chain_through_pointer_and_function_result(self):
        src = prog('f.name := \'x\'; findfirst(\'*.*\', anyfile, f); if f.ATTR = directory then;',
                   'var f: searchrec;', 'dos')
        out = norm(src)
        self.assertIn("f.Name := 'x'; FindFirst('*.*', AnyFile, f); if f.Attr = Directory then;", out)

    def test_tpu_file_and_source_unit_in_search_path(self):
        tmp = tempfile.mkdtemp()
        try:
            shutil.copy(os.path.join(D, 'GRAPH.TPU'), tmp)
            with open(os.path.join(tmp, 'mylib.pas'), 'wb') as f:
                f.write(('unit MyLib;\ninterface\ntype Pt = record X, Y: integer end;\nvar Origin: Pt;\n'
                         'procedure Move(var P: Pt);\nimplementation\nprocedure Move; begin end;\nend.\n').encode('cp866'))
            src = prog('initgraph(gd, gm, \'\'); origin.x := 1; MYLIB.move(ORIGIN); graphresult',
                       'var gd, gm: integer;', 'graph, mylib')
            rep = []
            out = norm(src, [tmp], report=rep)
            self.assertIn('uses Graph, MyLib;', out)
            self.assertIn("InitGraph(gd, gm, ''); Origin.X := 1; MyLib.Move(Origin); GraphResult", out)
            self.assertEqual(rep[0].missing_units, [])
        finally:
            shutil.rmtree(tmp)

    def test_missing_unit_is_reported_and_its_names_stay(self):
        rep = []
        out = norm(prog('SetColor(1); delay(1)', '', 'vesa, crt'), report=rep)
        self.assertIn('SetColor(1); Delay(1)', out)
        self.assertEqual([t.text for t in rep[0].missing_units], ['vesa'])

    def test_last_unit_in_uses_wins(self):
        tmp = tempfile.mkdtemp()
        try:
            for n, sp in (('ua', 'Common'), ('ub', 'COMMON')):
                with open(os.path.join(tmp, n + '.pas'), 'wb') as f:
                    f.write(('unit %s;\ninterface\nprocedure %s;\nimplementation\nprocedure %s; begin end;\nend.\n'
                             % (n, sp, sp)).encode('cp866'))
            out = norm(prog('common', '', 'ua, ub'), [tmp])
            self.assertIn('begin\nCOMMON\nend.', out)
            out = norm(prog('common', '', 'ub, ua'), [tmp])
            self.assertIn('begin\nCommon\nend.', out)
        finally:
            shutil.rmtree(tmp)


class UnitFiles(unittest.TestCase):
    def test_implementation_header_takes_interface_spelling_and_parameters(self):
        src = ('unit u;\ninterface\nfunction GetIt(Index: integer; var Buf: string): boolean;\n'
               'implementation\nfunction getit;\nbegin\n  GETIT := (INDEX > 0) and (buf <> \'\');\nend;\nend.\n')
        out = norm(src)
        self.assertIn('function GetIt;', out)
        self.assertIn('GetIt := (Index > 0) and (Buf <> \'\');', out)

    def test_header_repeated_with_own_parameters(self):
        src = ('unit u;\ninterface\nprocedure Run(A: integer);\nimplementation\n'
               'procedure RUN(b: integer);\nbegin B := 1 end;\nend.\n')
        out = norm(src)
        self.assertIn('procedure Run(b: Integer);', out)
        self.assertIn('begin b := 1 end;', out)

    def test_implementation_sees_interface_and_own_declarations(self):
        src = ('unit u;\ninterface\nvar Pub: integer;\nimplementation\nvar Priv: integer;\n'
               'procedure P; begin pub := 1; PRIV := 2 end;\nend.\n')
        out = norm(src)
        self.assertIn('begin Pub := 1; Priv := 2 end;', out)

    def test_own_unit_name_qualification(self):
        src = 'unit MyU;\ninterface\nvar V: integer;\nimplementation\nprocedure P; begin myu.v := 1 end;\nend.\n'
        self.assertIn('begin MyU.V := 1 end;', norm(src))

    def test_samples(self):
        out = norm(rd('polsk.pas'), [D])
        self.assertIn('n:=NextChar(str);', out)
        self.assertNotIn('Nextchar', out)
        out = norm(rd('TEST.PAS'), [D])
        self.assertIn('uses vesa,Dos,objects,Crt,Polsk,option;', out)     # vesa/objects: not available, left as is
        self.assertIn('str_15=string[15];', out)


class ObjectNames(unittest.TestCase):
    SRC = ('program p;\ntype\n  PShape = ^TShape;\n  TShape = object\n    x, y: Integer;\n    constructor Init(AX, AY: Integer);\n'
           '    destructor Done; virtual;\n    procedure Draw; virtual;\n    function Area: Integer;\n  end;\n  PCircle = ^TCircle;\n'
           '  TCircle = object(TShape)\n    r: Integer;\n    constructor Init(AX, AY, AR: Integer);\n    procedure Draw; virtual;\n  end;\n'
           '  TPt = record\n    a, b: Integer;\n    procedure Move(d: Integer);\n  end;\nvar\n  c: TCircle;\n  pc: PCircle;\n  pt: TPt;\n\n'
           'constructor TShape.Init(AX, AY: Integer);\nbegin\n  X := ax;\n  Y := AY;\nend;\n\ndestructor TShape.Done;\nbegin\nend;\n\n'
           'procedure TShape.Draw;\nbegin\n  writeln(x);\nend;\n\nfunction TShape.Area: Integer;\nbegin\n  area := 0;\nend;\n\n'
           'constructor TCircle.Init;\nbegin\n  inherited init(ax, ay);\n  R := ar;\n  self.r := 1;\nend;\n\n'
           'procedure TCircle.Draw;\nbegin\n  inherited DRAW;\n  X := y + r + SELF.x + area;\n  draw;\nend;\n\n'
           'procedure TPt.Move(d: Integer);\nbegin\n  A := a + D;\nend;\n\n'
           'begin\n  c.init(1, 2, 3);\n  c.DRAW;\n  new(pc, init(1, 2, 3));\n  dispose(pc, DONE);\n  pc^.draw;\n  pt.move(3);\n'
           '  writeln(c.AREA, pc^.R);\nend.\n')

    def test_members_self_inherited_and_constructor_arguments_are_normalised(self):
        out = norm(self.SRC)
        for want in ('  x := AX;\n', '  area := 0;\n'.replace('area', 'Area'), '  inherited Init(AX, AY);\n', '  r := AR;\n',
                     '  Self.r := 1;\n', '  inherited Draw;\n', '  x := y + r + Self.x + Area;\n', '  Draw;\n',
                     '  a := a + d;\n', '  c.Init(1, 2, 3);\n', '  c.Draw;\n', '  New(pc, Init(1, 2, 3));\n',
                     '  Dispose(pc, Done);\n', '  pc^.Draw;\n', '  pt.Move(3);\n', '  WriteLn(c.Area, pc^.r);\n'):
            self.assertIn(want, out)

    def test_nothing_is_unresolved(self):
        rep = []
        norm(self.SRC, report=rep)
        self.assertEqual([t.text for t in rep[0].unresolved], [])

    def test_headers_take_the_spelling_of_the_declaration(self):
        out = norm('program p;\ntype T = object\n  procedure DoIt(Count: Integer);\nend;\nprocedure t.DOIT(count: Integer);\nbegin\n'
                   '  count := 1\nend;\nbegin end.\n')
        self.assertIn('procedure T.DoIt(count: Integer);', out)

    def test_a_method_without_a_declaration_is_reported_and_declares_nothing(self):
        rep = []
        norm('program p;\ntype T = object x: Integer; end;\nprocedure T.Nope; begin end;\nbegin Nope end.\n', report=rep)
        self.assertEqual(sorted(t.text for t in rep[0].unresolved), ['Nope', 'Nope'])

    def test_a_header_without_parameters_sees_the_declared_ones(self):
        out = norm('program p;\ntype T = object x: Integer;\n  procedure Put(Value: Integer);\nend;\n'
                   'procedure T.Put;\nbegin\n  x := value\nend;\nbegin end.\n')
        self.assertIn('x := Value', out)

    def test_parameters_and_locals_hide_members(self):
        out = norm('program p;\ntype T = object X: Integer;\n  procedure Put(Value: Integer);\nend;\n'
                   'procedure T.Put(Value: Integer);\nvar x: Real;\nbegin\n  X := value\nend;\nbegin end.\n')
        self.assertIn('  x := Value', out)                       # the local x (declared lower case) wins

    def test_ancestor_from_another_unit(self):
        d = tempfile.mkdtemp()
        try:
            with open(os.path.join(d, 'BASE.PAS'), 'wb') as f:
                f.write(b'unit Base;\r\ninterface\r\ntype\r\n  TBase = object\r\n    Count: Integer;\r\n    procedure Bump;\r\n  end;\r\n'
                        b'implementation\r\nprocedure TBase.Bump; begin Inc(Count) end;\r\nend.\r\n')
            out = norm('program p;\nuses Base;\ntype TKid = object(tbase)\n  procedure Twice;\nend;\n'
                       'procedure TKid.Twice;\nbegin\n  bump; BUMP; count := 0\nend;\nvar k: TKid;\nbegin\n  k.BUMP\nend.\n', dirs=[d])
            self.assertIn('object(TBase)', out)
            self.assertIn('  Bump; Bump; Count := 0', out)
            self.assertIn('  k.Bump', out)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_fields_of_ancestors_through_with(self):
        out = norm('program p;\ntype A = object x: Integer; end; B = object(A) y: Integer; end;\nvar v: B;\nbegin\n  with v do begin X := 1; Y := 2 end\nend.\n')
        self.assertIn('begin x := 1; y := 2 end', out)

    def test_inherited_without_an_ancestor_does_not_crash(self):
        rep = []
        norm('program p;\ntype A = object procedure P; end;\nprocedure A.P; begin inherited P end;\nbegin end.\n', report=rep)
        self.assertEqual([t.text for t in rep[0].unresolved], ['P'])

    def test_ancestor_cycle_terminates(self):
        norm('program p;\ntype A = object(B) x: Integer; end; B = object(A) y: Integer; end;\nvar v: A;\nbegin v.X := 1 end.\n')


class WithFormatter(unittest.TestCase):
    def test_format_with_normalize_matches_reference_layout_plus_case(self):
        prov = Provider([D], TPL)
        out = format_source(rd('polsk.pas'), normalize=True, provider=prov)
        ref = rd('polsk_formatted.pas')
        self.assertEqual([x.lower() for x in significant_texts(out)], [x.lower() for x in significant_texts(ref)])
        self.assertEqual(out.lower(), ref.lower())               # same layout, differing only in letter case
        self.assertNotEqual(out, ref)
        self.assertEqual(format_source(out, normalize=True, provider=prov), out)     # idempotent

    def test_option_layout_unchanged_by_normalization(self):
        prov = Provider([D], TPL)
        out = format_source(rd('option.pas'), normalize=True, provider=prov)
        self.assertEqual(out.lower(), rd('option_formatted.pas').lower())


class BrokenCode(unittest.TestCase):
    """Half-typed code (the usual state of an editor buffer) must never crash the binder."""

    def test_designator_without_a_name(self):
        for src in ('program t;\ntype O = object procedure P; end;\nprocedure O.P;\nbegin\n  with inherited do P;\nend;\nbegin end.\n',
                    'program t;\nvar a: integer;\nbegin\n  with ^ do a := 1;\n  with . do;\nend.\n',
                    'program t;\ntype O = object(\nbegin end.\n',
                    'program t;\ntype O = object X: Integer; procedure P; virtual;\nprocedure O.P;\nbegin\n  inherited;\n  Self.\nend;\n'):
            res = parse(src)
            normalize_case(res, Provider([], TPL))                # must not raise


def significant_texts(src):
    return [t.text for t in significant(lex(src))]


if __name__ == '__main__':
    unittest.main(verbosity=2)
