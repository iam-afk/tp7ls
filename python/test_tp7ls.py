#!/usr/bin/env python3
"""Tests for tp7ls.py: edit helpers (unit) and the real server as a subprocess speaking LSP over pipes.
Run: python3 test_tp7ls.py [DIR_WITH_SAMPLES]   (DIR: TURBO.TPL, polsk.pas, option.pas, TEST.PAS)"""
import json, os, queue, random, shutil, subprocess, sys, tempfile, threading, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tp7ls import apply_edits, compute_edits, split_lines, u16len, uri_to_path
from tp7fmt import format_source
from tp7sema import Provider

D = sys.argv.pop(1) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else '/mnt/user-data/uploads'
TPL = os.path.join(D, 'TURBO.TPL')


def rd(name):
    with open(os.path.join(D, name), 'rb') as f:
        return f.read().decode('cp866')


def uri(path):
    return 'file://' + os.path.abspath(path)


# ---------------------------------------------------------------------------------------------------
class Edits(unittest.TestCase):
    def test_split_lines_only_cr_lf_crlf(self):
        self.assertEqual(split_lines('a\r\nb\rc\nd'), ['a\r\n', 'b\r', 'c\n', 'd'])
        self.assertEqual(split_lines('x\x0cy z\n'), ['x\x0cy z\n'])
        self.assertEqual(split_lines(''), [])
        self.assertEqual(split_lines('\n\n'), ['\n', '\n'])

    def test_fuzz_apply_compute_roundtrip(self):
        rnd = random.Random(3)
        atoms = ['a', 'bb', 'Ж', 'ё', '😀', ' ', '{c}', 'x := 1;']
        eols = ['\n', '\r\n', '\r', '']

        def doc():
            return ''.join(rnd.choice(atoms) * rnd.randint(0, 2) + rnd.choice(eols[:3] if rnd.random() < .9 else eols)
                           for _ in range(rnd.randint(0, 12)))
        for _ in range(4000):
            a, b = doc(), doc()
            e = compute_edits(a, b)
            self.assertEqual(apply_edits(a, e), b, (a, b, e))
            if a == b:
                self.assertEqual(e, [])

    def test_edits_are_minimal_and_line_aligned(self):
        a = 'one\ntwo\nthree\nfour\n'
        b = 'one\n2\nthree\nfour\nfive\n'
        e = compute_edits(a, b)
        self.assertEqual(len(e), 2)
        self.assertEqual(e[0], {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 2, 'character': 0}},
                                'newText': '2\n'})
        self.assertEqual(e[1]['range']['start'], {'line': 4, 'character': 0})
        self.assertTrue(all(x['range']['start']['character'] == 0 for x in e))

    def test_missing_final_newline_uses_utf16_end(self):
        e = compute_edits('a\nЖ😀', 'a\nZ')
        self.assertEqual(e[0]['range']['end'], {'line': 1, 'character': 3})          # Ж=1 unit, 😀=2 units
        self.assertEqual(u16len('Ж😀'), 3)

    def test_uri_to_path(self):
        self.assertEqual(uri_to_path('file:///home/u/a%20b/x.pas'), '/home/u/a b/x.pas')
        self.assertIsNone(uri_to_path('untitled:Untitled-1'))


# ---------------------------------------------------------------------------------------------------
class Client:
    def __init__(self, env=None, cwd=None):
        e = dict(os.environ)
        e.pop('TP7_TPL', None)
        e.pop('TP7_PATH', None)
        e.update(env or {})
        self.p = subprocess.Popen([sys.executable, os.path.join(HERE, 'tp7ls.py')], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, cwd=cwd)
        self.q = queue.Queue()
        self.next_id = 1
        self.notes = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: [None for _ in self.p.stderr], daemon=True).start()

    def _read(self):
        f = self.p.stdout
        while True:
            n = None
            while True:
                line = f.readline()
                if not line:
                    self.q.put(None)
                    return
                if line.strip() == b'':
                    break
                k, _, v = line.decode().partition(':')
                if k.lower() == 'content-length':
                    n = int(v)
            self.q.put(json.loads(f.read(n).decode('utf-8')))

    def send(self, msg):
        data = json.dumps(msg, ensure_ascii=False).encode('utf-8')
        self.p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(data) + data)
        self.p.stdin.flush()

    def notify(self, method, params=None):
        self.send({'jsonrpc': '2.0', 'method': method, 'params': params or {}})

    def request(self, method, params=None, timeout=20):
        rid = self.next_id
        self.next_id += 1
        self.send({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params or {}})
        while True:
            m = self.q.get(timeout=timeout)
            self.assertion = m
            if m is None:
                raise EOFError('server closed the pipe')
            if m.get('id') == rid and 'method' not in m:
                return m
            self.notes.append(m)

    def wait_note(self, method, timeout=20, pred=lambda p: True):
        for i, m in enumerate(self.notes):
            if m.get('method') == method and pred(m['params']):
                return self.notes.pop(i)['params']
        while True:
            m = self.q.get(timeout=timeout)
            if m is None:
                raise EOFError('server closed the pipe')
            if m.get('method') == method and pred(m['params']):
                return m['params']
            self.notes.append(m)

    def start(self, root=None, options=None):
        r = self.request('initialize', {'processId': None, 'rootUri': uri(root) if root else None,
                                        'capabilities': {}, 'initializationOptions': options or {}})
        self.notify('initialized')
        return r

    def open(self, path, text, version=1):
        self.notify('textDocument/didOpen', {'textDocument': {'uri': uri(path), 'languageId': 'pascal',
                                                              'version': version, 'text': text}})

    def change(self, path, text, version):
        self.notify('textDocument/didChange', {'textDocument': {'uri': uri(path), 'version': version},
                                               'contentChanges': [{'text': text}]})

    def format(self, path):
        return self.request('textDocument/formatting', {'textDocument': {'uri': uri(path)},
                                                        'options': {'tabSize': 2, 'insertSpaces': True}})

    def shutdown(self):
        r = self.request('shutdown')
        self.notify('exit')
        self.p.wait(timeout=10)
        return r, self.p.returncode

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()
        for s in (self.p.stdin, self.p.stdout, self.p.stderr):
            try:
                s.close()
            except Exception:
                pass


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.c = Client()
        self.addCleanup(self.c.kill)
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, name):
        return os.path.join(self.tmp, name)

    def reference(self, text, dirs=()):
        return format_source(text, normalize=True, provider=Provider(list(dirs), TPL))


class Protocol(ServerCase):
    def test_initialize_capabilities_and_clean_shutdown(self):
        r = self.c.start(self.tmp)
        caps = r['result']['capabilities']
        self.assertTrue(caps['documentFormattingProvider'])
        self.assertEqual(caps['textDocumentSync']['change'], 1)
        self.assertEqual(r['result']['serverInfo']['name'], 'tp7ls')
        res, code = self.c.shutdown()
        self.assertIsNone(res['result'])
        self.assertEqual(code, 0)

    def test_exit_without_shutdown_is_an_error_exit(self):
        self.c.start(self.tmp)
        self.c.notify('exit')
        self.c.p.wait(timeout=10)
        self.assertEqual(self.c.p.returncode, 1)

    def test_request_before_initialize_and_unknown_method(self):
        r = self.c.request('textDocument/formatting', {'textDocument': {'uri': uri(self.path('a.pas'))}})
        self.assertEqual(r['error']['code'], -32002)
        self.c.start(self.tmp)
        r = self.c.request('textDocument/hover', {})
        self.assertEqual(r['error']['code'], -32601)
        self.c.notify('$/setTrace', {'value': 'off'})                      # unknown notifications are ignored
        self.c.notify('workspace/didChangeConfiguration', {'settings': {}})
        self.assertIsNone(self.c.request('shutdown')['result'])

    def test_garbage_between_messages_does_not_kill_the_server(self):
        self.c.start(self.tmp)
        self.c.p.stdin.write(b'Content-Type: nothing\r\n\r\nContent-Length: 5\r\n\r\n{bad}')
        self.c.p.stdin.flush()
        self.assertIsNone(self.c.request('shutdown')['result'])

    def test_closed_stdin_without_shutdown_exits_1(self):
        self.c.start(self.tmp)
        self.c.p.stdin.close()
        self.c.p.wait(timeout=10)
        self.assertEqual(self.c.p.returncode, 1)


class Formatting(ServerCase):
    def setUp(self):
        super().setUp()
        self.c.start(self.tmp, {'tpl': TPL, 'paths': [D]})

    def test_formatting_matches_the_library_and_reaches_a_fixed_point(self):
        for name in ('polsk.pas', 'TEST.PAS'):
            src = rd(name)
            p = self.path(name)
            self.c.open(p, src)
            r = self.c.format(p)
            edits = r['result']
            self.assertIsInstance(edits, list, r)
            want = self.reference(src, [D])
            self.assertEqual(apply_edits(src, edits), want, name)
            # apply, tell the server, ask again: nothing left to do
            self.c.change(p, want, 2)
            self.assertEqual(self.c.format(p)['result'], [], name)

    def test_edits_are_small_for_a_nearly_formatted_file(self):
        src = rd('polsk_formatted.pas')                                    # reference layout, identifier case not normalised
        p = self.path('x.pas')
        self.c.open(p, src)
        edits = self.c.format(p)['result']
        changed = sum(len(split_lines(e['newText'])) for e in edits)
        self.assertTrue(0 < len(edits))
        self.assertLess(changed, len(split_lines(src)) // 3)               # only the case fixes, never a rewrite
        self.assertTrue(all(e['range']['start']['character'] == 0 for e in edits))

    def test_non_ascii_text_survives_utf8_transport(self):
        src = rd('polsk.pas')
        self.assertIn('А', src)                                            # Cyrillic inside string literals
        p = self.path('u.pas')
        self.c.open(p, src)
        out = apply_edits(src, self.c.format(p)['result'])
        self.assertIn("['А'..'Я']", out)

    def test_syntax_error_refuses_with_request_failed(self):
        p = self.path('bad.pas')
        self.c.open(p, 'program t;\nbegin\n  x := ;\nend.\n')
        r = self.c.format(p)
        self.assertEqual(r['error']['code'], -32803)
        self.assertIn('syntax problems', r['error']['message'])
        self.assertIn('3:', r['error']['message'])

    def test_unknown_document(self):
        r = self.c.format(self.path('never_opened.pas'))
        self.assertEqual(r['error']['code'], -32602)

    def test_close_clears_diagnostics_and_formatting_then_fails(self):
        p = self.path('c.pas')
        self.c.open(p, 'program t; begin x := ; end.')
        self.c.wait_note('textDocument/publishDiagnostics')
        self.c.notify('textDocument/didClose', {'textDocument': {'uri': uri(p)}})
        n = self.c.wait_note('textDocument/publishDiagnostics', pred=lambda q: q['diagnostics'] == [])
        self.assertEqual(n['uri'], uri(p))
        self.assertEqual(self.c.format(p)['error']['code'], -32602)

    def test_defines_from_initialization_options(self):
        c = Client()
        self.addCleanup(c.kill)
        c.start(self.tmp, {'tpl': TPL, 'defines': ['DEBUG']})
        src = 'program t;\n{$IFDEF DEBUG}\nvar   a:integer;\n{$ELSE}\nvar   b:integer;\n{$ENDIF}\nbegin end.\n'
        p = self.path('d.pas')
        c.open(p, src)
        out = apply_edits(src, c.format(p)['result'])
        self.assertIn('var\n  a: Integer;', out)
        self.assertIn('var   b:integer;', out)

    def test_other_unit_from_disk_and_from_unsaved_buffer(self):
        with open(self.path('mylib.pas'), 'wb') as f:
            f.write('unit MyLib;\ninterface\nvar Counter: integer;\nimplementation\nend.\n'.encode('cp866'))
        prog = 'program t;\nuses mylib;\nbegin\n  COUNTER := 1;\nend.\n'
        p = self.path('t.pas')
        self.c.open(p, prog)
        self.assertIn('  Counter := 1;', apply_edits(prog, self.c.format(p)['result']))
        # the unit is now open in the editor with an unsaved change: the buffer wins over the disk
        lib = self.path('mylib.pas')
        self.c.open(lib, 'unit MyLib;\ninterface\nvar CounTER: integer;\nimplementation\nend.\n')
        self.assertIn('  CounTER := 1;', apply_edits(prog, self.c.format(p)['result']))
        self.c.change(lib, 'unit MyLib;\ninterface\nvar Total: integer;\nimplementation\nend.\n', 2)
        self.assertIn('  COUNTER := 1;', apply_edits(prog, self.c.format(p)['result']))        # no longer declared

    def test_formatting_twice_gives_the_same_answer(self):
        src = rd('option.pas')
        p = self.path('o.pas')
        self.c.open(p, src)
        a = self.c.format(p)['result']
        b = self.c.format(p)['result']
        self.assertEqual(a, b)


class Diagnostics(ServerCase):
    def test_diagnostics_positions_in_utf16_and_update_on_change(self):
        self.c.start(self.tmp, {'tpl': TPL})
        p = self.path('e.pas')
        src = "program t;\nbegin\n  s := 'Ж😀'; x := ;\nend.\n"
        self.c.open(p, src, version=7)
        n = self.c.wait_note('textDocument/publishDiagnostics')
        self.assertEqual(n['uri'], uri(p))
        self.assertEqual(n['version'], 7)
        d = n['diagnostics'][0]
        self.assertEqual(d['severity'], 1)
        self.assertEqual(d['range']['start']['line'], 2)
        self.assertEqual(d['range']['start']['character'], len("  s := 'Ж😀'; x := ") + 1)     # 😀 counts as 2 units
        self.c.change(p, 'program t;\nbegin\nend.\n', 8)
        n = self.c.wait_note('textDocument/publishDiagnostics', pred=lambda q: q['version'] == 8)
        self.assertEqual(n['diagnostics'], [])

    def test_object_types_are_supported(self):
        self.c.start(self.tmp, {'tpl': TPL})
        p = self.path('o.pas')
        self.c.open(p, 'program t;\ntype T = object x: integer; end;\nbegin end.\n')
        n = self.c.wait_note('textDocument/publishDiagnostics')
        self.assertEqual(n['diagnostics'], [])


class Discovery(ServerCase):
    def test_tpl_found_next_to_the_document_in_bin_and_units_dir_used(self):
        tp = os.path.join(self.tmp, 'TP')
        os.makedirs(os.path.join(tp, 'BIN'))
        os.makedirs(os.path.join(tp, 'UNITS'))
        os.makedirs(os.path.join(tp, 'SRC'))
        shutil.copy(TPL, os.path.join(tp, 'BIN', 'turbo.tpl'))
        shutil.copy(os.path.join(D, 'GRAPH.TPU'), os.path.join(tp, 'UNITS', 'GRAPH.TPU'))
        src = 'program t;\nuses graph, crt;\nvar gd, gm: integer;\nbegin\n  initgraph(gd, gm, \'\'); clrscr;\nend.\n'
        p = os.path.join(tp, 'SRC', 'T.PAS')
        self.c.start(os.path.join(tp, 'SRC'))                                  # no options at all
        self.c.open(p, src)
        out = apply_edits(src, self.c.format(p)['result'])
        self.assertIn('uses\n  Graph, Crt;', out)
        self.assertIn("  InitGraph(gd, gm, '');", out)
        self.assertIn('  ClrScr;', out)

    def test_without_tpl_it_still_formats_and_says_so(self):
        c = Client(cwd=self.tmp)
        self.addCleanup(c.kill)
        c.start(self.tmp)
        src = 'PROGRAM t; VAR x:integer; BEGIN x:=1 END.'
        p = self.path('n.pas')
        c.open(p, src)
        out = apply_edits(src, c.format(p)['result'])
        self.assertIn('program t;', out)
        self.assertIn('  x := 1;', out)
        m = c.wait_note('window/logMessage', pred=lambda q: 'TURBO.TPL not found' in q['message'])
        self.assertEqual(m['type'], 2)

    def test_environment_variable_tp7_tpl(self):
        c = Client(env={'TP7_TPL': TPL})
        self.addCleanup(c.kill)
        c.start(self.tmp)
        src = 'program t; begin writeln(ord(true)) end.'
        p = self.path('v.pas')
        c.open(p, src)
        self.assertIn('  WriteLn(Ord(True));', apply_edits(src, c.format(p)['result']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
