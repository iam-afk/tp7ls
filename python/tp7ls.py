#!/usr/bin/env python3
"""
tp7ls.py - Language Server (LSP over stdio) for Turbo Pascal 7.  Prototype, milestone M3.

Features
  * textDocument/formatting: whole-file fixed-style formatting + identifier-case normalisation (tp7fmt + tp7sema).
    The answer is a set of minimal LINE edits (difflib), not a whole-document replacement, so cursor, marks and
    folds of the editor stay put.  A file with syntax errors is refused: the request fails with code -32803
    (RequestFailed) and the reason as the message.
  * diagnostics: the parser's problems, published on open / change / save.

Text encoding: the editor decodes the file (cp866 -> UTF-8, see the neovim config) and sends UTF-8 text; the server
never touches cp866 for open documents.  Other units are read from disk as cp866 (.pas) or as binary (.tpu/.tpl),
unless the unit is open in the editor, in which case the buffer wins.

Where the server looks for things (there are no formatting options, only locations):
  initializationOptions = {"tpl": "C:/TP/BIN/TURBO.TPL", "paths": ["C:/TP/UNITS", ...], "defines": ["DEBUG"]}
  environment: TP7_TPL (path to TURBO.TPL), TP7_PATH (directories separated by os.pathsep)
  otherwise: TURBO.TPL is searched in the document's directory, the workspace folders and their BIN subdirectories
  (and in the parents of the document's directory); the units path is: the document's directory, workspace folders,
  "paths", TP7_PATH, the directory of TURBO.TPL and the UNITS directory next to its BIN directory.
Without TURBO.TPL formatting still works, but System/Dos/Crt identifiers keep their spelling (reported in the log).
"""
import copy
import difflib
import json
import os
import re
import sys
from typing import Dict, List, Optional
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from tp7fmt import FormatError, format_source          # noqa: E402
from tp7parse import DEFAULT_DEFINES, parse            # noqa: E402
from tp7sema import Provider                           # noqa: E402

SERVER_NAME = 'tp7ls'
SERVER_VERSION = '0.1.0'

PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS, INTERNAL_ERROR = -32700, -32600, -32601, -32602, -32603
SERVER_NOT_INITIALIZED, REQUEST_FAILED = -32002, -32803

_LINE_RE = re.compile(r'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+')


# ---------------------------------------------------------------------------------------------------
# text helpers (pure functions, unit-tested)
def split_lines(text: str) -> List[str]:
    """Lines WITH their terminators; only \\r\\n, \\r and \\n end a line (that is what LSP says)."""
    return _LINE_RE.findall(text)


def u16len(s: str) -> int:
    return len(s.encode('utf-16-le', 'surrogatepass')) // 2


def u16_to_index(line: str, units: int) -> int:
    """Index in `line` (code points) of UTF-16 offset `units` (clamped to the line)."""
    n = 0
    for i, ch in enumerate(line):
        if n >= units:
            return i
        n += 2 if ord(ch) > 0xFFFF else 1
    return len(line)


def compute_edits(old: str, new: str) -> List[dict]:
    """Minimal line-based TextEdits that turn `old` into `new`."""
    if old == new:
        return []
    a, b = split_lines(old), split_lines(new)

    def pos(i):
        if i < len(a):
            return {'line': i, 'character': 0}
        if not a:
            return {'line': 0, 'character': 0}
        last = a[-1]
        if last.endswith('\n') or last.endswith('\r'):
            return {'line': len(a), 'character': 0}
        return {'line': len(a) - 1, 'character': u16len(last)}

    edits = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        edits.append({'range': {'start': pos(i1), 'end': pos(i2)}, 'newText': ''.join(b[j1:j2])})
    return edits


def apply_edits(text: str, edits: List[dict]) -> str:
    """Apply TextEdits (non-overlapping) to `text`; used by the tests and for the sanity check in the server."""
    lines = split_lines(text)
    starts, off = [], 0
    for ln in lines:
        starts.append(off)
        off += len(ln)
    total = off

    def offset(p):
        i = p['line']
        if i >= len(lines):
            return total
        return starts[i] + u16_to_index(lines[i], p['character'])

    out, last = [], 0
    for e in sorted(edits, key=lambda e: (offset(e['range']['start']), offset(e['range']['end']))):
        s, t = offset(e['range']['start']), offset(e['range']['end'])
        out.append(text[last:s])
        out.append(e['newText'])
        last = t
    out.append(text[last:])
    return ''.join(out)


def uri_to_path(uri: str) -> Optional[str]:
    u = urlparse(uri)
    if u.scheme != 'file':
        return None
    path = url2pathname(unquote(u.path))
    if u.netloc and u.netloc != 'localhost':                 # UNC: file://server/share/x
        path = '//' + u.netloc + unquote(u.path)
    return path


def find_file_ci(directory: str, name: str) -> Optional[str]:
    try:
        for fn in os.listdir(directory):
            if fn.lower() == name.lower():
                return os.path.join(directory, fn)
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------------------------------
class Doc:
    def __init__(self, uri, text, version):
        self.uri = uri
        self.text = text
        self.version = version
        self.path = uri_to_path(uri)

    @property
    def dir(self) -> Optional[str]:
        return os.path.dirname(self.path) if self.path else None


class Server:
    def __init__(self, inp, out):
        self.inp, self.out = inp, out
        self.docs: Dict[str, Doc] = {}
        self.options: dict = {}
        self.roots: List[str] = []
        self.initialized = False
        self.shutdown_requested = False
        self.exit_code: Optional[int] = None
        self._providers: Dict[Optional[str], Provider] = {}
        self._warned_no_tpl = False

    # -- transport --------------------------------------------------------------------------------
    def read_message(self) -> Optional[dict]:
        while True:
            headers = {}
            while True:
                line = self.inp.readline()
                if not line:
                    return None
                line = line.strip()
                if not line:
                    break
                k, _, v = line.decode('ascii', 'replace').partition(':')
                headers[k.strip().lower()] = v.strip()
            try:
                n = int(headers.get('content-length', ''))
            except ValueError:
                continue                                         # not a LSP frame: ignore and resync
            body = self.inp.read(n)
            if len(body) < n:
                return None
            try:
                return json.loads(body.decode('utf-8'))
            except ValueError:
                self.send({'jsonrpc': '2.0', 'id': None, 'error': {'code': PARSE_ERROR, 'message': 'parse error'}})

    def send(self, msg: dict):
        data = json.dumps(msg, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        self.out.write(b'Content-Length: %d\r\n\r\n' % len(data))
        self.out.write(data)
        self.out.flush()

    def respond(self, req_id, result=None):
        self.send({'jsonrpc': '2.0', 'id': req_id, 'result': result})

    def fail(self, req_id, code: int, message: str):
        self.send({'jsonrpc': '2.0', 'id': req_id, 'error': {'code': code, 'message': message}})

    def notify(self, method: str, params: dict):
        self.send({'jsonrpc': '2.0', 'method': method, 'params': params})

    def log(self, message: str, kind: int = 3):
        self.notify('window/logMessage', {'type': kind, 'message': message})

    # -- main loop --------------------------------------------------------------------------------
    def serve(self) -> int:
        while self.exit_code is None:
            msg = self.read_message()
            if msg is None:
                return 0 if self.shutdown_requested else 1
            if not isinstance(msg, dict):
                continue
            try:
                self.dispatch(msg)
            except Exception as e:                                # a bug must never kill the server
                import traceback
                traceback.print_exc(file=sys.stderr)
                if 'id' in msg and 'method' in msg:
                    self.fail(msg['id'], INTERNAL_ERROR, 'internal error: %s: %s' % (type(e).__name__, e))
                else:
                    self.log('internal error in %s: %s: %s' % (msg.get('method'), type(e).__name__, e), 1)
        return self.exit_code

    def dispatch(self, msg: dict):
        method = msg.get('method')
        if method is None:
            return                                                # a response to us: we send no requests
        rid = msg.get('id')
        is_request = 'id' in msg
        params = msg.get('params') or {}
        if method == 'exit':
            self.exit_code = 0 if self.shutdown_requested else 1
            return
        if not self.initialized and method != 'initialize':
            if is_request:
                self.fail(rid, SERVER_NOT_INITIALIZED, 'server not initialized')
            return
        if self.shutdown_requested and is_request:
            self.fail(rid, INVALID_REQUEST, 'server is shutting down')
            return
        handler = getattr(self, 'on_' + re.sub(r'[^A-Za-z0-9]', '_', method), None)
        if handler is None:
            if is_request:
                self.fail(rid, METHOD_NOT_FOUND, 'method not supported: %s' % method)
            return                                                # unknown notifications (incl. $/...) are ignored
        result = handler(params)
        if is_request:
            if isinstance(result, tuple):                         # (code, message) = failure
                self.fail(rid, result[0], result[1])
            else:
                self.respond(rid, result)

    # -- lifecycle --------------------------------------------------------------------------------
    def on_initialize(self, p):
        self.options = p.get('initializationOptions') or {}
        roots = [f['uri'] for f in (p.get('workspaceFolders') or []) if f.get('uri')]
        if not roots and p.get('rootUri'):
            roots = [p['rootUri']]
        self.roots = [r for r in (uri_to_path(u) for u in roots) if r]
        self.initialized = True
        return {
            'capabilities': {
                'positionEncoding': 'utf-16',
                'textDocumentSync': {'openClose': True, 'change': 1, 'save': {'includeText': False}},
                'documentFormattingProvider': True,
            },
            'serverInfo': {'name': SERVER_NAME, 'version': SERVER_VERSION},
        }

    def on_initialized(self, p):
        pass

    def on_shutdown(self, p):
        self.shutdown_requested = True
        return None

    # -- documents --------------------------------------------------------------------------------
    def on_textDocument_didOpen(self, p):
        td = p['textDocument']
        doc = Doc(td['uri'], td['text'], td.get('version', 0))
        self.docs[doc.uri] = doc
        self.publish(doc)

    def on_textDocument_didChange(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        changes = p.get('contentChanges') or []
        if doc is None or not changes:
            return
        doc.text = changes[-1]['text']                            # full sync: the last change is the whole text
        doc.version = p['textDocument'].get('version', doc.version)
        self.publish(doc)

    def on_textDocument_didSave(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is not None:
            self.publish(doc)

    def on_textDocument_didClose(self, p):
        uri = p['textDocument']['uri']
        if self.docs.pop(uri, None) is not None:
            self.notify('textDocument/publishDiagnostics', {'uri': uri, 'diagnostics': []})

    # -- configuration of locations ------------------------------------------------------------------
    @property
    def defines(self) -> List[str]:
        return list(DEFAULT_DEFINES) + [str(d) for d in (self.options.get('defines') or [])]

    def find_tpl(self, doc: Doc) -> Optional[str]:
        cand = self.options.get('tpl') or os.environ.get('TP7_TPL')
        if cand and os.path.isfile(cand):
            return cand
        starts = [d for d in [doc.dir] + self.roots if d]
        for d in starts:
            cur = d
            for _ in range(5):                                    # the directory and a few parents
                for sub in ('', 'BIN'):
                    base = find_file_ci(cur, sub) if sub else cur
                    if base and os.path.isdir(base):
                        f = find_file_ci(base, 'turbo.tpl')
                        if f:
                            return f
                parent = os.path.dirname(cur)
                if parent == cur:
                    break
                cur = parent
        return None

    def search_dirs(self, doc: Doc, tpl: Optional[str]) -> List[str]:
        dirs = [d for d in [doc.dir] + self.roots if d]
        dirs += [str(x) for x in (self.options.get('paths') or [])]
        dirs += [x for x in os.environ.get('TP7_PATH', '').split(os.pathsep) if x]
        if tpl:
            bindir = os.path.dirname(os.path.abspath(tpl))
            dirs.append(bindir)
            units = find_file_ci(os.path.dirname(bindir), 'units')
            if units:
                dirs.append(units)
        seen, out = set(), []
        for d in dirs:
            k = os.path.normcase(os.path.abspath(d))
            if k not in seen and os.path.isdir(d):
                seen.add(k)
                out.append(d)
        return out

    def provider_for(self, doc: Doc) -> Provider:
        tpl = self.find_tpl(doc)
        base = self._providers.get(tpl)
        if base is None:
            base = Provider([], tpl)
            for n in list(base.std_names):                        # bind the standard units to the shared instance
                base.get(n)
            self._providers[tpl] = base
            if tpl is None and not self._warned_no_tpl:
                self._warned_no_tpl = True
                self.log('TURBO.TPL not found: standard identifiers keep their spelling '
                         '(set initializationOptions.tpl or TP7_TPL)', 2)
            elif tpl:
                self.log('using %s' % tpl)
        p = copy.copy(base)
        p.dirs = self.search_dirs(doc, tpl)
        p.cache = {k: v for k, v in base.cache.items() if k in base.std_names}   # sources are re-read on every request
        p._loading = set()
        p.overlay = {os.path.normcase(os.path.abspath(d.path)): d.text
                     for d in self.docs.values() if d.path and d.uri != doc.uri}
        return p

    # -- formatting -----------------------------------------------------------------------------------
    def on_textDocument_formatting(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            return (INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        try:
            new = format_source(doc.text, self.defines, normalize=True, provider=self.provider_for(doc))
        except FormatError as e:
            return (REQUEST_FAILED, str(e))
        except AssertionError as e:                               # the formatter's own safety net tripped
            self.log('formatter safety check failed: %s' % e, 1)
            return (REQUEST_FAILED, 'formatter safety check failed (the file was not changed): %s' % e)
        edits = compute_edits(doc.text, new)
        if apply_edits(doc.text, edits) != new:                   # never send edits we have not verified
            return (INTERNAL_ERROR, 'internal error: edit computation mismatch (the file was not changed)')
        return edits

    # -- diagnostics ----------------------------------------------------------------------------------
    def publish(self, doc: Doc):
        try:
            res = parse(doc.text, self.defines)
        except Exception as e:                                    # parse() should never raise; be safe anyway
            self.log('parse failed: %s' % e, 1)
            return
        lines = split_lines(doc.text)
        out = []
        for tok, msg in res.diags[:200]:
            li = max(tok.line - 1, 0)
            text = lines[li] if li < len(lines) else ''
            c0 = u16len(text[:max(tok.col - 1, 0)])
            width = u16len(tok.text.split('\n')[0].rstrip('\r')) or 1
            out.append({
                'range': {'start': {'line': li, 'character': c0}, 'end': {'line': li, 'character': c0 + width}},
                'severity': 2 if 'not supported' in msg else 1,
                'source': SERVER_NAME,
                'message': msg,
            })
        self.notify('textDocument/publishDiagnostics', {'uri': doc.uri, 'version': doc.version, 'diagnostics': out})


def main(argv) -> int:
    out = sys.stdout.buffer
    sys.stdout = sys.stderr                                       # stray prints must never corrupt the protocol stream
    return Server(sys.stdin.buffer, out).serve()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
