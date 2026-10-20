#!/usr/bin/env python3
"""Tests of the responsiveness machinery of tp7lsp.py: coalesced diagnostics, stale and cancelled requests, the caches, and
the fast lexer (against the slow reference one).
Run: python3 test_tp7perf.py [DIR_WITH_SAMPLES]   (DIR must contain TURBO.TPL and GRAPH.TPU, like test_tp7lsp.py)"""
import glob
import os
import random
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_tp7lsp                                                        # noqa: E402
from test_tp7lsp import Base, D                                           # noqa: E402
import tp7lex                                                             # noqa: E402
import tp7lsp                                                             # noqa: E402


class FakeTransport:
    def __init__(self):
        self.sent = []

    def send(self, msg):
        self.sent.append(msg)

    def read(self):
        return None


def make_server(stub_dir):
    t = FakeTransport()
    s = tp7lsp.Server(t)
    s.initialized = True
    s.tpl = os.path.join(D, 'TURBO.TPL')
    s.stubs = tp7lsp.StubStore(stub_dir)
    return s, t


def big_source(procs=300):
    out = ['program big;', 'uses Crt;', 'type TRec = record X, Y: Integer end;']
    for i in range(procs):
        out += ['procedure P%d(A: Integer; var R: TRec);' % i, 'var I: Integer;', 'begin',
                '  for I := 1 to A do R.X := R.X + I * %d;' % i, '  GotoXY(R.X, R.Y);', 'end;', '']
    out += ['begin', 'end.', '']
    return '\r\n'.join(out)


class Queueing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='tp7perf_')
        self.s, self.t = make_server(os.path.join(self.tmp, 'stubs'))
        self.uri = 'file://' + os.path.join(self.tmp, 'a.pas')
        self.s.dispatch({'method': 'textDocument/didOpen', 'params': {'textDocument': {
            'uri': self.uri, 'version': 1, 'text': 'program a;\nbegin\nend.\n'}}})
        self.t.sent.clear()

    def change(self, version, text):
        self.s.dispatch({'method': 'textDocument/didChange', 'params': {
            'textDocument': {'uri': self.uri, 'version': version}, 'contentChanges': [{'text': text}]}})

    def published(self):
        return [m['params'] for m in self.t.sent if m.get('method') == 'textDocument/publishDiagnostics']

    def test_changes_are_diagnosed_once_when_the_typing_pauses(self):
        for v in range(2, 12):
            self.change(v, 'program a;\nbegin\n  x := %d;\nend.\n' % v)
        self.assertEqual(self.published(), [])                           # nothing yet: more input may follow
        self.s.flush_diagnostics()
        self.assertEqual(self.published(), [])                           # ...and not before the quiet time is over
        self.s.flush_diagnostics(force=True)
        pub = self.published()
        self.assertEqual([p['version'] for p in pub], [11])              # one answer, for the newest text
        self.assertIn("unknown identifier 'x'", pub[0]['diagnostics'][0]['message'])

    def test_quiet_time_and_longest_wait(self):
        self.change(2, 'program a;\nbegin\n  y := 1;\nend.\n')
        first, last = self.s.pending[self.uri]
        self.s.pending[self.uri] = (first - 10, last - tp7lsp.DIAG_DELAY - 0.01)       # long quiet: due
        self.s.flush_diagnostics()
        self.assertEqual([p['version'] for p in self.published()], [2])
        self.t.sent.clear()
        self.change(3, 'program a;\nbegin\n  z := 1;\nend.\n')
        now = time.monotonic()
        self.s.pending[self.uri] = (now - tp7lsp.DIAG_MAX_DELAY - 0.01, now)           # typing never stops: due anyway
        self.s.flush_diagnostics()
        self.assertEqual([p['version'] for p in self.published()], [3])

    def test_close_forgets_the_pending_diagnostics(self):
        self.change(2, 'program a;\nbegin\n  y := 1;\nend.\n')
        self.s.dispatch({'method': 'textDocument/didClose', 'params': {'textDocument': {'uri': self.uri}}})
        self.s.flush_diagnostics(force=True)
        self.assertEqual([p['diagnostics'] for p in self.published()], [[]])

    def test_a_request_about_text_that_already_moved_on_is_refused(self):
        self.change(2, 'program a;\nbegin\nend.\n')
        self.s.inbox.put({'jsonrpc': '2.0', 'method': 'textDocument/didChange', 'params': {
            'textDocument': {'uri': self.uri, 'version': 3}, 'contentChanges': [{'text': 'program a;\nbegin end.\n'}]}})
        self.s.dispatch({'jsonrpc': '2.0', 'id': 7, 'method': 'textDocument/semanticTokens/full',
                         'params': {'textDocument': {'uri': self.uri}}})
        self.assertEqual(self.t.sent[-1]['error']['code'], tp7lsp.CONTENT_MODIFIED)
        self.s.dispatch({'jsonrpc': '2.0', 'id': 8, 'method': 'textDocument/hover',      # hover is answered anyway
                         'params': {'textDocument': {'uri': self.uri}, 'position': {'line': 0, 'character': 0}}})
        self.assertNotIn('error', self.t.sent[-1])

    def test_a_cancelled_request_is_not_answered_with_work(self):
        self.s.cancelled.add(9)
        self.s.dispatch({'jsonrpc': '2.0', 'id': 9, 'method': 'textDocument/documentSymbol',
                         'params': {'textDocument': {'uri': self.uri}}})
        self.assertEqual(self.t.sent[-1]['error']['code'], tp7lsp.REQUEST_CANCELLED)


class Dependents(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='tp7perf_')
        self.s, self.t = make_server(os.path.join(self.tmp, 'stubs'))
        self.geom_uri = 'file://' + os.path.join(self.tmp, 'geom.pas')
        self.main_uri = 'file://' + os.path.join(self.tmp, 'main.pas')
        for name, text in (('geom.pas', 'unit Geom;\ninterface\nvar Origin: Integer;\nimplementation\nend.\n'),):
            with open(os.path.join(self.tmp, name), 'wb') as f:
                f.write(text.encode('cp866'))
        self.open(self.geom_uri, 'unit Geom;\ninterface\nvar Origin: Integer;\nimplementation\nend.\n')
        self.open(self.main_uri, 'program main;\nuses Geom;\nbegin\n  Origin := 1;\n  Other := 2;\nend.\n')
        self.t.sent.clear()

    def open(self, uri, text):
        self.s.dispatch({'method': 'textDocument/didOpen', 'params': {'textDocument': {'uri': uri, 'version': 1, 'text': text}}})

    def change(self, uri, version, text):
        self.s.dispatch({'method': 'textDocument/didChange', 'params': {
            'textDocument': {'uri': uri, 'version': version}, 'contentChanges': [{'text': text}]}})

    def last(self, uri):
        got = [m['params'] for m in self.t.sent if m.get('method') == 'textDocument/publishDiagnostics' and m['params']['uri'] == uri]
        return got[-1] if got else None

    def test_a_unit_change_refreshes_the_program_that_uses_it(self):
        self.change(self.geom_uri, 2, 'unit Geom;\ninterface\nvar Origin: Integer; Other: Integer;\nimplementation\nend.\n')
        self.assertIn(self.main_uri, self.s.pending)
        self.s.flush_diagnostics(force=True)
        d = self.last(self.main_uri)
        self.assertEqual([x['message'] for x in d['diagnostics'] if x['severity'] < 4], [])       # `Other` is declared now

    def test_a_program_change_does_not_refresh_others(self):
        self.change(self.main_uri, 2, 'program main;\nuses Geom;\nbegin\n  Origin := 1;\nend.\n')
        self.assertNotIn(self.geom_uri, self.s.pending)

    def test_save_and_file_watcher_refresh(self):
        self.s.dispatch({'method': 'textDocument/didSave', 'params': {'textDocument': {'uri': self.geom_uri}}})
        self.assertIn(self.main_uri, self.s.pending)
        self.s.pending.clear()
        self.s.dispatch({'method': 'workspace/didChangeWatchedFiles', 'params': {'changes': []}})
        self.assertEqual(set(self.s.pending), {self.geom_uri, self.main_uri})


class Caches(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='tp7perf_')
        self.s, self.t = make_server(os.path.join(self.tmp, 'stubs'))
        self.path = os.path.join(self.tmp, 'a.pas')
        self.doc = tp7lsp.Doc('file://' + self.path, 1, 'program a;\nuses Geom;\nbegin\n  Origin := 1;\nend.\n')
        self.s.docs[self.doc.uri] = self.doc
        self.geom = os.path.join(self.tmp, 'geom.pas')
        self.put(self.geom, 'unit Geom;\ninterface\nvar Origin: Integer;\nimplementation\nend.\n')

    @staticmethod
    def put(path, text):
        with open(path, 'wb') as f:
            f.write(text.encode('cp866'))

    def test_provider_is_reused_until_a_unit_changes(self):
        p1 = self.s.provider_for(self.doc)
        p1.get('Geom')
        self.assertIs(self.s.provider_for(self.doc), p1)
        self.put(self.geom, 'unit Geom;\ninterface\nvar Origin: Integer; Extra: Char;\nimplementation\nend.\n')
        p2 = self.s.provider_for(self.doc)
        self.assertIsNot(p2, p1)
        self.assertIn('extra', p2.get('Geom').exports)

    def test_a_new_unit_file_is_found(self):
        p1 = self.s.provider_for(self.doc)
        self.assertIsNone(p1.get('Later'))
        time.sleep(0.01)
        self.put(os.path.join(self.tmp, 'later.pas'), 'unit Later;\ninterface\nimplementation\nend.\n')
        self.assertIsNotNone(self.s.provider_for(self.doc).get('Later'))

    def test_an_open_buffer_of_another_unit_wins_and_is_cached(self):
        other = tp7lsp.Doc('file://' + self.geom, 1, 'unit Geom;\ninterface\nvar Mine: Integer;\nimplementation\nend.\n')
        self.s.docs[other.uri] = other
        p1 = self.s.provider_for(self.doc)
        self.assertIn('mine', p1.get('Geom').exports)
        self.assertIs(self.s.provider_for(self.doc), p1)
        other.text = 'unit Geom;\ninterface\nvar Yours: Integer;\nimplementation\nend.\n'
        self.assertIn('yours', self.s.provider_for(self.doc).get('Geom').exports)

    def test_binding_is_shared_until_the_text_changes(self):
        prov = self.s.provider_for(self.doc)
        b1 = self.s.bind_doc(self.doc, prov)
        self.assertIs(self.s.bind_doc(self.doc, self.s.provider_for(self.doc)), b1)
        self.doc.text += ' '
        self.assertIsNot(self.s.bind_doc(self.doc, self.s.provider_for(self.doc)), b1)

    def test_diagnosing_twice_gives_the_same_answer(self):
        d1 = self.s.diagnose(self.doc)
        self.assertEqual(self.s.diagnose(self.doc), d1)
        self.assertEqual([x['message'] for x in d1 if x['severity'] < 4], [])


class FastLexer(unittest.TestCase):
    def same(self, text):
        a, b = tp7lex.lex(text), tp7lex.lex_reference(text)
        self.assertEqual([(t.kind, t.text, t.pos, t.line, t.col) for t in a], [(t.kind, t.text, t.pos, t.line, t.col) for t in b], repr(text))

    def test_samples(self):
        files = glob.glob(os.path.join(D, '*.[pP][aA][sS]')) + glob.glob(os.path.join(D, '*.[iI][nN][cC]'))
        for f in files:
            with open(f, 'rb') as fh:
                self.same(fh.read().decode('cp866'))

    def test_broken_input(self):
        for s in ["{ never closed", "(* never closed", "'unterminated\nnext", "#", "#$", "$", "a\x1a", "\x1a\r\n\x1a", "x := 1;\x1a",
                  "\"!?\\&%", "1..2 1.5e+3 1e 2e5 $FF $G", "@@lab @@ @", "(. .) (.", "{$I+} (*$X*) {$}", "é Ж_1", "a\rb\r\nc\nd"]:
            self.same(s)

    def test_random_input(self):
        rnd = random.Random(7)
        alpha = ["{", "}", "(*", "*)", "'", "''", '"', "#", "$", "@@", "@", "a", "Z", "_", "0", "9", "1.5", "1..2", "1e5", ".", ":=",
                 ":", "<", ">", "=", "\r", "\n", "\r\n", " ", "\t", "\x1a", "^", "(.", ".)", "é", "begin", "end", "{$I+}", "(*$X*)"]
        for _ in range(4000):
            self.same(''.join(rnd.choice(alpha) for _ in range(rnd.randint(0, 14))))

    def test_it_is_faster_than_the_reference(self):
        src = big_source(200)

        def best(f):
            runs = []
            for _ in range(7):
                t0 = time.perf_counter()
                f(src)
                runs.append(time.perf_counter() - t0)
            return min(runs)
        self.assertLess(best(tp7lex.lex), best(tp7lex.lex_reference) * 1.05)    # (timing is noisy: only 'not slower' is claimed)


class Typing(Base):
    def test_fast_typing_in_a_large_file_is_answered_for_the_last_version(self):
        text = big_source(400)
        c = self.start()
        u = c.open(os.path.join(self.ws, 'big.pas'), text)
        c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        start = time.time()
        n = 25
        for v in range(2, 2 + n):                                           # a keystroke every few milliseconds
            c.change(u, text.replace('begin\r\nend.', 'begin\r\n  zz%d := 1;\r\nend.' % v), v)
            c.notify('textDocument/semanticTokens/full', {})                  # (ignored: no id) keeps the queue busy
        last = 1 + n
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u and m['params']['version'] == last, timeout=60)
        self.assertIn('zz%d' % last, m['params']['diagnostics'][0]['message'])
        versions = [x['params']['version'] for x in c.seen if x.get('method') == 'textDocument/publishDiagnostics']
        self.assertLess(len(versions), n // 2, versions)                    # the intermediate versions were skipped
        self.assertLess(time.time() - start, 30)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + [a for a in sys.argv[1:] if a.startswith('-')], verbosity=2)
