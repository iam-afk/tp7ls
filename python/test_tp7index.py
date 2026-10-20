#!/usr/bin/env python3
"""Tests of the project index (tp7index): units in subfolders of the workspace.
Run: python3 test_tp7index.py"""
import os
import sys
import tempfile
import unittest
import shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tp7lsp import Base                                              # noqa: E402
from tp7index import ProjectIndex                                         # noqa: E402
from tp7sema import Provider                                              # noqa: E402

UNIT = 'unit %s;\ninterface\nvar V%s: Integer;\nprocedure P%s;\nimplementation\nprocedure P%s;\nbegin\nend;\nend.\n'


def unit(name):
    return UNIT % (name, name, name, name)


class Tree(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def put(self, rel, text='x'):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(text.encode('cp866'))
        return p

    def test_units_below_the_root_are_found_pas_before_tpu(self):
        a = self.put('src/deep/Alpha.pas', unit('Alpha'))
        self.put('lib/ALPHA.TPU')
        self.put('lib/Beta.tpu')
        ix = ProjectIndex([self.d], throttle=0)
        self.assertEqual(ix.find_unit('alpha', '.pas'), a)
        self.assertTrue(ix.find_unit('ALPHA', '.tpu').endswith('ALPHA.TPU'))
        self.assertEqual(ix.unit_names(), ['Alpha', 'Beta'])
        self.assertEqual([os.path.basename(p) for p in ix.sources()], ['Alpha.pas'])

    def test_nearest_of_several_wins(self):
        self.put('a/x/Util.pas', unit('Util'))
        b = self.put('b/Util.pas', unit('Util'))
        user = self.put('b/sub/main.pas')
        ix = ProjectIndex([self.d], throttle=0)
        self.assertEqual(ix.find_unit('util', '.pas', near=user), b)
        self.assertEqual(len(ix.duplicates()['util']), 2)

    def test_changes_are_seen_and_generation_moves(self):
        ix = ProjectIndex([self.d], throttle=0)
        ix.refresh()
        g = ix.generation
        self.assertIsNone(ix.find_unit('late', '.pas'))
        self.put('new/dir/Late.pas', unit('Late'))
        self.assertIsNotNone(ix.find_unit('late', '.pas'))
        self.assertGreater(ix.generation, g)
        g = ix.generation
        ix.refresh(force=True)
        self.assertEqual(ix.generation, g)                         # nothing changed: nothing rebuilt
        os.remove(os.path.join(self.d, 'new/dir/Late.pas'))
        self.assertIsNone(ix.find_unit('late', '.pas'))

    def test_hidden_folders_and_limits(self):
        self.put('.git/Hid.pas')
        for i in range(30):
            self.put('f/U%d.pas' % i)
        ix = ProjectIndex([self.d], max_files=10, throttle=0)
        ix.refresh()
        self.assertTrue(ix.truncated)
        self.assertIsNone(ix.find_unit('hid', '.pas'))

    def test_include_by_name_in_another_folder(self):
        p = self.put('common/defs.inc', 'const K = 1;')
        ix = ProjectIndex([self.d], throttle=0)
        self.assertEqual(ix.find_file('DEFS.INC'), p)
        self.assertEqual(ix.find_file('common\\defs.inc'), p)
        self.assertIsNone(ix.find_file('other/defs.inc'))

    def test_provider_loads_a_unit_from_a_subfolder(self):
        self.put('src/Alpha.pas', unit('Alpha'))
        ix = ProjectIndex([self.d], throttle=0)
        prov = Provider([self.d], None, index=ix)
        u = prov.get('alpha')
        self.assertIn('valpha', u.exports)
        self.assertIn('Alpha', prov.unit_names())
        self.assertTrue(prov.still_valid())
        self.put('src2/Gamma.pas', unit('Gamma'))
        self.assertFalse(prov.still_valid())                       # the tree changed: loaded units are suspect


class Workspace(Base):
    def fresh(self):
        d = tempfile.mkdtemp(dir=self.tmp)                     # every test its own workspace
        self.root = d
        return d

    def put(self, rel, text):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(text.encode('cp866'))
        return p

    def test_unit_in_subfolder_is_known_and_navigable(self):
        self.fresh()
        self.put('lib/core/alpha.pas', unit('Alpha'))
        c = self.start(root=self.root)
        src = 'program m;\nuses Alpha;\nbegin\n  PAlpha;\n  VAlpha := 1;\n  Unknwn := 2;\nend.\n'
        u = c.open(os.path.join(self.root, 'm.pas'), src)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual([x['message'] for x in m['params']['diagnostics']], ["unknown identifier 'Unknwn'"])
        r = c.request('textDocument/definition', {'textDocument': {'uri': u}, 'position': {'line': 3, 'character': 3}})['result']
        loc = r[0] if isinstance(r, list) else r
        self.assertTrue(loc['uri'].lower().endswith('lib/core/alpha.pas'), loc)

    def test_uses_completion_offers_project_units(self):
        self.fresh()
        self.put('zlib/Zeta.pas', unit('Zeta'))
        c = self.start(root=self.root)
        u = c.open(os.path.join(self.root, 'm.pas'), 'program m;\nuses Ze\nbegin\nend.\n')
        r = c.request('textDocument/completion', {'textDocument': {'uri': u}, 'position': {'line': 1, 'character': 7}})['result']
        items = r['items'] if isinstance(r, dict) else r
        self.assertIn('Zeta', [i['label'] for i in items])

    def test_unit_created_later_is_picked_up_after_a_watched_files_event(self):
        self.fresh()
        c = self.start(root=self.root)
        u = c.open(os.path.join(self.root, 'm.pas'), 'program m;\nuses Later;\nbegin\nend.\n')
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertIn("unit 'Later' not found", m['params']['diagnostics'][0]['message'])
        self.put('zsrc/deep/later.pas', unit('Later'))
        c.notify('workspace/didChangeWatchedFiles', {'changes': [{'uri': u, 'type': 1}]})
        m = c.wait_for('textDocument/publishDiagnostics',
                       lambda m: m['params']['uri'] == u and not any('not found' in x['message'] for x in m['params']['diagnostics']))
        self.assertTrue(all(x['severity'] > 2 for x in m['params']['diagnostics']))     # at most the hint 'not used'

    def test_references_reach_files_in_subfolders(self):
        self.fresh()
        self.put('alpha.pas', unit('Alpha'))
        self.put('zsub/user.pas', 'program user;\nuses Alpha;\nbegin\n  PAlpha;\nend.\n')
        c = self.start(root=self.root)
        u = c.open(os.path.join(self.root, 'alpha.pas'), unit('Alpha'))
        r = c.request('textDocument/references', {'textDocument': {'uri': u}, 'position': {'line': 3, 'character': 11},
                                                  'context': {'includeDeclaration': True}})['result']
        self.assertTrue(any(x['uri'].lower().endswith('zsub/user.pas') for x in r), r)


if __name__ == '__main__':
    unittest.main()
