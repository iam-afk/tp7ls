"""Index of the project folder: which unit lives in which file, anywhere below the workspace roots.

Turbo Pascal finds units by file name in a flat search path, but a project is rarely flat: units sit in subfolders
(src/, lib/, tools/...).  The index walks the folders once and keeps
  * units:    lower-case name -> [paths of NAME.PAS and NAME.TPU], the nearest to a given file first
  * includes: lower-case file name (also NAME.INC etc.) -> [paths], for `{$I file}` that is not next to its user
  * sources:  every *.PAS, for workspace/symbol and for the files a rename or a search for references must look at
It re-reads only the folders whose modification time changed, so asking for it before every request is cheap.
"""
import os
import threading
from typing import Dict, List, Optional, Tuple

MAX_FILES = 5000                    # a folder tree larger than this is cut off (and says so in `truncated`)
UNIT_EXT = ('.pas', '.tpu')
INCLUDE_EXT = ('.inc', '.pas')
SKIP_DIRS = {'node_modules', '__pycache__'}


def _norm(p: str) -> str:
    return os.path.normcase(os.path.abspath(p))


class ProjectIndex:
    def __init__(self, roots=(), max_files: int = MAX_FILES, throttle: float = 1.0):
        self.roots: List[str] = [os.path.abspath(r) for r in roots]
        self.max_files = max_files
        self.throttle = throttle
        self.generation = 0                       # grows whenever the set of files changed: caches built on it are stale
        self.truncated = False
        self._dirs: Dict[str, Tuple[float, List[Tuple[str, str]]]] = {}    # dir -> (mtime_ns, [(file name, full path)])
        self._units: Dict[str, List[str]] = {}
        self._files: Dict[str, List[str]] = {}
        self._sources: List[str] = []
        self._checked = 0.0
        self._lock = threading.RLock()

    # -- keeping up with the disk -----------------------------------------------------------------------
    def invalidate(self):
        """Something may have changed on disk: look again at the next question."""
        self._checked = 0.0

    def refresh(self, force: bool = False):
        import time
        now = time.monotonic()
        with self._lock:
            if not force and self._checked and now - self._checked < self.throttle:
                return
            self._checked = now or 1e-9
            changed, seen, count = False, set(), 0
            stack = list(self.roots)
            self.truncated = False
            while stack:
                d = stack.pop()
                try:
                    mt = os.stat(d).st_mtime_ns
                except OSError:
                    continue
                key = _norm(d)
                if key in seen:
                    continue
                seen.add(key)
                old = self._dirs.get(key)
                if old is None or old[0] != mt:
                    try:
                        names = sorted(os.listdir(d))
                    except OSError:
                        names = []
                    entries = [(n, os.path.join(d, n)) for n in names]
                    self._dirs[key] = (mt, entries, d)
                    changed = True
                    old = self._dirs[key]
                for n, full in old[1]:
                    if n.startswith('.') or n in SKIP_DIRS:
                        continue
                    if os.path.isdir(full):
                        if not os.path.islink(full):                 # a link could lead back up: loops
                            stack.append(full)
                        continue
                    count += 1
                    if count > self.max_files:
                        self.truncated = True
                        stack = []
                        break
            gone = [k for k in self._dirs if k not in seen]
            if gone:
                for k in gone:
                    del self._dirs[k]
                changed = True
            if changed or not self._units and not self._files:
                self._rebuild(seen)
                self.generation += 1

    def _rebuild(self, live):
        units: Dict[str, List[str]] = {}
        files: Dict[str, List[str]] = {}
        sources: List[str] = []
        for key in sorted(live):
            ent = self._dirs.get(key)
            if ent is None:
                continue
            for n, full in ent[1]:
                if n.startswith('.'):
                    continue
                base, ext = os.path.splitext(n)
                ext = ext.lower()
                if ext in UNIT_EXT and os.path.isfile(full):
                    units.setdefault(base.lower(), []).append(full)
                if ext == '.pas' and os.path.isfile(full):
                    sources.append(full)
                if ext in INCLUDE_EXT or ext == '.inc':
                    files.setdefault(n.lower(), []).append(full)
        for v in units.values():                  # source before object code, as the provider does
            v.sort(key=lambda p: (os.path.splitext(p)[1].lower() != '.pas', p.lower()))
        self._units, self._files, self._sources = units, files, sources

    # -- questions ----------------------------------------------------------------------------------------
    @staticmethod
    def _distance(path: str, near: Optional[str]) -> int:
        """How many folder steps lie between a file and the file that wants it: 0 = same folder."""
        if not near:
            return 0
        a = _norm(os.path.dirname(path)).split(os.sep)
        b = _norm(os.path.dirname(os.path.abspath(near))).split(os.sep)
        i = 0
        while i < len(a) and i < len(b) and a[i] == b[i]:
            i += 1
        return (len(a) - i) + (len(b) - i)

    def _ranked(self, paths: List[str], near: Optional[str]) -> List[str]:
        return sorted(paths, key=lambda p: (self._distance(p, near), os.path.splitext(p)[1].lower() != '.pas', p.lower()))

    def find_unit(self, name: str, ext: str, near: Optional[str] = None) -> Optional[str]:
        return (self.find_unit_all(name, ext, near) or [None])[0]

    def find_unit_all(self, name: str, ext: str, near: Optional[str] = None) -> List[str]:
        self.refresh()
        return self._ranked([p for p in self._units.get(name.lower(), []) if p.lower().endswith(ext)], near)

    def find_file(self, rel: str, near: Optional[str] = None) -> Optional[str]:
        """A file of the tree by its name (for an include: `defs.inc`, or `sub/defs.inc` by its last part)."""
        self.refresh()
        base = rel.replace('\\', '/').split('/')[-1].lower()
        tail = rel.replace('\\', '/').lower()
        got = self._ranked(self._files.get(base, []), near)
        for p in got:
            if p.replace('\\', '/').lower().endswith(tail):
                return p
        return None

    def unit_names(self) -> List[str]:
        self.refresh()
        out = {}
        for k, paths in self._units.items():
            out[k] = os.path.splitext(os.path.basename(paths[0]))[0]
        return sorted(out.values(), key=str.lower)

    def sources(self) -> List[str]:
        self.refresh()
        return list(self._sources)

    def duplicates(self) -> Dict[str, List[str]]:
        """Units that exist more than once (same kind of file): a choice the compiler would make by its search path."""
        self.refresh()
        out = {}
        for k, paths in self._units.items():
            for ext in UNIT_EXT:
                same = [p for p in paths if p.lower().endswith(ext)]
                if len(same) > 1:
                    out.setdefault(k, []).extend(same)
        return out
