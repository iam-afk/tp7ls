#!/usr/bin/env python3
"""Differential check of the Free Pascal port against the Python prototype (python/).

  python3 tools/compare.py lex FILE.PAS...    tokens:  python/tp7lex.py  vs  build/tp7lex --dump FILE
  python3 tools/compare.py parse [-D SYM]... FILE.PAS...   tree, diagnostics, inactive tokens, {$I}, roundtrip
  python3 tools/compare.py fmt [-D SYM]... [--width N] [--normalize [--path DIR]... [--tpl TPL]] FILE.PAS...   output (byte-exact), stderr and exit status
                                              of python/tp7fmt.py  vs  build/tp7fmt FILE  (--width: format_source(width=N)
                                              in-process vs  build/tp7fmt -w N; 0 = never wrap)

  python3 tools/compare.py sema [--path DIR]... [--tpl TURBO.TPL] FILE.PAS...   tp7sema: what every name refers to,
                                              declarations, unresolved / uncertain names, missing units, duplicates,
                                              the normalized text (build/tp7sema --dump)
  python3 tools/compare.py types [--path DIR]... [--tpl TURBO.TPL] FILE.PAS...   tp7types: type errors, inlay hints,
                                              types of the names, types of the expressions at operators / brackets
  python3 tools/compare.py stub [--lib TURBO.TPL] FILE.TPU...   tp7stub: the text of every unit's stub and its index
                                              (ENTRY kind|owner|name line col len, col / len in UTF-8 bytes, the
                                              declaration and the length of the block of each entry; build/tp7stub --dump)
  python3 tools/compare.py tpu [--lib TURBO.TPL] FILE.TPU...   tpu_dump.py vs build/tpudump: --json (parsed and
                                              compared as data), --pas and --names (byte-exact)

  python3 tools/compare.py lsp [--tp7 DIR] [--step N] [--rename N] FILE.PAS...   the server: the same LSP session
                                              (python/tp7lsp.py vs build/tp7ls, workspace = the folder of the file, tp7Dir =
                                              DIR) compared reply by reply as data: diagnostics, outline, semantic tokens,
                                              formatting, code actions, inlay hints, workspace symbols; at every N-th token
                                              (default 1) hover, definition, declaration, typeDefinition, implementation,
                                              highlight, references, prepareRename, prepareTypeHierarchy, selectionRange,
                                              completion and signatureHelp; rename of the first N names (default 3).
                                              Internal errors (-32603) are equal whatever their text: the exception
                                              classes of the two languages differ

A directory argument stands for every *.pas / *.inc in it (recursively; *.tpu / *.tpl for `tpu`).  --bin DIR overrides the directory of
the port's binaries (default: build/).  Exit status 1 if any file differs.

Token dump format (the port must print exactly this, one token per line, cp866 bytes of the text):
  KIND LINE:COL TEXT
TEXT (the rest of the line) is the token text with every byte outside 0x20..0x7E and the backslash written as
\\xHH, upper-case hex (CRLF is \\x0D\\x0A).

Parse dump: the tree, a node per line (its kind, indented by two spaces per level), its tokens as in the token dump
one level deeper; then  DIAG LINE:COL MESSAGE,  INACTIVE LINE:COL  for every inactive token,
INCLUDE LINE:COL NAME,  and  ROUNDTRIP OK | BROKEN.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'python'))


def esc(text):
    return ''.join(chr(b) if 0x20 <= b <= 0x7E and b != 0x5C else '\\x%02X' % b for b in text.encode('cp866'))


def lex_dump(path):
    from tp7lex import lex
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    return ''.join(tok_line(t) + '\n' for t in lex(src)).encode('ascii')


def tok_line(t):
    return '%s %d:%d %s' % (t.kind, t.line, t.col, esc(t.text))


def parse_dump(path, defines):
    from tp7parse import DEFAULT_DEFINES, Node, parse, reconstruct
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    r = parse(src, list(DEFAULT_DEFINES) + defines)
    out = []

    def node(n, depth):
        out.append('  ' * depth + n.kind)
        for k in n.kids:
            if isinstance(k, Node):
                node(k, depth + 1)
            else:
                out.append('  ' * (depth + 1) + tok_line(k))
    node(r.tree, 0)
    out += ['DIAG %d:%d %s' % (t.line, t.col, esc(m)) for t, m in r.diags]
    out += ['INACTIVE %d:%d' % (t.line, t.col) for t in r.tokens if not t.active]
    out += ['INCLUDE %d:%d %s' % (x[0].line, x[0].col, esc(x[1])) for x in r.includes]
    out.append('ROUNDTRIP ' + ('OK' if reconstruct(r) == src else 'BROKEN'))
    return ''.join(s + '\n' for s in out).encode('ascii')


def sema_dump(path, dirs, tpl):
    from tp7lex import Token
    from tp7parse import parse, reconstruct, ROUTINE_DIRECTIVES
    from tp7sema import Binder, Provider
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    prov = Provider(dirs or [os.path.dirname(os.path.abspath(path))], tpl)
    res = parse(src, include=prov.include_resolver(path), path=path)
    for t in res.sig:
        if t.kind == 'KW':
            t.text = t.text.lower()
    for n in res.tree.walk():
        if n.kind == 'Directives':
            for t in n.kids:
                if isinstance(t, Token) and t.kind == 'IDENT' and t.text.lower() in ROUTINE_DIRECTIVES:
                    t.text = t.text.lower()
        elif n.kind in ('Absolute', 'Section') and n.kids and isinstance(n.kids[0], Token):
            n.kids[0].text = n.kids[0].text.lower()
    b = Binder(res, prov)
    b.run()

    def pos(t):
        return '%s L%d' % (os.path.basename(t.file), t.line) if t.file else '%d:%d' % (t.line, t.col)

    def where(s):
        if s.tok is not None:
            w = 'L%d' % s.tok.line
            if s.file and os.path.abspath(s.file) != os.path.abspath(path):
                w += ' ' + os.path.basename(s.file)
        elif s.kind == 'unit':
            w = 'unit:' + (os.path.basename(s.file) if s.file else 'lib')
        elif s.lib:
            w = '@' + (s.home or '?')
        elif s.implicit:
            w = 'self'
        else:
            w = '-'
        return '%s %s %s' % (s.kind, esc(s.name), w)
    out = []
    for t in res.sig:
        s = b.refs.get(id(t))
        if s is not None:
            out.append('REF %s %s -> %s' % (pos(t), esc(t.text), where(s)))
    for t in res.sig:
        s = b.decls.get(id(t))
        if s is not None:
            out.append('DECL %s %s -> %s' % (pos(t), esc(t.text), where(s)))
    out += ['UNRESOLVED %s %s' % (pos(t), esc(t.text)) for t in b.unresolved]
    out += ['UNCERTAIN %s %s' % (pos(t), esc(t.text)) for t in b.uncertain]
    out += ['MISSING %s %s' % (pos(t), esc(t.text)) for t in b.missing_units]
    out += ['DUP %s %s -> %s' % (pos(t), esc(t.text), where(o)) for t, o in b.dups]
    out.append('RENAMED %d' % b.renamed)
    out.append('ERRORS %d' % len(prov.errors))
    out.append('TEXT ' + esc(reconstruct(res)))
    return ''.join(x + '\n' for x in out).encode('ascii')


def types_dump(path, dirs, tpl):
    from tp7parse import parse
    from tp7sema import Binder, Provider
    from tp7types import Types, check_types, inlay_data, expr_at, type_text, const_type_name, FLOAT
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    prov = Provider([os.path.dirname(path)] + list(dirs), tpl)
    res = parse(src, include=prov.include_resolver(path), path=path)
    out = []

    def pos(t):
        return '%s L%d' % (os.path.basename(t.file), t.line) if t.file else '%d:%d' % (t.line, t.col)
    b = Binder(res, prov)
    try:
        b.run()
    except BROKEN:
        return b'BIND EXCEPTION\n'
    try:
        check_types(res, b, prov, lambda t, m: out.append('PROBLEM %s %s' % (pos(t), esc(m))))
    except BROKEN:
        out.append('EXCEPTION')
    try:
        d = inlay_data(res, b, prov)
        out += ['PARAM %s %s' % (pos(t), esc(x)) for t, x in d['params']]
        out += ['CONST %s %s' % (pos(t), esc(x)) for t, x in d['consts']]
        out += ['END %s %s %d' % (pos(t), esc(n), k) for t, n, k in d['ends']]
    except BROKEN:
        out.append('INLAY EXCEPTION')
    types = Types(prov)
    for t in res.sig:
        sym = b.refs.get(id(t))
        if sym is None:
            continue
        try:
            text = type_text(types.of_type_sym(sym) if sym.kind == 'type' else types.of_sym(sym))
        except BROKEN:
            text = '<exception>'
        out.append('TYPE %s %s: %s' % (pos(t), esc(t.text), esc(text)))
    for t in res.doc_sig:
        if t.kind not in ('SYM', 'KW'):
            continue
        try:
            got = expr_at(res.tree, lambda x: b.refs.get(id(x)), prov, t)
        except BROKEN:
            out.append('EXPR %s <exception>' % pos(t))
            continue
        if got is None:
            continue
        node, ty = got
        toks = list(node.tokens())
        text = type_text(ty)
        if ty.kind == 'int' and ty.value is not None:
            text = '%s = %d' % (const_type_name(ty), ty.value)
        out.append('EXPR %s %s %s-%s: %s%s' % (pos(t), esc(t.text), pos(toks[0]), pos(toks[-1]), esc(text),
                                              ' float' if ty is FLOAT else ''))
    return ''.join(x + '\n' for x in out).encode('ascii')


BROKEN = (IndexError, StopIteration, AttributeError, ValueError, TypeError)


def fmt_out(path, defines, width, norm=()):
    if width is not None:
        return fmt_width(path, defines, width)
    p = subprocess.run([sys.executable, os.path.join(ROOT, 'python', 'tp7fmt.py'), path,
                        *[a for d in defines for a in ('-D', d)], *norm], capture_output=True)
    return with_stderr(p)


def fmt_width(path, defines, width):
    from tp7fmt import FormatError, format_source
    from tp7parse import DEFAULT_DEFINES
    with open(path, 'rb') as f:
        src = f.read().decode('cp866')
    warnings = []
    try:
        out, err, code = format_source(src, list(DEFAULT_DEFINES) + defines, width=width, warnings=warnings), b'', 0
    except FormatError as e:
        out, err, code = '', ('error: %s\n' % e).encode(), 2
    err = b''.join(('warning: %s\n' % w).encode() for w in warnings) + err
    return out.encode('cp866') + b'\n--- stderr, exit %d\n' % code + err


def with_stderr(p):
    return p.stdout + b'\n--- stderr, exit %d\n' % p.returncode + p.stderr


def port(binary, *args):
    return subprocess.run([binary, *args], capture_output=True).stdout


def port_fmt(binary, path, defines, width, norm=()):
    w = ['-w', str(width)] if width is not None else []
    return with_stderr(subprocess.run([binary, path, *w, *[a for d in defines for a in ('-D', d)], *norm],
                                      capture_output=True))


def files(args, exts=('.pas', '.inc')):
    for a in args:
        if os.path.isdir(a):
            for d, _, names in os.walk(a):
                for n in sorted(names):
                    if n.lower().endswith(exts):
                        yield os.path.join(d, n)
        else:
            yield a


def first_data_diff(a, b, path='$'):
    if type(a) != type(b):
        return '%s: %r vs %r' % (path, a, b)
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return '%s.%s: missing in %s' % (path, k, 'python' if k not in a else 'port')
            d = first_data_diff(a[k], b[k], '%s.%s' % (path, k))
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return '%s: %d vs %d items' % (path, len(a), len(b))
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_data_diff(x, y, '%s[%d]' % (path, i))
            if d:
                return d
        return None
    return None if a == b else '%s: %r vs %r' % (path, a, b)


def compare_tpu(binary, path, lib):
    import json
    extra = ['--lib', lib] if lib else []
    out = []
    for mode in ('--json', '--pas', '--names'):
        p = subprocess.run([sys.executable, os.path.join(ROOT, 'python', 'tpu_dump.py'), path, *extra, mode],
                           capture_output=True)
        q = subprocess.run([binary, path, *extra, mode], capture_output=True)
        if p.returncode != q.returncode:
            out.append('%s: exit %d vs %d (%s)' % (mode, p.returncode, q.returncode, p.stderr.decode()[-300:]))
        elif p.returncode != 0 and p.stdout == q.stdout == b'':
            continue
        elif mode == '--json':
            try:
                d = first_data_diff(json.loads(p.stdout), json.loads(q.stdout))
            except ValueError as e:
                d = 'not JSON (%s): python %r..., port %r...' % (e, p.stdout[:60], q.stdout[:60])
            if d:
                out.append('--json ' + d)
        elif p.stdout != q.stdout:
            line, x, y = first_diff(p.stdout, q.stdout)
            out.append('%s line %d\n    python: %s\n    port:   %s' % (mode, line, x.decode(), y.decode()))
    return out


def stub_dump(path, lib):
    from tpu_dump import Loader, split_images
    from tp7sema import Provider
    from tp7stub import render
    if lib is None:
        cand = os.path.join(os.path.dirname(os.path.abspath(path)), 'TURBO.TPL')
        lib = cand if os.path.exists(cand) and os.path.abspath(cand) != os.path.abspath(path) else None
    imgs = split_images(open(path, 'rb').read())
    n = len(imgs)
    if lib:
        imgs += split_images(open(lib, 'rb').read())
    prov = Provider(dirs=[os.path.dirname(os.path.abspath(path))])
    prov.lib_images = split_images(open(lib, 'rb').read()) if lib else []
    imgs += prov._tpu_dependencies(imgs, os.path.dirname(os.path.abspath(path)))
    ld = Loader(imgs, primary=n)
    out = []
    for k in ld.primary:
        st = render(ld.units[k], os.path.abspath(path))
        out.append(st.text)
        for key, (ln, col, length) in st.index.items():
            kind, owner, name = key[0], key[1] if len(key) == 3 else '', key[-1] if len(key) > 1 else ''
            text = st.lines[ln]
            col, length = len(text[:col].encode()), len((name or text[col:col + length]).encode())
            out.append('ENTRY %s|%s|%s %d %d %d\n' % (kind, owner, name, ln, col, length))
            k2 = 'routine' if kind == 'method' else kind
            out.append('DECL %s\n' % st.declaration(k2, name, owner or None))
            out.append('BLOCK %d\n' % len(st.block(k2, name, owner or None)))
    return ''.join(out).encode('utf-8')


def lsp_messages(path, tp7, step, renames):
    from tp7lex import lex
    with open(path, 'rb') as f:
        text = f.read().decode('cp866')
    root = os.path.dirname(os.path.abspath(path))
    import pathlib
    uri = pathlib.Path(os.path.abspath(path)).as_uri()
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')

    def u16(s):
        return len(s.encode('utf-16-le', 'surrogatepass')) // 2

    def at(tok, end=False):
        ln = tok.line - 1
        line = lines[ln] if ln < len(lines) else ''
        ch = u16(line[:tok.col - 1]) + (u16(tok.text) if end else 0)
        return {'line': ln, 'character': ch}
    td = {'uri': uri}
    msgs = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
        'processId': None, 'rootUri': pathlib.Path(root).as_uri(),
        'workspaceFolders': [{'uri': pathlib.Path(root).as_uri(), 'name': 'ws'}],
        'capabilities': {'textDocument': {'documentSymbol': {'hierarchicalDocumentSymbolSupport': True}}},
        'initializationOptions': {'tp7Dir': tp7} if tp7 else {}}},
            {'jsonrpc': '2.0', 'method': 'initialized', 'params': {}},
            {'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {'textDocument': {
                'uri': uri, 'languageId': 'pascal', 'version': 1, 'text': text}}}]
    n = len(lines)
    whole = {'start': {'line': 0, 'character': 0}, 'end': {'line': n, 'character': 0}}
    reqs = [('textDocument/documentSymbol', {'textDocument': td}),
            ('textDocument/semanticTokens/full', {'textDocument': td}),
            ('textDocument/semanticTokens/range', {'textDocument': td, 'range': {
                'start': {'line': 0, 'character': 0}, 'end': {'line': min(n, 30), 'character': 0}}}),
            ('textDocument/formatting', {'textDocument': td, 'options': {'tabSize': 2, 'insertSpaces': True}}),
            ('textDocument/rangeFormatting', {'textDocument': td, 'range': {
                'start': {'line': 3, 'character': 0}, 'end': {'line': 12, 'character': 0}}, 'options': {}}),
            ('textDocument/codeAction', {'textDocument': td, 'range': whole, 'context': {'diagnostics': []}}),
            ('textDocument/inlayHint', {'textDocument': td, 'range': whole}),
            ('workspace/symbol', {'query': ''})]
    sig = [t for t in lex(text) if t.kind in ('IDENT', 'SYM', 'KW', 'INT')]
    idents = [t for t in sig if t.kind == 'IDENT']
    for q in sorted({t.text.lower()[:3] for t in idents[:40]}):
        reqs.append(('workspace/symbol', {'query': q}))
    poss = []
    for i, t in enumerate(sig):
        if i % step:
            continue
        p0 = at(t)
        reqs.append(('textDocument/hover', {'textDocument': td, 'position': p0}))
        poss.append(p0)
        if t.kind in ('IDENT', 'INT'):
            for m in ('definition', 'declaration', 'typeDefinition', 'implementation', 'documentHighlight',
                      'prepareRename', 'prepareTypeHierarchy'):
                reqs.append(('textDocument/' + m, {'textDocument': td, 'position': p0}))
            reqs.append(('textDocument/references', {'textDocument': td, 'position': p0,
                                                     'context': {'includeDeclaration': i % 2 == 0}}))
        if t.kind == 'IDENT' or t.text in ('.', '(', ',', ':', '=', '^'):
            pe = at(t, end=True)
            reqs.append(('textDocument/completion', {'textDocument': td, 'position': pe}))
            reqs.append(('textDocument/signatureHelp', {'textDocument': td, 'position': pe}))
    reqs.append(('textDocument/selectionRange', {'textDocument': td, 'positions': poss[:200]}))
    seen = set()
    for t in idents:
        if len(seen) >= renames:
            break
        if t.text.lower() in seen:
            continue
        seen.add(t.text.lower())
        reqs.append(('textDocument/rename', {'textDocument': td, 'position': at(t), 'newName': t.text + 'Zq'}))
    for k, (m, prm) in enumerate(reqs):
        msgs.append({'jsonrpc': '2.0', 'id': 100 + k, 'method': m, 'params': prm})
    msgs += [{'jsonrpc': '2.0', 'id': 99, 'method': 'shutdown'}, {'jsonrpc': '2.0', 'method': 'exit'}]
    return msgs


def lsp_run(cmd, msgs, stubs):
    import json
    body = b''.join(b'Content-Length: %d\r\n\r\n%s' % (len(b), b) for b in (json.dumps(m).encode() for m in msgs))
    env = dict(os.environ)
    env.pop('TP7_DIR', None)
    env['TP7LS_STUB_DIR'] = stubs
    p = subprocess.run(cmd, input=body, capture_output=True, env=env, timeout=3600)
    out, data, i = [], p.stdout, 0
    while i < len(data):
        j = data.index(b'\r\n\r\n', i)
        n = int(data[i:j].split(b':')[1])
        out.append(json.loads(data[j + 4:j + 4 + n]))
        i = j + 4 + n
    return out


def compare_lsp(binary, path, tp7, step, renames, stubs):
    msgs = lsp_messages(path, tp7, step, renames)
    a = lsp_run([sys.executable, os.path.join(ROOT, 'python', 'tp7lsp.py')], msgs, stubs)
    b = lsp_run([binary], msgs, stubs)
    by_id = {m['id']: m for m in msgs if 'id' in m}
    out = []
    ra = {m['id']: m for m in a if 'id' in m and 'method' not in m}
    rb = {m['id']: m for m in b if 'id' in m and 'method' not in m}
    for i in sorted(set(ra) | set(rb), key=str):
        x, y = ra.get(i), rb.get(i)
        if x != y and not (internal_error(x) and internal_error(y)):
            req = by_id.get(i, {})
            out.append('%s %s\n    python: %s\n    port:   %s' % (req.get('method'), json_short((req.get('params') or {}).get(
                'position')), json_short(x), json_short(y)))
    na = [m for m in a if 'method' in m]
    nb = [m for m in b if 'method' in m]
    if na != nb:
        out.append('notifications\n    python: %s\n    port:   %s' % (json_short(na), json_short(nb)))
    return out, len(ra)


def internal_error(reply):
    return isinstance(reply, dict) and (reply.get('error') or {}).get('code') == -32603


def json_short(x, limit=600):
    import json
    s = json.dumps(x, ensure_ascii=False)
    return s if len(s) <= limit else s[:limit] + '...'


def first_diff(a, b):
    la, lb = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return i + 1, x, y
    n = min(len(la), len(lb))
    return n + 1, la[n] if n < len(la) else b'<end>', lb[n] if n < len(lb) else b'<end>'


def main(argv):
    bindir = os.path.join(ROOT, 'build')
    if '--bin' in argv:
        i = argv.index('--bin')
        bindir = argv[i + 1]
        del argv[i:i + 2]
    width = None
    if '--width' in argv:
        i = argv.index('--width')
        width = int(argv[i + 1])
        del argv[i:i + 2]
    defines = []
    while '-D' in argv:
        i = argv.index('-D')
        defines.append(argv[i + 1])
        del argv[i:i + 2]
    dirs, tpl = [], None
    while '--path' in argv:
        i = argv.index('--path')
        dirs.append(argv[i + 1])
        del argv[i:i + 2]
    if '--tpl' in argv:
        i = argv.index('--tpl')
        tpl = argv[i + 1]
        del argv[i:i + 2]
    lib = None
    if '--lib' in argv:
        i = argv.index('--lib')
        lib = argv[i + 1]
        del argv[i:i + 2]
    tp7, step, renames = None, 1, 3
    if '--tp7' in argv:
        i = argv.index('--tp7')
        tp7 = os.path.abspath(argv[i + 1])
        del argv[i:i + 2]
    if '--step' in argv:
        i = argv.index('--step')
        step = int(argv[i + 1])
        del argv[i:i + 2]
    if '--rename' in argv:
        i = argv.index('--rename')
        renames = int(argv[i + 1])
        del argv[i:i + 2]
    normalize = '--normalize' in argv
    if normalize:
        argv.remove('--normalize')
    if len(argv) < 3 or argv[1] not in ('lex', 'parse', 'fmt', 'tpu', 'sema', 'types', 'stub', 'lsp'):
        print(__doc__)
        return 2
    mode = argv[1]
    binary = os.path.join(bindir, {'tpu': 'tpudump', 'lsp': 'tp7ls'}.get(mode, 'tp7' + mode))
    if not os.path.exists(binary):
        print('no %s: build the port first (make)' % binary)
        return 2
    bad = total = 0
    if mode == 'lsp':
        import tempfile
        import shutil
        stubs = tempfile.mkdtemp(prefix='tp7stubs_')
        try:
            for path in files(argv[2:]):
                total += 1
                diffs, n = compare_lsp(binary, path, tp7, step, renames, stubs)
                if diffs:
                    bad += 1
                    print('DIFF %s (%d of %d replies)\n  %s' % (path, len(diffs), n, '\n  '.join(diffs[:10])))
        finally:
            shutil.rmtree(stubs, ignore_errors=True)
        print('%d files, %d differ' % (total, bad))
        return 1 if bad else 0
    for path in files(argv[2:], ('.tpu', '.tpl') if mode in ('tpu', 'stub') else ('.pas', '.inc')):
        total += 1
        if mode == 'stub':
            try:
                ref = stub_dump(path, lib)
            except Exception as e:
                ref = b''
            q = subprocess.run([binary, path, *(['--lib', lib] if lib else []), '--dump'], capture_output=True)
            got = q.stdout
            if ref != got:
                bad += 1
                line, x, y = first_diff(ref, got)
                print('DIFF %s line %d\n    python: %s\n    port:   %s' % (path, line, x.decode('utf-8', 'replace'),
                                                                    y.decode('utf-8', 'replace')))
            continue
        if mode == 'tpu':
            diffs = compare_tpu(binary, path, lib)
            if diffs:
                bad += 1
                print('DIFF %s\n  %s' % (path, '\n  '.join(diffs)))
            continue
        if mode == 'lex':
            ref, got = lex_dump(path), port(binary, '--dump', path)
        elif mode == 'sema':
            try:
                ref = sema_dump(path, dirs, tpl)
            except Exception as e:
                ref = b'EXCEPTION\n'
            q = subprocess.run([binary, '--dump', *[a for d in dirs for a in ('--path', d)],
                                *(['--tpl', tpl] if tpl else []), path], capture_output=True)
            got = q.stdout if q.returncode == 0 else b'EXCEPTION\n'
        elif mode == 'types':
            try:
                ref = types_dump(path, dirs, tpl)
            except Exception as e:
                ref = b'CRASH\n'
            q = subprocess.run([binary, '--dump', *[a for d in dirs for a in ('--path', d)],
                                *(['--tpl', tpl] if tpl else []), path], capture_output=True)
            got = q.stdout if q.returncode == 0 else b'CRASH\n'
        elif mode == 'parse':
            ref = parse_dump(path, defines)
            got = port(binary, '--dump', *[a for d in defines for a in ('-D', d)], path)
        else:
            norm = []
            if normalize:
                norm = ['--normalize', *[a for d in dirs for a in ('--path', d)], *(['--tpl', tpl] if tpl else [])]
            ref, got = fmt_out(path, defines, width, norm), port_fmt(binary, path, defines, width, norm)
        if ref != got:
            bad += 1
            line, x, y = first_diff(ref, got)
            print('DIFF %s line %d\n  python: %s\n  port:   %s' % (path, line, x.decode('cp866'), y.decode('cp866')))
    print('%d files, %d differ' % (total, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
