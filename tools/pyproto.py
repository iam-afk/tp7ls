#!/usr/bin/env python3
"""The protocol test suites of the prototype (python/test_*.py, the classes that drive the server over stdio) run
against the port: every `python3 python/tp7lsp.py` the suites would start is replaced by build/tp7ls.

  python3 tools/pyproto.py DATA_DIR [-k PATTERN] [--bin DIR] [MODULE...]

DATA_DIR is the folder with TURBO.TPL, GRAPH.TPU, ... (testdata).  MODULE: test_tp7lsp, test_tp7diag, ... (default: all
of them).  Exit status 1 if a test fails."""
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = ['test_tp7lsp', 'test_tp7diag', 'test_tp7edit', 'test_tp7oop', 'test_tp7stub', 'test_tp7tpuobj',
           'test_tp7inc', 'test_tp7index', 'test_tp7types', 'test_tp7perf']


def main(argv):
    args = argv[1:]
    bindir = os.path.join(ROOT, 'build')
    if '--bin' in args:
        i = args.index('--bin')
        bindir = args[i + 1]
        del args[i:i + 2]
    pattern = None
    if '-k' in args:
        i = args.index('-k')
        pattern = args[i + 1]
        del args[i:i + 2]
    if not args or not os.path.isdir(args[0]):
        print(__doc__)
        return 2
    data, mods = os.path.abspath(args[0]), args[1:] or MODULES
    port = os.path.join(bindir, 'tp7ls')
    sys.path.insert(0, os.path.join(ROOT, 'python'))
    sys.argv = [sys.argv[0], data]
    import test_tp7lsp
    real = subprocess.Popen

    def popen(cmd, *a, **k):
        if isinstance(cmd, (list, tuple)) and list(cmd) == [sys.executable, test_tp7lsp.SERVER]:
            cmd = [port]
        return real(cmd, *a, **k)
    subprocess.Popen = popen
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    if pattern:
        loader.testNamePatterns = ['*%s*' % pattern]
    for name in mods:
        mod = __import__(name)
        for obj in vars(mod).values():
            if isinstance(obj, type) and issubclass(obj, test_tp7lsp.Base) and obj is not test_tp7lsp.Base \
                    and obj.__module__ == name:
                suite.addTests(loader.loadTestsFromTestCase(obj))
    r = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if r.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
