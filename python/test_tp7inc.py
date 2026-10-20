#!/usr/bin/env python3
"""Protocol tests of {$I file} include files (tp7parse.prepare splices them, tp7lsp maps positions).
Run: python3 test_tp7inc.py [DIR_WITH_SAMPLES]"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tp7lsp import Base, uri                                         # noqa: E402
from tp7parse import parse                                                # noqa: E402


class Splice(unittest.TestCase):
    FILES = {'a.inc': 'const A = 1;\n{$I b.inc}\n', 'b.inc': 'type T = integer;\n{$I a.inc}\n'}

    @staticmethod
    def inc(name, frm):
        n = name.strip()
        return (os.path.abspath(n), Splice.FILES[n]) if n in Splice.FILES else None

    def test_tokens_are_spliced_and_marked(self):
        r = parse('program p;\n{$I a.inc}\nvar x: T;\nbegin end.\n', include=self.inc, path='main.pas')
        self.assertEqual(r.diags, [])
        words = [(t.text, os.path.basename(t.file) if t.file else None) for t in r.sig]
        self.assertIn(('A', 'a.inc'), words)
        self.assertIn(('T', 'b.inc'), words)
        self.assertIn(('x', None), words)
        self.assertTrue(all(t.via is not None for t in r.sig if t.file))

    def test_loop_is_left_unresolved(self):
        r = parse('program p;\n{$I a.inc}\nbegin end.\n', include=self.inc, path='main.pas')
        self.assertEqual([len(x) for x in r.includes], [3, 3, 2])        # a.inc, b.inc, then a.inc again: not spliced

    def test_without_a_resolver_nothing_changes(self):
        r = parse('program p;\n{$I a.inc}\nbegin end.\n')
        self.assertEqual(len(r.includes), 1)
        self.assertEqual(len(r.includes[0]), 2)
        self.assertTrue(all(t.file is None for t in r.sig))


class Includes(Base):
    def open(self, text, files=None, name='a.pas'):
        for n, t in (files or {}).items():
            os.makedirs(os.path.dirname(os.path.join(self.ws, n)), exist_ok=True)
            self.write(n, t)
        c = self.start()
        path = os.path.join(self.ws, name)
        u = c.open(path, text)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        return c, u, m['params']['diagnostics']

    DEFS = 'const MaxN = 10;\nvar Total: Integer;\nprocedure Bump;\nbegin\n  Inc(Total);\nend;\n'

    def test_names_of_the_include_file_are_known(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  Total := MaxN;\n  Bump;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        self.assertEqual(d, [])

    def test_unknown_names_are_still_reported(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  Totl := MaxN;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        self.assertEqual([x['message'] for x in d], ["unknown identifier 'Totl'"])
        self.assertEqual(d[0]['range']['start']['line'], 3)

    def test_missing_include_is_an_error_at_the_directive_and_names_are_not_checked(self):
        src = 'program a;\n{$I nothere.inc}\nbegin\n  Whatever := 1;\nend.\n'
        c, u, d = self.open(src)
        self.assertEqual(len(d), 1, d)
        self.assertEqual((d[0]['severity'], d[0]['range']['start']['line']), (1, 1))
        self.assertIn("include file 'nothere.inc' not found", d[0]['message'])

    def test_name_is_found_without_regard_to_case_extension_and_backslash(self):
        src = 'program a;\n{$I INC\\Defs}\nbegin\n  Total := 1;\nend.\n'
        c, u, d = self.open(src, {'inc/defs.pas': self.DEFS})
        self.assertEqual(d, [])

    def test_nested_include_is_relative_to_the_file_that_includes_it(self):
        src = 'program a;\n{$I sub/outer.inc}\nbegin\n  Deep := 1;\nend.\n'
        c, u, d = self.open(src, {'sub/outer.inc': '{$I inner.inc}\n', 'sub/inner.inc': 'var Deep: Integer;\n'})
        self.assertEqual(d, [])

    def test_variable_used_only_in_an_include_is_not_unused(self):
        src = 'program a;\nvar V: Integer;\nbegin\n{$I body.inc}\nend.\n'
        c, u, d = self.open(src, {'body.inc': 'V := 1;\n'})
        self.assertEqual(d, [])

    def test_declarations_in_the_include_file_get_no_hints(self):
        src = 'program a;\n{$I defs.inc}\nbegin\nend.\n'
        c, u, d = self.open(src, {'defs.inc': 'var Never: Integer;\n'})
        self.assertEqual(d, [])

    def test_syntax_error_inside_an_include_file_shows_at_the_directive(self):
        src = 'program a;\n{$I bad.inc}\nbegin\nend.\n'
        c, u, d = self.open(src, {'bad.inc': 'var X: ;\n'})
        self.assertTrue(d)
        self.assertTrue(all(x['range']['start']['line'] == 1 for x in d), d)

    def test_definition_and_hover_lead_into_the_include_file(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  Total := 1;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        pos = {'line': 3, 'character': 4}
        r = c.request('textDocument/definition', {'textDocument': {'uri': u}, 'position': pos})['result']
        r = r[0] if isinstance(r, list) else r
        self.assertEqual(os.path.basename(r['uri']), 'defs.inc')
        self.assertEqual((r['range']['start']['line'], r['range']['start']['character']), (1, 4))
        h = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': pos})['result']
        self.assertIn('defs.inc', h['contents']['value'])

    def test_unsaved_buffer_of_the_include_file_wins_and_changes_refresh_the_includer(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  Total := 1;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        self.assertEqual(d, [])
        inc = os.path.join(self.ws, 'defs.inc')
        ui = c.open(inc, self.DEFS.replace('Total', 'Sum'))                       # the editor has other text
        m = c.wait_for('textDocument/publishDiagnostics',
                       lambda m: m['params']['uri'] == u and m['params']['diagnostics'])
        self.assertEqual([x['message'] for x in m['params']['diagnostics']], ["unknown identifier 'Total'"])
        c.change(ui, self.DEFS, 2)
        m = c.wait_for('textDocument/publishDiagnostics',
                       lambda m: m['params']['uri'] == u and not m['params']['diagnostics'])
        self.assertEqual(m['params']['diagnostics'], [])

    def test_references_include_the_uses_in_the_include_file(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  Total := 1;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        r = c.request('textDocument/references', {'textDocument': {'uri': u}, 'position': {'line': 3, 'character': 3},
                                                  'context': {'includeDeclaration': True}})['result']
        got = sorted((os.path.basename(x['uri']), x['range']['start']['line']) for x in r)
        self.assertEqual(got, [('a.pas', 3), ('defs.inc', 1), ('defs.inc', 4)])

    def test_rename_is_refused_across_include_files_and_works_otherwise(self):
        src = 'program a;\nvar Mine: Integer;\n{$I defs.inc}\nbegin\n  Total := Mine;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        r = c.request('textDocument/rename', {'textDocument': {'uri': u}, 'position': {'line': 4, 'character': 3},
                                              'newName': 'Sum'})
        self.assertIn('declared in the include file defs.inc', r['error']['message'])
        r = c.request('textDocument/rename', {'textDocument': {'uri': u}, 'position': {'line': 1, 'character': 5},
                                              'newName': 'Yours'})
        self.assertEqual(len(r['result']['changes'][u]), 2)
        r = c.request('textDocument/rename', {'textDocument': {'uri': u}, 'position': {'line': 1, 'character': 5},
                                              'newName': 'MaxN'})
        self.assertIn('already declared in this scope (defs.inc, line 1)', r['error']['message'])

    def test_formatting_keeps_the_directive_and_does_not_inline_the_file(self):
        src = 'program a;\n{$I defs.inc}\nbegin\n  total:=1;\nend.\n'
        c, u, d = self.open(src, {'defs.inc': self.DEFS})
        out = c.formatted(u, src)
        self.assertIn('{$I defs.inc}', out)
        self.assertNotIn('MaxN', out)


if __name__ == '__main__':
    unittest.main()
