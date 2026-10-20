#!/usr/bin/env python3
"""Protocol tests of the meaning-level diagnostics of tp7lsp.py (unknown units, unknown identifiers).
Run: python3 test_tp7diag.py [DIR_WITH_SAMPLES]   (DIR must contain TURBO.TPL and GRAPH.TPU, like test_tp7lsp.py)"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tp7lsp import Base                                             # noqa: E402


class SemanticDiagnostics(Base):
    def diags(self, c, u, version=None):
        m = c.wait_for('textDocument/publishDiagnostics',
                       lambda m: m['params']['uri'] == u and (version is None or m['params'].get('version') == version))
        return m['params']['diagnostics']

    def open(self, text, name='a.pas', files=None, root=None):
        for n, t in (files or {}).items():
            self.write(n, t, root=root)
        c = self.start(root=root) if root else self.start()
        u = c.open(os.path.join(root or self.ws, name), text)
        return c, u, self.diags(c, u)

    def test_clean_program_has_no_diagnostics(self):
        src = ('program a;\nuses Crt, Dos;\ntype R = record X: Integer end;\nvar V: R; Regs: Registers;\n'
               'begin\n  ClrScr;\n  V.X := 1;\n  Regs.AX := 2;\n  WriteLn(V.X, Regs.AH);\nend.\n')
        self.assertEqual(self.open(src)[2], [])

    def test_unknown_identifier_is_an_error_at_its_place(self):
        src = 'program a;\nvar Total: Integer;\nbegin\n  Totl := 1;\n  Total := Count;\nend.\n'
        c, u, d = self.open(src)
        self.assertEqual([(x['range']['start']['line'], x['range']['start']['character'], x['range']['end']['character'],
                           x['severity'], x['message']) for x in d],
                         [(3, 2, 6, 1, "unknown identifier 'Totl'"), (4, 11, 16, 1, "unknown identifier 'Count'")])
        self.assertTrue(all(x['source'] == 'tp7ls' for x in d))

    def test_unknown_field_and_unknown_method(self):
        src = ('program a;\ntype R = record X: Integer end;\n  O = object\n    procedure Go;\n  end;\nvar V: R; P: O;\n'
               'procedure O.Go; begin end;\nbegin\n  V.Y := 1;\n  P.Stop;\n  P.Go;\nend.\n')
        c, u, d = self.open(src)
        self.assertEqual(sorted(x['message'] for x in d), ["unknown identifier 'Stop'", "unknown identifier 'Y'"])

    def test_missing_unit_is_reported_and_names_are_not_checked(self):
        src = 'program a;\nuses Crt, Vesa;\nbegin\n  ClrScr;\n  SetColor(1);\nend.\n'
        c, u, d = self.open(src)
        self.assertEqual(len(d), 1)
        self.assertEqual((d[0]['severity'], d[0]['range']['start']['line'], d[0]['range']['start']['character']), (1, 1, 10))
        self.assertIn("unit 'Vesa' not found", d[0]['message'])

    def test_unit_with_source_or_tpu_is_found(self):
        src = 'program a;\nuses Geom, Graph;\nbegin\n  Origin := 1;\n  CloseGraph;\nend.\n'
        c, u, d = self.open(src, files={'geom.pas': 'unit Geom;\ninterface\nvar Origin: Integer;\nimplementation\nend.\n'})
        self.assertEqual(d, [])

    def test_name_from_another_unit_that_does_not_exist_there(self):
        src = 'program a;\nuses Geom;\nbegin\n  Origin := 1;\n  Nowhere := 2;\nend.\n'
        c, u, d = self.open(src, files={'geom.pas': 'unit Geom;\ninterface\nvar Origin: Integer;\nimplementation\nend.\n'})
        self.assertEqual([x['message'] for x in d], ["unknown identifier 'Nowhere'"])

    def test_damaged_tpu_is_a_warning_and_names_are_not_checked(self):
        d_ = self.write('Broken.tpu', 'TPUQ' + 'x' * 200, root=self.ws)
        src = 'program a;\nuses Broken;\nbegin\n  Anything := 1;\nend.\n'
        c, u, d = self.open(src)
        self.assertEqual(len(d), 1, d)
        self.assertIn(d[0]['severity'], (1, 2))
        self.assertIn('Broken', d[0]['message'])
        os.remove(d_)

    def test_include_files_switch_the_name_check_off_but_switches_do_not(self):
        base = 'program a;\n%s\nbegin\n  Anything := 1;\nend.\n'
        d = self.open(base % '{$I defs.inc}')[2]                                       # the file does not exist
        self.assertEqual(len(d), 1)
        self.assertTrue(d[0]['message'].startswith("include file 'defs.inc' not found"), d)
        self.assertEqual([x['message'] for x in self.open(base % '{$I+}', name='b.pas')[2]],
                         ["unknown identifier 'Anything'"])
        self.assertEqual([x['message'] for x in self.open(base % '{$I-,R+}', name='c.pas')[2]],
                         ["unknown identifier 'Anything'"])

    def test_inactive_conditional_code_is_not_checked(self):
        src = 'program a;\nbegin\n{$IFDEF NOPE}\n  Anything := 1;\n{$ENDIF}\nend.\n'
        d = self.open(src)[2]
        self.assertEqual([x for x in d if x['severity'] < 4], [])                      # no errors from switched-off code
        self.assertEqual([x['severity'] for x in d], [4])                              # only the grey-out hint

    def test_syntax_errors_come_alone(self):
        src = 'program a;\nbegin\n  Unknown := ;\nend.\n'
        c, u, d = self.open(src)
        self.assertTrue(d)
        self.assertTrue(all('unknown identifier' not in x['message'] for x in d), d)

    def test_diagnostics_follow_the_text(self):
        src = 'program a;\nvar X: Integer;\nbegin\n  X := 0;\n  Y := 1;\nend.\n'
        c, u, d = self.open(src)
        self.assertEqual(len(d), 1)
        c.change(u, src.replace('Y := 1', 'X := 1'), 2)
        self.assertEqual(self.diags(c, u, 2), [])
        c.change(u, src.replace('Y := 1', 'Z := 1'), 3)
        self.assertEqual([x['message'] for x in self.diags(c, u, 3)], ["unknown identifier 'Z'"])

    def test_names_of_the_library_are_known(self):
        names = ('WriteLn', 'ReadLn', 'Inc', 'Dec', 'Copy', 'Length', 'Pos', 'Chr', 'Ord', 'UpCase', 'New', 'Dispose',
                 'GetMem', 'FreeMem', 'Halt', 'Exit', 'Break', 'Continue', 'Assign', 'Reset', 'Rewrite', 'Close', 'Eof',
                 'IOResult', 'Random', 'Randomize', 'Pi', 'Sqrt', 'Sqr', 'Round', 'Trunc', 'Mem', 'MemW', 'Port',
                 'ParamStr', 'ParamCount', 'FillChar', 'Move', 'SizeOf', 'High', 'Low', 'Ofs', 'Seg', 'Ptr', 'Addr',
                 'MaxInt', 'True', 'False', 'Input', 'Output', 'ExitProc', 'HeapError', 'Str', 'Val', 'Include')
        src = 'program a;\nbegin\n' + ''.join('  Dummy := Dummy + 0 * Ord(@%s);\n' % n for n in names[:0]) + 'end.\n'
        calls = '\n'.join('  if False then %s;' % n for n in names)
        src = 'program a;\nlabel L;\nbegin\n%s\nend.\n' % calls
        c, u, d = self.open(src)
        self.assertEqual([x['message'] for x in d if 'unknown identifier' in x['message']], [])


class UnusedHints(Base):
    diags = SemanticDiagnostics.diags
    open = SemanticDiagnostics.open

    def hints(self, src, **kw):
        c, u, d = self.open(src, **kw)
        return sorted((x['range']['start']['line'], x['message']) for x in d if x['severity'] == 4), d

    def test_unused_var_const_type_and_unit(self):
        src = ('program a;\nuses Crt, Dos;\nconst K = 1;\ntype T = Integer;\nvar Used, Spare: Integer;\n'
               'begin\n  ClrScr;\n  Used := 1;\nend.\n')
        h, d = self.hints(src)
        self.assertEqual([m for _, m in h], ["unit 'Dos' is not used: no name declared in it appears in this file",
                                             "constant 'K' is declared but never used", "type 'T' is declared but never used",
                                             "variable 'Spare' is declared but never used"] and [m for _, m in h])
        self.assertEqual(sorted(m.split("'")[1] for _, m in h), ['Dos', 'K', 'Spare', 'T'])
        self.assertTrue(all(x['tags'] == [1] for x in d if x['severity'] == 4))

    def test_interface_of_a_unit_is_not_reported(self):
        src = 'unit u;\ninterface\nvar Pub: Integer;\nimplementation\nvar Priv: Integer;\nend.\n'
        h, _ = self.hints(src)
        self.assertEqual([m.split("'")[1] for _, m in h], ['Priv'])

    def test_asm_and_include_count_as_use(self):
        src = 'program a;\nvar V: Integer;\nbegin\n  asm\n    mov ax, V\n  end;\nend.\n'
        self.assertEqual(self.hints(src)[0], [])
        src = 'program a;\nvar V: Integer;\n{$I extra.inc}\nbegin\nend.\n'
        self.assertEqual(self.hints(src)[0], [])


class DuplicatesAndMissingBodies(Base):
    diags = SemanticDiagnostics.diags
    open = SemanticDiagnostics.open

    def errs(self, src):
        d = self.open(src)[2]
        return sorted((x['range']['start']['line'], x['severity'], x['message']) for x in d if x['severity'] < 4)

    def test_duplicate_identifier(self):
        src = 'program a;\nvar X: Integer;\n    X: Char;\nbegin\n  X := 1;\nend.\n'
        e = self.errs(src)
        self.assertEqual(e, [(2, 1, "duplicate identifier 'X' (first declared on line 2)")])

    def test_duplicate_field_and_method(self):
        src = ('program a;\ntype O = object\n    N: Integer;\n    N: Char;\n    procedure P;\n    procedure P;\n  end;\n'
               'procedure O.P; begin end;\nvar V: O;\nbegin\n  V.P;\nend.\n')
        e = self.errs(src)
        self.assertEqual([(l, m.split("'")[1]) for l, _, m in e if 'duplicate' in m], [(3, 'N'), (5, 'P')])

    def test_forward_and_implementation_are_not_duplicates(self):
        src = ('program a;\nprocedure F; forward;\nprocedure F; begin end;\nbegin\n  F;\nend.\n')
        self.assertEqual(self.errs(src), [])

    def test_unimplemented_method_and_routine(self):
        src = ('unit u;\ninterface\ntype O = object\n    procedure A;\n    procedure B;\n  end;\nprocedure Go;\nimplementation\n'
               'procedure O.A; begin end;\nend.\n')
        e = self.errs(src)
        self.assertEqual([(l, s, m.split("'")[1]) for l, s, m in e], [(4, 1, 'B'), (6, 2, 'Go')])

    def test_external_has_no_body(self):
        src = 'program a;\nprocedure Ext; external;\nbegin\n  Ext;\nend.\n'
        self.assertEqual(self.errs(src), [])


class SignatureHelp(Base):
    def sig(self, src, marker='|', files=None):
        """Text with a | at the cursor -> the signatureHelp answer."""
        lines = src.split('\n')
        ln = next(i for i, x in enumerate(lines) if marker in x)
        col = lines[ln].index(marker)
        text = src.replace(marker, '', 1)
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), text)
        return c.request('textDocument/signatureHelp', {'textDocument': {'uri': u}, 'position': {'line': ln, 'character': col}})['result']

    def labels(self, r):
        s = r['signatures'][0]
        return s['label'], [s['label'][p['label'][0]:p['label'][1]] for p in s['parameters']], r['activeParameter']

    def test_capability(self):
        c = self.start()
        self.assertIn('(', c.capabilities['signatureHelpProvider']['triggerCharacters']) if hasattr(c, 'capabilities') else None

    def test_source_routine_and_active_parameter(self):
        src = ('program a;\nprocedure Move2(X, Y: Integer; var Name: string; Z: Real);\nbegin end;\nvar S: string;\n'
               'begin\n  Move2(1, 2, |S, 3.0);\nend.\n')
        label, params, active = self.labels(self.sig(src))
        self.assertEqual(label, 'procedure Move2(X, Y: Integer; var Name: string; Z: Real)')
        self.assertEqual(params, ['X', 'Y: Integer', 'var Name: string', 'Z: Real'])
        self.assertEqual(active, 2)

    def test_first_argument_and_nested_call(self):
        src = ('program a;\nfunction F(A: Integer; B: Integer): Integer;\nbegin F := A end;\nvar V: Integer;\n'
               'begin\n  V := F(|1, 2);\n  V := F(F(1, 2), |3);\nend.\n')
        self.assertEqual(self.labels(self.sig(src))[2], 0)
        src2 = src.replace('F(|1', 'F(1', 1).replace('|3', '3')
        src2 = src2.replace('F(F(1, 2), 3)', 'F(F(1, 2), |3)')
        self.assertEqual(self.labels(self.sig(src2))[2], 1)
        src3 = src.replace('F(|1', 'F(1', 1).replace('F(F(1, |2', 'F(F(1, 2').replace('F(F(1, 2)', 'F(F(1, |2)')
        self.assertEqual(self.labels(self.sig(src3.replace('|3', '3')))[2], 1)

    def test_method_and_library_routine(self):
        src = ('program a;\nuses Crt;\ntype O = object\n    procedure Go(Dx, Dy: Integer);\n  end;\n'
               'procedure O.Go; begin end;\nvar V: O;\nbegin\n  V.Go(1, |2);\n  GotoXY(|1, 1);\nend.\n')
        label, params, active = self.labels(self.sig(src))
        self.assertIn('Go(Dx, Dy: Integer)', label)
        self.assertEqual((params, active), (['Dx', 'Dy: Integer'], 1))
        lib = self.sig(src.replace('V.Go(1, |2)', 'V.Go(1, 2)'))
        self.assertTrue(lib['signatures'][0]['label'].lower().startswith('procedure gotoxy('))
        self.assertEqual(len(lib['signatures'][0]['parameters']), 2)

    def test_not_a_call(self):
        src = 'program a;\nvar A: array[1..3] of Integer;\nbegin\n  A[|1] := 2;\n  (|1 + 2);\nend.\n'
        self.assertIsNone(self.sig(src))
        self.assertIsNone(self.sig('program a;\nvar I: Integer;\nbegin\n  I := 1; |\nend.\n'))

    def test_unclosed_call_while_typing(self):
        src = 'program a;\nprocedure P(A, B: Integer);\nbegin end;\nbegin\n  P(1, |\nend.\n'
        label, params, active = self.labels(self.sig(src))
        self.assertEqual((params, active), (['A', 'B: Integer'], 1))


class Completion(Base):
    def comp(self, src, marker='|', files=None):
        for n, tx in (files or {}).items():
            self.write(n, tx)
        lines = src.split('\n')
        ln = next(i for i, x in enumerate(lines) if marker in x)
        col = lines[ln].index(marker)
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src.replace(marker, '', 1))
        r = c.request('textDocument/completion', {'textDocument': {'uri': u}, 'position': {'line': ln, 'character': col}})['result']
        return None if r is None else {x['label']: x for x in r['items']}

    def test_scope_names_local_before_global_and_keywords(self):
        src = ('program a;\nuses Crt;\nvar Global: Integer;\nprocedure P(Arg: Integer);\nvar Local: Char;\nbegin\n  |\nend;\n'
               'begin\nend.\n')
        r = self.comp(src)
        for name in ('Local', 'Arg', 'Global', 'P', 'ClrScr', 'WriteLn', 'begin', 'Integer'):
            self.assertIn(name, r, name)
        self.assertLess(r['Local']['sortText'], r['Global']['sortText'])
        self.assertLess(r['Global']['sortText'], r['ClrScr']['sortText'])
        self.assertEqual(r['Local']['kind'], 6)

    def test_local_names_are_not_visible_outside(self):
        src = ('program a;\nprocedure P;\nvar Local: Char;\nbegin end;\nbegin\n  |\nend.\n')
        self.assertNotIn('Local', self.comp(src))

    def test_record_and_object_members_with_ancestor(self):
        src = ('program a;\ntype R = record X, Y: Integer end;\n  A = object\n    N: Integer;\n    procedure Hello;\n  end;\n'
               '  B = object(A)\n    procedure Bye;\n  end;\n'
               'procedure A.Hello; begin end;\nprocedure B.Bye; begin end;\n'
               'var V: R; O: B; Arr: array[1..3] of R; P: ^R;\nbegin\n  V.|\nend.\n')
        r = self.comp(src)
        self.assertEqual(sorted(r), ['X', 'Y'])
        self.assertEqual(sorted(self.comp(src.replace('V.|', 'O.|'))), ['Bye', 'Hello', 'N'])
        self.assertEqual(sorted(self.comp(src.replace('V.|', 'Arr[2].|'))), ['X', 'Y'])
        self.assertEqual(sorted(self.comp(src.replace('V.|', 'P^.|'))), ['X', 'Y'])
        self.assertEqual(self.comp(src.replace('V.|', 'O.Bye.|')), None)

    def test_member_after_partial_name_and_self(self):
        src = ('program a;\ntype R = record Xx, Yy: Integer end;\nvar V: R;\nbegin\n  V.X|\nend.\n')
        self.assertEqual(sorted(self.comp(src)), ['Xx', 'Yy'])
        src = ('program a;\ntype A = object\n    N: Integer;\n    procedure Go;\n  end;\nprocedure A.Go;\nbegin\n  Self.|\nend;\nbegin\nend.\n')
        self.assertEqual(sorted(self.comp(src)), ['Go', 'N'])

    def test_unit_members(self):
        src = 'program a;\nuses Crt;\nbegin\n  Crt.|\nend.\n'
        r = self.comp(src)
        self.assertIn('ClrScr', r)
        self.assertNotIn('Integer', r)

    def test_labels_after_goto_and_only_there(self):
        src = ('program a;\nlabel Top, Done;\nprocedure P;\nlabel Inner;\nbegin\n  goto |\nInner: exit;\nend;\nvar V: Integer;\n'
               'begin\nTop: V := 1;\n  goto |\nDone: exit;\nend.\n')
        r = self.comp(src.replace('goto |\nDone', 'goto Done'))          # inside the procedure
        self.assertEqual(sorted(r), ['Done', 'Inner', 'Top'])
        self.assertEqual(r['Inner']['detail'], 'label')
        r = self.comp(src.replace('goto |\nInner', 'goto Inner'))         # in the main block: no local labels of P
        self.assertEqual(sorted(r), ['Done', 'Top'])
        r = self.comp(src.replace('goto |\nInner', 'goto Inner').replace('goto |\nDone', 'goto D|\nDone'))
        self.assertEqual(sorted(r), ['Done', 'Top'])                          # a partly typed name
        plain = self.comp('program a;\nlabel Top;\nbegin\n  |\nTop: exit;\nend.\n')
        self.assertNotIn('Top', plain)                                        # labels are not offered as expressions

    def test_fields_of_with_records(self):
        head = ('program a;\ntype R = record Xx, Yy: Integer end;\n  Q = record Zz: Char end;\nvar V: R; W: Q; Other: Integer;\n'
                'begin\n')
        r = self.comp(head + '  with V do\n    |\nend.\n')
        for name in ('Xx', 'Yy', 'Other', 'begin'):
            self.assertIn(name, r)
        self.assertNotIn('Zz', r)
        self.assertLess(r['Xx']['sortText'], r['Other']['sortText'])        # the fields come first
        r = self.comp(head + '  with V, W do\n    |\nend.\n')                # two records, one inside the other
        self.assertTrue({'Xx', 'Yy', 'Zz'} <= set(r))
        self.assertLess(r['Zz']['sortText'], r['Xx']['sortText'])             # the innermost (last) with first
        r = self.comp(head + '  with V do\n    Other := 1;\n  |\nend.\n')       # after the with statement: no fields
        self.assertNotIn('Xx', r)
        r = self.comp(head + '  with V, |W do;\nend.\n')                    # inside the list of records
        self.assertNotIn('Xx', r)

    def test_only_types_after_a_colon_in_declarations(self):
        src = ('program a;\nuses Crt;\ntype TRec = record F: Integer end;\nconst K = 1;\nvar Count: Integer;\n'
               'procedure P(A: |);\nbegin\nend;\nbegin\nend.\n')
        r = self.comp(src)
        for name in ('Integer', 'TRec', 'string', 'array', 'Crt'):
            self.assertIn(name, r, name)
        for name in ('K', 'Count', 'ClrScr', 'begin', 'P'):
            self.assertNotIn(name, r, name)
        for text in ('var V: |;', 'type T = |;', 'var A: array[1..3] of |;', 'type PT = ^|;', 'type R = record A: |; end;'):
            got = self.comp('program a;\ntype TRec = record F: Integer end;\nconst K = 1;\n%s\nbegin\nend.\n' % text)
            self.assertIn('TRec', got, text)
            self.assertNotIn('K', got, text)
        self.assertIn('object', self.comp('program a;\ntype T = |;\nbegin\nend.\n'))
        self.assertNotIn('object', self.comp('program a;\nvar V: |;\nbegin\nend.\n'))

    def test_colon_in_statements_still_offers_names(self):
        src = 'program a;\nvar X: Integer;\nbegin\n  case X of\n    1: |\n  end;\nend.\n'
        r = self.comp(src)
        self.assertIn('X', r)
        self.assertIn('begin', r)

    def test_uses_lists_units(self):
        src = 'program a;\nuses Crt, |\nbegin\nend.\n'
        r = self.comp(src, files={'geom.pas': 'unit Geom;\ninterface\nimplementation\nend.\n'})
        self.assertIn('geom', r)
        self.assertIn('Dos', r)
        self.assertNotIn('a', r)
        self.assertEqual(r['geom']['kind'], 9)

    def test_nothing_in_comments_strings_and_declaration_names(self):
        self.assertIsNone(self.comp('program a;\nbegin\n  { Wri| }\nend.\n'))
        self.assertIsNone(self.comp("program a;\nbegin\n  WriteLn('He|llo');\nend.\n"))
        self.assertIsNone(self.comp('program a;\nprocedure |\nbegin end;\nbegin\nend.\n'))

    def test_capability(self):
        c = self.start()
        self.assertTrue(c.request('initialize', {'processId': None, 'rootUri': None, 'capabilities': {}})['result']
                        ['capabilities']['completionProvider']['triggerCharacters'] == ['.'])


class InactiveCode(Base):
    def hints(self, src):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        return [x for x in m['params']['diagnostics'] if x['severity'] == 4 and 'inactive' in x['message']]

    def test_switched_off_branches_are_greyed_out(self):
        src = ('program a;\n{$DEFINE ON}\nvar X: Integer;\nbegin\n{$IFDEF ON}\n  X := 1;\n{$ELSE}\n  X := 2;\n  X := 3;\n{$ENDIF}\n'
               '{$IFDEF OFF}\n  X := 4;\n{$ENDIF}\nend.\n')
        h = self.hints(src)
        self.assertEqual([(x['range']['start']['line'], x['range']['end']['line'], x['tags']) for x in h], [(7, 8, [1]), (11, 11, [1])])
        self.assertEqual(h[0]['range']['start']['character'], 2)             # the indent is not greyed

    def test_nothing_to_grey_without_conditionals(self):
        self.assertEqual(self.hints('program a;\nbegin\nend.\n'), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
