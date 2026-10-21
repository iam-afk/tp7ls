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
    normalize = '--normalize' in argv
    if normalize:
        argv.remove('--normalize')
    if len(argv) < 3 or argv[1] not in ('lex', 'parse', 'fmt', 'tpu', 'sema', 'types', 'stub'):
        print(__doc__)
        return 2
    mode = argv[1]
    binary = os.path.join(bindir, 'tpudump' if mode == 'tpu' else 'tp7' + mode)
    if not os.path.exists(binary):
        print('no %s: build the port first (make)' % binary)
        return 2
    bad = total = 0
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
