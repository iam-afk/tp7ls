#!/usr/bin/env python3
"""
tp7lsp.py - Language Server (LSP 3.17) for Turbo Pascal 7, prototype.  JSON-RPC over stdio.

Features
  * textDocument/formatting     whole-file formatter with fixed style + identifier-case normalisation
                                (tp7fmt + tp7sema); answers with ONE minimal TextEdit (common leading/trailing
                                lines are kept, so cursor and marks do not jump); [] when nothing changes
  * publishDiagnostics          syntax problems from the tolerant parser, and lines over 126 characters, which Turbo
                                Pascal 7 refuses (Error 11); on open / change.  The formatter wraps long code lines
  * unsaved buffers             other open units are read from their editor buffers, not from the disk
  * textDocument/declaration    where a name is declared: a routine's header in `interface` (or `forward`), a
                                variable / constant / type / field / parameter / label at its declaring identifier
  * textDocument/definition     where it is implemented: a routine's body header in `implementation` (this file or
                                another unit that exists as source, unsaved buffers included); everything else has no
                                separate implementation, so it is the same place as the declaration.  Names that come
                                from TPU files and the standard library (System, Crt, Dos...) have no source, so
                                they lead to a generated stub: an interface-only unit with every constant, type
                                (records with fields), variable and routine (see tp7stub.py; the files are written
                                to initializationOptions.stubDir, env TP7LS_STUB_DIR, or the user's cache directory
                                ~/.cache/tp7ls/stubs, read only).  Names of parameters are not stored in a TPU: P1, P2...
  * textDocument/hover               what a name is: routine signature, `var X: T`, constants with their value, types
                                (records with their fields), enumeration constants, units; where it is declared if that
                                is another file.  Names from System / TPU files: the declaration as written in their stub.
                                On an operator, a parenthesis, a bracket or `^`: the type of the expression it makes
                                (`a + b`, `(...)`, `A[i]`, `P^`, `F(x)`), with the value of a constant integer one;
                                nothing when the type is not known
  * textDocument/typeDefinition      from a variable / parameter / field / typed constant / function to the declaration of
                                its type (through ^, array of, packed, set of, file of); from an enumeration constant to
                                its enumeration type; a type name goes to its own declaration
  * textDocument/documentHighlight   every occurrence of the name under the cursor in this file (writes marked as such)
  * textDocument/references          every use of a symbol: this file, and - when the symbol is visible outside the file
                                (interface part of a unit, names from another unit, names from System/Crt/...) - every
                                .pas file of the workspace; unsaved buffers included
  * textDocument/prepareRename, rename   all occurrences, in all files; refused for names from TPU / the standard
                                library, units and bad identifiers; the edit is checked by binding the edited sources
                                again: if any identifier would change its meaning (capture, shadowing) it is refused
  * textDocument/documentSymbol outline: unit / program -> interface, implementation -> constants, types (records with
                                their fields, enumerations with their members), variables, routines (with their
                                nested routines).  Hierarchical DocumentSymbol[] when the client announces support for
                                it, otherwise a flat SymbolInformation[] with containerName.
  * textDocument/semanticTokens full + range: identifiers coloured by what they ARE (variable, parameter, property =
                                record field, function, type, enumMember, namespace = unit, label); const and enum
                                members get `readonly`, declaration sites `declaration`, names from TPU files and the
                                standard library `defaultLibrary`; reserved words and routine directives (far,
                                forward, external...) are `keyword`, compiler directives are `macro`; text of inactive {$IFDEF}
                                branches is reported as `comment`.  Unresolved names get no token.
Diagnostics     syntax errors (the parser's), lines over 126 characters, and - when the text has no syntax errors -
                unknown units in `uses` (error) and identifiers declared nowhere (error).  Names are NOT checked when
                the server cannot see everything the compiler sees: a unit that is missing or could not be read, or an
                `{$I file}` that cannot be found (error at the directive; then only that is reported); inactive {$IFDEF}
                branches are not checked either.  `{$I file}` files that exist are read and spliced in (next to the
                including file, then in the search path; no extension = .PAS; open buffers win): their names are known,
                definition / hover / references lead into them, problems inside them are shown at the directive, and
                changes of the include file re-diagnose the documents that include it.  Rename is refused when it would
                have to edit an include file.  The formatter keeps `{$I}` as an opaque directive.
                Generated stubs get none.  Unused variables/constants/types and unused `uses` units are hints (greyed out). Numeric labels work like named ones. Completion offers the fields of `with` records and only types where a type is expected. A change of a unit re-diagnoses the open documents that use it (also on save and on file watcher events). Switched-off {$IFDEF} branches are greyed out. Responsiveness: a thread reads the client's messages, diagnostics wait until the typing pauses (0.15 s, at most 1 s) and are made once for the newest text, requests about text that already changed (semantic tokens, highlight, code actions) and cancelled requests are refused, one parse and binding per version of the text is shared by all features, and the units loaded from disk are kept while their files stay unchanged. Selection ranges, range formatting, workspace symbols and code actions (remove unused declarations and units, organize imports, spelling fixes, add a missing implementation) work. Completion (names in scope, members after a dot, units in `uses`, keywords) and signature help (signatureHelp) work for source, TPU, System and method calls. Duplicate identifiers (error) and routines or methods without an implementation (error for methods, warning for routines) are reported. Type errors (tp7types.py, errors; off with initializationOptions.typeDiagnostics = false): assignments and constants out of range, non-Boolean conditions, non-ordinal for/case, operators, comparisons, argument counts and types of calls, non-variables for var parameters. Only certain mistakes are reported; whatever is not understood stays silent. Inlay hints (textDocument/inlayHint; initializationOptions.inlayHints {parameters, constants, endLabels}): argument names in calls, types of constants declared without one, the routine name after the `end` of a long routine. The folders of the project are indexed (tp7index.py): units and {$I} files are found in any subfolder.
Objects         `object` types (ancestors, fields, constructors / destructors / methods, `virtual`, `private` / `public`),
                methods of a `record`, `T.M` implementations, `Self`, `inherited` and `New(P, Init(..))` take part in all of
                the above: a method's declaration is in the type, its definition is the `T.M` header; fields and methods of
                the ancestors are found; the outline shows the members (class / struct -> field, method, constructor);
                methods are semantic tokens of type `method`; rename of a member checks the type and its ancestors and, for a
                virtual method, follows the whole chain of overrides.
  * textDocument/implementation   a virtual method: its own body and the bodies of every override in the descendants
                                (other files of the workspace included, open or not); another method: its body; an
                                object type: the types that descend from it
  * textDocument/prepareTypeHierarchy, typeHierarchy/supertypes, typeHierarchy/subtypes   the object inheritance tree,
                                from a type name, a variable / parameter / field of an object type, a method or `Self`
Not (yet) supported: range formatting, incremental sync (full sync is advertised), completion,
                     semanticTokens/full/delta, objects that come from a TPU (only their name is known).

Text encoding
  The editor owns the file encoding.  Configure it to decode DOS sources (cp866) and the server only ever sees
  Unicode text; files read from disk by the server itself (other units, from the search path) are decoded as cp866.
  Columns in diagnostics are UTF-16 code units (the LSP default).

Where things are found (no settings for the STYLE, but the server must know where Turbo Pascal lives)
  TURBO.TPL    initializationOptions.tp7Dir, env TP7_DIR, then the workspace folder(s); the directory itself
               or its BIN subdirectory
  units        directory of the edited file, workspace folder(s), <tp7Dir>/UNITS, <tp7Dir>
  If TURBO.TPL is missing, formatting still works, but identifiers of System/Crt/Dos... keep their spelling.
"""
import json
import os
import queue
import threading
import time
import pathlib
import re
import sys
import traceback
import urllib.parse
import urllib.request
from typing import Dict, List, Optional

from tp7fmt import format_source, FormatError, TP_LINE_LIMIT
from tp7parse import parse, ROUTINE_DIRECTIVES, Node, routine_names, fieldlist_of
from tp7lex import Token, RESERVED
from tp7sema import Provider, Binder, UnitInfo
from tp7stub import StubStore, default_dir
from tp7index import ProjectIndex
from tp7types import check_types, inlay_data, expr_at, type_text, const_type_name, FLOAT

NAME = 'tp7ls'
VERSION = '0.1'

# JSON-RPC / LSP error codes
PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS, INTERNAL_ERROR = -32700, -32600, -32601, -32602, -32603
SERVER_NOT_INITIALIZED, REQUEST_FAILED = -32002, -32803
REQUEST_CANCELLED, CONTENT_MODIFIED = -32800, -32801
DIAG_DELAY, DIAG_MAX_DELAY = 0.15, 1.0                       # seconds: quiet time before diagnostics, and the longest wait
STALE_OK = frozenset(['textDocument/semanticTokens/full', 'textDocument/semanticTokens/range',
                      'textDocument/documentHighlight', 'textDocument/codeAction'])   # worthless once the text moved on

NL_RE = re.compile(r'\r\n|\r|\n')
LINES_RE = re.compile(r'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+')


def log(*a):
    print('[%s]' % NAME, *a, file=sys.stderr, flush=True)


UNIT_HEAD_RE = re.compile(r'(?is)\s*(?:\{[^}]*\}\s*|\(\*.*?\*\)\s*)*unit\b')


class RequestError(Exception):
    def __init__(self, code: int, message: str):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


# ---------------------------------------------------------------------------------------------------
# text helpers
def utf16_len(s: str) -> int:
    return len(s.encode('utf-16-le', 'surrogatepass')) // 2


def split_lines(text: str) -> List[str]:
    """Lines WITH their terminators, the same line breaks LSP counts (CRLF, LF, lone CR)."""
    return LINES_RE.findall(text)


def has_eol(line: str) -> bool:
    return line.endswith('\n') or line.endswith('\r')


def compute_edits(old: str, new: str) -> List[dict]:
    """At most one TextEdit turning `old` into `new`; whole lines only (character 0), except at an unterminated
    last line."""
    a, b = split_lines(old), split_lines(new)
    if a == b:
        return []
    p = 0
    while p < len(a) and p < len(b) and a[p] == b[p]:
        p += 1
    s = 0
    while s < len(a) - p and s < len(b) - p and a[-1 - s] == b[-1 - s]:
        s += 1
    end_line = len(a) - s
    if end_line == len(a) and a and not has_eol(a[-1]):
        end = {'line': len(a) - 1, 'character': utf16_len(a[-1])}
    else:
        end = {'line': end_line, 'character': 0}
    return [{'range': {'start': {'line': p, 'character': 0}, 'end': end}, 'newText': ''.join(b[p:len(b) - s])}]


def token_range(tok, lines: List[str], raw: bool = False) -> dict:
    """LSP range of a lexer token (line/col are 1-based, col counts characters).  A token that comes from an {$I} include
    file has no place in this document: it is shown at the directive (raw=True: where it really is, for `lines` of
    the include file)."""
    if not raw and tok.via is not None:
        tok = tok.via
    ln = tok.line - 1
    text_line = lines[ln] if 0 <= ln < len(lines) else ''
    sc = utf16_len(text_line[:tok.col - 1])
    parts = NL_RE.split(tok.text)
    if len(parts) == 1:
        ec_line, ec = ln, sc + utf16_len(tok.text)
    else:
        ec_line, ec = ln + len(parts) - 1, utf16_len(parts[-1])
    return {'start': {'line': ln, 'character': sc}, 'end': {'line': ec_line, 'character': ec}}


def ident_at(sig, lines: List[str], line: int, character: int):
    """Identifier token under the LSP position (the position may touch either end of the identifier)."""
    for tok in sig:
        if tok.kind not in ('IDENT', 'INT') or tok.line - 1 != line:         # (a number may be a label)
            continue
        r = token_range(tok, lines)
        if r['start']['character'] <= character <= r['end']['character']:
            return tok
    return None


def token_under(sig, lines: List[str], line: int, character: int):
    """The token of the text under the LSP position (the character right of the position belongs to it), or None."""
    for tok in sig:
        if tok.line - 1 != line:
            continue
        r = token_range(tok, lines)
        if r['start']['character'] <= character < r['end']['character'] and r['end']['line'] == line:
            return tok
    return None


_CALL_STOP = {'begin', 'end', 'then', 'do', 'else', 'of', 'repeat', 'until', 'var', 'const', 'type', 'procedure',
              'function', 'implementation', 'interface'}


def call_context(sig, lines: List[str], line: int, character: int):
    """The call the position is inside of: (name token, index of the argument) or None.  Walks back from the position to the
    parenthesis that is still open, counting the commas of that level; a bracket pair or a grouping parenthesis is skipped."""
    before = []
    for tok in sig:
        r = token_range(tok, lines)['start']
        if (r['line'], r['character']) < (line, character):
            before.append(tok)
        else:
            break
    depth = 0                                                   # of ) and ] seen while walking back
    commas = 0
    for i in range(len(before) - 1, -1, -1):
        t = before[i]
        text = t.text
        if t.kind in ('STRING', 'NUMBER', 'COMMENT'):
            continue
        if text in (')', ']'):
            depth += 1
        elif text in ('(', '['):
            if depth > 0:
                depth -= 1
            elif text == '(':
                prev = before[i - 1] if i else None
                if prev is not None and prev.kind == 'IDENT':
                    return prev, commas
                commas = 0                                      # a grouping parenthesis: the call, if any, is outside
            else:
                commas = 0                                      # inside an index
        elif depth == 0:
            if text == ',':
                commas += 1
            elif text == ';' or (t.kind != 'IDENT' and text.lower() in _CALL_STOP):
                return None
    return None


def signature_params(label: str):
    """[(start, end)] of every parameter of the first parenthesised list of a header like `procedure P(a, b: T; var c)`.  A
    name of a group `a, b: T` is a parameter of its own; the last one of the group takes the type with it."""
    o = label.find('(')
    if o < 0:
        return []
    depth, end = 0, len(label)
    for i in range(o, len(label)):
        if label[i] == '(':
            depth += 1
        elif label[i] == ')':
            depth -= 1
            if depth == 0:
                end = i
                break
    segs, start, depth = [], o + 1, 0
    for i in range(o + 1, end + 1):
        ch = label[i] if i < end else ';'
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ';' and depth <= 0:
            segs.append((start, i))
            start = i + 1
    out = []
    for a, b in segs:
        text = label[a:b]
        lead = len(text) - len(text.lstrip(' []'))
        a += lead
        text = label[a:b].rstrip(' []')
        b = a + len(text)
        if not text:
            continue
        m = re.match(r'(?i)(var|const)\s+', text)
        kw = m.end() if m else 0
        colon = text.find(':')
        names = text[kw:colon] if colon >= 0 else text[kw:]
        found = [[a + kw + m.start(), a + kw + m.end()] for m in re.finditer(r'[A-Za-z_]\w*', names)]
        if found:
            found[0][0] = a                                       # `var` / `const` belongs to the first name
            if colon >= 0 and '[' not in text:
                found[-1][1] = b
            out += [tuple(x) for x in found]
    return out


PAS_KEYWORDS = ('and array asm begin case const constructor destructor div do downto else end file for function goto if '
                'implementation in inherited inline interface label mod nil not object of or packed procedure program '
                'record repeat set shl shr string then to type unit until uses var while with xor').split()
CK_METHOD, CK_FUNCTION, CK_CONSTRUCTOR, CK_FIELD, CK_VARIABLE, CK_CLASS, CK_MODULE = 2, 3, 4, 5, 6, 7, 9
CK_KEYWORD, CK_CONSTANT, CK_ENUMMEMBER, CK_STRUCT = 14, 21, 20, 22
CK_REFERENCE = 18
_NO_NAME_AFTER = {'procedure', 'function', 'constructor', 'destructor', 'program', 'unit', 'label'}


def completion_kind(sym) -> int:
    k = sym.kind
    if k in ('routine', 'builtin'):
        if sym.method_kind:                                         # a method of an object that comes from a TPU
            return CK_CONSTRUCTOR if sym.method_kind in ('constructor', 'destructor') else CK_METHOD
        if sym.owner is not None:
            kw = sym.node.kids[0].text.lower() if sym.node is not None and sym.node.kids else ''
            return CK_CONSTRUCTOR if kw in ('constructor', 'destructor') else CK_METHOD
        return CK_FUNCTION
    if k == 'type':
        inner = sym.tnode
        while inner is not None and getattr(inner, 'kind', '') == 'PackedType' and len(inner.kids) > 1:
            inner = inner.kids[1]
        return CK_CLASS if getattr(inner, 'kind', '') == 'ObjectType' else CK_STRUCT
    return {'var': CK_VARIABLE, 'param': CK_VARIABLE, 'const': CK_CONSTANT, 'enum': CK_ENUMMEMBER,
            'field': CK_FIELD, 'unit': CK_MODULE}.get(k, CK_VARIABLE)


def completion_detail(sym) -> str:
    if sym.kind == 'routine' and sym.node is not None and sym.node.kids:
        sig = compact(_signature(sym.node), 120).replace(' :', ':')
        return sig if sig.startswith('(') else (' ' + sig if sig else '')
    if sym.lib and sym.home:
        return 'unit ' + sym.home
    return {'unit': 'unit', 'builtin': 'System'}.get(sym.kind, '')


def member_chain(before) -> Optional[list]:
    """Tokens before a dot -> the chain [('name', text), ('index', n), ('deref',), ('call',)...] of the expression it ends
    with, or None when no expression stands there."""
    chain = []
    i = len(before) - 1
    while i >= 0:
        t = before[i]
        if t.text == '^':
            chain.append(('deref',))
            i -= 1
        elif t.text in (')', ']'):
            close, depth, commas, j = t.text, 0, 0, i
            while j >= 0:
                x = before[j].text
                if x in (')', ']'):
                    depth += 1
                elif x in ('(', '['):
                    depth -= 1
                    if depth == 0:
                        break
                elif x == ',' and depth == 1:
                    commas += 1
                j -= 1
            if j < 0:
                return None
            chain.append(('index', commas + 1) if close == ']' else ('call',))
            i = j - 1
        elif t.kind == 'IDENT':
            chain.append(('name', t.text))
            if i > 0 and before[i - 1].text == '.':
                i -= 2
                continue
            return chain[::-1]
        else:
            return None
    return None



# ---------------------------------------------------------------------------------------------------
# selection ranges, partial formatting, edits of code actions
def _first_token(node):
    for k in node.kids:
        if isinstance(k, Token):
            return k
        t = _first_token(k)
        if t is not None:
            return t
    return None


def _last_token(node):
    for k in reversed(node.kids):
        if isinstance(k, Token):
            return k
        t = _last_token(k)
        if t is not None:
            return t
    return None


def node_span(node, lines):
    """((line, char), (line, char)) of a syntax node: from its first token to its last; None for an empty one."""
    a, b = _first_token(node), _last_token(node)
    if a is None or b is None:
        return None
    ra, rb = token_range(a, lines), token_range(b, lines)
    return ((ra['start']['line'], ra['start']['character']), (rb['end']['line'], rb['end']['character']))


def selection_chain(res, lines, line: int, character: int) -> list:
    """Ranges around a position, innermost first: the token, then every syntax node that contains it."""
    here = (line, character)
    spans = []
    node = res.tree
    while node is not None:
        sp = node_span(node, lines)
        if sp is not None and sp[0] <= here <= sp[1]:
            spans.append(sp)
        nxt = None
        for k in node.kids:
            if isinstance(k, Token):
                r = token_range(k, lines)
                a, b = (r['start']['line'], r['start']['character']), (r['end']['line'], r['end']['character'])
                if a <= here <= b and k.kind not in ('EOF',):
                    spans.append((a, b))
            else:
                ks = node_span(k, lines)
                if ks is not None and ks[0] <= here <= ks[1] and (nxt is None or ks[0] >= node_span(nxt, lines)[0]):
                    nxt = k
        node = nxt
    spans.sort(key=lambda sp: (sp[1][0] - sp[0][0], sp[1][1] - sp[0][1] if sp[0][0] == sp[1][0] else 0))
    out, last = [], None
    for sp in spans:
        if sp != last and (last is None or (sp[0] <= last[0] and last[1] <= sp[1])):
            out.append(sp)
            last = sp
    return out


def selection_range(res, lines, line: int, character: int) -> dict:
    chain = selection_chain(res, lines, line, character) or [((line, character), (line, character))]
    sel = None
    for a, b in reversed(chain):
        r = {'start': {'line': a[0], 'character': a[1]}, 'end': {'line': b[0], 'character': b[1]}}
        sel = {'range': r, 'parent': sel} if sel is not None else {'range': r}
    return sel


def is_subsequence(needle: str, hay: str) -> bool:
    it = iter(hay)
    return all(ch in it for ch in needle)


def range_edits(old: str, new: str, first: int, last: int) -> List[dict]:
    """Edits that turn `old` into `new` only where they touch the lines first..last (0-based, inclusive).  The change is
    split into hunks by a line diff and the hunks outside the range are dropped."""
    import difflib
    a, b = split_lines(old), split_lines(new)
    if a == b:
        return []
    edits = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        if tag == 'replace' and i2 - i1 == j2 - j1 and i2 < len(a):      # same number of lines: judge every line by itself
            for k in range(i2 - i1):
                if first <= i1 + k <= last and a[i1 + k] != b[j1 + k]:
                    edits.append({'range': {'start': {'line': i1 + k, 'character': 0}, 'end': {'line': i1 + k + 1, 'character': 0}},
                                  'newText': b[j1 + k]})
            continue
        touches = (first <= i1 <= last + 1) if i1 == i2 else (i1 <= last and i2 > first)
        if not touches:
            continue
        if i2 == len(a) and a and not has_eol(a[-1]):
            end = {'line': len(a) - 1, 'character': utf16_len(a[-1])}
            text = ''.join(b[j1:j2])
            if i1 == i2:
                continue
        else:
            end = {'line': i2, 'character': 0}
            text = ''.join(b[j1:j2])
        edits.append({'range': {'start': {'line': i1, 'character': 0}, 'end': end}, 'newText': text})
    return edits


def _pos(r):
    return (r['line'], r['character'])


def whole_lines(lines: List[str], start: dict, end: dict) -> dict:
    """Widen a range to the whole lines it covers when nothing else stands on them (so deleting it leaves no blank line)."""
    sl, el = start['line'], end['line']
    if sl < len(lines) and el < len(lines) and not lines[sl][:start['character']].strip() \
            and not lines[el][end['character']:].strip():
        return {'start': {'line': sl, 'character': 0}, 'end': {'line': el + 1, 'character': 0}}
    return {'start': start, 'end': end}


def names_edit(lines: List[str], name_toks, keep) -> dict:
    """Edit that rewrites a comma-separated list of names (`A, B, C`) so that only the tokens in `keep` stay."""
    a = token_range(name_toks[0], lines)['start']
    b = token_range(name_toks[-1], lines)['end']
    return {'range': {'start': a, 'end': b}, 'newText': ', '.join(t.text for t in keep)}



def token_ancestors(tree, tok):
    """The syntax nodes that hold a token, innermost first (found by descending along token indexes: no search of the whole
    tree)."""
    path = []
    node = tree
    while node is not None:
        path.append(node)
        nxt = None
        for k in node.kids:
            if k is tok:
                return path[::-1]
            if isinstance(k, Node):
                a, b = _first_token(k), _last_token(k)
                if a is not None and b is not None and a.idx <= tok.idx <= b.idx:
                    nxt = k
                    break
        node = nxt
    return []


TYPE_TAILS = {'ArrayType': 'of', 'SetType': 'of', 'FileType': 'of'}
TYPE_STARTERS = 'array record set file string packed'.split()


def in_type_position(prev, ancestors) -> bool:
    """Does a type have to stand right after the token `prev`?  (`var X: |`, `type T = |`, `array[..] of |`, `^|`, the result of
    a function, a field or a parameter)"""
    if prev is None or not ancestors:
        return False
    parent = ancestors[0]
    text = prev.text.lower()
    if text == ':':
        return parent.kind in ('VarDecl', 'FieldDecl', 'ParamGroup', 'ConstDecl', 'Routine')
    if text == '=':
        return parent.kind == 'TypeDecl'
    if text == 'of':
        return parent.kind in TYPE_TAILS
    if text == '^':
        return parent.kind == 'PointerType'
    return text == 'packed' and parent.kind == 'PackedType'


SEM_TYPES = ['namespace', 'type', 'enumMember', 'function', 'parameter', 'variable', 'property', 'label',
             'comment', 'macro', 'keyword', 'method']
SEM_MODS = ['declaration', 'readonly', 'defaultLibrary']
_KIND_TYPE = {'unit': 'namespace', 'type': 'type', 'enum': 'enumMember', 'routine': 'function', 'builtin': 'function',
              'param': 'parameter', 'var': 'variable', 'const': 'variable', 'field': 'property', 'label': 'label'}


def sem_class(sym, is_decl: bool):
    """-> (type index, modifier bit mask) for a symbol, or None."""
    name = _KIND_TYPE.get(sym.kind)
    if name is None:
        return None
    if sym.kind == 'routine' and (sym.owner is not None or sym.method_kind):
        name = 'method'
    mods = 0
    if is_decl:
        mods |= 1
    if sym.kind in ('const', 'enum'):
        mods |= 2
    if sym.lib:
        mods |= 4
    return SEM_TYPES.index(name), mods


def tok_pieces(tok):
    """(line, start column in characters, text) of each line of a token (comments and directives may span lines)."""
    for i, part in enumerate(NL_RE.split(tok.text)):
        if part.strip():
            yield tok.line - 1 + i, (tok.col - 1 if i == 0 else 0), part


def semantic_data(res, binder, lines: List[str], first: int = 0, last: Optional[int] = None) -> List[int]:
    """LSP semantic tokens (relative encoding) of the lines first..last."""
    items = []                                                  # (line, start, length, type, mods)

    def add(line, col, text, typ, mods):
        if line < first or (last is not None and line > last) or line >= len(lines):
            return
        stripped = text.rstrip()
        start = utf16_len(lines[line][:col])
        items.append((line, start, utf16_len(stripped), typ, mods))

    comment, macro = SEM_TYPES.index('comment'), SEM_TYPES.index('macro')
    for tok in res.tokens:
        if tok.kind == 'DIRECTIVE':
            for ln, col, text in tok_pieces(tok):
                add(ln, col, text, macro, 0)
        elif not tok.active and tok.kind not in ('WS', 'NL', 'CTRLZ', 'EOF'):
            for ln, col, text in tok_pieces(tok):
                add(ln, col, text, comment, 0)
    keyword = SEM_TYPES.index('keyword')
    for node in res.tree.walk():                                # far / forward / external / absolute are plain identifiers
        if node.kind == 'Directives':
            toks = [t for t in node.kids if isinstance(t, Token) and t.kind == 'IDENT'
                    and t.text.lower() in ROUTINE_DIRECTIVES]
        elif node.kind in ('Absolute', 'Section') and node.kids and isinstance(node.kids[0], Token):
            toks = [node.kids[0]]
        else:
            continue
        for t in toks:
            add(t.line - 1, t.col - 1, t.text, keyword, 0)
    for tok in res.doc_sig:
        if tok.kind == 'KW':
            add(tok.line - 1, tok.col - 1, tok.text, keyword, 0)
            continue
        if tok.kind != 'IDENT':
            continue
        sym = binder.refs.get(id(tok))
        decl = binder.decls.get(id(tok))
        if sym is None:
            sym = decl
        if sym is None:
            continue
        cls = sem_class(sym, id(tok) in binder.decls)
        if cls is not None:
            add(tok.line - 1, tok.col - 1, tok.text, cls[0], cls[1])
    items.sort()
    data, pl, pc, pend = [], 0, 0, (-1, 0)
    for line, start, length, typ, mods in items:
        if length <= 0 or (line, start) < pend:                 # empty, or overlaps the previous token
            continue
        data += [line - pl, start - pc if line == pl else start, length, typ, mods]
        pl, pc, pend = line, start, (line, start + length)
    return data


# ---------------------------------------------------------------------------------------------------
# outline (textDocument/documentSymbol)
SK_MODULE, SK_NAMESPACE, SK_CLASS, SK_METHOD, SK_FIELD, SK_CONSTRUCTOR, SK_ENUM, SK_FUNCTION = 2, 3, 5, 6, 8, 9, 10, 12
SK_VARIABLE, SK_CONSTANT = 13, 14
SK_ARRAY, SK_ENUMMEMBER, SK_STRUCT, SK_TYPEPARAMETER = 18, 22, 23, 26
_TIGHT = [(' ,', ','), (' ;', ';'), (' :', ':'), ('( ', '('), (' )', ')'), ('[ ', '['), (' ]', ']'), (' ..', '..'),
          ('.. ', '..'), ('^ ', '^'), (' .', '.'), ('. ', '.')]


def compact(toks, limit: int = 80) -> str:
    """Source tokens joined for a `detail` line: single blanks, none before , ; : ) ] or around .."""
    text = ' '.join(t.text for t in toks)
    for a, b in _TIGHT:
        text = text.replace(a, b)
    return text if len(text) <= limit else text[:limit - 1] + '\u2026'


def _tokens(node):
    return [node] if isinstance(node, Token) else list(node.tokens())


def _extent(node, lines):
    toks = _tokens(node)
    return {'start': token_range(toks[0], lines)['start'], 'end': token_range(toks[-1], lines)['end']}


def _sym(name_tok, kind, detail, node, lines, children=None, name=None):
    d = {'name': name or name_tok.text, 'kind': kind, 'range': _extent(node, lines),
         'selectionRange': token_range(name_tok, lines)}
    if detail:
        d['detail'] = detail
    if children:
        d['children'] = children
    return d


def _decl_names(nodes):
    return [x.kids[0] for x in nodes if isinstance(x, Node) and x.kind == 'DeclName' and x.kids
            and isinstance(x.kids[0], Token)]


def _signature(r):
    """Tokens of a routine's header after its name: parameters and result type."""
    kids = r.kids
    start = 4 if routine_names(r)[0] is not None else 2
    end = next((i for i, x in enumerate(kids) if i >= start and isinstance(x, Token) and x.text == ';'), len(kids))
    return [t for x in kids[start:end] for t in _tokens(x)]


def _method_kind(r) -> int:
    kw = r.kids[0].text.lower() if r.kids and isinstance(r.kids[0], Token) else ''
    return SK_CONSTRUCTOR if kw in ('constructor', 'destructor') else SK_METHOD


def _fields(fl, lines):
    out = []
    for k in fl.kids:
        if not isinstance(k, Node):
            continue
        if k.kind == 'Routine':                                   # a method declared in a record / object
            _, dn = routine_names(k)
            names = _decl_names([dn]) if dn is not None else []
            if names:
                out.append(_sym(names[0], _method_kind(k), compact(_signature(k)) or None, k, lines))
        elif k.kind == 'FieldDecl':
            colon = max((i for i, x in enumerate(k.kids) if isinstance(x, Token) and x.text == ':'), default=None)
            if colon is None or colon + 1 >= len(k.kids):
                continue
            detail = compact(_tokens(k.kids[colon + 1]))
            out += [_sym(t, SK_FIELD, detail, k, lines) for t in _decl_names(k.kids[:colon])]
        elif k.kind == 'VariantPart':
            kids = k.kids
            if len(kids) > 3 and isinstance(kids[1], Node) and kids[1].kind == 'DeclName' and \
                    isinstance(kids[2], Token) and kids[2].text == ':':          # case Tag: Type of
                tag = Node('TagField', kids[1:4])                                # only `Tag: Type`, not the variants
                out += [_sym(t, SK_FIELD, compact(_tokens(kids[3])), tag, lines) for t in _decl_names([kids[1]])]
            for v in kids:
                if isinstance(v, Node) and v.kind == 'Variant' and len(v.kids) > 3 and isinstance(v.kids[3], Node):
                    out += _fields(v.kids[3], lines)
    return out


def _type_symbol(d, lines):
    names = _decl_names(d.kids[:1])
    if not names or len(d.kids) < 3 or not isinstance(d.kids[2], Node):
        return []
    ty = d.kids[2]
    while ty.kind == 'PackedType' and len(ty.kids) > 1 and isinstance(ty.kids[1], Node):
        ty = ty.kids[1]
    if ty.kind in ('RecordType', 'ObjectType'):
        fl = fieldlist_of(ty)
        her = next((x for x in ty.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
        detail = ('object' + compact(_tokens(her))) if her is not None else ('object' if ty.kind == 'ObjectType' else None)
        kind = SK_CLASS if ty.kind == 'ObjectType' else SK_STRUCT
        return [_sym(names[0], kind, detail, d, lines, _fields(fl, lines) if fl is not None else None)]
    if ty.kind == 'EnumType':
        members = [_sym(t, SK_ENUMMEMBER, None, t, lines) for t in _decl_names(ty.kids)]
        return [_sym(names[0], SK_ENUM, None, d, lines, members)]
    kind = SK_ARRAY if ty.kind == 'ArrayType' else SK_TYPEPARAMETER
    return [_sym(names[0], kind, compact(_tokens(d.kids[2])), d, lines)]


def _routine_symbol(r, lines):
    kids = r.kids
    owner, dn = routine_names(r)
    names = _decl_names([dn]) if dn is not None else []
    if not names:
        return []
    sig = _signature(r)
    block = next((x for x in kids if isinstance(x, Node) and x.kind == 'Block'), None)
    nested = _items(block.kids, lines) if block is not None else []
    nested = [x for x in nested if x['kind'] == SK_FUNCTION]                # only nested routines, not local data
    if owner is not None and owner.kids:                         # procedure T.M: a method implementation
        return [_sym(names[0], _method_kind(r), compact(sig) or None, r, lines, nested,
                     name='%s.%s' % (owner.kids[0].text, names[0].text))]
    return [_sym(names[0], SK_FUNCTION, compact(sig) or None, r, lines, nested)]


def _items(kids, lines):
    out = []
    for sec in kids:
        if not isinstance(sec, Node):
            continue
        if sec.kind == 'ConstSection':
            for d in sec.kids[1:]:
                if isinstance(d, Node) and d.kind == 'ConstDecl':
                    body = [t for x in d.kids[1:] for t in _tokens(x) if t.text != ';' or t is not _tokens(d)[-1]]
                    out += [_sym(t, SK_CONSTANT, compact(body) or None, d, lines) for t in _decl_names(d.kids[:1])]
        elif sec.kind == 'TypeSection':
            for d in sec.kids[1:]:
                if isinstance(d, Node) and d.kind == 'TypeDecl':
                    out += _type_symbol(d, lines)
        elif sec.kind == 'VarSection':
            for d in sec.kids[1:]:
                if isinstance(d, Node) and d.kind == 'VarDecl':
                    colon = next((i for i, x in enumerate(d.kids) if isinstance(x, Token) and x.text == ':'), None)
                    if colon is None or colon + 1 >= len(d.kids):
                        continue
                    detail = compact(_tokens(d.kids[colon + 1]))
                    out += [_sym(t, SK_VARIABLE, detail, d, lines) for t in _decl_names(d.kids[:colon])]
        elif sec.kind == 'Routine':
            out += _routine_symbol(sec, lines)
    return out


def document_symbols(text: str) -> list:
    """Hierarchical outline of a Turbo Pascal 7 source (the parser is tolerant: a broken file gives what is there)."""
    res = parse(text)
    lines = NL_RE.split(text)
    root = res.tree.kids[0] if res.tree.kids else None
    if root is None or not res.doc_sig or len(res.doc_sig) < 2:
        return []
    whole = {'start': token_range(res.doc_sig[0], lines)['start'], 'end': token_range(res.doc_sig[-2], lines)['end']}

    def module(name_tok, kids, fallback):
        d = {'name': name_tok.text if name_tok is not None else fallback, 'kind': SK_MODULE, 'range': whole,
             'selectionRange': token_range(name_tok, lines) if name_tok is not None else
             {'start': whole['start'], 'end': token_range(res.doc_sig[0], lines)['end']}}
        if kids:
            d['children'] = kids
        return [d]

    if root.kind == 'Unit':
        names = _decl_names(root.kids[1:2])
        parts = []
        for part in root.kids:
            if isinstance(part, Node) and part.kind in ('Interface', 'Implementation'):
                kw = part.kids[0]
                kids = _items([x for x in part.kids if isinstance(x, Node)], lines)
                parts.append(_sym(kw, SK_NAMESPACE, None, part, lines, kids, name=kw.text.lower()))
        return module(names[0] if names else None, parts, 'unit')
    if root.kind == 'Program':
        header = next((x for x in root.kids if isinstance(x, Node) and x.kind == 'ProgramHeader'), None)
        names = _decl_names(header.kids) if header is not None else []
        block = next((x for x in root.kids if isinstance(x, Node) and x.kind == 'Block'), None)
        return module(names[0] if names else None, _items(block.kids, lines) if block is not None else [], 'program')
    return []


def flatten_symbols(symbols: list, uri: str, container: Optional[str] = None) -> list:
    out = []
    for s in symbols:
        info = {'name': s['name'], 'kind': s['kind'], 'location': {'uri': uri, 'range': s['range']}}
        if container:
            info['containerName'] = container
        out.append(info)
        out += flatten_symbols(s.get('children') or [], uri, s['name'])
    return out


# ---------------------------------------------------------------------------------------------------
# references / highlight / rename
IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
MAX_SCAN_FILES, MAX_SCAN_BYTES = 2000, 2_000_000


def path_key(path: str) -> str:
    return os.path.normcase(os.path.abspath(path))


def sym_key(sym, here: str):
    """Identity of a symbol that is the same in every file that sees it: (file, index of the declaring token).
    Symbols without source (TPU, System...) are identified by kind and name."""
    if sym.kind == 'unit':
        return ('unit', sym.name.lower())
    if sym.implicit:                                               # Self: one symbol per type
        return ('self', sym_key(sym.owner, here) if sym.owner is not None else None)
    if sym.tok is None:
        return ('lib', sym.kind, sym.name.lower())
    return (path_key(sym.file) if sym.file else here, sym.tok.idx)


class Bound:
    """One source text, parsed and bound."""

    def __init__(self, key: str, uri: str, text: str, res, binder):
        self.key, self.uri, self.text, self.res, self.binder = key, uri, text, res, binder
        self.lines = NL_RE.split(text)

    def keyed(self):
        """[(token, symbol key or None, symbol, is a declaring token)] for every identifier of the active code."""
        out = []
        for tok in self.res.doc_sig:
            if tok.kind not in ('IDENT', 'INT'):
                continue
            sym = self.binder.refs.get(id(tok)) or self.binder.decls.get(id(tok))
            if sym is None and tok.kind == 'INT':
                continue                                           # an ordinary number
            out.append((tok, sym_key(sym, self.key) if sym is not None else None, sym, id(tok) in self.binder.decls))
        return out


def is_virtual(m) -> bool:
    """Is this method declared `virtual` (a constructor cannot be, but its header may carry the directive anyway)?"""
    node = getattr(m, 'node', None)
    dirs = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Directives'), None) if node is not None else None
    return dirs is not None and any(isinstance(t, Token) and t.text.lower() == 'virtual' for t in dirs.kids)


def virtual_chain(binder, m):
    """[m, the method it overrides, the one that one overrides, ...]: the same-named virtual methods up the ancestors."""
    out = [m]
    if m.owner is None or not is_virtual(m):
        return out
    ti = binder.type_ti(m.owner)
    anc = ti.get_ancestor() if ti is not None else None
    seen = 0
    while anc is not None and seen < 100:
        seen += 1
        up = anc.get_own().get(m.name.lower())
        if up is not None and up.kind == 'routine' and up.owner is not None and is_virtual(up):
            out.append(up)
        elif up is not None:
            break
        anc = anc.get_ancestor()
    return out


def object_node(sym):
    """The ObjectType node that a type symbol declares directly, or None."""
    n = getattr(sym, 'tnode', None) if sym is not None and sym.kind == 'type' else None
    return n if isinstance(n, Node) and n.kind == 'ObjectType' else None


def ancestor_sym(binder, sym):
    """The type symbol of `object(Ancestor)`, or None (no ancestor, or one that cannot be resolved)."""
    node = object_node(sym)
    her = next((x for x in node.kids if isinstance(x, Node) and x.kind == 'Heritage'), None) if node is not None else None
    if her is None or len(her.kids) < 2 or not isinstance(her.kids[1], Node):
        return None
    return binder.type_sym(her.kids[1], sym.scope)


def write_targets(res) -> set:
    """ids of the identifier tokens that are assigned to: the last field (or the variable) on the left of `:=`, the
    control variable of `for`."""
    out = set()

    def head(d):
        if isinstance(d, Token):
            return d
        if d.kind == 'Designator':
            fields = [x for x in d.kids[1:] if isinstance(x, Node) and x.kind == 'Field' and len(x.kids) > 1]
            if fields and isinstance(fields[-1].kids[1], Token):
                return fields[-1].kids[1]
            d = d.kids[0]
        while isinstance(d, Node) and d.kids:
            d = d.kids[0]
        return d if isinstance(d, Token) else None

    for n in res.tree.walk():
        if n.kind == 'Assign' and n.kids:
            t = head(n.kids[0])
        elif n.kind == 'For' and len(n.kids) > 1:
            t = head(n.kids[1])
        else:
            continue
        if t is not None and t.kind == 'IDENT':
            out.add(id(t))
    return out


def apply_token_edits(text: str, toks, new: str) -> str:
    for t in sorted(toks, key=lambda x: -x.pos):
        text = text[:t.pos] + new + text[t.pos + len(t.text):]
    return text


# ---------------------------------------------------------------------------------------------------
# hover / typeDefinition
_LIB_LABEL = {'routine': 'routine', 'builtin': 'standard routine', 'var': 'var', 'const': 'const', 'type': 'type',
              'field': 'field', 'enum': 'enumeration constant', 'param': 'parameter', 'unit': 'unit', 'label': 'label'}


def type_name_node(tn):
    """The `Name` node of the named type that a type expression is made of (through ^, array of, packed, set of,
    file of), or None."""
    while isinstance(tn, Node):
        if tn.kind == 'NamedType':
            return tn.kids[0] if tn.kids and isinstance(tn.kids[0], Node) else None
        if tn.kind == 'PointerType':
            return tn.kids[1] if len(tn.kids) > 1 and isinstance(tn.kids[1], Node) else None
        if tn.kind in ('ArrayType', 'PackedType', 'SetType', 'FileType'):
            nxt = next((x for x in reversed(tn.kids) if isinstance(x, Node)), None)
            if nxt is None or nxt is tn:
                return None
            tn = nxt
            continue
        return None
    return None


def _members_text(inner, limit: int = 14):
    """Body lines of a record / object type for a hover: fields, method headers, section markers, `case ... of ...`."""
    body = []
    fl = fieldlist_of(inner)
    for k in (fl.kids if fl is not None else []):
        if not isinstance(k, Node):
            continue
        if k.kind == 'FieldDecl':
            body.append('  ' + compact(_tokens(k), 120) + ';')
        elif k.kind == 'Routine':
            body.append('  ' + _method_line(k))
        elif k.kind == 'Section':
            body.append(k.kids[0].text.lower())
        elif k.kind == 'VariantPart':
            vk = k.kids
            i_of = next((i for i, x in enumerate(vk) if isinstance(x, Token) and x.text.lower() == 'of'), None)
            if i_of is not None:
                body.append('  ' + compact([t for x in vk[:i_of + 1] for t in _tokens(x)], 120) + ' ...')
    if len(body) > limit:
        body = body[:limit] + ['  ...']
    return body


def _method_line(r) -> str:
    """`procedure Draw(X: Integer); virtual;` - one method header, directives included, without a body."""
    _, dn = routine_names(r)
    sig = compact(_signature(r), 200)
    text = '%s %s%s' % (r.kids[0].text.lower(), dn.kids[0].text if dn is not None and dn.kids else '',
                        sig if sig.startswith('(') else (' ' + sig if sig else ''))
    text = text.replace(' :', ':')
    dirs = next((x for x in r.kids if isinstance(x, Node) and x.kind == 'Directives'), None)
    words = [t.text.lower() for t in dirs.kids if isinstance(t, Token) and t.kind == 'IDENT'] if dirs is not None else []
    return text + ''.join('; ' + w for w in words) + ';'


def hover_markdown(sym) -> Optional[str]:
    """Markdown for the hover of a symbol: a pascal code block, and a line about where it comes from."""
    kind = sym.kind
    if kind == 'unit':
        where = ('*source: %s*' % os.path.basename(sym.file)) if sym.file else '*standard library unit (no source)*'
        return '```pascal\nunit %s\n```\n%s' % (sym.name, where)
    if sym.implicit:                                              # Self
        return '```pascal\nSelf: %s\n```\n*the object this method works on*' % (
            sym.owner.name if sym.owner is not None else '?')
    if sym.tok is None:                                           # TPU / System: only the kind and the unit are known
        label = _LIB_LABEL.get(kind, kind)
        text = ('%s %s' % (label, sym.name)) if kind in ('var', 'const', 'type', 'routine', 'builtin') else sym.name
        return '```pascal\n%s\n```\n%s' % (text, '*unit %s*' % sym.home if sym.home else '')
    node = sym.node
    owner = sym.owner.name + '.' if sym.owner is not None else ''
    if kind == 'routine' and node is not None and node.kids:
        kids = node.kids
        sig = compact(_signature(node), 300)
        text = '%s %s%s%s' % (kids[0].text.lower(), owner, sym.name, sig if sig.startswith('(') else (' ' + sig if sig else ''))
        text = text.replace(' :', ':')
        dirs = next((x for x in kids if isinstance(x, Node) and x.kind == 'Directives'), None)
        if dirs is not None and sym.owner is not None:            # virtual, far ...: part of what a method is
            words = [t.text.lower() for t in dirs.kids if isinstance(t, Token) and t.kind == 'IDENT']
            if words:
                text += '; ' + '; '.join(words)
    elif kind in ('var', 'param', 'field') and sym.tnode is not None:
        text = ('var ' if kind == 'var' else '') + '%s: %s' % (sym.name, compact(_tokens(sym.tnode), 300))
    elif kind == 'const' and node is not None:
        parts = [t for x in node.kids[1:] for t in _tokens(x)]
        if parts and parts[-1].text == ';':
            parts = parts[:-1]
        text = 'const %s %s' % (sym.name, compact(parts, 300))
        text = text.replace(' :', ':')
    elif kind == 'type' and sym.tnode is not None:
        tn = sym.tnode
        inner = tn
        while inner.kind == 'PackedType' and len(inner.kids) > 1 and isinstance(inner.kids[1], Node):
            inner = inner.kids[1]
        if inner.kind in ('RecordType', 'ObjectType') and fieldlist_of(inner) is not None:
            her = next((x for x in inner.kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
            head = _tokens(inner)[0].text.lower() + (compact(_tokens(her)) if her is not None else '')
            text = 'type %s = %s\n%s\nend' % (sym.name, head, '\n'.join(_members_text(inner)))
        else:
            text = 'type %s = %s' % (sym.name, compact(_tokens(tn), 300))
    elif kind == 'enum':
        enum = compact(_tokens(sym.tnode), 200) if sym.tnode is not None else ''
        text = sym.name
        return '```pascal\n%s\n```\n*enumeration constant* of %s' % (text, enum)
    elif kind == 'label':
        text = 'label %s' % sym.name
    else:
        text = sym.name
    extra = {'param': '*parameter*', 'field': '*field*'}.get(kind, '')
    if sym.owner is not None and kind in ('field', 'routine'):
        extra = '*%s of %s*' % ('method' if kind == 'routine' else 'field', sym.owner.name)
    return '```pascal\n%s\n```%s' % (text, ('\n' + extra) if extra else '')


def diagnostics_for(text: str, res=None) -> List[dict]:
    res = res if res is not None else parse(text)
    lines = NL_RE.split(text)
    out = []
    for tok, msg in res.diags:
        out.append({'range': token_range(tok, lines), 'severity': 1, 'source': NAME, 'message': msg})
    for n, text in enumerate(lines):
        if len(text) > TP_LINE_LIMIT:                           # Turbo Pascal 7: Error 11, Line too long
            out.append({'range': {'start': {'line': n, 'character': utf16_len(text[:TP_LINE_LIMIT])},
                                  'end': {'line': n, 'character': utf16_len(text)}},
                        'severity': 1, 'source': NAME,
                        'message': 'line too long (%d characters): Turbo Pascal 7 accepts at most %d'
                                   % (len(text), TP_LINE_LIMIT)})
    return out


# ---------------------------------------------------------------------------------------------------
# files and paths
def uri_to_path(uri: str) -> Optional[str]:
    p = urllib.parse.urlparse(uri)
    if p.scheme != 'file':
        return None
    return os.path.abspath(urllib.request.url2pathname(p.path))


def list_ci(directory: str, name: str) -> Optional[str]:
    """Case-insensitive lookup of `name` inside `directory` (DOS-era names are upper case)."""
    try:
        for fn in os.listdir(directory):
            if fn.lower() == name.lower():
                return os.path.join(directory, fn)
    except OSError:
        pass
    return None


def find_tpl(bases: List[str]) -> Optional[str]:
    for base in bases:
        for d in (base, list_ci(base, 'bin')):
            if d and os.path.isdir(d):
                p = list_ci(d, 'turbo.tpl')
                if p and os.path.isfile(p):
                    return p
    return None


class Doc:
    def __init__(self, uri: str, version, text: str):
        self.uri, self.version, self.text = uri, version, text
        self.path = uri_to_path(uri)


# ---------------------------------------------------------------------------------------------------
class Transport:
    def __init__(self, rfile, wfile):
        self.rfile, self.wfile = rfile, wfile

    def read(self) -> Optional[dict]:
        """Next message, or None at end of input."""
        while True:
            length = None
            while True:
                line = self.rfile.readline()
                if not line:
                    return None
                line = line.rstrip(b'\r\n')
                if line == b'':
                    break
                name, _, value = line.partition(b':')
                if name.strip().lower() == b'content-length':
                    try:
                        length = int(value.strip())
                    except ValueError:
                        length = None
            if length is None:
                continue
            body = self.rfile.read(length)
            if len(body) < length:
                return None
            try:
                return json.loads(body.decode('utf-8'))
            except ValueError as e:
                log('invalid JSON ignored:', e)

    def send(self, msg: dict):
        body = json.dumps(msg).encode('utf-8')                 # ensure_ascii: pure ASCII on the wire
        self.wfile.write(b'Content-Length: %d\r\n\r\n' % len(body))
        self.wfile.write(body)
        self.wfile.flush()


class Server:
    def __init__(self, transport: Transport):
        self.t = transport
        self.docs: Dict[str, Doc] = {}
        self.roots: List[str] = []
        self.tp7_dir: Optional[str] = None
        self.tpl: Optional[str] = None
        self.stubs: Optional[StubStore] = None                    # generated stubs of TPU units (go to definition)
        self.bound_cache: Dict[str, tuple] = {}                   # uri -> (provider, text, Bound)
        self.provider_cache: Dict[tuple, Provider] = {}
        self.can_watch = False
        self.inlay = {'parameters': True, 'constants': True, 'endLabels': 25}     # initializationOptions.inlayHints
        self.type_checks = True                                   # initializationOptions.typeDiagnostics
        self.index: Optional[ProjectIndex] = None                # units and sources of the whole workspace tree
        self.symbol_cache: Dict[str, tuple] = {}                  # workspace/symbol: file key -> (stamp, symbols)
        self.hierarchical = False                                # client understands DocumentSymbol[]
        self.initialized = False
        self.shutdown = False
        self.inbox: 'queue.Queue' = queue.Queue()
        self.cancelled: set = set()                              # ids of requests the client gave up on
        self.pending: Dict[str, tuple] = {}                      # uri -> (first, last) time of a change not yet diagnosed
        self.exit_code: Optional[int] = None

    # -- plumbing --------------------------------------------------------------------------------------
    def reply(self, id_, result):
        self.t.send({'jsonrpc': '2.0', 'id': id_, 'result': result})

    def reply_error(self, id_, code, message):
        self.t.send({'jsonrpc': '2.0', 'id': id_, 'error': {'code': code, 'message': message}})

    def notify(self, method, params):
        self.t.send({'jsonrpc': '2.0', 'method': method, 'params': params})

    def reader(self):
        """Thread: reads the client's messages into the queue, so that the main loop can see what is waiting behind the
        message it works on.  A cancelled request is dropped here, the moment the cancellation arrives."""
        while True:
            try:
                msg = self.t.read()
            except Exception as e:                                # a broken pipe is the end of the input
                log('reader stopped: %s' % e)
                msg = None
            if msg is None:
                self.inbox.put(None)
                return
            if isinstance(msg, dict) and msg.get('method') == '$/cancelRequest':
                self.cancelled.add((msg.get('params') or {}).get('id'))
                continue
            self.inbox.put(msg)

    def run(self) -> int:
        threading.Thread(target=self.reader, daemon=True).start()
        while self.exit_code is None:
            wait = None
            if self.pending:                                      # diagnostics are due when the typing pauses
                now = time.monotonic()
                wait = max(0.0, min(min(last + DIAG_DELAY, first + DIAG_MAX_DELAY) for first, last in self.pending.values()) - now)
            try:
                msg = self.inbox.get(timeout=wait)
            except queue.Empty:
                self.flush_diagnostics()
                continue
            if msg is None:                                      # client vanished
                return 0 if self.shutdown else 1
            if isinstance(msg, dict):
                self.dispatch(msg)
        return self.exit_code

    def newer_change_waiting(self, uri) -> bool:
        """Is a change of that document waiting in the queue?"""
        with self.inbox.mutex:
            items = list(self.inbox.queue)
        for m in items:
            if isinstance(m, dict) and m.get('method') == 'textDocument/didChange' \
                    and ((m.get('params') or {}).get('textDocument') or {}).get('uri') == uri:
                return True
        return False

    def schedule_diagnostics(self, doc: Doc):
        now = time.monotonic()
        first = self.pending.get(doc.uri, (now, now))[0]
        self.pending[doc.uri] = (first, now)

    def flush_diagnostics(self, force: bool = False):
        now = time.monotonic()
        for uri, (first, last) in list(self.pending.items()):
            if not force and now < min(last + DIAG_DELAY, first + DIAG_MAX_DELAY):
                continue
            del self.pending[uri]
            doc = self.docs.get(uri)
            if doc is not None:
                self.publish(doc)

    def dispatch(self, msg: dict):
        method = msg.get('method')
        if method is None:
            return                                               # a response to a request we never send
        id_ = msg.get('id')
        is_request = 'id' in msg
        params = msg.get('params') or {}
        try:
            if method == 'exit':
                self.exit_code = 0 if self.shutdown else 1
                return
            if not self.initialized and method != 'initialize':
                if is_request:
                    raise RequestError(SERVER_NOT_INITIALIZED, 'server not initialized')
                return
            if self.shutdown and is_request:
                raise RequestError(INVALID_REQUEST, 'server is shutting down')
            if is_request and id_ in self.cancelled:
                self.cancelled.discard(id_)
                raise RequestError(REQUEST_CANCELLED, 'request cancelled')
            if is_request and method in STALE_OK and self.newer_change_waiting(
                    (params.get('textDocument') or {}).get('uri')):
                raise RequestError(CONTENT_MODIFIED, 'the document changed')
            h = getattr(self, 'on_' + re.sub(r'[^A-Za-z0-9]', '_', method), None)
            if h is None:
                if is_request:
                    raise RequestError(METHOD_NOT_FOUND, 'method not supported: %s' % method)
                return                                           # unknown notifications (incl. $/...) are ignored
            result = h(params)
            if is_request:
                self.reply(id_, result)
        except RequestError as e:
            if is_request:
                self.reply_error(id_, e.code, e.message)
            else:
                log('notification %s failed: %s' % (method, e.message))
        except Exception as e:                                   # never let one request kill the server
            log('internal error in %s:\n%s' % (method, traceback.format_exc()))
            if is_request:
                self.reply_error(id_, INTERNAL_ERROR, '%s: %s' % (type(e).__name__, e))

    # -- lifecycle -------------------------------------------------------------------------------------
    def on_initialize(self, p: dict):
        for f in p.get('workspaceFolders') or []:
            path = uri_to_path(f.get('uri', ''))
            if path:
                self.roots.append(path)
        if not self.roots:
            path = uri_to_path(p.get('rootUri') or '') or p.get('rootPath')
            if path:
                self.roots.append(os.path.abspath(path))
        ds = ((p.get('capabilities') or {}).get('textDocument') or {}).get('documentSymbol') or {}
        self.hierarchical = bool(ds.get('hierarchicalDocumentSymbolSupport'))
        opts = p.get('initializationOptions') or {}
        hint = opts.get('tp7Dir') if isinstance(opts, dict) else None
        self.tp7_dir = hint or os.environ.get('TP7_DIR') or None
        bases = ([self.tp7_dir] if self.tp7_dir else []) + self.roots
        self.tpl = find_tpl(bases)
        stub_dir = (opts.get('stubDir') if isinstance(opts, dict) else None) or os.environ.get('TP7LS_STUB_DIR')
        self.stubs = StubStore(stub_dir or default_dir())
        self.index = ProjectIndex(self.roots)
        if isinstance(opts, dict) and isinstance(opts.get('inlayHints'), dict):
            self.inlay.update(opts['inlayHints'])
        self.type_checks = not (isinstance(opts, dict) and opts.get('typeDiagnostics') is False)
        wf = ((p.get('capabilities') or {}).get('workspace') or {}).get('didChangeWatchedFiles') or {}
        self.can_watch = bool(wf.get('dynamicRegistration'))
        self.initialized = True
        return {'capabilities': {'positionEncoding': 'utf-16',
                                 'textDocumentSync': {'openClose': True, 'change': 1, 'save': {'includeText': False}},
                                 'documentFormattingProvider': True,
                                 'definitionProvider': True,
                                 'declarationProvider': True,
                                 'documentSymbolProvider': True,
                                 'documentHighlightProvider': True,
                                 'hoverProvider': True,
                                 'inlayHintProvider': True,
                                 'selectionRangeProvider': True,
                                 'documentRangeFormattingProvider': True,
                                 'workspaceSymbolProvider': True,
                                 'codeActionProvider': {'codeActionKinds': ['quickfix', 'source.organizeImports']},
                                 'completionProvider': {'triggerCharacters': ['.'], 'resolveProvider': False},
                                 'signatureHelpProvider': {'triggerCharacters': ['(', ','], 'retriggerCharacters': [',']},
                                 'typeDefinitionProvider': True,
                                 'implementationProvider': True,
                                 'typeHierarchyProvider': True,
                                 'referencesProvider': True,
                                 'renameProvider': {'prepareProvider': True},
                                 'semanticTokensProvider': {'legend': {'tokenTypes': SEM_TYPES,
                                                                       'tokenModifiers': SEM_MODS},
                                                            'full': True, 'range': True}},
                'serverInfo': {'name': NAME, 'version': VERSION}}

    def on_initialized(self, p):
        if self.can_watch and self.roots:                         # tell us when a unit appears, goes or is renamed
            self.t.send({'jsonrpc': '2.0', 'id': 'tp7ls-watch', 'method': 'client/registerCapability', 'params': {
                'registrations': [{'id': 'tp7ls-files', 'method': 'workspace/didChangeWatchedFiles',
                                   'registerOptions': {'watchers': [{'globPattern': '**/*.{pas,PAS,tpu,TPU,inc,INC}'}]}}]}})
        if self.index is not None:
            self.index.refresh(force=True)
            log('project index: %d units, %d sources%s' % (len(self.index._units), len(self.index._sources),
                                                          ' (cut off at %d files)' % self.index.max_files if self.index.truncated else ''))
        if self.tpl:
            log('TURBO.TPL:', self.tpl)
        else:
            self.notify('window/showMessage', {
                'type': 2, 'message': 'tp7ls: TURBO.TPL not found - identifiers of System/Crt/Dos... keep their '
                                      'spelling. Set TP7_DIR or initializationOptions.tp7Dir.'})

    def on_shutdown(self, p):
        self.shutdown = True
        return None

    # -- documents -------------------------------------------------------------------------------------
    def on_textDocument_didOpen(self, p):
        td = p['textDocument']
        doc = Doc(td['uri'], td.get('version'), td.get('text', ''))
        self.docs[doc.uri] = doc
        self.pending.pop(doc.uri, None)
        self.publish(doc)
        self.refresh_dependents(doc, only_includes=True)         # an {$I} file now has the editor's text

    def on_textDocument_didChange(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            return
        for ch in p.get('contentChanges') or []:
            if 'range' in ch and ch['range'] is not None:
                raise RequestError(INVALID_PARAMS, 'incremental changes are not supported (full sync was announced)')
            doc.text = ch.get('text', '')
        doc.version = p['textDocument'].get('version', doc.version)
        self.schedule_diagnostics(doc)
        if UNIT_HEAD_RE.match(doc.text):                         # the units that use it see new names
            self.refresh_dependents(doc)
        else:                                                    # maybe an {$I} file of another open document
            self.refresh_dependents(doc, only_includes=True)

    def on_textDocument_didSave(self, p):
        doc = self.docs.get((p.get('textDocument') or {}).get('uri'))
        if doc is not None:
            self.refresh_dependents(doc, only_units=False)

    def on_workspace_didChangeWatchedFiles(self, p):
        if self.index is not None:
            self.index.invalidate()
        self.refresh_dependents(None)                            # something changed on disk: look at everything again

    def refresh_dependents(self, changed: Optional[Doc], only_units: bool = True, only_includes: bool = False):
        """Diagnose the open documents that may use the changed one (their text names it), or all of them.
        only_includes: just the ones that have it in an {$I} directive."""
        name = os.path.splitext(os.path.basename(changed.path or ''))[0] if changed is not None else None
        if only_includes:
            if not name:
                return
            pat = re.compile(r'[{(*]\$I(NCLUDE)?\s+[^}*]*' + re.escape(name), re.I)
        else:
            pat = re.compile(r'\b' + re.escape(name) + r'\b', re.I) if name else None
        for d in self.docs.values():
            if d is changed or self.is_stub(d.path):
                continue
            if pat is None or pat.search(d.text):
                self.schedule_diagnostics(d)

    def on_textDocument_didClose(self, p):
        uri = p['textDocument']['uri']
        self.pending.pop(uri, None)
        self.bound_cache.pop(uri, None)
        closed = self.docs.pop(uri, None)
        if closed is not None:
            self.notify('textDocument/publishDiagnostics', {'uri': uri, 'diagnostics': []})
            self.refresh_dependents(closed, only_includes=True)  # ... and is back to what is on the disk

    def is_stub(self, path: Optional[str]) -> bool:
        return self.stubs is not None and self.stubs.is_stub(path)

    INCLUDE_RE = re.compile(r'(?i)(\{|\(\*)\$I(NCLUDE)?\s+[^\s+\-,}*]')      # {$I file}: not {$I+} / {$I-}

    def semantic_diagnostics(self, doc: Doc, bound: Optional['Bound'] = None, prov: Optional[Provider] = None) -> List[dict]:
        """Meaning-level problems: units that cannot be found, and identifiers that are declared nowhere.  Names are
        reported only when the server can see everything the compiler sees: a missing or damaged unit, or a {$I file}
        include, could declare them, so then only the unit itself is reported.  Syntax errors turn this off too (a
        half-typed line makes every name after it unreliable)."""
        if prov is None:
            prov = self.provider_for(doc)
        if bound is None:
            bound = self.bind_doc(doc, prov)
        res, b = bound.res, bound.binder
        if res.diags:
            return []
        lines = bound.lines
        out = []

        def add(tok, severity, msg):
            out.append({'range': token_range(tok, lines), 'severity': severity, 'source': NAME, 'message': msg})
        for tok in b.missing_units:
            add(tok, 1, "unit '%s' not found: there is no %s.pas or %s.tpu in the search path (Turbo Pascal: file not found)"
                % (tok.text, tok.text, tok.text))
        for err in prov.errors:                                  # 'Name: ErrorType: text' of units that failed to load
            name = err.split(':', 1)[0].strip().lower()
            tok = next((t for t in res.sig if t.kind == 'IDENT' and t.text.lower() == name), None)
            if tok is not None and all(m is not tok for m in b.missing_units):
                add(tok, 2, "unit '%s' could not be read, so the names it declares are not checked (%s)"
                    % (tok.text, err.split(':', 1)[1].strip() if ':' in err else err))
        lost = [x for x in res.includes if len(x) == 2]            # {$I file} that could not be found (or loops)
        for tok, name in lost:
            add(tok, 1, "include file '%s' not found: there is no such file next to this one or in the search path "
                        "(Turbo Pascal: file not found)" % name.strip())
        included = bool(lost)                                      # its names are unknown: do not report any
        blind = bool(b.missing_units) or bool(prov.errors) or included
        if not blind:
            seen = set()
            for tok in b.unresolved:
                if id(tok) not in seen:
                    seen.add(id(tok))
                    add(tok, 1, ("label '%s' is not declared" if tok.kind == 'INT' else "unknown identifier '%s'") % tok.text)
        for tok, first in b.dups:
            if tok.text.lower() == first.name.lower() and first.tok is not None and first.tok is not tok:
                add(tok, 1, "duplicate identifier '%s' (first declared %s)" % (tok.text, (
                    'in %s, line %d' % (os.path.basename(first.tok.file), first.tok.line)) if first.tok.file
                    else 'on line %d' % first.tok.line))
        if self.type_checks and not blind:
            try:
                check_types(res, b, prov, lambda t, m: add(t, 1, m))
            except Exception:                                      # a type check must never take diagnostics down
                log('type check failed:\n' + traceback.format_exc())
        if not included:                                          # an include file could use anything
            for tid, sym in b.decls.items():
                if sym.kind == 'routine' and sym.tok is not None and id(sym.tok) == tid and not sym.lib \
                        and sym.tok.via is None \
                        and not getattr(sym, 'has_body', True) and sym.node is not None \
                        and not self.routine_has_no_body_by_design(sym.node):
                    what = 'method' if sym.owner is not None else 'routine'
                    add(sym.tok, 1 if sym.owner is not None else 2,
                        "%s '%s' is declared but has no implementation in this file" % (what, sym.name))
            out += self.unused_hints(doc, res, b, prov, lines)
        return out

    @staticmethod
    def routine_has_no_body_by_design(node) -> bool:
        """`external`, `inline`, and the like: the routine never has a Pascal body."""
        return any(t.kind == 'IDENT' and t.text.lower() in ('external', 'inline') or t.text.lower() in ('external', 'inline')
                   for t in node.tokens())

    @staticmethod
    def hidden_words(res, asm_nodes=None) -> set:
        """Lower-case words of the text the binder does not see: assembler blocks and inactive {$IFDEF} branches.  A name
        that appears there counts as used."""
        words = set()
        word = re.compile(r'[A-Za-z_]\w*')
        for tok in res.doc_sig:
            for t in tok.leading:
                if not t.active:
                    words.update(w.lower() for w in word.findall(t.text))
        if asm_nodes is None:
            asm_nodes = [n for n in res.tree.walk() if n.kind == 'Asm']
        for n in asm_nodes:
            toks = list(n.tokens())
            if toks:
                raw = res.source[toks[0].pos:toks[-1].pos + len(toks[-1].text)]
                words.update(w.lower() for w in word.findall(raw))
        return words

    def unused_hints(self, doc: Doc, res, b: Binder, prov: Provider, lines: List[str]) -> List[dict]:
        """Hints (greyed out in the editor) for what unused_items finds."""
        return [{'range': token_range(it['tok'], lines), 'severity': 4, 'tags': [1], 'source': NAME, 'message': it['msg']}
                for it in self.unused_items(doc, res, b, prov)]

    def unused_items(self, doc: Doc, res, b: Binder, prov: Provider) -> List[dict]:
        """[{'kind': var / const / type / unit, 'tok': declaring token (name in `uses`), 'msg', 'sym'}] of the variables,
        constants and types that nothing refers to, and of the units in `uses` that no name of the file comes from.
        Declarations that other files can see (the interface of a unit) are never reported."""
        bound = Bound(self.doc_key(doc), doc.uri, doc.text, res, b)
        uses_nodes, asm_nodes = [], []
        for n in res.tree.walk():                                 # one pass over the tree for everything below
            if n.kind == 'UsesClause':
                uses_nodes.append(n)
            elif n.kind == 'Asm':
                asm_nodes.append(n)
        hidden = self.hidden_words(res, asm_nodes)
        in_uses = {id(t) for n in uses_nodes for t in n.tokens()}
        used_syms, used_units, used_paths = set(), set(), set()
        for tid, sym in b.refs.items():
            if tid in b.decls or tid in in_uses:
                continue
            used_syms.add(id(sym))
            if sym.kind == 'unit':
                used_units.add(sym.name.lower())
            elif sym.lib and sym.home:
                used_units.add(sym.home.lower())
            elif sym.file:
                used_paths.add(path_key(sym.file))
        out = []
        used_enum_types = {id(sym.type_tok) for tid, sym in b.refs.items()
                           if sym.kind == 'enum' and sym.type_tok is not None and tid not in b.decls}

        def hint(tok, msg, kind, sym=None):
            out.append({'kind': kind, 'tok': tok, 'msg': msg, 'sym': sym})
        by_id = {id(t): t for t in res.sig if t.via is None}          # not the tokens of include files
        label = {'var': 'variable', 'const': 'constant', 'type': 'type'}
        for tid, sym in b.decls.items():
            tok = by_id.get(tid)
            if tok is None or sym.tok is not tok or sym.kind not in label or sym.implicit:
                continue
            if id(sym) in used_syms or sym.name.lower() in hidden or self.visible_outside(sym, bound):
                continue
            if sym.kind == 'type' and id(tok) in used_enum_types:        # the type is not named, but its members are used
                continue
            hint(tok, "%s '%s' is declared but never used" % (label[sym.kind], sym.name), sym.kind, sym)
        for n in uses_nodes:
            for nm in n.kids:
                if not isinstance(nm, Node) or nm.kind != 'Name' or not nm.kids:
                    continue
                tok = nm.kids[0]
                info = prov.get(tok.text)
                if info is None or info.name.lower() == 'system':
                    continue
                if info.name.lower() in used_units or (info.path and path_key(info.path) in used_paths):
                    continue
                if hidden & set(info.exports):                    # a name of the unit is used where the binder cannot see
                    continue
                hint(tok, "unit '%s' is not used: no name declared in it appears in this file" % info.name, 'unit')
        return out

    def diagnose(self, doc: Doc) -> List[dict]:
        if self.is_stub(doc.path):
            return []                                            # generated text: nothing to report
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)                          # one parse and one binding serve every feature
        diags = diagnostics_for(doc.text, bound.res)
        diags += self.inactive_hints(bound)
        try:
            diags += self.semantic_diagnostics(doc, bound, prov)
        except Exception as e:                                   # a bug in the analysis must not silence the syntax errors
            log('semantic diagnostics failed: %s: %s' % (type(e).__name__, e))
        return diags

    @staticmethod
    def inactive_hints(bound: 'Bound') -> List[dict]:
        """Hints (greyed out in the editor) for the code of the {$IFDEF} branches that are switched off.  One hint per
        stretch; the blank space at its ends is left out."""
        out, run = [], []

        def flush():
            while run and run[-1].kind in ('WS', 'NL'):
                run.pop()
            while run and run[0].kind in ('WS', 'NL'):
                run.pop(0)
            if run:
                a, b = token_range(run[0], bound.lines), token_range(run[-1], bound.lines)
                out.append({'range': {'start': a['start'], 'end': b['end']}, 'severity': 4, 'tags': [1], 'source': NAME,
                            'message': 'inactive code: this branch of the conditional compilation is switched off'})
            run.clear()
        for tok in bound.res.tokens:
            if tok.active or tok.kind == 'EOF':
                flush()
            else:
                run.append(tok)
        flush()
        return out

    def publish(self, doc: Doc):
        diags = self.diagnose(doc)
        self.notify('textDocument/publishDiagnostics', {'uri': doc.uri, 'version': doc.version, 'diagnostics': diags})

    # -- formatting ------------------------------------------------------------------------------------
    def provider_for(self, doc: Doc, include_self: bool = False, texts: Optional[Dict[str, str]] = None) -> Provider:
        dirs = []
        if doc.path and not self.is_stub(doc.path):               # a stub must not hide the library it describes
            dirs.append(os.path.dirname(doc.path))
        dirs.extend(self.roots)
        if self.tp7_dir:
            u = list_ci(self.tp7_dir, 'units')
            if u:
                dirs.append(u)
            dirs.append(self.tp7_dir)
        if self.tpl:
            tpl_dir = os.path.dirname(self.tpl)
            u = list_ci(os.path.dirname(tpl_dir), 'units') if os.path.basename(tpl_dir).lower() == 'bin' else None
            if u:
                dirs.append(u)
        seen, uniq = set(), []
        for d in dirs:
            k = os.path.normcase(os.path.abspath(d))
            if k not in seen:
                seen.add(k)
                uniq.append(d)
        overlay = {path_key(d.path): d.text for d in self.docs.values() if d.path and (include_self or d is not doc)}
        if texts:
            overlay.update(texts)
        key = (tuple(os.path.normcase(os.path.abspath(d)) for d in uniq), self.tpl,
               tuple(sorted((k, hash(v)) for k, v in overlay.items())))
        prov = self.provider_cache.get(key)                       # the units already loaded, if nothing they come from moved
        if prov is not None and prov.still_valid():
            self.provider_cache[key] = self.provider_cache.pop(key)
            return prov
        prov = Provider(uniq, self.tpl, index=self.index)
        prov.near = doc.path
        prov.overlay = overlay
        self.provider_cache[key] = prov
        while len(self.provider_cache) > 6:
            self.provider_cache.pop(next(iter(self.provider_cache)))
        return prov

    def format_text(self, doc: Doc) -> str:
        prov = self.provider_for(doc)
        out = format_source(doc.text, normalize=True, provider=prov)
        if prov.errors:
            log('units that could not be loaded:', '; '.join(prov.errors))
        if prov.warnings:
            log('unit loading notes:', '; '.join(prov.warnings))
        return out

    def on_textDocument_formatting(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        if self.is_stub(doc.path):
            return []                                                       # a generated stub is never reformatted
        try:
            new = self.format_text(doc)
        except FormatError as e:
            raise RequestError(REQUEST_FAILED, str(e))
        return compute_edits(doc.text, new)

    # -- stubs of units without source ------------------------------------------------------------------
    def stub_target(self, prov: Provider, sym):
        """(path, Stub, (line, column, length)) of the generated stub text that declares a symbol of a TPU / TURBO.TPL
        unit (or the unit itself); None for anything else."""
        if self.stubs is None or sym is None:
            return None
        if sym.kind == 'unit':
            info, kind, name, owner = sym.unit, 'unit', sym.name, None
        elif sym.lib and sym.home:
            info, kind, name, owner = prov.get(sym.home), sym.kind, sym.name, sym.stub_owner
        else:
            return None
        got = self.stubs.get(info) if info is not None else None
        if got is None:
            return None
        pos = got[1].find(kind, name, owner)
        return (got[0], got[1], pos) if pos is not None else None

    def stub_hover(self, prov: Provider, sym) -> Optional[str]:
        """Hover of a name from a TPU / System: its declaration as it is written in the generated stub."""
        t = self.stub_target(prov, sym)
        if t is None or sym.kind == 'unit':
            return None
        path, stub, (ln, col, length) = t
        block = stub.block(sym.kind, sym.name, sym.stub_owner)
        if not block:
            return None
        first = block[0]
        indent = len(first) - len(first.lstrip())
        member = sym.kind == 'const' and (col != indent or not first.lstrip().lower().startswith(sym.name.lower()))
        if member:
            owner = re.match(r'\s*(\w+)', first)
            text = 'const %s' % sym.name
            extra = '*constant of %s*' % (owner.group(1) if owner else 'an enumeration')
        else:
            text = '\n'.join(re.sub(r';(\s*\{[^{}]*\})?\s*$', r'\1', x[indent:].rstrip()) for x in block)
            text = {'const': 'const ', 'type': 'type ', 'var': 'var '}.get(sym.kind, '') + text
            extra = ''
            if sym.kind == 'field' and sym.stub_owner:
                extra = '*field of %s*' % sym.stub_owner
            elif sym.kind == 'routine' and re.search(r'\bP1\b', text):
                extra = '*parameter names are not stored in TPU files: P1, P2... are placeholders*'
            elif sym.kind == 'builtin':
                extra = '*built-in: the signature is informal*'
        unit = '*unit %s*' % sym.home if sym.home else ''
        return '```pascal\n%s\n```\n%s' % (text, ' · '.join(x for x in (unit, extra) if x))

    def stub_location(self, prov: Provider, sym):
        t = self.stub_target(prov, sym)
        if t is None:
            return None
        path, stub, (ln, col, length) = t
        return {'uri': pathlib.Path(os.path.abspath(path)).as_uri(),
                'range': {'start': {'line': ln, 'character': col}, 'end': {'line': ln, 'character': col + length}}}

    # -- go to declaration / definition ------------------------------------------------------------------
    # Declaration = where a name is declared: for a routine its header in `interface` (or the `forward` header), for
    # variables, constants, types, fields, parameters... the declaring identifier.  Definition = where it is implemented:
    # for a routine the header of its body in `implementation`; everything else has no separate implementation, so the
    # definition is the declaration.
    def locate(self, p, definition: bool):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        pos = p.get('position') or {}
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        res, lines, b = bound.res, bound.lines, bound.binder
        tok = ident_at(res.doc_sig, lines, pos.get('line', 0), pos.get('character', 0))
        if tok is None:
            return None
        if prov.errors:
            log('units that could not be loaded:', '; '.join(prov.errors))
        if prov.warnings:
            log('unit loading notes:', '; '.join(prov.warnings))
        sym = b.refs.get(id(tok)) or b.decls.get(id(tok))
        if sym is None:
            return None
        if sym.implicit:                                        # Self: the object type it stands for
            target = (sym.owner.file, sym.owner.tok) if sym.owner is not None and sym.owner.tok is not None else None
        elif sym.kind == 'unit':
            if not sym.file:
                return self.stub_location(prov, sym)            # a TPU / library unit: the top of its generated stub
            target = (sym.file, None)                           # the top of the unit's source
        elif sym.tok is None:
            return self.stub_location(prov, sym)                # TPU / System: no source, the generated stub
        elif definition and sym.kind in ('routine', 'label') and sym.impl_tok is not None:
            target = (sym.file, sym.impl_tok)
        else:
            target = (sym.file, sym.tok)
        if target is None:
            return None
        return self.location(doc, prov, lines, *target)

    def location(self, doc: Doc, prov: Provider, lines: List[str], path: Optional[str], dtok):
        """LSP Location of a token of this document (path None) or of another source file.  dtok None: top of the file."""
        if path is None:
            uri, dlines = doc.uri, lines
        else:
            try:
                dlines = NL_RE.split(prov.read_text(path))
            except OSError:
                return None
            uri = pathlib.Path(os.path.abspath(path)).as_uri()
        if dtok is None:
            rng = {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}
        else:
            rng = token_range(dtok, dlines, raw=path is not None)
        return {'uri': uri, 'range': rng}

    def on_textDocument_definition(self, p):
        return self.locate(p, True)

    def on_textDocument_declaration(self, p):
        return self.locate(p, False)

    # -- hover / type definition ----------------------------------------------------------------------
    def on_textDocument_hover(self, p):
        h = self.expr_hover(p)
        if h is not None:
            return h
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if sym is None:
            return None
        md = (self.stub_hover(prov, sym) if sym.lib and not sym.implicit else None) or hover_markdown(sym)
        if md is None:
            return None
        if sym.tok is not None and sym.file and path_key(sym.file) != bound.key:
            md += '\n*declared in %s, line %d*' % (os.path.basename(sym.file), sym.tok.line)
        return {'contents': {'kind': 'markdown', 'value': md}, 'range': token_range(tok, bound.lines)}

    def expr_hover(self, p):
        """Hover of an operator / bracket token: the expression it makes and its type (tp7types.expr_at)."""
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            return None
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        pos = p.get('position') or {}
        tok = token_under(bound.res.doc_sig, bound.lines, pos.get('line', 0), pos.get('character', 0))
        if tok is None or tok.kind not in ('SYM', 'KW'):
            return None
        got = expr_at(bound.res.tree, lambda t: bound.binder.refs.get(id(t)), prov, tok)
        if got is None:
            return None
        node, ty = got
        toks = list(node.tokens())
        inside = all(t.via is None and not t.file for t in toks)
        if inside:
            a, b = toks[0], toks[-1]
            text = ' '.join(bound.text[a.pos:b.pos + len(b.text)].split())
            if len(text) > 80:
                text = text[:79] + '\u2026'
            rng = {'start': token_range(a, bound.lines)['start'], 'end': token_range(b, bound.lines)['end']}
        else:
            text, rng = compact(toks), token_range(tok, bound.lines)
        code = '%s: %s' % (text, type_text(ty))
        if ty.kind == 'int' and ty.value is not None:
            code = '%s: %s = %d' % (text, const_type_name(ty), ty.value)
        md = '```pascal\n%s\n```' % code
        if ty is FLOAT:
            md += '\n*Extended in {$N+} code*'
        return {'contents': {'kind': 'markdown', 'value': md}, 'range': rng}

    def on_textDocument_completion(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        pos = p.get('position') or {}
        line, character = pos.get('line', 0), pos.get('character', 0)
        here = (line, character)
        lines = bound.lines
        for tok in bound.res.tokens:                                  # not inside a comment, a directive or a string
            if tok.kind in ('COMMENT', 'DIRECTIVE', 'STRING'):
                r = token_range(tok, lines)
                if (r['start']['line'], r['start']['character']) < here < (r['end']['line'], r['end']['character']):
                    return None
        before = []
        for tok in bound.res.doc_sig:
            r = token_range(tok, lines)['start']
            if (r['line'], r['character']) < here:
                before.append(tok)
            else:
                break
        word_end = None                                               # a name being typed is not part of the context
        if before and before[-1].kind == 'IDENT':
            r = token_range(before[-1], lines)['end']
            if (r['line'], r['character']) >= here:
                word_end = before.pop()
        prev = before[-1] if before else None
        scope = self.scope_at(bound, here)
        items = []
        if prev is not None and prev.text == '.':                     # Rec.|  Obj.|  Unit.|
            chain = member_chain(before[:-1])
            target = bound.binder.chain_type(chain, scope) if chain and scope is not None else None
            if isinstance(target, UnitInfo):
                members = target.exports
            elif target is not None and target.kind == 'record':
                members = target.get_fields()
            else:
                return None
            for key, sym in members.items():
                items.append(self.completion_item(sym, '0'))
            return {'isIncomplete': False, 'items': items}
        if prev is not None and prev.kind == 'KW' and prev.text.lower() in _NO_NAME_AFTER:
            return None                                               # the name of something being declared
        if prev is not None and prev.kind == 'KW' and prev.text.lower() == 'goto':        # goto |  : only labels
            sc = scope
            seen = set()
            while sc is not None:
                for key, sym in sc.table.items():
                    if sym.kind == 'label' and key not in seen:
                        seen.add(key)
                        items.append({'label': sym.name, 'kind': CK_REFERENCE, 'detail': 'label',
                                      'sortText': '%d%s' % (min(len(seen), 9), sym.name.lower())})
                sc = sc.parent
            return {'isIncomplete': False, 'items': items}
        ancestors = token_ancestors(bound.res.tree, prev) if prev is not None else []
        if scope is not None and in_type_position(prev, ancestors):             # only types (and what starts one)
            seen, depth, sc = set(), 0, scope
            while sc is not None:
                tables = ([u.exports for u in reversed(sc.units)] if sc.units else []) + [sc.table]
                for table in tables:
                    for key, sym in table.items():
                        if key not in seen and sym.kind in ('type', 'unit'):
                            seen.add(key)
                            items.append(self.completion_item(sym, str(min(depth, 8))))
                depth += 1
                sc = sc.parent
            extra = TYPE_STARTERS + (['object'] if ancestors[0].kind == 'TypeDecl' else [])
            items += [{'label': kw, 'kind': CK_KEYWORD, 'sortText': '9' + kw} for kw in extra]
            return {'isIncomplete': False, 'items': items}
        in_uses = self.in_uses_clause(bound, before)
        if in_uses:
            own = os.path.splitext(os.path.basename(doc.path or ''))[0].lower()
            for name in prov.unit_names():
                if name.lower() == own:
                    continue
                items.append({'label': name, 'kind': CK_MODULE, 'sortText': '0' + name.lower()})
            return {'isIncomplete': False, 'items': items}
        withs = self.with_fields(bound, prev, ancestors, scope) if scope is not None else []
        for rank, members in enumerate(withs):                         # the fields of `with R do`: innermost with first
            for key, sym in members.items():
                items.append(self.completion_item(sym, '0%d' % min(rank, 9)))
        if scope is not None:
            seen, depth = set(), 0
            sc = scope
            while sc is not None:
                tables = [sc.table]
                if sc.units is not None:
                    tables = [u.exports for u in reversed(sc.units)] + tables
                for table in tables:
                    for key, sym in table.items():
                        if key in seen or sym.kind == 'label':
                            continue
                        seen.add(key)
                        items.append(self.completion_item(sym, str(min(depth, 8))))
                depth += 1
                sc = sc.parent
        for kw in PAS_KEYWORDS:
            items.append({'label': kw, 'kind': CK_KEYWORD, 'sortText': '9' + kw})
        return {'isIncomplete': False, 'items': items}

    @staticmethod
    def with_fields(bound: Bound, prev, ancestors, scope) -> list:
        """[{name: field}] of the records named by the `with` statements the position is inside of, innermost first."""
        out = []
        for node in ancestors:
            if node.kind != 'With' or len(node.kids) < 3:
                continue
            do = node.kids[-2]
            if not isinstance(do, Token) or prev.idx < do.idx:          # in the list of records itself, not in the body
                continue
            for k in reversed(node.kids[1:-2]):                         # `with A, B do` = `with A do with B do`: B is the inner
                if isinstance(k, Node):
                    chain = member_chain(list(k.tokens()))
                    t = bound.binder.chain_type(chain, scope) if chain else None
                    if t is not None and not isinstance(t, UnitInfo) and t.kind == 'record':
                        out.append(t.get_fields())
        return out

    @staticmethod
    def completion_item(sym, group: str) -> dict:
        it = {'label': sym.name, 'kind': completion_kind(sym), 'sortText': group + sym.name.lower()}
        detail = completion_detail(sym)
        if detail:
            it['detail'] = detail
        return it

    @staticmethod
    def in_uses_clause(bound: Bound, before) -> bool:
        """Is the position inside `uses A, B|`?  (after the keyword and the commas, before the semicolon)"""
        for t in reversed(before):
            if t.text == ',' or t.kind == 'IDENT':
                continue
            return t.kind == 'KW' and t.text.lower() == 'uses'
        return False

    @staticmethod
    def scope_at(bound: Bound, here):
        """The innermost scope that holds the position: a routine, the implementation / interface part, the program."""
        best, best_size = None, None
        for node, sc in bound.binder.node_scopes:
            toks = list(node.tokens())
            if not toks:
                continue
            a = token_range(toks[0], bound.lines)['start']
            b = token_range(toks[-1], bound.lines)['end']
            lo, hi = (a['line'], a['character']), (b['line'], b['character'])
            if lo <= here <= hi:
                size = (hi[0] - lo[0], hi[1] - lo[1])
                if best is None or size < best_size:
                    best, best_size = sc, size
        return best

    def on_textDocument_inlayHint(self, p):
        """Grey notes inside the text: the names of parameters in calls, the types of constants declared without one, and the
        name of a long routine after its closing `end`."""
        doc = self.docs.get((p.get('textDocument') or {}).get('uri'))
        if doc is None or self.is_stub(doc.path):
            return []
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        if bound.res.diags:
            return []                                              # a half-typed line: the names are not reliable
        rng = p.get('range') or {}
        first = (rng.get('start') or {}).get('line', 0)
        last = (rng.get('end') or {}).get('line', 1 << 30)
        data = inlay_data(bound.res, bound.binder, prov)
        lines = bound.lines
        out = []

        def keep(pos):
            return first <= pos['line'] <= last
        o = self.inlay
        if o.get('parameters'):
            for tok, label in data['params']:
                pos = token_range(tok, lines)['start']
                if keep(pos):
                    out.append({'position': pos, 'label': label, 'kind': 2, 'paddingRight': True})
        if o.get('constants'):
            for tok, label in data['consts']:
                pos = token_range(tok, lines)['end']
                if keep(pos):
                    out.append({'position': pos, 'label': label, 'kind': 1})
        mn = o.get('endLabels')
        if mn:
            for tok, name, n in data['ends']:
                pos = token_range(tok, lines)['end']
                if n >= int(mn) and keep(pos):
                    out.append({'position': pos, 'label': ' { %s }' % name, 'paddingLeft': True})
        out.sort(key=lambda h: (h['position']['line'], h['position']['character']))
        return out

    def on_textDocument_signatureHelp(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        pos = p.get('position') or {}
        ctx = call_context(bound.res.doc_sig, bound.lines, pos.get('line', 0), pos.get('character', 0))
        if ctx is None:
            return None
        tok, index = ctx
        sym = bound.binder.refs.get(id(tok))
        if sym is None or sym.kind not in ('routine', 'builtin'):
            return None
        md = (self.stub_hover(prov, sym) if sym.lib and not sym.implicit else None) or hover_markdown(sym)
        m = re.match(r'```pascal\n(.*?)\n```\n?(.*)', md or '', re.S)
        if m is None:
            return None
        label = m.group(1).split('\n')[0].rstrip(';')
        params = signature_params(label)
        if not params:
            return None
        note = ' · '.join(x.strip() for x in m.group(2).split('\n') if x.strip())
        sig = {'label': label, 'parameters': [{'label': [a, b]} for a, b in params]}
        if note:
            sig['documentation'] = {'kind': 'markdown', 'value': note}
        if index >= len(params) and '...' in label:                  # Write(F, A, B, ...): the last one repeats
            index = len(params) - 1
        if index < len(params):
            sig['activeParameter'] = index
        return {'signatures': [sig], 'activeSignature': 0, 'activeParameter': index if index < len(params) else None}

    def on_textDocument_typeDefinition(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if sym is None:
            return None
        if sym.lib and not sym.implicit:                                            # TPU / System: through the stub
            if sym.kind == 'type':
                return self.stub_location(prov, sym)
            if sym.type_ref:
                u = prov.get(sym.type_ref[0])
                ts = u.exports.get(sym.type_ref[1].lower()) if u is not None else None
                return self.stub_location(prov, ts) if ts is not None and ts.lib else None
            return None
        if sym.implicit and sym.owner is not None and sym.owner.tok is not None:
            return self.location(doc, prov, bound.lines, sym.owner.file, sym.owner.tok)
        if sym.kind == 'type' and sym.tok is not None:
            return self.location(doc, prov, bound.lines, sym.file, sym.tok)         # a type: its own declaration
        if sym.kind == 'enum' and sym.type_tok is not None:
            return self.location(doc, prov, bound.lines, sym.file, sym.type_tok)
        if sym.tnode is None or sym.scope is None or sym.kind not in ('var', 'param', 'field', 'const', 'routine'):
            return None
        name = type_name_node(sym.tnode)
        if name is None:
            return None
        ts = bound.binder.type_sym(name, sym.scope)
        if ts is None:
            return None
        if ts.tok is None:
            return self.stub_location(prov, ts) if ts.lib else None                 # System / TPU type: its stub
        return self.location(doc, prov, bound.lines, ts.file, ts.tok)

    # -- implementation / type hierarchy (objects) -------------------------------------------------------
    def object_types(self, doc: Doc, prov: Provider, bound: Bound):
        """[(Bound, type symbol, ancestor symbol or None)] of every object type declared in this document and in the
        other sources of the workspace."""
        prov = self.provider_for(doc, include_self=True)
        out, seen = [], set()

        def collect(b: Bound):
            for s in list(b.binder.decls.values()):
                if s.kind == 'type' and s.tok is not None and object_node(s) is not None and \
                        path_key(s.file or b.key) == b.key:
                    k = sym_key(s, b.key)
                    if k not in seen:
                        seen.add(k)
                        out.append((b, s, ancestor_sym(b.binder, s)))
        collect(bound)
        for k, uri, text in self.candidates(doc):
            if 'object' in text.lower():
                res = parse(text)
                b = Binder(res, prov)
                b.run()
                collect(Bound(k, uri, text, res, b))
        return out

    @staticmethod
    def descendants(types, root_key):
        """[(Bound, type symbol)] of the object types that descend (directly or not) from the type with key `root_key`."""
        kids = {}
        for b, s, a in types:
            if a is not None:
                kids.setdefault(sym_key(a, b.key), []).append((b, s))
        out, todo, seen = [], [root_key], {root_key}
        while todo:
            for b, s in kids.get(todo.pop(), []):
                k = sym_key(s, b.key)
                if k not in seen:
                    seen.add(k)
                    out.append((b, s))
                    todo.append(k)
        return out

    def on_textDocument_implementation(self, p):
        """A virtual method: its own body and the bodies of every override in the descendants; any other method: its body;
        an object type: the types that descend from it; everything else: like `definition`."""
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if sym is None:
            return None
        if sym.implicit and sym.owner is not None:
            sym = sym.owner
        if sym.kind == 'type' and object_node(sym) is not None:
            subs = self.descendants(self.object_types(doc, prov, bound), sym_key(sym, bound.key))
            return [{'uri': b.uri, 'range': token_range(s.tok, b.lines)} for b, s in subs]
        if sym.kind == 'routine' and sym.owner is not None:
            out = []
            own = sym.impl_tok or sym.tok
            loc = self.location(doc, prov, bound.lines, sym.file, own) if own is not None else None
            if loc is not None:
                out.append(loc)
            if is_virtual(sym):
                name = sym.name.lower()
                for b, s in self.descendants(self.object_types(doc, prov, bound), sym_key(sym.owner, bound.key)):
                    ti = b.binder.type_ti(s)
                    m = ti.get_own().get(name) if ti is not None else None
                    if m is not None and m.kind == 'routine' and (m.impl_tok or m.tok) is not None:
                        out.append({'uri': b.uri, 'range': token_range(m.impl_tok or m.tok, b.lines)})
            return out
        return self.locate(p, True)

    def hierarchy_type(self, bound: Bound, sym):
        """The object type that a symbol stands for: the type itself, Self, a method's object, or the declared type of a
        variable / parameter / field / constant."""
        if sym is None:
            return None
        if sym.implicit:
            sym = sym.owner
        elif sym.kind == 'routine' and sym.owner is not None:
            sym = sym.owner
        elif sym.kind in ('var', 'param', 'field', 'const') and sym.tnode is not None and sym.scope is not None:
            name = type_name_node(sym.tnode)
            sym = bound.binder.type_sym(name, sym.scope) if name is not None else None
        return sym if object_node(sym) is not None and sym.tok is not None else None

    def hier_item(self, uri: str, lines: List[str], sym):
        rng = token_range(sym.tok, lines)
        her = next((x for x in object_node(sym).kids if isinstance(x, Node) and x.kind == 'Heritage'), None)
        return {'name': sym.name, 'kind': SK_CLASS, 'detail': 'object' + (compact(_tokens(her)) if her is not None else ''),
                'uri': uri, 'range': rng, 'selectionRange': rng}

    def on_textDocument_prepareTypeHierarchy(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        ts = self.hierarchy_type(bound, sym)
        if ts is None:
            return None
        if ts.file and path_key(ts.file) != bound.key:
            loc = self.location(doc, prov, bound.lines, ts.file, ts.tok)
            if loc is None:
                return None
            try:
                lines = NL_RE.split(prov.read_text(ts.file))
            except OSError:
                return None
            return [self.hier_item(loc['uri'], lines, ts)]
        return [self.hier_item(doc.uri, bound.lines, ts)]

    def item_type(self, item):
        """(doc, provider, Bound, type symbol) that a type hierarchy item stands for (its file need not be open)."""
        uri = (item or {}).get('uri')
        doc = self.docs.get(uri)
        if doc is None:
            path = uri_to_path(uri) if isinstance(uri, str) else None
            try:
                with open(path, 'rb') as f:
                    doc = Doc(uri, None, f.read().decode('cp866'))
            except (OSError, TypeError):
                raise RequestError(INVALID_PARAMS, 'cannot read %s' % uri)
        prov = self.provider_for(doc, include_self=True)
        bound = self.bind_doc(doc, prov)
        pos = (item.get('selectionRange') or {}).get('start') or {}
        tok = ident_at(bound.res.doc_sig, bound.lines, pos.get('line', 0), pos.get('character', 0))
        sym = bound.binder.decls.get(id(tok)) if tok is not None else None
        return doc, prov, bound, (sym if object_node(sym) is not None else None)

    def on_typeHierarchy_supertypes(self, p):
        doc, prov, bound, sym = self.item_type(p.get('item'))
        if sym is None:
            return []
        anc = ancestor_sym(bound.binder, sym)
        if anc is None or anc.tok is None or object_node(anc) is None:
            return []
        loc = self.location(doc, prov, bound.lines, anc.file, anc.tok)
        if loc is None:
            return []
        try:
            lines = bound.lines if anc.file is None or path_key(anc.file) == bound.key else NL_RE.split(prov.read_text(anc.file))
        except OSError:
            return []
        return [self.hier_item(loc['uri'], lines, anc)]

    def on_typeHierarchy_subtypes(self, p):
        doc, prov, bound, sym = self.item_type(p.get('item'))
        if sym is None:
            return []
        me = sym_key(sym, bound.key)
        out = []
        for b, s, a in self.object_types(doc, prov, bound):                      # direct children only
            if a is not None and sym_key(a, b.key) == me:
                out.append(self.hier_item(b.uri, b.lines, s))
        return out

    # -- references / highlight / rename ------------------------------------------------------------------
    def doc_key(self, doc: Doc) -> str:
        return path_key(doc.path) if doc.path else doc.uri

    def bind_doc(self, doc: Doc, prov: Provider) -> Bound:
        """Parse and bind the text of a document.  The result is kept for as long as the text and the provider (the world of
        units the names are looked up in) stay the same, so hover, highlight, completion and diagnostics of one version
        of the text share it."""
        got = self.bound_cache.get(doc.uri)
        if got is not None and got[0] is prov and got[1] == doc.text:
            return got[2]
        res = parse(doc.text, include=prov.include_resolver(doc.path), path=doc.path)
        b = Binder(res, prov)
        b.run()
        bound = Bound(self.doc_key(doc), doc.uri, doc.text, res, b)
        self.bound_cache[doc.uri] = (prov, doc.text, bound)
        return bound

    def candidates(self, doc: Doc):
        """[(key, uri, text)] of the other sources of the workspace: open buffers, then *.pas below the workspace folders."""
        out, seen = [], {self.doc_key(doc)}
        for d in self.docs.values():
            k = self.doc_key(d)
            if k not in seen and not self.is_stub(d.path):
                seen.add(k)
                out.append((k, d.uri, d.text))
        paths = self.index.sources() if self.index is not None else []
        if doc.path and not any(path_key(doc.path).startswith(path_key(r)) for r in self.roots):
            extra = ProjectIndex([os.path.dirname(doc.path)])               # a file outside the workspace: its folder tree
            paths = paths + extra.sources()
        for path in paths:
            k = path_key(path)
            if k in seen or self.is_stub(path):
                continue
            seen.add(k)
            try:
                if os.path.getsize(path) > MAX_SCAN_BYTES:
                    continue
                with open(path, 'rb') as f:
                    out.append((k, pathlib.Path(os.path.abspath(path)).as_uri(), f.read().decode('cp866')))
            except OSError:
                pass
        return out

    @staticmethod
    def visible_outside(sym, bound: Bound) -> bool:
        """Can another file see (and so use) this symbol?"""
        if sym.implicit:
            return False
        if sym.tok is None:
            return True
        if sym.kind in ('param', 'label'):
            return False
        if sym.file and path_key(sym.file) != bound.key:
            return True
        root = bound.res.tree.kids[0] if bound.res.tree.kids else None
        if root is None or root.kind != 'Unit':
            return False
        impl = next((x for x in root.kids if isinstance(x, Node) and x.kind == 'Implementation'), None)
        first = next(impl.tokens(), None) if impl is not None else None
        return first is None or sym.tok.idx < first.idx

    def symbol_at(self, p, prov_include_self: bool = False):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        pos = p.get('position') or {}
        tok = ident_at(bound.res.doc_sig, bound.lines, pos.get('line', 0), pos.get('character', 0))
        if tok is None:
            return doc, prov, bound, None, None, None
        sym = bound.binder.refs.get(id(tok)) or bound.binder.decls.get(id(tok))
        if sym is None and tok.kind == 'INT':
            return doc, prov, bound, None, None, None               # an ordinary number, not a label
        if sym is None:
            return doc, prov, bound, tok, None, None
        return doc, prov, bound, tok, sym, sym_key(sym, bound.key)

    def occurrences(self, doc: Doc, prov: Provider, bound: Bound, sym, key, extra_names=(), family=False):
        """{file key: (Bound, [(token, is declaring token)])} of every use of the symbol.  Files that do not contain the
        name (or one of extra_names) are not even parsed.  family=True (rename of a virtual method): the methods that
        override it or that it overrides count as the same symbol."""
        prov = self.provider_for(doc, include_self=True)          # other files that use this one see its unsaved text
        root = sym
        virtual = family and sym.kind == 'routine' and sym.owner is not None and is_virtual(sym)
        if virtual:
            root = virtual_chain(bound.binder, sym)[-1]
        scan = self.candidates(doc) if (self.visible_outside(sym, bound) or self.visible_outside(root, bound)) else []
        name = sym.name.lower()
        keys = self.family_keys(prov, bound, sym, root, scan, sym_key(root, bound.key)) if virtual else {key}
        out = {bound.key: (bound, [(t, d) for t, k, _, d in bound.keyed() if k in keys])}
        if not scan:
            return out
        for k, uri, text in scan:
            low = text.lower()
            if name not in low:
                continue
            res = parse(text)
            b = Binder(res, prov)
            b.run()
            other = Bound(k, uri, text, res, b)
            hits = [(t, d) for t, kk, _, d in other.keyed() if kk in keys]
            if hits:
                out[k] = (other, hits)
        return out

    def family_keys(self, prov, bound: Bound, sym, root, scan, root_key):
        """Keys of every virtual method with the name of `sym` whose chain of overridden methods ends in `root`."""
        keys = {root_key, sym_key(sym, bound.key)}
        name = sym.name.lower()

        def collect(b: Bound):
            for tok_id, m in b.binder.decls.items():
                if m.kind == 'routine' and m.owner is not None and m.name.lower() == name and is_virtual(m):
                    chain = virtual_chain(b.binder, m)
                    if sym_key(chain[-1], b.key) == root_key:
                        keys.update(sym_key(x, b.key) for x in chain)
        collect(bound)
        for k, uri, text in scan:
            if name in text.lower():
                res = parse(text)
                b = Binder(res, prov)
                b.run()
                collect(Bound(k, uri, text, res, b))
        return keys

    def on_textDocument_documentHighlight(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if key is None:
            return None
        writes = write_targets(bound.res)
        out = []
        for t, k, _, d in bound.keyed():
            if k == key:
                out.append({'range': token_range(t, bound.lines), 'kind': 3 if id(t) in writes else 1 if d else 2})
        return out

    def on_textDocument_references(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if key is None:
            return None
        include = bool((p.get('context') or {}).get('includeDeclaration', True))
        out = []
        for k, (b, hits) in sorted(self.occurrences(doc, prov, bound, sym, key).items(), key=lambda kv: kv[1][0].uri):
            for t, d in hits:
                if include or not d:
                    out.append({'uri': b.uri, 'range': token_range(t, b.lines)})
        if any(len(x) == 3 for x in bound.res.includes):          # uses (and the declaration) inside {$I} files
            bnd = bound.binder
            for t in bound.res.sig:
                if t.via is None or t.kind != 'IDENT':
                    continue
                decl = bnd.decls.get(id(t)) is sym
                if (bnd.refs.get(id(t)) is sym or decl) and (include or not decl):
                    loc = self.location(doc, prov, bound.lines, t.file, t)
                    if loc is not None:
                        out.append(loc)
        return out

    def renameable(self, tok, sym):
        if sym is None:
            raise RequestError(REQUEST_FAILED, 'cannot rename %s: it is not a declared name' % tok.text)
        if sym.kind == 'label' and sym.name.isdigit():
            raise RequestError(REQUEST_FAILED, 'cannot rename the numeric label %s' % sym.name)
        if sym.kind == 'unit':
            raise RequestError(REQUEST_FAILED, 'cannot rename the unit %s: that would mean renaming its file' % sym.name)
        if sym.implicit:
            raise RequestError(REQUEST_FAILED, 'cannot rename Self: it is the object a method works on')
        if sym.tok is None:
            raise RequestError(REQUEST_FAILED, 'cannot rename %s: it comes from a TPU / the standard library' % sym.name)

    @staticmethod
    def line_note(tok) -> str:
        """ ' (line 5)' or, for a token of an include file, ' (defs.inc, line 5)'."""
        if tok is None:
            return ''
        return ' (%s, line %d)' % (os.path.basename(tok.file), tok.line) if tok.file else ' (line %d)' % tok.line

    def check_includes_for_rename(self, bound: 'Bound', prov: Provider, sym, new: str):
        """Edits would have to be made inside {$I} files too, which is not done: say so instead of renaming half."""
        if sym.tok is not None and sym.tok.via is not None:
            raise RequestError(REQUEST_FAILED, '%s is declared in the include file %s: rename it there'
                               % (sym.name, os.path.basename(sym.file or '')))
        for x in bound.res.includes:
            if len(x) != 3:
                continue
            try:
                text = prov.read_text(x[2])
            except OSError:
                continue
            for word in (sym.name, new):
                if re.search(r'(?<![A-Za-z0-9_])' + re.escape(word) + r'(?![A-Za-z0-9_])', text, re.I):
                    raise RequestError(REQUEST_FAILED, 'cannot rename: %s also appears in the include file %s, and edits '
                                                       'inside include files are not made' % (word, os.path.basename(x[2])))

    def on_textDocument_prepareRename(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        if tok is None:
            return None
        self.renameable(tok, sym)
        return {'range': token_range(tok, bound.lines), 'placeholder': sym.name}

    def on_textDocument_rename(self, p):
        doc, prov, bound, tok, sym, key = self.symbol_at(p)
        new = p.get('newName') or ''
        prov = self.provider_for(doc, include_self=True)
        if tok is None:
            raise RequestError(REQUEST_FAILED, 'there is no identifier at this position')
        self.renameable(tok, sym)
        if not IDENT_RE.match(new) or new.lower() in RESERVED:
            raise RequestError(REQUEST_FAILED, '%r is not a valid identifier (or it is a reserved word)' % new)
        if sym.owner is not None and sym.kind in ('field', 'routine'):         # a member: its type and the ancestors
            ti = bound.binder.type_ti(sym.owner)
            clash = ti.get_fields().get(new.lower()) if ti is not None else None
            if clash is not None and clash is not sym and (clash.tok is None or clash.tok is not sym.tok):
                where = self.line_note(clash.tok)
                raise RequestError(REQUEST_FAILED, '%s is already a member of %s%s' % (new, sym.owner.name, where))
        elif sym.kind in ('var', 'const', 'type', 'routine', 'enum') and sym.scope is not None:
            clash = sym.scope.table.get(new.lower())
            if clash is not None and clash is not sym and (clash.tok is None or clash.tok is not sym.tok):
                where = self.line_note(clash.tok)
                raise RequestError(REQUEST_FAILED, '%s is already declared in this scope%s' % (new, where))
        self.check_includes_for_rename(bound, prov, sym, new)
        occ = self.occurrences(doc, prov, bound, sym, key, family=True)
        # sources that may see the new name too: they are checked as well
        edits = {k: (b, [t for t, _ in hits]) for k, (b, hits) in occ.items()}
        new_texts = {k: apply_token_edits(b.text, toks, new) for k, (b, toks) in edits.items()}
        watch = dict(occ)
        for k, uri, text in self.candidates(doc):
            if k not in watch and new.lower() in text.lower():
                res = parse(text, include=prov.include_resolver(k if os.path.isabs(k) else None),
                            path=k if os.path.isabs(k) else None)
                bb = Binder(res, prov)
                bb.run()
                watch[k] = (Bound(k, uri, text, res, bb), [])
        # bind everything again with the edited texts and compare what every identifier means
        paths = {k: new_texts.get(k, b.text) for k, (b, _) in watch.items()}
        prov2 = self.provider_for(doc, include_self=True, texts={k: t for k, t in paths.items() if os.path.isabs(k)})
        for k, (b, _) in watch.items():
            text2 = paths[k]
            res2 = parse(text2, include=prov2.include_resolver(k if os.path.isabs(k) else None),
                         path=k if os.path.isabs(k) else None)
            b2 = Binder(res2, prov2)
            b2.run()
            after = Bound(k, b.uri, text2, res2, b2)
            before = {t.idx: key_ for t, key_, _, _ in b.keyed()}
            now = {t.idx: key_ for t, key_, _, _ in after.keyed()}
            before_all = {t.idx: before.get(t.idx) for t in b.res.doc_sig if t.kind == 'IDENT'}
            now_all = {t.idx: now.get(t.idx) for t in res2.doc_sig if t.kind == 'IDENT'}
            for idx in sorted(set(before_all) | set(now_all)):
                if before_all.get(idx) != now_all.get(idx):
                    t = res2.tokens[idx]
                    raise RequestError(REQUEST_FAILED, 'renaming to %s would change the meaning of %s at %s:%d'
                                       % (new, t.text, os.path.basename(k) if os.path.isabs(k) else k, t.line))
        skipped = sum(1 for k, (b, _) in occ.items() for t in b.res.tokens
                      if not t.active and t.kind == 'IDENT' and t.text.lower() == sym.name.lower())
        if skipped:
            self.notify('window/showMessage', {'type': 2, 'message': 'tp7ls: %d occurrence(s) of %s in inactive {$IFDEF} '
                                                                     'branches were not renamed' % (skipped, sym.name)})
        changes = {}
        for k, (b, toks) in edits.items():
            changes.setdefault(b.uri, []).extend({'range': token_range(t, b.lines), 'newText': new} for t in toks)
        return {'changes': changes}

    # -- outline ---------------------------------------------------------------------------------------
    def on_textDocument_documentSymbol(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        symbols = document_symbols(doc.text)
        return symbols if self.hierarchical else flatten_symbols(symbols, doc.uri)

    # -- selection ranges / partial formatting / workspace symbols -------------------------------------------
    def on_textDocument_selectionRange(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        res = parse(doc.text)
        lines = NL_RE.split(doc.text)
        return [selection_range(res, lines, q.get('line', 0), q.get('character', 0)) for q in p.get('positions') or []]

    def on_textDocument_rangeFormatting(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        if self.is_stub(doc.path):
            return []
        try:
            new = self.format_text(doc)
        except FormatError as e:
            raise RequestError(REQUEST_FAILED, str(e))
        r = p.get('range') or {}
        first = (r.get('start') or {}).get('line', 0)
        end = r.get('end') or {}
        last = end.get('line', first)
        if end.get('character', 1) == 0 and last > first:
            last -= 1
        return range_edits(doc.text, new, first, last)

    def workspace_sources(self):
        """[(key, uri, stamp, loader)] of every source of the workspace: open buffers and *.pas below the roots.  The text of
        a file on disk is read only when its stamp (size, mtime) is new."""
        out, seen = [], set()
        for d in self.docs.values():
            if self.is_stub(d.path):
                continue
            k = self.doc_key(d)
            seen.add(k)
            out.append((k, d.uri, ('open', hash(d.text)), lambda d=d: d.text))
        for path in (self.index.sources() if self.index is not None else []):
            k = path_key(path)
            if k in seen or self.is_stub(path):
                continue
            seen.add(k)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_size > MAX_SCAN_BYTES:
                continue
            out.append((k, pathlib.Path(os.path.abspath(path)).as_uri(), (st.st_size, st.st_mtime_ns),
                        lambda path=path: open(path, 'rb').read().decode('cp866')))
        return out

    def on_workspace_symbol(self, p):
        query = (p.get('query') or '').lower()
        found = []
        for key, uri, stamp, load in self.workspace_sources():
            cached = self.symbol_cache.get(key)
            if cached is None or cached[0] != stamp:
                try:
                    symbols = flatten_symbols(document_symbols(load()), uri)
                except (OSError, UnicodeDecodeError, RecursionError):
                    symbols = []
                self.symbol_cache[key] = cached = (stamp, symbols)
            for sym in cached[1]:
                name = sym['name'].lower()
                base = re.split(r'[(:\s]', name, 1)[0]
                rank = 0 if base == query else 1 if base.startswith(query) else 2 if query in name else \
                    3 if is_subsequence(query, base) else None
                if rank is not None:
                    found.append((rank, base, sym))
        found.sort(key=lambda x: (x[0], x[1]))
        return [x[2] for x in found[:200]]

    # -- code actions -------------------------------------------------------------------------------------
    @staticmethod
    def uses_edit(res, lines, drop_ids: set) -> List[dict]:
        """Edits that take the names whose token ids are in drop_ids out of the `uses` clauses: a clause that loses all its
        names disappears, a clause that keeps some is rewritten without the others."""
        edits = []
        for n in res.tree.walk():
            if n.kind != 'UsesClause':
                continue
            names = [nm.kids[0] for nm in n.kids if isinstance(nm, Node) and nm.kind == 'Name' and nm.kids]
            gone = [t for t in names if id(t) in drop_ids]
            if not gone:
                continue
            keep = [t for t in names if id(t) not in drop_ids]
            if keep:
                edits.append(names_edit(lines, names, keep))
            else:
                a = token_range(_first_token(n), lines)['start']
                b = token_range(_last_token(n), lines)['end']
                edits.append({'range': whole_lines(lines, a, b), 'newText': ''})
        return edits

    @staticmethod
    def decl_edit(res, lines, tok) -> Optional[dict]:
        """Edit that removes the declaration of a variable, constant or type (the name `tok`): the whole declaration, the
        section keyword too when it was the only one, or only the name from `A, B: T`."""
        for sec in res.tree.walk():
            if sec.kind not in ('VarSection', 'ConstSection', 'TypeSection'):
                continue
            decls = [d for d in sec.kids if isinstance(d, Node)]
            for d in decls:
                names = [x.kids[0] for x in d.kids if isinstance(x, Node) and x.kind == 'DeclName' and x.kids]
                if not any(t is tok for t in names):
                    continue
                if len(names) > 1 and sec.kind == 'VarSection':
                    return names_edit(lines, names, [t for t in names if t is not tok])
                target = sec if len(decls) == 1 else d
                a = token_range(_first_token(target), lines)['start']
                b = token_range(_last_token(target), lines)['end']
                return {'range': whole_lines(lines, a, b), 'newText': ''}
        return None

    @staticmethod
    def implementation_stub(res, lines, sym, eol: str) -> Optional[dict]:
        """Edit that adds an empty implementation of a method / routine that is declared but has none, before the
        initialization part of a unit or the main block of a program."""
        node = sym.node
        if node is None or not node.kids:
            return None
        root = res.tree.kids[0] if res.tree.kids else None
        anchor = None
        if root is not None and root.kind == 'Unit':
            if not any(isinstance(x, Node) and x.kind == 'Implementation' for x in root.kids):
                return None
            init = next((x for x in root.kids if isinstance(x, Node) and x.kind == 'InitSection'), None)
            anchor = _first_token(init) if init is not None else None
        elif root is not None and root.kind == 'Program':
            block = next((x for x in root.kids if isinstance(x, Node) and x.kind == 'Block'), None)
            comp = next((x for x in block.kids if isinstance(x, Node) and x.kind == 'Compound'), None) if block else None
            anchor = _first_token(comp) if comp is not None else None
        if anchor is None:
            return None
        sig = compact(_signature(node), 300).replace(' :', ':')
        owner = sym.owner.name + '.' if sym.owner is not None else ''
        head = '%s %s%s%s;' % (node.kids[0].text.lower(), owner, sym.name,
                               sig if sig.startswith('(') else (' ' + sig if sig else ''))
        at = token_range(anchor, lines)['start']
        return {'range': {'start': at, 'end': at}, 'newText': eol.join([head, 'begin', 'end;', '', ''])}

    def on_textDocument_codeAction(self, p):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        if self.is_stub(doc.path):
            return []
        res = parse(doc.text)
        if res.diags:
            return []
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        res = bound.res                                          # the tree the binder worked on
        b, lines = bound.binder, bound.lines
        want = p.get('context', {}).get('only')
        rng = p.get('range') or {}
        lo = (rng.get('start', {}).get('line', 0), rng.get('start', {}).get('character', 0))
        hi = (rng.get('end', {}).get('line', 0), rng.get('end', {}).get('character', 0))

        def near(tok) -> bool:
            r = token_range(tok, lines)
            return lo <= _pos(r['end']) and _pos(r['start']) <= hi

        def allowed(kind: str) -> bool:
            return not want or any(kind == w or kind.startswith(w + '.') for w in want)

        def action(title, kind, edits, tok=None):
            diags = []
            if tok is not None:
                tr = token_range(tok, lines)
                diags = [d for d in p.get('context', {}).get('diagnostics') or [] if d.get('range') == tr]
            a = {'title': title, 'kind': kind, 'edit': {'changes': {doc.uri: edits}}}
            if diags:
                a['diagnostics'] = diags
            return a
        eol = '\r\n' if '\r\n' in doc.text else '\n'
        out = []
        included = any(len(x) == 2 for x in res.includes)
        if not included:
            items = self.unused_items(doc, res, b, prov)
            units = [it for it in items if it['kind'] == 'unit']
            if allowed('quickfix'):
                for it in items:
                    if not near(it['tok']):
                        continue
                    if it['kind'] == 'unit':
                        edits = self.uses_edit(res, lines, {id(it['tok'])})
                        out.append(action("Remove unused unit '%s'" % it['tok'].text, 'quickfix', edits, it['tok']))
                    else:
                        e = self.decl_edit(res, lines, it['tok'])
                        if e is not None:
                            out.append(action("Remove unused %s '%s'" % ({'var': 'variable', 'const': 'constant'}.get(it['kind'], it['kind']),
                                                              it['sym'].name), 'quickfix', [e], it['tok']))
            if units and allowed('source.organizeImports'):
                edits = self.uses_edit(res, lines, {id(it['tok']) for it in units})
                out.append(action('Remove unused units', 'source.organizeImports', edits))
        if allowed('quickfix'):
            blind = bool(b.missing_units) or bool(prov.errors) or included
            if not blind:
                import difflib
                for tok in b.unresolved:
                    if not near(tok):
                        continue
                    sc = self.scope_at(bound, (token_range(tok, lines)['start']['line'], token_range(tok, lines)['start']['character']))
                    names = {}
                    while sc is not None:
                        for tables in ([u.exports for u in sc.units] if sc.units else []) + [sc.table]:
                            for key, sym in tables.items():
                                names.setdefault(key, sym.name)
                        sc = sc.parent
                    for key in difflib.get_close_matches(tok.text.lower(), list(names), n=3, cutoff=0.7):
                        out.append(action("Change to '%s'" % names[key], 'quickfix',
                                          [{'range': token_range(tok, lines), 'newText': names[key]}], tok))
            for tid, sym in b.decls.items():
                if sym.kind == 'routine' and sym.tok is not None and id(sym.tok) == tid and not sym.lib \
                        and not getattr(sym, 'has_body', True) and sym.node is not None \
                        and sym.tok.via is None \
                        and not self.routine_has_no_body_by_design(sym.node) and near(sym.tok):
                    e = self.implementation_stub(res, lines, sym, eol)
                    if e is not None:
                        what = (sym.owner.name + '.' if sym.owner is not None else '') + sym.name
                        out.append(action("Add implementation of '%s'" % what, 'quickfix', [e], sym.tok))
        return out

    # -- semantic tokens -------------------------------------------------------------------------------
    def semantic(self, p, ranged: bool):
        doc = self.docs.get(p['textDocument']['uri'])
        if doc is None:
            raise RequestError(INVALID_PARAMS, 'document is not open: %s' % p['textDocument']['uri'])
        prov = self.provider_for(doc)
        bound = self.bind_doc(doc, prov)
        res, b = bound.res, bound.binder
        if prov.errors:
            log('units that could not be loaded:', '; '.join(prov.errors))
        if prov.warnings:
            log('unit loading notes:', '; '.join(prov.warnings))
        first, last = 0, None
        if ranged:
            r = p.get('range') or {}
            first = (r.get('start') or {}).get('line', 0)
            last = (r.get('end') or {}).get('line')
        return {'data': semantic_data(res, b, NL_RE.split(doc.text), first, last)}

    def on_textDocument_semanticTokens_full(self, p):
        return self.semantic(p, False)

    def on_textDocument_semanticTokens_range(self, p):
        return self.semantic(p, True)


def main(argv) -> int:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    # keep stdout exclusively for the protocol: anything that prints by accident goes to stderr
    sys.stdout = sys.stderr
    code = Server(Transport(stdin, stdout)).run()
    try:
        stdout.flush()
        sys.stderr.flush()
    finally:
        os._exit(code)                      # the reader thread may sit in a blocking read of stdin: do not wait for it


if __name__ == '__main__':
    sys.exit(main(sys.argv))
