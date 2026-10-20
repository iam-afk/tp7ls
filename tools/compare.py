#!/usr/bin/env python3
"""Differential check of the Free Pascal port against the Python prototype (python/).

  python3 tools/compare.py lex FILE.PAS...    tokens:  python/tp7lex.py  vs  build/tp7lex --dump FILE
  python3 tools/compare.py fmt FILE.PAS...    output:  python/tp7fmt.py  vs  build/tp7fmt FILE   (byte-exact)

A directory argument stands for every *.pas / *.inc in it (recursively).  --bin DIR overrides the directory of
the port's binaries (default: build/).  Exit status 1 if any file differs.

Token dump format (the port must print exactly this, one token per line, cp866 bytes of the text):
  KIND LINE:COL TEXT
TEXT (the rest of the line) is the token text with every byte outside 0x20..0x7E and the backslash written as
\\xHH, upper-case hex (CRLF is \\x0D\\x0A).
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
    return ''.join('%s %d:%d %s\n' % (t.kind, t.line, t.col, esc(t.text)) for t in lex(src)).encode('ascii')


def fmt_out(path):
    p = subprocess.run([sys.executable, os.path.join(ROOT, 'python', 'tp7fmt.py'), path], capture_output=True)
    return p.stdout


def port(binary, *args):
    return subprocess.run([binary, *args], capture_output=True).stdout


def files(args):
    for a in args:
        if os.path.isdir(a):
            for d, _, names in os.walk(a):
                for n in sorted(names):
                    if n.lower().endswith(('.pas', '.inc')):
                        yield os.path.join(d, n)
        else:
            yield a


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
    if len(argv) < 3 or argv[1] not in ('lex', 'fmt'):
        print(__doc__)
        return 2
    mode = argv[1]
    binary = os.path.join(bindir, 'tp7' + mode)
    if not os.path.exists(binary):
        print('no %s: build the port first (make)' % binary)
        return 2
    bad = total = 0
    for path in files(argv[2:]):
        total += 1
        if mode == 'lex':
            ref, got = lex_dump(path), port(binary, '--dump', path)
        else:
            ref, got = fmt_out(path), port(binary, path)
        if ref != got:
            bad += 1
            line, x, y = first_diff(ref, got)
            print('DIFF %s line %d\n  python: %s\n  port:   %s' % (path, line, x.decode('cp866'), y.decode('cp866')))
    print('%d files, %d differ' % (total, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
