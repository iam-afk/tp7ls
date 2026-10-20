#!/usr/bin/env python3
"""Protocol tests of selectionRange, rangeFormatting, workspace/symbol and codeAction of tp7lsp.py.
Run: python3 test_tp7edit.py [DIR_WITH_SAMPLES]   (DIR must contain TURBO.TPL and GRAPH.TPU, like test_tp7lsp.py)"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tp7lsp import Base                                             # noqa: E402


def apply(text, edits):
    """Apply LSP TextEdits (non-overlapping) to a text with \\n or \\r\\n line ends."""
    lines = text.split('\n')
    starts = [0]
    for ln in lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)

    def off(p):
        return starts[min(p['line'], len(lines) - 1)] + p['character'] if p['line'] < len(lines) else len(text)
    for e in sorted(edits, key=lambda e: off(e['range']['start']), reverse=True):
        text = text[:off(e['range']['start'])] + e['newText'] + text[off(e['range']['end']):]
    return text


class EditBase(Base):
    def open_doc(self, src, name='a.pas', root=None):
        c = self.start(root=root) if root else self.start()
        u = c.open(os.path.join(root or self.ws, name), src)
        return c, u

    def actions(self, src, needle, only=None, nth=0, length=None):
        """Code actions for the range of the nth `needle` in src."""
        c, u = self.open_doc(src)
        idx = -1
        for _ in range(nth + 1):
            idx = src.index(needle, idx + 1)
        before = src[:idx]
        ln = before.count('\n')
        col = idx - (before.rfind('\n') + 1)
        rng = {'start': {'line': ln, 'character': col}, 'end': {'line': ln, 'character': col + (length or len(needle))}}
        ctx = {'diagnostics': []}
        if only:
            ctx['only'] = only
        r = c.request('textDocument/codeAction', {'textDocument': {'uri': u}, 'range': rng, 'context': ctx})['result']
        return {a['title']: a for a in r}, u


class SelectionRange(EditBase):
    def test_expands_from_token_to_the_whole_file(self):
        src = 'program a;\nvar X: Integer;\nbegin\n  X := (1 + 2) * 3;\nend.\n'
        c, u = self.open_doc(src)
        r = c.request('textDocument/selectionRange', {'textDocument': {'uri': u}, 'positions': [{'line': 3, 'character': 10}]})['result'][0]
        chain = []
        while r is not None:
            chain.append(r['range'])
            r = r.get('parent')
        self.assertEqual(chain[0], {'start': {'line': 3, 'character': 10}, 'end': {'line': 3, 'character': 11}})   # the 1
        self.assertGreater(len(chain), 4)
        for inner, outer in zip(chain, chain[1:]):                       # every range holds the previous one
            a, b = (inner['start']['line'], inner['start']['character']), (outer['start']['line'], outer['start']['character'])
            self.assertLessEqual(b, a)
            self.assertGreaterEqual((outer['end']['line'], outer['end']['character']), (inner['end']['line'], inner['end']['character']))
        self.assertEqual(chain[-1]['start'], {'line': 0, 'character': 0})
        self.assertEqual(chain[-1]['end']['line'], 4)

    def test_every_position_gets_an_answer(self):
        c, u = self.open_doc('program a;\n\nbegin\nend.\n')
        r = c.request('textDocument/selectionRange', {'textDocument': {'uri': u},
                                                       'positions': [{'line': 1, 'character': 0}, {'line': 2, 'character': 2}]})['result']
        self.assertEqual(len(r), 2)
        self.assertTrue(all('range' in x for x in r))


class RangeFormatting(EditBase):
    SRC = 'program a;\nvar X:Integer;\nbegin\n  X:=1;\n  X:=2;\nend.\n'

    def test_only_the_selected_lines_change(self):
        c, u = self.open_doc(self.SRC)
        full = c.request('textDocument/formatting', {'textDocument': {'uri': u}, 'options': {}})['result']
        self.assertIn('X := 1;', apply(self.SRC, full))
        r = c.request('textDocument/rangeFormatting', {'textDocument': {'uri': u}, 'options': {},
                      'range': {'start': {'line': 4, 'character': 0}, 'end': {'line': 4, 'character': 6}}})['result']
        out = apply(self.SRC, r)
        self.assertIn('  X := 2;', out)
        self.assertIn('  X:=1;', out)
        self.assertIn('var X:Integer;', out)

    def test_nothing_to_do_in_a_formatted_range(self):
        c, u = self.open_doc(self.SRC)
        full = apply(self.SRC, c.request('textDocument/formatting', {'textDocument': {'uri': u}, 'options': {}})['result'])
        c.change(u, full, 2)
        r = c.request('textDocument/rangeFormatting', {'textDocument': {'uri': u}, 'options': {},
                      'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 5, 'character': 0}}})['result']
        self.assertEqual(r, [])


class WorkspaceSymbols(EditBase):
    def test_finds_symbols_in_files_and_ranks_them(self):
        self.write('geom.pas', 'unit Geom;\ninterface\nprocedure MoveTo(X, Y: Integer);\nimplementation\n'
                               'procedure MoveTo(X, Y: Integer); begin end;\nend.\n')
        self.write('b.pas', 'program b;\nprocedure Remove; begin end;\nprocedure Mover; begin end;\nbegin\nend.\n')
        c = self.start()
        r = c.request('workspace/symbol', {'query': 'move'})['result']
        names = [x['name'].split('(')[0].strip() for x in r]
        self.assertIn('MoveTo', names)
        self.assertIn('Mover', names)
        self.assertIn('Remove', names)
        self.assertLess(names.index('Mover'), names.index('Remove'))        # prefix before substring
        self.assertTrue(all(x['location']['uri'].startswith('file://') for x in r))
        self.assertEqual(c.request('workspace/symbol', {'query': 'zzzz'})['result'], [])

    def test_open_buffer_wins_and_changes_are_seen(self):
        c, u = self.open_doc('program a;\nprocedure Alpha; begin end;\nbegin\nend.\n')
        self.assertIn('Alpha', [x['name'].split('(')[0] for x in c.request('workspace/symbol', {'query': 'alp'})['result']])
        c.change(u, 'program a;\nprocedure Beta; begin end;\nbegin\nend.\n', 2)
        self.assertEqual(c.request('workspace/symbol', {'query': 'alp'})['result'], [])
        self.assertTrue(c.request('workspace/symbol', {'query': 'bet'})['result'])


class CodeActions(EditBase):
    def test_remove_unused_variable_and_declaration_pieces(self):
        src = 'program a;\nvar Used, Spare: Integer;\n    Gone: Char;\nbegin\n  Used := 1;\nend.\n'
        acts, u = self.actions(src, 'Spare')
        self.assertEqual(apply(src, acts["Remove unused variable 'Spare'"]['edit']['changes'][u]),
                         'program a;\nvar Used: Integer;\n    Gone: Char;\nbegin\n  Used := 1;\nend.\n')
        acts, u = self.actions(src, 'Gone')
        self.assertEqual(apply(src, acts["Remove unused variable 'Gone'"]['edit']['changes'][u]),
                         'program a;\nvar Used, Spare: Integer;\nbegin\n  Used := 1;\nend.\n')

    def test_the_only_declaration_takes_its_section_along(self):
        src = 'program a;\nconst K = 1;\nbegin\nend.\n'
        acts, u = self.actions(src, 'K')
        self.assertEqual(apply(src, acts["Remove unused constant 'K'"]['edit']['changes'][u]), 'program a;\nbegin\nend.\n')

    def test_remove_unused_unit_and_organize_imports(self):
        src = 'program a;\nuses Crt, Dos, Printer;\nbegin\n  ClrScr;\nend.\n'
        acts, u = self.actions(src, 'Dos')
        self.assertEqual(apply(src, acts["Remove unused unit 'Dos'"]['edit']['changes'][u]),
                         'program a;\nuses Crt, Printer;\nbegin\n  ClrScr;\nend.\n')
        acts, u = self.actions(src, 'Dos', only=['source.organizeImports'])
        self.assertEqual(list(acts), ['Remove unused units'])
        self.assertEqual(apply(src, acts['Remove unused units']['edit']['changes'][u]),
                         'program a;\nuses Crt;\nbegin\n  ClrScr;\nend.\n')
        src2 = 'program a;\nuses Dos;\nbegin\nend.\n'
        acts, u = self.actions(src2, 'Dos')
        self.assertEqual(apply(src2, acts["Remove unused unit 'Dos'"]['edit']['changes'][u]), 'program a;\nbegin\nend.\n')

    def test_enumeration_members_used_without_the_type_name(self):
        src = 'program a;\ntype Color = (Red, Green);\nvar C: Integer;\nbegin\n  C := Ord(Red);\nend.\n'
        acts, u = self.actions(src, 'Color')
        self.assertNotIn("Remove unused type 'Color'", acts)

    def test_spelling_suggestion(self):
        src = 'program a;\nvar Counter: Integer;\nbegin\n  Countr := 1;\n  Counter := 2;\nend.\n'
        acts, u = self.actions(src, 'Countr')
        self.assertEqual(apply(src, acts["Change to 'Counter'"]['edit']['changes'][u]),
                         src.replace('Countr', 'Counter'))

    def test_add_missing_implementation(self):
        src = ('unit u;\ninterface\ntype O = object\n    procedure Go(Dx: Integer);\n    virtual;\n  end;\nfunction F(A: Integer): Boolean;\n'
               'implementation\nfunction F(A: Integer): Boolean; begin F := True end;\nend.\n')
        acts, u = self.actions(src, 'Go')
        out = apply(src, acts["Add implementation of 'O.Go'"]['edit']['changes'][u])
        self.assertIn('procedure O.Go(Dx: Integer);\nbegin\nend;\n', out)
        self.assertLess(out.index('procedure O.Go'), out.rindex('end.'))
        src = 'program a;\nprocedure P(A: Integer); forward;\nbegin\nend.\n'
        acts, u = self.actions(src, 'P', nth=0, length=1)
        out = apply(src, acts["Add implementation of 'P'"]['edit']['changes'][u])
        self.assertIn('procedure P(A: Integer);\nbegin\nend;\n\nbegin\nend.', out)

    def test_no_actions_when_the_file_does_not_parse(self):
        c, u = self.open_doc('program a;\nvar X: ;\nbegin\nend.\n')
        r = c.request('textDocument/codeAction', {'textDocument': {'uri': u}, 'context': {'diagnostics': []},
                      'range': {'start': {'line': 1, 'character': 4}, 'end': {'line': 1, 'character': 5}}})['result']
        self.assertEqual(r, [])


class Labels(EditBase):
    SRC = 'program a;\nlabel\n  m;\nbegin\n  goto m;\nm:\n  exit;\nend.\n'

    def go(self, method, line, col):
        c, u = self.open_doc(self.SRC)
        r = c.request('textDocument/' + method, {'textDocument': {'uri': u}, 'position': {'line': line, 'character': col}})['result']
        return (r['range']['start']['line'], r['range']['start']['character'])

    def test_definition_of_a_goto_is_the_label_itself(self):
        self.assertEqual(self.go('definition', 4, 8), (5, 0))

    def test_declaration_of_a_goto_is_the_label_section(self):
        self.assertEqual(self.go('declaration', 4, 8), (2, 2))

    def test_definition_from_the_declaration_and_from_the_label(self):
        self.assertEqual(self.go('definition', 2, 2), (5, 0))
        self.assertEqual(self.go('definition', 5, 0), (5, 0))


class NumericLabels(EditBase):
    SRC = 'program a;\nlabel\n  1, Done;\nbegin\n  goto 1;\n  goto Done;\n1:\n  Inc(x);\nDone:\nend.\n'

    def req(self, c, u, method, line, col, **extra):
        return c.request('textDocument/' + method, dict({'textDocument': {'uri': u}, 'position': {'line': line, 'character': col}}, **extra))

    def test_definition_declaration_references_and_highlight(self):
        c, u = self.open_doc(self.SRC)
        r = self.req(c, u, 'definition', 4, 8)['result']
        self.assertEqual((r['range']['start']['line'], r['range']['start']['character']), (6, 0))     # the label `1:`
        r = self.req(c, u, 'declaration', 4, 8)['result']
        self.assertEqual((r['range']['start']['line'], r['range']['start']['character']), (2, 2))     # `label 1`
        refs = self.req(c, u, 'references', 4, 8, context={'includeDeclaration': True})['result']
        self.assertEqual(sorted(x['range']['start']['line'] for x in refs), [2, 4, 6])
        hl = self.req(c, u, 'documentHighlight', 6, 0)['result']
        self.assertEqual(sorted(x['range']['start']['line'] for x in hl), [2, 4, 6])

    def test_ordinary_numbers_are_not_labels(self):
        c, u = self.open_doc('program a;\nvar x: Integer;\nbegin\n  x := 10;\nend.\n')
        self.assertIsNone(self.req(c, u, 'definition', 3, 8)['result'])
        self.assertIsNone(self.req(c, u, 'prepareRename', 3, 8)['result'])
        self.assertEqual(self.req(c, u, 'hover', 3, 8)['result'], None)

    def test_a_numeric_label_is_not_renamed(self):
        c, u = self.open_doc(self.SRC)
        r = c.request('textDocument/rename', {'textDocument': {'uri': u}, 'position': {'line': 4, 'character': 8}, 'newName': 'Top'})
        self.assertIn('numeric label', r['error']['message'])

    def test_undeclared_numeric_label_is_reported(self):
        c, u = self.open_doc('program a;\nbegin\n  goto 7;\nend.\n')
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual([d['message'] for d in m['params']['diagnostics']], ["label '7' is not declared"])

    def test_goto_completion_offers_numeric_labels_too(self):
        src = 'program a;\nlabel 1, Done;\nbegin\n  goto \nDone: exit;\nend.\n'
        c, u = self.open_doc(src)
        r = self.req(c, u, 'completion', 3, 7)['result']
        self.assertEqual(sorted(x['label'] for x in r['items']), ['1', 'Done'])


if __name__ == '__main__':
    args = [a for a in sys.argv[1:]]
    unittest.main(argv=[sys.argv[0]] + [a for a in args if a.startswith('-')], verbosity=2)
