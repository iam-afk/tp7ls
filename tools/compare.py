#!/usr/bin/env python3
"""Differential check of the Free Pascal port against the Python prototype (python/).

  python3 tools/compare.py lex FILE.PAS...    tokens:  python/tp7lex.py  vs  build/tp7lex --dump FILE
  python3 tools/compare.py parse [-D SYM]... FILE.PAS...   tree, diagnostics, inactive tokens, {$I}, roundtrip
  python3 tools/compare.py fmt [-D SYM]... [--width N] FILE.PAS...   output (byte-exact), stderr and exit status
                                              of python/tp7fmt.py  vs  build/tp7fmt FILE  (--width: format_source(width=N)
                                              in-process vs  build/tp7fmt -w N; 0 = never wrap)

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


def fmt_out(path, defines, width):
    if width is not None:
        return fmt_width(path, defines, width)
    p = subprocess.run([sys.executable, os.path.join(ROOT, 'python', 'tp7fmt.py'), path,
                        *[a for d in defines for a in ('-D', d)]], capture_output=True)
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


def port_fmt(binary, path, defines, width):
    w = ['-w', str(width)] if width is not None else []
    return with_stderr(subprocess.run([binary, path, *w, *[a for d in defines for a in ('-D', d)]],
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
    lib = None
    if '--lib' in argv:
        i = argv.index('--lib')
        lib = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) < 3 or argv[1] not in ('lex', 'parse', 'fmt', 'tpu'):
        print(__doc__)
        return 2
    mode = argv[1]
    binary = os.path.join(bindir, 'tpudump' if mode == 'tpu' else 'tp7' + mode)
    if not os.path.exists(binary):
        print('no %s: build the port first (make)' % binary)
        return 2
    bad = total = 0
    for path in files(argv[2:], ('.tpu', '.tpl') if mode == 'tpu' else ('.pas', '.inc')):
        total += 1
        if mode == 'tpu':
            diffs = compare_tpu(binary, path, lib)
            if diffs:
                bad += 1
                print('DIFF %s\n  %s' % (path, '\n  '.join(diffs)))
            continue
        if mode == 'lex':
            ref, got = lex_dump(path), port(binary, '--dump', path)
        elif mode == 'parse':
            ref = parse_dump(path, defines)
            got = port(binary, '--dump', *[a for d in defines for a in ('-D', d)], path)
        else:
            ref, got = fmt_out(path, defines, width), port_fmt(binary, path, defines, width)
        if ref != got:
            bad += 1
            line, x, y = first_diff(ref, got)
            print('DIFF %s line %d\n  python: %s\n  port:   %s' % (path, line, x.decode('cp866'), y.decode('cp866')))
    print('%d files, %d differ' % (total, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
