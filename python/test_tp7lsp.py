#!/usr/bin/env python3
"""Protocol tests for tp7lsp.py: the server is started as a real subprocess and driven over its stdin/stdout with
Content-Length framed JSON-RPC, exactly as an editor does.  Run: python3 test_tp7lsp.py [DIR_WITH_SAMPLES]
DIR must contain TURBO.TPL, GRAPH.TPU, polsk.pas and polsk_formatted.pas."""
import json
import os
import pathlib
import queue
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tp7lsp import compute_edits, split_lines, utf16_len          # pure helpers

SERVER = os.path.join(HERE, 'tp7lsp.py')
D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'


def rd(name):
    with open(os.path.join(D, name), 'rb') as f:
        return f.read().decode('cp866')


def uri(path):
    return pathlib.Path(path).as_uri()


def apply_edits(text, edits):
    """LSP semantics: positions are (line, UTF-16 column) in the ORIGINAL text."""
    lines = split_lines(text)

    def offset(pos):
        line, ch = pos['line'], pos['character']
        if line >= len(lines):
            return len(text)
        off = sum(len(x) for x in lines[:line])
        s, units, i = lines[line], 0, 0
        while i < len(s) and units < ch:
            units += 2 if ord(s[i]) > 0xFFFF else 1
            i += 1
        return off + i

    spans = sorted(((offset(e['range']['start']), offset(e['range']['end']), e['newText']) for e in edits),
                   reverse=True)
    for s, e, new in spans:
        text = text[:s] + new + text[e:]
    return text


# ---------------------------------------------------------------------------------------------------
class Client:
    def __init__(self, env=None):
        e = dict(os.environ)
        e.pop('TP7_DIR', None)
        e.update(env or {})
        self.p = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=e)
        self.q = queue.Queue()
        self.seen = []
        self.stderr = []
        self.next_id = 1
        threading.Thread(target=self._pump, daemon=True).start()
        threading.Thread(target=self._drain, daemon=True).start()

    def _pump(self):
        out = self.p.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    self.q.put(None)
                    return
                line = line.rstrip(b'\r\n')
                if not line:
                    break
                k, _, v = line.partition(b':')
                if k.lower() == b'content-length':
                    length = int(v)
            body = out.read(length)
            self.q.put(json.loads(body.decode('utf-8')))

    def _drain(self):
        for line in self.p.stderr:
            self.stderr.append(line.decode('utf-8', 'replace'))

    # -- sending ---------------------------------------------------------------------------------------
    def raw(self, data: bytes):
        self.p.stdin.write(data)
        self.p.stdin.flush()

    def send(self, msg):
        body = json.dumps(msg).encode('utf-8')
        self.raw(b'Content-Length: %d\r\n\r\n' % len(body) + body)

    def notify(self, method, params=None):
        self.send({'jsonrpc': '2.0', 'method': method, 'params': params or {}})

    def get(self, timeout=15):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError('timeout waiting for the server; stderr:\n' + ''.join(self.stderr))

    def request(self, method, params=None, timeout=15):
        i = self.next_id
        self.next_id += 1
        self.send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params or {}})
        while True:
            m = self.get(timeout)
            if m is None:
                raise AssertionError('server closed the connection; stderr:\n' + ''.join(self.stderr))
            if m.get('id') == i and 'method' not in m:
                return m
            self.seen.append(m)

    def wait_for(self, method, pred=lambda m: True, timeout=15):
        for m in self.seen:
            if m.get('method') == method and pred(m):
                self.seen.remove(m)
                return m
        end = time.time() + timeout
        while True:
            m = self.get(max(0.1, end - time.time()))
            if m is None:
                raise AssertionError('server closed the connection while waiting for ' + method)
            if m.get('method') == method and pred(m):
                return m
            self.seen.append(m)

    # -- conveniences ----------------------------------------------------------------------------------
    def initialize(self, root=None, tp7=None, hier=True, options=None):
        opts = dict({'tp7Dir': tp7} if tp7 else {}, **(options or {}))
        caps = {'textDocument': {'documentSymbol': {'hierarchicalDocumentSymbolSupport': True}}} if hier else {}
        params = {'processId': None, 'rootUri': uri(root) if root else None, 'capabilities': caps,
                  'workspaceFolders': [{'uri': uri(root), 'name': 'ws'}] if root else None,
                  'initializationOptions': opts}
        r = self.request('initialize', params)
        self.notify('initialized')
        return r

    def open(self, path, text, version=1):
        u = uri(path)
        self.notify('textDocument/didOpen', {'textDocument': {'uri': u, 'languageId': 'pascal', 'version': version,
                                                                'text': text}})
        return u

    def change(self, u, text, version):
        self.notify('textDocument/didChange', {'textDocument': {'uri': u, 'version': version},
                                               'contentChanges': [{'text': text}]})

    def fmt(self, u):
        return self.request('textDocument/formatting', {'textDocument': {'uri': u},
                                                        'options': {'tabSize': 4, 'insertSpaces': False}})

    def formatted(self, u, text):
        r = self.fmt(u)
        assert 'result' in r, r
        return apply_edits(text, r['result'])

    def close(self):
        try:
            try:
                self.p.stdin.close()
            except Exception:
                pass
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        finally:
            for f in (self.p.stdout, self.p.stderr):
                try:
                    f.close()
                except Exception:
                    pass


# ---------------------------------------------------------------------------------------------------
class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix='tp7lsp_')
        cls.ws = os.path.join(cls.tmp, 'ws')
        cls.stubs = os.path.join(cls.tmp, 'stubs')                 # generated stubs never go to the real cache
        cls.tp7 = os.path.join(cls.tmp, 'TP')
        os.makedirs(cls.ws)
        os.makedirs(os.path.join(cls.tp7, 'BIN'))
        os.makedirs(os.path.join(cls.tp7, 'UNITS'))
        shutil.copy(os.path.join(D, 'TURBO.TPL'), os.path.join(cls.tp7, 'BIN', 'TURBO.TPL'))
        shutil.copy(os.path.join(D, 'GRAPH.TPU'), os.path.join(cls.tp7, 'UNITS', 'GRAPH.TPU'))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.clients = []

    def tearDown(self):
        for c in self.clients:
            c.close()

    def start(self, root='default', tp7='default', env=None, init=True):
        c = Client(dict({'TP7LS_STUB_DIR': self.stubs}, **(env or {})))
        self.clients.append(c)
        if init:
            c.initialize(self.ws if root == 'default' else root, self.tp7 if tp7 == 'default' else tp7)
        return c

    def write(self, name, text, root=None):
        path = os.path.join(root or self.ws, name)
        with open(path, 'wb') as f:
            f.write(text.encode('cp866'))
        return path


class Lifecycle(Base):
    def test_initialize_announces_capabilities(self):
        c = self.start(init=False)
        r = c.initialize(self.ws, self.tp7)['result']
        cap = r['capabilities']
        self.assertTrue(cap['documentFormattingProvider'])
        self.assertEqual(cap['textDocumentSync'], {'openClose': True, 'change': 1, 'save': {'includeText': False}})
        self.assertEqual(cap['positionEncoding'], 'utf-16')
        self.assertEqual(r['serverInfo']['name'], 'tp7ls')

    def test_requests_before_initialize_are_rejected(self):
        c = self.start(init=False)
        c.notify('textDocument/didOpen', {'textDocument': {'uri': 'file:///x.pas', 'version': 1, 'text': 'x'}})
        r = c.request('textDocument/formatting', {'textDocument': {'uri': 'file:///x.pas'}})
        self.assertEqual(r['error']['code'], -32002)

    def test_unknown_request_is_an_error_and_unknown_notification_is_ignored(self):
        c = self.start()
        self.assertEqual(c.request('foo/bar')['error']['code'], -32601)
        c.notify('$/cancelRequest', {'id': 99})
        c.notify('workspace/didChangeConfiguration', {'settings': {}})
        u = c.open(os.path.join(self.ws, 'a.pas'), 'program a; begin end.')
        self.assertIn('result', c.fmt(u))                       # still alive and well

    def test_formatting_an_unopened_document_is_invalid_params(self):
        c = self.start()
        r = c.fmt(uri(os.path.join(self.ws, 'nope.pas')))
        self.assertEqual(r['error']['code'], -32602)

    def test_shutdown_then_exit_gives_status_0(self):
        c = self.start()
        self.assertIsNone(c.request('shutdown')['result'])
        self.assertEqual(c.request('textDocument/formatting', {'textDocument': {'uri': 'file:///x'}})['error']['code'],
                         -32600)
        c.notify('exit')
        self.assertEqual(c.p.wait(timeout=10), 0)

    def test_exit_without_shutdown_gives_status_1(self):
        c = self.start()
        c.notify('exit')
        self.assertEqual(c.p.wait(timeout=10), 1)

    def test_end_of_input_terminates_the_server(self):
        c = self.start()
        c.p.stdin.close()
        self.assertEqual(c.p.wait(timeout=10), 1)

    def test_framing_tolerates_extra_headers_split_writes_and_bad_json(self):
        c = self.start(init=False)
        junk = b'{not json'
        c.raw(b'Content-Length: %d\r\n\r\n' % len(junk) + junk)                        # ignored
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                           'params': {'rootUri': None, 'capabilities': {}}}).encode()
        head = b'Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: %d\r\n\r\n' % len(body)
        data = head + body
        for i in range(0, len(data), 7):                                                 # dribble it in
            c.raw(data[i:i + 7])
            time.sleep(0.001)
        m = c.get()
        self.assertEqual(m['id'], 1)
        self.assertIn('capabilities', m['result'])

    def test_stdout_carries_nothing_but_protocol(self):
        c = self.start()
        c.open(os.path.join(self.ws, 'a.pas'), 'program a; begin x := ; end.')
        c.request('shutdown')
        c.notify('exit')
        c.p.wait(timeout=10)
        # the pump thread would have crashed on a stray non-protocol line; everything it saw parsed as JSON
        rest = []
        while True:
            m = c.q.get(timeout=5)
            if m is None:
                break
            rest.append(m)
        self.assertTrue(all(isinstance(m, dict) for m in rest))


class Formatting(Base):
    def test_polsk_matches_reference_layout_with_normalized_case(self):
        c = self.start()
        src = rd('polsk.pas')
        u = c.open(os.path.join(self.ws, 'polsk.pas'), src)
        out = c.formatted(u, src)
        self.assertEqual(out.lower(), rd('polsk_formatted.pas').lower())          # same layout, differing only in case
        for want in ('function pr(n: string): Integer;', '  correct: Boolean;', '    n := NextChar(str);',
                     '      Inc(k);', '      Exit;'):
            self.assertIn(want, out.replace('\r\n', '\n').split('\n'), want)

    def test_formatting_twice_gives_no_edits(self):
        c = self.start()
        src = rd('polsk.pas')
        u = c.open(os.path.join(self.ws, 'polsk.pas'), src)
        once = c.formatted(u, src)
        c.change(u, once, 2)
        self.assertEqual(c.fmt(u)['result'], [])

    def test_edit_is_minimal_and_whole_line(self):
        c = self.start()
        src = rd('polsk.pas')
        u = c.open(os.path.join(self.ws, 'polsk.pas'), src)
        good = c.formatted(u, src)
        lines = split_lines(good)
        k = lines.index('    Dec(top);\r\n')
        bad = ''.join(lines[:k] + ['    dec(  top);\r\n'] + lines[k + 1:])
        c.change(u, bad, 3)
        edits = c.fmt(u)['result']
        self.assertEqual(edits, [{'range': {'start': {'line': k, 'character': 0}, 'end': {'line': k + 1, 'character': 0}},
                                  'newText': '    Dec(top);\r\n'}])

    def test_latest_buffer_text_is_what_gets_formatted(self):
        c = self.start()
        p = os.path.join(self.ws, 'x.pas')
        u = c.open(p, 'this is garbage')
        self.assertIn('error', c.fmt(u))
        src = rd('polsk.pas')
        c.change(u, src, 2)
        self.assertEqual(c.formatted(u, src).lower(), rd('polsk_formatted.pas').lower())

    def test_syntax_errors_refuse_formatting_with_request_failed(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'bad.pas'), 'program t;\nbegin\n  x := ;\nend.\n')
        r = c.fmt(u)
        self.assertEqual(r['error']['code'], -32803)
        self.assertIn('syntax', r['error']['message'])

    def test_cyrillic_and_unicode_survive(self):
        c = self.start()
        src = "program t;\nvar s:string;\nbegin\ns:='ПРОГРАММА';{ коммент 😀 }\nwriteln(s)\nend.\n"
        u = c.open(os.path.join(self.ws, 't.pas'), src)
        out = c.formatted(u, src)
        self.assertIn("  s := 'ПРОГРАММА'; { коммент 😀 }", out)
        self.assertIn('var\n  s: string;', out)                    # `string` is a reserved word: always lower case
        self.assertIn('WriteLn(s);', out)

    def test_crlf_text_is_answered_with_crlf(self):
        c = self.start()
        src = 'program t;\r\nvar x:integer;\r\nbegin\r\nx:=1\r\nend.\r\n'
        u = c.open(os.path.join(self.ws, 't.pas'), src)
        out = c.formatted(u, src)
        self.assertEqual(out, 'program t;\r\n\r\nvar\r\n  x: Integer;\r\n\r\nbegin\r\n  x := 1;\r\nend.\r\n')

    def test_lf_text_is_answered_with_lf(self):
        c = self.start()
        src = 'program t;\nvar x:integer;\nbegin\nx:=1\nend.\n'
        u = c.open(os.path.join(self.ws, 't.pas'), src)
        self.assertEqual(c.formatted(u, src), 'program t;\n\nvar\n  x: Integer;\n\nbegin\n  x := 1;\nend.\n')

    def test_no_trailing_newline_is_preserved(self):
        c = self.start()
        src = 'program t;\nbegin\nend.'
        u = c.open(os.path.join(self.ws, 't.pas'), src)
        self.assertEqual(c.formatted(u, src), 'program t;\n\nbegin\nend.')


class Discovery(Base):
    PROG = "program p;\nuses crt, graph;\nvar gd, gm: integer;\nbegin\nclrscr; initgraph(gd, gm, '')\nend.\n"

    def check(self, c):
        u = c.open(os.path.join(self.ws, 'prog.pas'), self.PROG)
        out = c.formatted(u, self.PROG)
        for want in ('  Crt, Graph;', '  gd, gm: Integer;', '  ClrScr;', "  InitGraph(gd, gm, '');"):
            self.assertIn(want, out.split('\n'), want)

    def test_tp7dir_init_option_finds_bin_tpl_and_units_dir(self):
        self.check(self.start())

    def test_tp7_dir_environment_variable(self):
        self.check(self.start(tp7=None, env={'TP7_DIR': self.tp7}))

    def test_tpl_in_the_workspace_itself_with_odd_case(self):
        root = os.path.join(self.tmp, 'ws_with_tpl')
        os.makedirs(os.path.join(root, 'bin'))
        shutil.copy(os.path.join(D, 'TURBO.TPL'), os.path.join(root, 'bin', 'turbo.tpl'))
        c = self.start(root=root, tp7=None)
        u = c.open(os.path.join(root, 'p.pas'), 'program p; var x: INTEGER; begin writeln(x) end.')
        out = c.formatted(u, 'program p; var x: INTEGER; begin writeln(x) end.')
        self.assertIn('  x: Integer;', out)
        self.assertIn('WriteLn(x);', out)

    def test_missing_tpl_warns_once_and_still_formats(self):
        c = self.start(root=os.path.join(self.tmp, 'empty'), tp7=None)
        m = c.wait_for('window/showMessage')
        self.assertIn('TURBO.TPL', m['params']['message'])
        src = 'PROGRAM T; VAR X: INTEGER; BEGIN X := 1 END.'
        u = c.open(os.path.join(self.tmp, 'empty', 't.pas'), src)
        out = c.formatted(u, src)
        self.assertEqual(out, 'program T;\n\nvar\n  X: INTEGER;\n\nbegin\n  X := 1;\nend.')       # keywords yes, System names untouched

    def test_unit_from_the_edited_files_directory(self):
        self.write('mylib.pas', 'unit MyLib;\ninterface\nprocedure DoIt;\nimplementation\nprocedure DoIt; begin end;\nend.\n')
        c = self.start()
        src = 'program p;\nuses mylib;\nbegin\ndoit\nend.\n'
        u = c.open(os.path.join(self.ws, 'p.pas'), src)
        out = c.formatted(u, src)
        self.assertIn('  MyLib;', out)
        self.assertIn('  DoIt;', out.split('\n'))

    def test_damaged_unit_file_does_not_break_formatting(self):
        with open(os.path.join(self.ws, 'broken.tpu'), 'wb') as f:
            f.write(b'TPUQ' + b'\xff' * 300)
        c = self.start()
        src = 'program p;\nuses broken;\nvar x: integer;\nbegin\nx := 1\nend.\n'
        u = c.open(os.path.join(self.ws, 'p.pas'), src)
        out = c.formatted(u, src)
        self.assertIn('  x: Integer;', out.split('\n'))

    def test_unsaved_buffer_of_another_unit_wins_over_the_disk(self):
        b = self.write('b.pas', 'unit b;\ninterface\nprocedure Foo;\nimplementation\nprocedure Foo; begin end;\nend.\n')
        c = self.start()
        ub = c.open(b, 'unit b;\ninterface\nprocedure FOO;\nimplementation\nprocedure FOO; begin end;\nend.\n')
        src = 'program a;\nuses b;\nbegin\nfoo\nend.\n'
        ua = c.open(os.path.join(self.ws, 'a.pas'), src)
        self.assertIn('  FOO;', c.formatted(ua, src).split('\n'))
        c.notify('textDocument/didClose', {'textDocument': {'uri': ub}})
        self.assertIn('  Foo;', c.formatted(ua, src).split('\n'))                 # back to the disk version


class Diagnostics(Base):
    def test_published_on_open_then_cleared_on_fix(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'bad.pas'), 'program t;\nbegin\n  x := ;\nend.\n', version=7)
        m = c.wait_for('textDocument/publishDiagnostics')
        self.assertEqual(m['params']['uri'], u)
        self.assertEqual(m['params']['version'], 7)
        d = m['params']['diagnostics']
        self.assertTrue(d)
        self.assertEqual(d[0]['range']['start'], {'line': 2, 'character': 7})
        self.assertEqual((d[0]['severity'], d[0]['source']), (1, 'tp7ls'))
        c.change(u, 'program t;\nvar x: integer;\nbegin\n  x := 1;\nend.\n', 8)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params'].get('version') == 8)
        self.assertEqual(m['params']['diagnostics'], [])

    def test_columns_are_utf16_code_units(self):
        c = self.start()
        c.open(os.path.join(self.ws, 'bad.pas'), 'program t;\nbegin\n  { 😀 } x := ;\nend.\n')
        d = c.wait_for('textDocument/publishDiagnostics')['params']['diagnostics'][0]
        self.assertEqual(d['range']['start'], {'line': 2, 'character': 14})        # 13 characters, one of them 2 units
        self.assertEqual(d['range']['end'], {'line': 2, 'character': 15})

    def test_object_types_are_ordinary_code(self):
        c = self.start()
        c.open(os.path.join(self.ws, 'o.pas'), 'program t;\ntype B = object procedure P; virtual; end;\n'
                                              'T = object(B) x: integer; procedure P; virtual; end;\n'
                                              'procedure B.P; begin end;\n'
                                              'procedure T.P; begin inherited P end;\nbegin end.\n')
        d = c.wait_for('textDocument/publishDiagnostics')['params']['diagnostics']
        self.assertEqual(d, [])

    def test_line_over_126_characters_is_an_error(self):
        c = self.start()
        long = 'x' * 126 + '\u00e9\U0001F600yy'
        u = c.open(os.path.join(self.ws, 'long.pas'), 'program a;\n{ %s }\nbegin\nend.\n' % ('x' * 122))      # exactly 126 wide
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual(m['params']['diagnostics'], [])
        c.change(u, 'program a;\n{%s}\nbegin\nend.\n' % long, 2)
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u and m['params']['version'] == 2)
        d = m['params']['diagnostics']
        self.assertEqual(len(d), 1)
        self.assertEqual(d[0]['severity'], 1)
        self.assertEqual(d[0]['range']['start'], {'line': 1, 'character': 126})
        self.assertEqual(d[0]['range']['end'], {'line': 1, 'character': 133})        # 132 characters, the emoji is 2 UTF-16 units
        self.assertIn('line too long', d[0]['message'])

    def test_cleared_when_the_document_is_closed(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'bad.pas'), 'program t; begin x := ; end.')
        c.wait_for('textDocument/publishDiagnostics')
        c.notify('textDocument/didClose', {'textDocument': {'uri': u}})
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['diagnostics'] == [])
        self.assertEqual(m['params']['uri'], u)

    def test_clean_file_has_no_diagnostics(self):
        c = self.start()
        c.open(os.path.join(self.ws, 'polsk.pas'), rd('polsk.pas'))
        self.assertEqual(c.wait_for('textDocument/publishDiagnostics')['params']['diagnostics'], [])


class Definition(Base):
    @staticmethod
    def pos(src, needle, nth=0, off=0):
        """LSP position of the nth occurrence of `needle` in src (+ off characters)."""
        i = -1
        for _ in range(nth + 1):
            i = src.index(needle, i + 1)
        i += off
        line = src.count('\n', 0, i)
        col = utf16_len(src[src.rfind('\n', 0, i) + 1:i])
        return {'line': line, 'character': col}

    def define(self, c, u, position, method='definition'):
        r = c.request('textDocument/' + method, {'textDocument': {'uri': u}, 'position': position})
        self.assertNotIn('error', r, r)
        return r['result']

    def declare(self, c, u, position):
        return self.define(c, u, position, 'declaration')

    def span(self, loc):
        r = loc['range']
        return (r['start']['line'], r['start']['character'], r['end']['line'], r['end']['character'])

    def test_capability_is_announced(self):
        c = self.start(init=False)
        cap = c.initialize(self.ws, self.tp7)['result']['capabilities']
        self.assertTrue(cap['definitionProvider'])
        self.assertTrue(cap['declarationProvider'])

    def test_variable_routine_and_field_in_the_same_file(self):
        src = ('program a;\r\ntype\r\n  TRec = record\r\n    Count: Integer;\r\n  end;\r\nvar\r\n  Total: Integer;\r\n'
               '  R: TRec;\r\nprocedure Bump(Step: Integer);\r\nbegin\r\n  Total := Total + STEP;\r\nend;\r\n'
               'begin\r\n  bump(1);\r\n  r.COUNT := total;\r\nend.\r\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        loc = self.define(c, u, self.pos(src, 'total', 0))                      # `total` in the main body
        self.assertEqual(loc['uri'], u)
        self.assertEqual(self.span(loc), (6, 2, 6, 7))
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'STEP'))), (8, 15, 8, 19))    # parameter
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'bump', 0))), (8, 10, 8, 14))  # routine
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'COUNT', 0))), (3, 4, 3, 9))   # field via R
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'TRec', 1))), (2, 2, 2, 6))    # type of R

    def test_position_at_either_end_of_the_identifier(self):
        src = 'program a;\nvar Total: Integer;\nbegin\n  Total := 1;\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        for off in (0, 3, 5):
            self.assertEqual(self.span(self.define(c, u, self.pos(src, 'Total :=', 0, off))), (1, 4, 1, 9), off)

    def test_nothing_to_jump_to(self):
        src = "program a;\nuses Crt;\nvar I: Integer;\nbegin\n  ClrScr;\n  WriteLn('x', I);\n  I := 1 { c };\nend.\n"
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        for needle, stub in (('ClrScr', 'Crt.pas'), ('WriteLn', 'System.pas')):  # no source: the generated stub
            r = self.define(c, u, self.pos(src, needle))
            self.assertEqual(os.path.basename(r['uri']), stub, needle)
            self.assertTrue(r['uri'].startswith(uri(self.stubs)), r['uri'])
        self.assertIsNone(self.define(c, u, self.pos(src, 'begin')))              # keyword
        self.assertIsNone(self.define(c, u, self.pos(src, "'x'", 0, 1)))          # string
        self.assertIsNone(self.define(c, u, self.pos(src, ' c ')))                # comment
        self.assertIsNone(self.define(c, u, {'line': 99, 'character': 0}))        # outside the text
        r = self.define(c, u, self.pos(src, 'Crt'))                               # uses Crt: the top of its stub
        self.assertEqual((os.path.basename(r['uri']), self.span(r)), ('Crt.pas', (5, 5, 5, 8)))

    def test_unopened_document_is_invalid_params(self):
        c = self.start()
        r = c.request('textDocument/definition', {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))},
                                                  'position': {'line': 0, 'character': 0}})
        self.assertEqual(r['error']['code'], -32602)

    def test_definition_is_the_implementation_declaration_is_the_interface_header(self):
        src = ('unit u;\ninterface\nprocedure Foo(N: Integer);\nimplementation\nprocedure FOO(N: Integer);\n'
               'begin\n  foo(N - 1)\nend;\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'u.pas'), src)
        impl, iface = (4, 10, 4, 13), (2, 10, 2, 13)
        for needle, nth in (('Foo', 0), ('FOO', 0), ('foo(N', 0)):          # interface header, body header, a call
            at = self.pos(src, needle, nth)
            self.assertEqual(self.span(self.define(c, u, at)), impl, ('definition', needle))
            self.assertEqual(self.span(self.declare(c, u, at)), iface, ('declaration', needle))

    def test_forward_declaration(self):
        src = ('program a;\nprocedure Ping(N: Integer); forward;\nprocedure Pong(N: Integer);\nbegin\n  Ping(N)\nend;\n'
               'procedure Ping;\nbegin\n  Pong(N)\nend;\nbegin\n  Ping(1)\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        at = self.pos(src, 'Ping(N)\nend;')
        self.assertEqual(self.span(self.declare(c, u, at)), (1, 10, 1, 14))
        self.assertEqual(self.span(self.define(c, u, at)), (6, 10, 6, 14))
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'Pong(N)'))), (2, 10, 2, 14))   # no forward: same place

    def test_declaration_works_for_variables_types_fields_parameters_and_constants(self):
        src = ('program a;\r\nconst\r\n  Limit = 10;\r\ntype\r\n  TRec = record\r\n    Count: Integer;\r\n  end;\r\nvar\r\n'
               '  R: TRec;\r\nprocedure Bump(Step: Integer);\r\nbegin\r\n  R.Count := Step + Limit;\r\nend;\r\n'
               'begin\r\n  Bump(1)\r\nend.\r\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        want = {('R.Count', 0): (8, 2, 8, 3), ('Count :=', 0): (5, 4, 5, 9), ('Step +', 0): (9, 15, 9, 19),
                ('Limit;', 0): (2, 2, 2, 7)}
        for (needle, nth), span in want.items():
            at = self.pos(src, needle, nth)
            self.assertEqual(self.span(self.declare(c, u, at)), span, needle)
            self.assertEqual(self.span(self.define(c, u, at)), span, needle)      # no separate implementation
        self.assertEqual(self.span(self.declare(c, u, self.pos(src, 'TRec', 1))), (4, 2, 4, 6))
        self.assertEqual(self.span(self.declare(c, u, self.pos(src, 'Bump(1)'))), (9, 10, 9, 14))   # no interface: the header

    def test_declaration_of_library_names_is_the_stub(self):
        src = 'program a;\nuses Crt;\nvar I: Integer;\nbegin\n  ClrScr;\n  WriteLn(I)\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        for needle, stub in (('ClrScr', 'Crt.pas'), ('WriteLn', 'System.pas'), ('Integer', 'System.pas'), ('Crt', 'Crt.pas')):
            self.assertEqual(os.path.basename(self.declare(c, u, self.pos(src, needle))['uri']), stub, needle)
        self.assertEqual(self.span(self.declare(c, u, self.pos(src, 'I)'))), (2, 4, 2, 5))

    def test_declaration_of_an_unopened_document_is_invalid_params(self):
        c = self.start()
        r = c.request('textDocument/declaration', {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))},
                                                   'position': {'line': 0, 'character': 0}})
        self.assertEqual(r['error']['code'], -32602)

    def test_declaration_site_returns_itself(self):
        src = 'program a;\nvar Total: Integer;\nbegin\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'Total'))), (1, 4, 1, 9))

    def test_into_another_unit_from_disk(self):
        b = self.write('geom.pas', 'unit Geom;\r\ninterface\r\ntype\r\n  TPoint = record\r\n    X, Y: Integer;\r\n  end;\r\n'
                       'procedure Move(var P: TPoint);\r\nimplementation\r\nprocedure Move(var P: TPoint);\r\n'
                       'begin\r\nend;\r\nend.\r\n')
        src = 'program a;\nuses geom;\nvar P: TPoint;\nbegin\n  MOVE(p);\n  p.y := 1;\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        loc = self.define(c, u, self.pos(src, 'MOVE'))                              # the body, in implementation
        self.assertEqual(loc['uri'], uri(b))
        self.assertEqual(self.span(loc), (8, 10, 8, 14))
        loc = self.declare(c, u, self.pos(src, 'MOVE'))                             # the header, in interface
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (6, 10, 6, 14)))
        loc = self.define(c, u, self.pos(src, 'TPoint'))
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (3, 2, 3, 8)))
        loc = self.define(c, u, self.pos(src, 'p.y', 0, 2))                         # field of a record from the unit
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (4, 7, 4, 8)))
        loc = self.define(c, u, self.pos(src, 'geom'))                              # the unit itself
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (0, 0, 0, 0)))

    def test_unsaved_buffer_of_the_other_unit_is_used(self):
        b = self.write('geom2.pas', 'unit Geom2;\ninterface\nprocedure Move;\nimplementation\nprocedure Move; begin end;\nend.\n')
        c = self.start()
        c.open(b, 'unit Geom2;\ninterface\n\n\n{ \u00e9\U0001F600 } procedure Move;\nimplementation\nprocedure Move; begin end;\nend.\n')
        src = 'program a;\nuses geom2;\nbegin\n  Move\nend.\n'
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        loc = self.declare(c, u, self.pos(src, 'Move'))
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (4, 18, 4, 22)))   # the emoji takes two UTF-16 units
        loc = self.define(c, u, self.pos(src, 'Move'))
        self.assertEqual((loc['uri'], self.span(loc)), (uri(b), (6, 10, 6, 14)))

    def test_utf16_columns_in_the_current_document(self):
        src = 'program a;\n{ \U0001F600\u0436 } var Total: Integer;\nbegin\n  { \U0001F600 } Total := 1;\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        loc = self.define(c, u, self.pos(src, 'Total :=', 0, 1))
        self.assertEqual(self.span(loc), (1, 12, 1, 17))

    def test_with_and_nested_routines(self):
        src = ('program a;\ntype TR = record Left: Integer; end;\nvar R: TR;\nprocedure Outer;\n  var Local: Integer;\n'
               '  procedure Inner;\n  begin\n    local := 1\n  end;\nbegin\n  with r do left := 2;\n  inner\nend;\nbegin\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'local'))), (4, 6, 4, 11))
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'left'))), (1, 17, 1, 21))
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'inner'))), (5, 12, 5, 17))

    def test_broken_file_still_answers(self):
        src = 'program a;\nvar Total: Integer;\nbegin\n  Total := ;\n  if then\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        self.assertEqual(self.span(self.define(c, u, self.pos(src, 'Total :='))), (1, 4, 1, 9))


class Semantic(Base):
    TYPES = ['namespace', 'type', 'enumMember', 'function', 'parameter', 'variable', 'property', 'label',
             'comment', 'macro', 'keyword', 'method']
    MODS = ['declaration', 'readonly', 'defaultLibrary']

    def tokens(self, c, u, rng=None):
        method = 'textDocument/semanticTokens/' + ('range' if rng else 'full')
        params = {'textDocument': {'uri': u}}
        if rng:
            params['range'] = rng
        r = c.request(method, params)
        self.assertNotIn('error', r, r)
        d = r['result']['data']
        self.assertEqual(len(d) % 5, 0)
        out, line, col = [], 0, 0
        for i in range(0, len(d), 5):
            dl, ds, n, t, m = d[i:i + 5]
            line += dl
            col = ds if dl else col + ds
            out.append((line, col, n, self.TYPES[t], tuple(x for j, x in enumerate(self.MODS) if m >> j & 1)))
        return out

    def find(self, toks, src, needle, nth=0):
        """The token that starts at the nth occurrence of `needle` in src."""
        p = Definition.pos(src, needle, nth)
        for t in toks:
            if (t[0], t[1]) == (p['line'], p['character']):
                return t
        return None

    def test_legend_and_capabilities(self):
        c = self.start(init=False)
        cap = c.initialize(self.ws, self.tp7)['result']['capabilities']['semanticTokensProvider']
        self.assertEqual(cap['legend'], {'tokenTypes': self.TYPES, 'tokenModifiers': self.MODS})
        self.assertTrue(cap['full'])
        self.assertTrue(cap['range'])

    SRC = ('program a;\nuses Crt;\ntype\n  TColor = (Red, Green);\n  TRec = record\n    Count: Integer;\n  end;\n'
           'const\n  Limit = 10;\nvar\n  R: TRec;\n  C: TColor;\nlabel Done;\n'
           'procedure Bump(Step: Integer);\nbegin\n  WriteLn(Step, Limit);\n  R.Count := Ord(Red);\nend;\n'
           'begin\n  Bump(1);\n  goto Done;\n  Done: ClrScr\nend.\n')

    def test_every_kind_of_symbol(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), self.SRC)
        t = self.tokens(c, u)
        f = lambda needle, nth=0: self.find(t, self.SRC, needle, nth)
        self.assertEqual(f('Crt')[3:], ('namespace', ('defaultLibrary',)))
        self.assertEqual(f('TColor')[3:], ('type', ('declaration',)))
        self.assertEqual(f('Red')[3:], ('enumMember', ('declaration', 'readonly')))
        self.assertEqual(f('Count')[3:], ('property', ('declaration',)))
        self.assertEqual(f('Integer')[3:], ('type', ('defaultLibrary',)))
        self.assertEqual(f('Limit')[3:], ('variable', ('declaration', 'readonly')))
        self.assertEqual(f('R:')[3:], ('variable', ('declaration',)))
        self.assertEqual(f('Done')[3:], ('label', ('declaration',)))
        self.assertEqual(f('Bump')[3:], ('function', ('declaration',)))
        self.assertEqual(f('Step')[3:], ('parameter', ('declaration',)))
        self.assertEqual(f('WriteLn')[3:], ('function', ('defaultLibrary',)))
        self.assertEqual(f('Step', 1)[3:], ('parameter', ()))
        self.assertEqual(f('Limit', 1)[3:], ('variable', ('readonly',)))
        self.assertEqual(f('R.Count')[3:], ('variable', ()))
        self.assertEqual(f('Count', 1)[3:], ('property', ()))              # R.Count
        self.assertEqual(f('Red', 1)[3:], ('enumMember', ('readonly',)))
        self.assertEqual(f('Ord')[3:], ('function', ('defaultLibrary',)))
        self.assertEqual(f('Bump', 1)[3:], ('function', ()))
        self.assertEqual(f('ClrScr')[3:], ('function', ('defaultLibrary',)))
        self.assertEqual(f('Done', 1)[3:], ('label', ()))                  # goto Done
        self.assertEqual(f('Done', 2)[3:], ('label', ()))                  # Done: ClrScr
        lengths = {(x[0], x[1]): x[2] for x in t}
        self.assertEqual(lengths[(self.find(t, self.SRC, 'TColor')[0], 2)], 6)

    def test_keywords_and_routine_directives(self):
        src = ('program a;\nvar V: string; W: Byte absolute $B800:0;\nprocedure P; far; forward;\n'
               'procedure P; begin case V of 1: V := 2 else end end;\nbegin\n  if V = 1 then Far := 1\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        t = self.tokens(c, u)
        kw = [(x[0], x[2]) for x in t if x[3] == 'keyword']
        words = [src.split('\n')[l][t_[1]:t_[1] + t_[2]] for t_ in t if t_[3] == 'keyword' for l in [t_[0]]]
        self.assertEqual(words, ['program', 'var', 'string', 'absolute', 'procedure', 'far', 'forward',
                                 'procedure', 'begin', 'case', 'of', 'else', 'end', 'end', 'begin', 'if', 'then', 'end'])
        self.assertEqual(self.find(t, src, 'Far')[3] if self.find(t, src, 'Far') else None, None)   # an identifier, not a directive

    def test_tokens_are_sorted_and_do_not_overlap(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), self.SRC)
        t = self.tokens(c, u)
        self.assertEqual(t, sorted(t))
        for a, b in zip(t, t[1:]):
            self.assertTrue(a[0] < b[0] or a[1] + a[2] <= b[1], (a, b))

    def test_inactive_branches_are_comments_and_directives_are_macros(self):
        src = ('program a;\n{$IFDEF FOO}\nvar Dead: Integer;\n{ note }\n{$ELSE}\nvar Live: Integer;\n{$ENDIF}\n'
               'begin\n  Live := 1\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        t = self.tokens(c, u)
        kinds = {x[0]: x[3] for x in t if x[0] in (1, 4, 6)}
        self.assertEqual(kinds, {1: 'macro', 4: 'macro', 6: 'macro'})
        dead = [x for x in t if x[0] == 2]
        self.assertEqual([x[3] for x in dead], ['comment'] * 5)               # var Dead : Integer ;
        self.assertTrue(any(x[0] == 3 and x[3] == 'comment' for x in t))      # the comment inside the dead branch
        self.assertEqual(self.find(t, src, 'Live', 0)[3:], ('variable', ('declaration',)))
        self.assertEqual(self.find(t, src, 'Live', 1)[3:], ('variable', ()))

    def test_columns_are_utf16_and_multiline_comments_in_dead_code_are_split(self):
        src = ('program a;\n{$IFDEF FOO}\n{ one\ntwo }\n{$ENDIF}\nvar V: Integer;\nbegin\n'
               '  { \U0001F600 } V := 1\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        t = self.tokens(c, u)
        self.assertEqual([x for x in t if x[3] == 'comment'], [(2, 0, 5, 'comment', ()), (3, 0, 5, 'comment', ())])
        v = [x for x in t if x[0] == 7]
        self.assertEqual(v, [(7, 9, 1, 'variable', ())])                      # emoji = 2 units: 2 + 2 + 2 + 1 + 2 = 9

    def test_range_request_returns_only_those_lines(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), self.SRC)
        full = self.tokens(c, u)
        part = self.tokens(c, u, {'start': {'line': 14, 'character': 0}, 'end': {'line': 17, 'character': 0}})
        self.assertEqual(part, [x for x in full if 14 <= x[0] <= 17])
        self.assertTrue(part)

    def test_broken_and_empty_documents(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), 'program a;\nvar V: Integer;\nbegin\n  V := ;\n  if then\nend.\n')
        self.assertTrue(any(x[3] == 'variable' for x in self.tokens(c, u)))
        u2 = c.open(os.path.join(self.ws, 'e.pas'), '')
        self.assertEqual(self.tokens(c, u2), [])

    def test_names_from_another_unit_source(self):
        self.write('shapes.pas', 'unit Shapes;\ninterface\ntype TPoint = record X: Integer end;\nprocedure Move;\n'
                   'implementation\nprocedure Move; begin end;\nend.\n')
        src = 'program a;\nuses shapes;\nvar P: TPoint;\nbegin\n  Move;\n  P.X := 1\nend.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        t = self.tokens(c, u)
        self.assertEqual(self.find(t, src, 'shapes')[3:], ('namespace', ()))      # source unit: not "default library"
        self.assertEqual(self.find(t, src, 'TPoint')[3:], ('type', ()))
        self.assertEqual(self.find(t, src, 'Move')[3:], ('function', ()))
        self.assertEqual(self.find(t, src, 'P.X', 0)[3:], ('variable', ()))

    def test_unopened_document_is_invalid_params(self):
        c = self.start()
        r = c.request('textDocument/semanticTokens/full', {'textDocument': {'uri': uri(os.path.join(self.ws, 'q.pas'))}})
        self.assertEqual(r['error']['code'], -32602)


class HoverAndTypes(Base):
    """textDocument/hover and textDocument/typeDefinition."""
    pos = staticmethod(Definition.pos)

    SRC = ('program a;\nuses Crt;\nlabel Done;\nconst K = 3; T: Integer = 4;\n'
           'type E = (Red, Green); R = record x, y: Integer; case Tag: Byte of 0: (p: Word) end; P = ^R;\n'
           '  Arr = array [1..3] of R;\nvar V: R; Ptr: P; A: Arr; C: E; Q: ^R; W: array [0..1] of E;\n'
           'procedure Foo(N: Integer; var S: string);\nbegin\n  V.x := N; WriteLn(K); ClrScr; goto Done;\n  Done: C := Red\nend;\n'
           'function Bar(X: Integer): Boolean; begin Bar := True end;\nbegin\n  Foo(1, \'x\'); if Bar(2) then\nend.\n')

    def project(self):
        return tempfile.mkdtemp(prefix='ht_', dir=self.tmp)

    def hover(self, c, u, needle, nth=0, off=0):
        r = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': self.pos(self.SRC, needle, nth, off)})
        self.assertNotIn('error', r, r)
        return r['result']

    def tdef(self, c, u, src, needle, nth=0, off=0):
        r = c.request('textDocument/typeDefinition', {'textDocument': {'uri': u}, 'position': self.pos(src, needle, nth, off)})
        self.assertNotIn('error', r, r)
        return r['result']

    def span(self, loc):
        r = loc['range']
        return (r['start']['line'], r['start']['character'], r['end']['line'], r['end']['character'])

    def code(self, h):
        """The pascal code block of a hover."""
        v = h['contents']['value']
        self.assertEqual(h['contents']['kind'], 'markdown')
        self.assertTrue(v.startswith('```pascal\n'))
        return v[len('```pascal\n'):v.index('\n```')]

    def test_capabilities(self):
        c = self.start(init=False)
        cap = c.initialize(self.ws, self.tp7)['result']['capabilities']
        self.assertTrue(cap['hoverProvider'])
        self.assertTrue(cap['typeDefinitionProvider'])

    def test_hover_texts(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), self.SRC)
        want = [
            (('K)',), 'const K = 3'), (('V.x',), 'var V: R'), (('Foo(1',), 'procedure Foo(N: Integer; var S: string)'),
            (('Bar(2',), 'function Bar(X: Integer): Boolean'), (('Ptr:',), 'var Ptr: P'), (('N: Integer',), 'N: Integer'),
            (('x := N',), 'x: Integer'), (('Done;',), 'label Done'), (('Q:',), 'var Q: ^R'),
            (('W:',), 'var W: array [0..1] of E'),
        ]
        for args, text in want:
            h = self.hover(c, u, *args)
            if text is None:
                continue
            self.assertEqual(self.code(h), text, args)
        self.assertEqual(self.code(self.hover(c, u, 'T: Integer')), 'const T: Integer = 4')
        self.assertEqual(self.code(self.hover(c, u, 'E = ')), 'type E = (Red, Green)')
        self.assertEqual(self.code(self.hover(c, u, 'Arr =')), 'type Arr = array [1..3] of R')
        self.assertEqual(self.code(self.hover(c, u, 'P = ^R')), 'type P = ^R')
        self.assertEqual(self.code(self.hover(c, u, 'R = record')),
                         'type R = record\n  x, y: Integer;\n  case Tag: Byte of ...\nend')
        h = self.hover(c, u, 'Red')
        self.assertEqual(self.code(h), 'Red')
        self.assertIn('*enumeration constant* of (Red, Green)', h['contents']['value'])
        self.assertIn('*parameter*', self.hover(c, u, 'N: Integer')['contents']['value'])
        self.assertIn('*field of R*', self.hover(c, u, 'x := N')['contents']['value'])

    EXPR = ('program e;\nconst K = 3;\ntype PR = ^TR; TR = record f: Integer; nx: PR end;\n'
            'var i, j: Integer; b: Byte; w: Word; l: Longint; x: Real; p: PR; a: array [1..3] of TR;\n'
            '  m: array [1..2, 0..9] of Char; st: string[10];\nbegin\n'
            '  i := i + j * 2;\n  l := i + w;\n  w := w + 1;\n  i := b + b;\n  x := x / 2;\n  i := (i - 1) div K;\n'
            '  i := a[1].f + p^.nx^.f;\n  if not (i > j) and Odd(i) then i := K * 4;\n  st[1] := m[1][2];\n'
            '  x := Q + 1;\nend.\n')

    def test_hover_on_an_operator_or_a_bracket_shows_the_type_of_the_expression(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'e.pas'), self.EXPR)
        hov = lambda needle, off, nth=0: c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': self.pos(
            self.EXPR, needle, nth, off)})['result']
        want = [
            ('i + j', 2, 'i + j * 2: Integer'), ('j * 2', 2, 'j * 2: Integer'), ('i + w', 2, 'i + w: Longint'),
            ('w + 1', 2, 'w + 1: Word'), ('b + b', 2, 'b + b: integer'), ('x / 2', 2, 'x / 2: Real'),
            ('(i - 1)', 0, '(i - 1): Integer'), ('(i - 1)', 6, '(i - 1): Integer'), (') div', 2, '(i - 1) div K: Integer'),
            ('a[1]', 1, 'a[1]: TR'), ('a[1]', 3, 'a[1]: TR'), ('p^', 1, 'p^: TR'), ('nx^', 2, 'p^.nx^: TR'),
            ('.f + p', 3, 'a[1].f + p^.nx^.f: Integer'), ('not', 0, 'not (i > j): Boolean'), ('> j', 0, 'i > j: Boolean'),
            ('Odd(', 3, 'Odd(i): Boolean'), ('K * 4', 2, 'K * 4: Integer = 12'), ('m[1]', 1, 'm[1]: array [0..9] of Char'),
            ('m[1][', 4, 'm[1][2]: Char'), ('st[', 2, 'st[1]: Char'),
        ]
        for needle, off, text in want:
            h = hov(needle, off)
            self.assertIsNotNone(h, (needle, off))
            self.assertEqual(self.code(h), text, (needle, off))
        h = hov('x / 2', 2)
        self.assertIn('*Extended in {$N+} code*', h['contents']['value'])
        p = self.pos(self.EXPR, 'i + j')
        self.assertEqual(self.span(hov('i + j', 2)),
                         (p['line'], p['character'], p['line'], p['character'] + len('i + j * 2')))
        self.assertIsNone(hov('Q + 1', 2))                     # Q is unknown: no type, no hover
        self.assertIsNone(hov(':= i + j', 0))                  # not an expression
        self.assertEqual(self.code(hov('i + j', 0)), 'var i: Integer')       # names keep their own hover
        self.assertEqual(self.code(hov('Odd(', 2)), self.code(hov('Odd(', 0)))  # the end of a name is still the name

    def test_hover_range_is_the_identifier_and_keywords_have_none(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), self.SRC)
        h = self.hover(c, u, 'Foo(1')
        self.assertEqual(self.span(h), (self.pos(self.SRC, 'Foo(1')['line'], self.pos(self.SRC, 'Foo(1')['character'],
                                        self.pos(self.SRC, 'Foo(1')['line'], self.pos(self.SRC, 'Foo(1')['character'] + 3))
        self.assertIsNone(self.hover(c, u, 'begin'))
        self.assertIsNone(self.hover(c, u, "'x'", 0, 1))
        self.assertIsNone(self.hover(c, u, 'Nope', 0) if 'Nope' in self.SRC else None)

    def test_hover_library_names_and_units(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), self.SRC)
        h = self.hover(c, u, 'WriteLn')
        self.assertTrue(self.code(h).startswith('procedure WriteLn('), self.code(h))
        self.assertIn('*unit System*', h['contents']['value'])
        h = self.hover(c, u, 'ClrScr')
        self.assertEqual(self.code(h), 'procedure ClrScr')
        self.assertIn('*unit Crt*', h['contents']['value'])
        h = self.hover(c, u, 'Integer')
        self.assertEqual(self.code(h), 'type Integer = -32768..32767')
        h = self.hover(c, u, 'Crt')
        self.assertEqual(self.code(h), 'unit Crt')
        self.assertIn('standard library unit', h['contents']['value'])

    def test_hover_on_a_name_from_another_unit_says_where_it_is_declared(self):
        d = self.project()
        self.write('geom.pas', 'unit Geom;\ninterface\ntype TPoint = record X, Y: Integer end;\nvar Origin: TPoint;\n'
                   'procedure Move(var P: TPoint; Dx: Integer);\nimplementation\nprocedure Move(var P: TPoint; Dx: Integer);\n'
                   'begin\nend;\nend.\n', root=d)
        src = 'program a;\nuses geom;\nbegin\n  Move(Origin, 1)\nend.\n'
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': self.pos(src, 'Move')})['result']
        self.assertIn('procedure Move(var P: TPoint; Dx: Integer)', r['contents']['value'])
        self.assertIn('*declared in geom.pas, line 5*', r['contents']['value'])
        r = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': self.pos(src, 'Origin')})['result']
        self.assertIn('var Origin: TPoint', r['contents']['value'])
        self.assertIn('*declared in geom.pas, line 4*', r['contents']['value'])
        r = c.request('textDocument/hover', {'textDocument': {'uri': u}, 'position': self.pos(src, 'geom')})['result']
        self.assertIn('unit Geom', r['contents']['value'])
        self.assertIn('*source: geom.pas*', r['contents']['value'])

    def test_type_definition_in_the_same_file(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), self.SRC)
        S = self.SRC
        rt = self.pos(S, 'R = record')
        want = {
            ('V.x',): (rt['line'], rt['character'], rt['line'], rt['character'] + 1),            # V: R
        }
        loc = self.tdef(c, u, S, 'V.x')
        self.assertEqual(self.span(loc), want[('V.x',)])
        self.assertEqual(loc['uri'], u)
        p = self.pos(S, 'P = ^R')
        self.assertEqual(self.span(self.tdef(c, u, S, 'Ptr:')), (p['line'], p['character'], p['line'], p['character'] + 1))
        a = self.pos(S, 'Arr =')
        self.assertEqual(self.span(self.tdef(c, u, S, 'A:')), (a['line'], a['character'], a['line'], a['character'] + 3))
        self.assertEqual(self.span(self.tdef(c, u, S, 'Q:')), want[('V.x',)])                   # ^R -> R
        e = self.pos(S, 'E = (')
        self.assertEqual(self.span(self.tdef(c, u, S, 'W:')), (e['line'], e['character'], e['line'], e['character'] + 1))
        self.assertEqual(self.span(self.tdef(c, u, S, 'Red,')), (e['line'], e['character'], e['line'], e['character'] + 1))
        self.assertEqual(self.span(self.tdef(c, u, S, 'C := Red')), (e['line'], e['character'], e['line'], e['character'] + 1))
        # a type name goes to its own declaration
        self.assertEqual(self.span(self.tdef(c, u, S, 'R = record')), want[('V.x',)])

    def test_type_definition_of_library_types_goes_to_the_stub_and_plain_names_is_null(self):
        d = self.project()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), self.SRC)
        S = self.SRC
        for needle in ('WriteLn', 'begin', 'Foo(1'):
            self.assertIsNone(self.tdef(c, u, S, needle), needle)
        r = self.tdef(c, u, S, 'N: Integer')                                          # System.Integer: its stub
        self.assertEqual(os.path.basename(r['uri']), 'System.pas')

    def test_type_definition_into_another_unit(self):
        d = self.project()
        self.write('geom.pas', 'unit Geom;\ninterface\ntype\n  TPoint = record X, Y: Integer end;\nvar Origin: TPoint;\n'
                   'function Where: TPoint;\nimplementation\nfunction Where: TPoint; begin end;\nend.\n', root=d)
        src = 'program a;\nuses geom;\nvar Here: TPoint;\nbegin\n  Here := Origin;\n  Here := Where\nend.\n'
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        for needle in ('Origin', 'Here :=', 'Where\nend'):
            loc = self.tdef(c, u, src, needle)
            self.assertEqual((os.path.basename(loc['uri']), self.span(loc)), ('geom.pas', (3, 2, 3, 8)), needle)

    def test_unopened_documents(self):
        c = self.start()
        for m in ('hover', 'typeDefinition'):
            r = c.request('textDocument/' + m, {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))},
                                                'position': {'line': 0, 'character': 0}})
            self.assertEqual(r['error']['code'], -32602, m)


class Refactor(Base):
    """documentHighlight, references, prepareRename, rename.  Every test works in a workspace of its own, because
    references and rename look at all *.pas files below the workspace folder."""

    def proj(self, files=None):
        d = tempfile.mkdtemp(prefix='proj_', dir=self.tmp)
        for name, text in (files or {}).items():
            self.write(name, text, root=d)
        return d

    pos = staticmethod(Definition.pos)

    def span(self, loc):
        r = loc['range']
        return (r['start']['line'], r['start']['character'], r['end']['line'], r['end']['character'])

    def ask(self, c, method, u, position, **extra):
        params = {'textDocument': {'uri': u}, 'position': position}
        params.update(extra)
        r = c.request('textDocument/' + method, params)
        return r

    def refs(self, c, u, position, decl=True):
        r = self.ask(c, 'references', u, position, context={'includeDeclaration': decl})
        self.assertNotIn('error', r, r)
        return r['result']

    # -- documentHighlight -------------------------------------------------------------------------------
    def test_highlight_marks_declaration_reads_and_writes(self):
        src = ('program a;\nvar Total, N: Integer;\nbegin\n  Total := 0;\n  for N := 1 to 3 do Total := Total + N;\n'
               '  WriteLn(TOTAL)\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.ask(c, 'documentHighlight', u, self.pos(src, 'Total :='))['result']
        got = [(x['range']['start']['line'], x['range']['start']['character'], x['kind']) for x in r]
        self.assertEqual(got, [(1, 4, 1), (3, 2, 3), (4, 21, 3), (4, 30, 2), (5, 10, 2)])
        r = self.ask(c, 'documentHighlight', u, self.pos(src, 'N :='))['result']
        self.assertEqual([x['kind'] for x in r], [1, 3, 2])                    # decl, for variable, read

    def test_highlight_only_the_same_symbol_not_the_same_name(self):
        src = ('program a;\nvar X: Integer;\nprocedure P;\nvar X: Byte;\nbegin\n  X := 1\nend;\nbegin\n  X := 2\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        inner = self.ask(c, 'documentHighlight', u, self.pos(src, 'X := 1'))['result']
        self.assertEqual([x['range']['start']['line'] for x in inner], [3, 5])
        outer = self.ask(c, 'documentHighlight', u, self.pos(src, 'X := 2'))['result']
        self.assertEqual([x['range']['start']['line'] for x in outer], [1, 8])

    def test_highlight_fields_and_nothing(self):
        src = ('program a;\ntype R = record Count: Integer end;\nvar V: R;\nbegin\n  V.Count := 1;\n  V.count := V.COUNT + 1\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.ask(c, 'documentHighlight', u, self.pos(src, 'Count: '))['result']
        self.assertEqual([(x['range']['start']['line'], x['kind']) for x in r], [(1, 1), (4, 3), (5, 3), (5, 2)])
        self.assertIsNone(self.ask(c, 'documentHighlight', u, self.pos(src, 'begin'))['result'])

    # -- references ----------------------------------------------------------------------------------------
    def test_references_in_one_file(self):
        src = ('unit u;\ninterface\nprocedure Foo(N: Integer);\nimplementation\nprocedure FOO(N: Integer);\n'
               'begin\n  if N > 0 then foo(N - 1)\nend;\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'u.pas'), src)
        full = self.refs(c, u, self.pos(src, 'foo(N'))
        self.assertEqual(sorted(self.span(x) for x in full), [(2, 10, 2, 13), (4, 10, 4, 13), (6, 16, 6, 19)])
        self.assertTrue(all(x['uri'] == u for x in full))
        some = self.refs(c, u, self.pos(src, 'foo(N'), decl=False)
        self.assertEqual(sorted(self.span(x) for x in some), [(6, 16, 6, 19)])      # both headers count as declarations
        n = self.refs(c, u, self.pos(src, 'N > 0'))
        self.assertEqual(sorted(self.span(x)[0] for x in n), [4, 6, 6])

    def test_references_of_a_unit_routine_cover_the_workspace(self):
        geom = 'unit geom;\ninterface\nprocedure Move(X: Integer);\nimplementation\nprocedure Move(X: Integer);\nbegin\nend;\nend.\n'
        other = 'program b;\nuses geom;\nbegin\n  Move(2)\nend.\n'
        unrelated = 'program c;\nvar Move: Integer;\nbegin\n  Move := 1\nend.\n'
        d = self.proj({'geom.pas': geom, 'b.pas': other, 'c.pas': unrelated})
        c = self.start(root=d)
        src = 'program a;\nuses geom;\nbegin\n  MOVE(1);\n  Move(3)\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        got = sorted((os.path.basename(x['uri']), self.span(x)[0]) for x in self.refs(c, u, self.pos(src, 'MOVE')))
        self.assertEqual(got, [('a.pas', 3), ('a.pas', 4), ('b.pas', 3), ('geom.pas', 2), ('geom.pas', 4)])   # not c.pas
        # asked from the unit itself (interface header): the same set
        ug = c.open(os.path.join(d, 'geom.pas'), geom)
        got2 = sorted((os.path.basename(x['uri']), self.span(x)[0]) for x in self.refs(c, ug, self.pos(geom, 'Move')))
        self.assertEqual(got2, got)

    def test_references_use_unsaved_buffers(self):
        geom = 'unit geom;\ninterface\nprocedure Move;\nimplementation\nprocedure Move; begin end;\nend.\n'
        d = self.proj({'geom.pas': geom, 'b.pas': 'program b;\nuses geom;\nbegin\n  Move\nend.\n'})
        c = self.start(root=d)
        c.open(os.path.join(d, 'b.pas'), 'program b;\nuses geom;\nbegin\n\n\n  Move;\n  Move\nend.\n')      # not saved
        src = 'program a;\nuses geom;\nbegin\n  Move\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        got = sorted((os.path.basename(x['uri']), self.span(x)[0]) for x in self.refs(c, u, self.pos(src, 'Move')))
        self.assertEqual(got, [('a.pas', 3), ('b.pas', 5), ('b.pas', 6), ('geom.pas', 2), ('geom.pas', 4)])

    def test_local_names_do_not_look_at_other_files(self):
        d = self.proj({'b.pas': 'program b;\nvar Local: Integer;\nbegin\n  Local := 1\nend.\n'})
        c = self.start(root=d)
        src = 'program a;\nvar Local: Integer;\nbegin\n  Local := 1\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        got = self.refs(c, u, self.pos(src, 'Local :='))
        self.assertEqual({os.path.basename(x['uri']) for x in got}, {'a.pas'})
        self.assertEqual(len(got), 2)

    def test_references_of_a_library_name(self):
        d = self.proj({'b.pas': 'program b;\nbegin\n  WriteLn(1);\n  writeln\nend.\n'})
        c = self.start(root=d)
        src = 'program a;\nbegin\n  WriteLn(1)\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        got = sorted((os.path.basename(x['uri']), self.span(x)[0]) for x in self.refs(c, u, self.pos(src, 'WriteLn')))
        self.assertEqual(got, [('a.pas', 2), ('b.pas', 2), ('b.pas', 3)])

    def test_fields_of_an_interface_record_are_found_in_other_files(self):
        geom = 'unit geom;\ninterface\ntype TP = record X, Y: Integer end;\nvar P: TP;\nimplementation\nend.\n'
        d = self.proj({'geom.pas': geom})
        c = self.start(root=d)
        src = 'program a;\nuses geom;\nbegin\n  P.Y := 1\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        got = sorted((os.path.basename(x['uri']), self.span(x)[0]) for x in self.refs(c, u, self.pos(src, 'Y :=')))
        self.assertEqual(got, [('a.pas', 3), ('geom.pas', 2)])

    # -- rename ----------------------------------------------------------------------------------------------
    def rename(self, c, u, position, new):
        return self.ask(c, 'rename', u, position, newName=new)

    def apply(self, c, d, changes):
        """Apply a WorkspaceEdit to the files / buffers of the test; returns {basename: text}."""
        out = {}
        for u, edits in changes.items():
            path = os.path.join(d, os.path.basename(u))
            text = c.texts.get(u) if hasattr(c, 'texts') and u in c.texts else None
            if text is None:
                with open(path, 'rb') as f:
                    text = f.read().decode('cp866')
            out[os.path.basename(u)] = apply_edits(text, edits)
        return out

    def test_prepare_rename(self):
        src = 'program a;\nuses Crt;\nvar Total: Integer;\nbegin\n  Total := 1;\n  ClrScr\nend.\n'
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.ask(c, 'prepareRename', u, self.pos(src, 'Total :=', 0, 2))['result']
        self.assertEqual((self.span({'range': r['range']}), r['placeholder']), ((4, 2, 4, 7), 'Total'))
        for needle in ('ClrScr', 'Integer', 'Crt'):                                 # library names, a unit
            self.assertEqual(self.ask(c, 'prepareRename', u, self.pos(src, needle))['error']['code'], -32803, needle)
        self.assertIsNone(self.ask(c, 'prepareRename', u, self.pos(src, 'begin'))['result'])

    def test_rename_a_variable_everywhere_in_the_file(self):
        src = 'program a;\r\nvar Total: Integer;\r\nbegin\r\n  total := 1;\r\n  WriteLn(TOTAL)\r\nend.\r\n'
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.rename(c, u, self.pos(src, 'Total'), 'Sum')
        self.assertNotIn('error', r, r)
        self.assertEqual(list(r['result']['changes']), [u])
        out = apply_edits(src, r['result']['changes'][u])
        self.assertEqual(out, 'program a;\r\nvar Sum: Integer;\r\nbegin\r\n  Sum := 1;\r\n  WriteLn(Sum)\r\nend.\r\n')

    def test_rename_a_unit_routine_changes_every_file(self):
        geom = 'unit geom;\ninterface\nprocedure Move(X: Integer);\nimplementation\nprocedure Move(X: Integer);\nbegin\n  if X > 0 then Move(X - 1)\nend;\nend.\n'
        other = 'program b;\nuses geom;\nbegin\n  move(2)\nend.\n'
        d = self.proj({'geom.pas': geom, 'b.pas': other})
        c = self.start(root=d)
        src = 'program a;\nuses geom;\nbegin\n  Move(1)\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.rename(c, u, self.pos(src, 'Move'), 'Shift')
        self.assertNotIn('error', r, r)
        ch = r['result']['changes']
        self.assertEqual(sorted(os.path.basename(k) for k in ch), ['a.pas', 'b.pas', 'geom.pas'])
        self.assertEqual(apply_edits(src, ch[u]), 'program a;\nuses geom;\nbegin\n  Shift(1)\nend.\n')
        gu = [k for k in ch if k.endswith('geom.pas')][0]
        self.assertEqual(apply_edits(geom, ch[gu]), geom.replace('Move', 'Shift'))
        bu = [k for k in ch if k.endswith('b.pas')][0]
        self.assertEqual(apply_edits(other, ch[bu]), 'program b;\nuses geom;\nbegin\n  Shift(2)\nend.\n')

    def test_rename_a_record_field_and_a_parameter(self):
        src = ('program a;\ntype R = record Count: Integer end;\nvar V: R;\nprocedure P(Step: Integer);\nbegin\n'
               '  V.Count := Step;\n  with V do Count := Count + Step\nend;\nbegin\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        out = apply_edits(src, self.rename(c, u, self.pos(src, 'Count:'), 'Total')['result']['changes'][u])
        self.assertEqual(out, src.replace('Count', 'Total'))
        out = apply_edits(src, self.rename(c, u, self.pos(src, 'Step'), 'Delta')['result']['changes'][u])
        self.assertEqual(out, src.replace('Step', 'Delta'))

    def test_rename_refuses_bad_names(self):
        src = 'program a;\nvar Total: Integer;\nbegin\n  Total := 1\nend.\n'
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        for bad in ('', '1x', 'a b', 'begin', 'Begin', 'x-y', '\u0436'):
            r = self.rename(c, u, self.pos(src, 'Total'), bad)
            self.assertEqual(r['error']['code'], -32803, bad)
        r = self.rename(c, u, self.pos(src, 'Integer'), 'Int')
        self.assertEqual(r['error']['code'], -32803)                              # System

    def test_rename_refuses_when_a_meaning_would_change(self):
        src = ('program a;\nvar Total, Sum: Integer;\nprocedure P;\nvar Local: Integer;\nbegin\n  Local := Total\nend;\n'
               'begin\n  Total := 1\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.rename(c, u, self.pos(src, 'Total,'), 'Sum')                      # clashes with the other global
        self.assertEqual(r['error']['code'], -32803)
        r = self.rename(c, u, self.pos(src, 'Total,'), 'Local')                    # captured by the local inside P
        self.assertEqual(r['error']['code'], -32803)
        self.assertIn('would change the meaning', r['error']['message'])
        r = self.rename(c, u, self.pos(src, 'Total,'), 'Fresh')
        self.assertNotIn('error', r, r)

    def test_rename_checks_other_files_for_capture(self):
        geom = 'unit geom;\ninterface\nprocedure Move;\nimplementation\nprocedure Move; begin end;\nend.\n'
        other = 'unit other;\ninterface\nprocedure Shift;\nimplementation\nprocedure Shift; begin end;\nend.\n'
        user = 'program b;\nuses other, geom;\nbegin\n  Shift\nend.\n'        # Shift is other.Shift today
        d = self.proj({'geom.pas': geom, 'other.pas': other, 'b.pas': user})
        c = self.start(root=d)
        src = 'program a;\nuses geom;\nbegin\n  Move\nend.\n'
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.rename(c, u, self.pos(src, 'Move'), 'Shift')                      # b.pas would pick geom.Shift
        self.assertEqual(r['error']['code'], -32803)
        self.assertIn('b.pas', r['error']['message'])

    def test_rename_reports_inactive_branches(self):
        src = ('program a;\nvar Total: Integer;\nbegin\n{$IFDEF FOO}\n  Total := 2;\n{$ELSE}\n  Total := 1;\n{$ENDIF}\nend.\n')
        d = self.proj()
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'a.pas'), src)
        r = self.rename(c, u, self.pos(src, 'Total'), 'Sum')
        self.assertNotIn('error', r, r)
        self.assertEqual(len(r['result']['changes'][u]), 2)                        # the declaration and the active use
        m = c.wait_for('window/showMessage', lambda m: 'not renamed' in m['params']['message'])
        self.assertIn('1 occurrence', m['params']['message'])

    def test_unopened_and_nothing_under_the_cursor(self):
        c = self.start()
        for m in ('references', 'documentHighlight', 'prepareRename'):
            r = c.request('textDocument/' + m, {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))},
                                                'position': {'line': 0, 'character': 0}})
            self.assertEqual(r['error']['code'], -32602, m)
        r = c.request('textDocument/rename', {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))},
                                              'position': {'line': 0, 'character': 0}, 'newName': 'X'})
        self.assertEqual(r['error']['code'], -32602)

    def test_capabilities(self):
        c = self.start(init=False)
        cap = c.initialize(self.ws, self.tp7)['result']['capabilities']
        self.assertTrue(cap['documentHighlightProvider'])
        self.assertTrue(cap['referencesProvider'])
        self.assertEqual(cap['renameProvider'], {'prepareProvider': True})


class Outline(Base):
    SRC = ('unit U;\r\ninterface\r\nuses Crt;\r\nconst\r\n  K = 3;\r\n  T: Integer = 4;\r\ntype\r\n  E = (A, B);\r\n'
           '  R = record\r\n    x, y: Integer;\r\n    case Tag: Byte of\r\n      0: (p: Word);\r\n      1: (q: Char; r: Byte);\r\n'
           '  end;\r\n  P = ^R;\r\n  Arr = array [1..3] of Byte;\r\nvar\r\n  V, W: Integer;\r\n'
           'procedure Foo(N: Integer; var S: string);\r\nfunction Bar: Boolean;\r\nimplementation\r\n'
           'procedure Foo(N: Integer; var S: string);\r\nvar Local: Integer;\r\n  procedure Inner;\r\n  begin\r\n  end;\r\n'
           'begin\r\nend;\r\nfunction Bar: Boolean;\r\nbegin\r\n  Bar := True\r\nend;\r\nbegin\r\nend.\r\n')

    def symbols(self, c, u):
        r = c.request('textDocument/documentSymbol', {'textDocument': {'uri': u}})
        self.assertNotIn('error', r, r)
        return r['result']

    @staticmethod
    def tree(syms):
        return [(s['name'], s['kind'], s.get('detail'), Outline.tree(s.get('children') or [])) for s in syms]

    def contained(self, outer, inner):
        a = (outer['start']['line'], outer['start']['character']), (outer['end']['line'], outer['end']['character'])
        b = (inner['start']['line'], inner['start']['character']), (inner['end']['line'], inner['end']['character'])
        return a[0] <= b[0] and b[1] <= a[1]

    def check_ranges(self, syms, parent=None):
        prev_end = None
        for s in syms:
            self.assertTrue(self.contained(s['range'], s['selectionRange']), s['name'])
            if parent is not None:
                self.assertTrue(self.contained(parent['range'], s['range']), (parent['name'], s['name']))
            self.check_ranges(s.get('children') or [], s)

    def test_capability(self):
        c = self.start(init=False)
        self.assertTrue(c.initialize(self.ws, self.tp7)['result']['capabilities']['documentSymbolProvider'])

    def test_unit_outline(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'u.pas'), self.SRC)
        syms = self.symbols(c, u)
        self.assertEqual(self.tree(syms), [
            ('U', 2, None, [
                ('interface', 3, None, [
                    ('K', 14, '= 3', []),
                    ('T', 14, ': Integer = 4', []),
                    ('E', 10, None, [('A', 22, None, []), ('B', 22, None, [])]),
                    ('R', 23, None, [('x', 8, 'Integer', []), ('y', 8, 'Integer', []), ('Tag', 8, 'Byte', []),
                                     ('p', 8, 'Word', []), ('q', 8, 'Char', []), ('r', 8, 'Byte', [])]),
                    ('P', 26, '^R', []),
                    ('Arr', 18, 'array [1..3] of Byte', []),
                    ('V', 13, 'Integer', []),
                    ('W', 13, 'Integer', []),
                    ('Foo', 12, '(N: Integer; var S: string)', []),
                    ('Bar', 12, ': Boolean', [])]),
                ('implementation', 3, None, [
                    ('Foo', 12, '(N: Integer; var S: string)', [('Inner', 12, None, [])]),
                    ('Bar', 12, ': Boolean', [])])])])
        self.check_ranges(syms)

    def test_selection_ranges_are_the_names_and_ranges_cover_the_declaration(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'u.pas'), self.SRC)
        iface = self.symbols(c, u)[0]['children'][0]['children']
        by = {x['name']: x for x in iface}
        foo = by['Foo']
        self.assertEqual(foo['selectionRange'], {'start': {'line': 18, 'character': 10}, 'end': {'line': 18, 'character': 13}})
        self.assertEqual(foo['range']['start'], {'line': 18, 'character': 0})
        impl_foo = self.symbols(c, u)[0]['children'][1]['children'][0]
        self.assertEqual(impl_foo['range']['start']['line'], 21)
        self.assertEqual(impl_foo['range']['end']['line'], 27)                     # up to the `end` of its body
        self.assertEqual(by['V']['selectionRange']['start'], {'line': 17, 'character': 2})
        self.assertEqual(by['W']['selectionRange']['start'], {'line': 17, 'character': 5})

    def test_program_outline_and_local_data_is_left_out(self):
        src = ('program P;\nuses Crt;\nvar Total: Integer;\nprocedure Run;\nvar Tmp: Integer;\nconst C = 1;\n'
               '  procedure Step; begin end;\nbegin\nend;\nbegin\n  Run\nend.\n')
        c = self.start()
        u = c.open(os.path.join(self.ws, 'p.pas'), src)
        syms = self.symbols(c, u)
        self.assertEqual(self.tree(syms), [('P', 2, None, [('Total', 13, 'Integer', []),
                                                            ('Run', 12, None, [('Step', 12, None, [])])])])
        self.check_ranges(syms)

    def test_program_without_a_header(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'p.pas'), 'var I: Integer;\nbegin\nend.\n')
        syms = self.symbols(c, u)
        self.assertEqual(self.tree(syms), [('program', 2, None, [('I', 13, 'Integer', [])])])
        self.check_ranges(syms)

    def test_empty_and_broken_documents(self):
        c = self.start()
        self.assertEqual(self.symbols(c, c.open(os.path.join(self.ws, 'e.pas'), '')), [])
        u = c.open(os.path.join(self.ws, 'b.pas'), 'program a;\nvar V: Integer;\nprocedure P(;\nbegin\n  V := ;\nend.\n')
        syms = self.symbols(c, u)
        self.assertEqual(syms[0]['name'], 'a')
        self.assertTrue(any(x['name'] == 'V' for x in syms[0]['children']))
        self.check_ranges(syms)

    def test_inactive_branches_are_not_in_the_outline(self):
        src = 'program a;\n{$IFDEF FOO}\nvar Dead: Integer;\n{$ELSE}\nvar Live: Integer;\n{$ENDIF}\nbegin end.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        self.assertEqual(self.tree(self.symbols(c, u)), [('a', 2, None, [('Live', 13, 'Integer', [])])])

    def test_utf16_columns(self):
        src = 'program a;\nconst { \U0001F600 } K = 1;\nbegin end.\n'
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), src)
        k = self.symbols(c, u)[0]['children'][0]
        self.assertEqual(k['selectionRange']['start'], {'line': 1, 'character': 13})      # 'const { ' = 8, the emoji = 2 units, ' } ' = 3

    def test_flat_symbol_information_when_the_client_has_no_hierarchy(self):
        c = self.start(init=False)
        c.initialize(self.ws, self.tp7, hier=False)
        u = c.open(os.path.join(self.ws, 'u.pas'), self.SRC)
        flat = self.symbols(c, u)
        self.assertTrue(all('location' in x and 'children' not in x for x in flat))
        self.assertEqual(flat[0]['name'], 'U')
        self.assertNotIn('containerName', flat[0])
        inner = [x for x in flat if x['name'] == 'Inner'][0]
        self.assertEqual(inner['containerName'], 'Foo')
        self.assertEqual(inner['location']['uri'], u)
        a = [x for x in flat if x['name'] == 'A'][0]
        self.assertEqual(a['containerName'], 'E')
        self.assertEqual(len(flat), 24)

    def test_unopened_document_is_invalid_params(self):
        c = self.start()
        r = c.request('textDocument/documentSymbol', {'textDocument': {'uri': uri(os.path.join(self.ws, 'zz.pas'))}})
        self.assertEqual(r['error']['code'], -32602)

    def test_follows_edits(self):
        c = self.start()
        u = c.open(os.path.join(self.ws, 'a.pas'), 'program a;\nvar V: Integer;\nbegin end.\n')
        self.assertEqual(len(self.symbols(c, u)[0]['children']), 1)
        c.change(u, 'program a;\nvar V: Integer;\nvar W: Byte;\nbegin end.\n', 2)
        self.assertEqual([x['name'] for x in self.symbols(c, u)[0]['children']], ['V', 'W'])


class EditComputation(unittest.TestCase):
    CASES = [('', ''), ('', 'a\n'), ('a\n', ''), ('a', 'b'), ('a\nb', 'a\nc'), ('a\r\nb\r\n', 'a\r\nB\r\n'),
             ('x\ny', 'x\ny\n'), ('x\ny\n', 'x\ny'), ('\n\n', '\n'), ('a\nb\nc\n', 'a\nc\n'), ('a\n', 'a\nb\nc\n'),
             ('é😀\nz', 'é😀\nZ'), ('a\rb\r', 'a\rc\r')]

    def test_cases_round_trip(self):
        for old, new in self.CASES:
            edits = compute_edits(old, new)
            self.assertLessEqual(len(edits), 1)
            self.assertEqual(apply_edits(old, edits), new, (old, new))

    def test_equal_texts_give_no_edits(self):
        self.assertEqual(compute_edits('a\nb\n', 'a\nb\n'), [])

    def test_exact_ranges(self):
        self.assertEqual(compute_edits('a\nb\nc\n', 'a\nc\n'),
                         [{'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 2, 'character': 0}},
                           'newText': ''}])
        self.assertEqual(compute_edits('a', 'b'),
                         [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}},
                           'newText': 'b'}])
        self.assertEqual(compute_edits('x\ny', 'x\ny\n')[0]['range']['end'], {'line': 1, 'character': 1})

    def test_end_column_counts_utf16_units(self):
        self.assertEqual(compute_edits('😀', 'x')[0]['range']['end'], {'line': 0, 'character': 2})
        self.assertEqual(utf16_len('é😀'), 3)

    def test_fuzz(self):
        rnd = random.Random(3)
        parts = ['a\n', 'b\n', 'c', '\r\n', 'é\n', '😀x\n', '', '\n', 'a\r\n', 'zz']
        for _ in range(3000):
            old = ''.join(rnd.choice(parts) for _ in range(rnd.randint(0, 6)))
            new = ''.join(rnd.choice(parts) for _ in range(rnd.randint(0, 6)))
            self.assertEqual(apply_edits(old, compute_edits(old, new)), new, (old, new))


if __name__ == '__main__':
    unittest.main(verbosity=2)
