#!/usr/bin/env python3
"""
tp7lex.py - lossless lexer for Turbo Pascal 7 (prototype, milestone M0).

Properties
  * LOSSLESS: ''.join(t.text for t in lex(src)) == src, for ANY input (bad input becomes ERROR tokens).
  * Trivia (whitespace, newlines, comments, directives) are ordinary tokens, so a formatter can
    re-emit or reshape them.  Use `significant()` to skip trivia.
  * Never raises.

TP7 specifics that differ from Delphi / Free Pascal (and are handled here):
  * comments are only  { ... }  and  (* ... *);  NO `//` comments (two '/' symbols);
    comments do not nest: `{ { }` ends at the first `}`; a `{` comment may contain `(*`, and vice versa
  * `{$...}` / `(*$...*)` are compiler directives (DIRECTIVE tokens), not comments
  * `(.` and `.)` are alternative spellings of `[` and `]`
  * `string` is a reserved word; absolute/far/near/forward/external/interrupt/virtual/... are NOT
    reserved (they lex as IDENT; the parser decides)
  * strings use apostrophes only, `''` is an escaped apostrophe, a string cannot span lines
  * `#13`, `#$0D` are character codes (CHARCODE); adjacent STRING/CHARCODE tokens form one literal
    (the parser joins them).  `^A` control literals are NOT recognised here: `^` is always a symbol
  * `@@name` is an assembler label (ASMLABEL); the body of `asm .. end` is lexed with the normal
    rules (the parser must take the raw text between `asm` and `end`)
  * a Ctrl-Z (0x1A) at the very end of a DOS source file is kept as a CTRLZ trivia token
Input is expected as `str`.  For cp866 files decode with  data.decode('cp866')  (one char per byte,
lossless); the language server will receive UTF-8 from the editor instead.
"""
import re
import sys
from dataclasses import dataclass, field
from typing import Iterator, List

RESERVED = frozenset('''and array asm begin case const constructor destructor div do downto else end
file for function goto if implementation in inherited inline interface label mod nil not object of or
packed procedure program record repeat set shl shr string then to type unit until uses var while with
xor'''.split())

TRIVIA = frozenset(['WS', 'NL', 'COMMENT', 'DIRECTIVE', 'CTRLZ'])

# kinds: WS NL COMMENT DIRECTIVE CTRLZ | IDENT KW INT HEX REAL STRING CHARCODE SYM ASMLABEL | ERROR EOF


@dataclass(slots=True)
class Token:
    kind: str
    text: str
    pos: int          # offset in characters
    line: int         # 1-based
    col: int          # 1-based, in characters
    # filled in by tp7parse.prepare(); they do not take part in equality or repr
    active: bool = field(default=True, repr=False, compare=False)    # False inside an inactive {$IFDEF} branch
    leading: object = field(default=(), repr=False, compare=False)  # trivia before this token (a list once parsed)
    idx: int = field(default=-1, repr=False, compare=False)          # index in Result.tokens (stable when names change)
    file: object = field(default=None, repr=False, compare=False)    # token of an {$I} include file: its path (else None)
    via: object = field(default=None, repr=False, compare=False)     # ... and the {$I} directive token that brought it in

    @property
    def lower(self) -> str:
        return self.text.lower()

    def __repr__(self):
        return '%s(%r)@%d:%d' % (self.kind, self.text, self.line, self.col)


_ws = re.compile(r'[ \t\f\v]+')
_nl = re.compile(r'\r\n|\r|\n')
_ident = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
_asmlabel = re.compile(r'@@[A-Za-z0-9_]+')
_hex = re.compile(r'\$[0-9A-Fa-f]+')
# real needs a digit after '.', so `1..10` is INT '..' INT; exponent only with digits
_real = re.compile(r'\d+\.\d+(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+')
_int = re.compile(r'\d+')
_charcode = re.compile(r'#(?:\$[0-9A-Fa-f]+|\d+)')
_string = re.compile(r"'(?:[^'\r\n]|'')*'")
_symbols = [':=', '<=', '>=', '<>', '..', '(.', '.)',
            '+', '-', '*', '/', '=', '<', '>', '[', ']', '.', ',', '(', ')', ':', ';', '^', '@']


def lex_reference(src: str) -> List[Token]:
    """The first, character-by-character lexer: slow, kept as the specification that lex() is tested against."""
    out: List[Token] = []
    i, n = 0, len(src)
    line, line_start = 1, 0

    def add(kind, text):
        out.append(Token(kind, text, i, line, i - line_start + 1))

    while i < n:
        c = src[i]
        m = None
        if c in ' \t\f\v':
            m = _ws.match(src, i)
            add('WS', m.group())
        elif c in '\r\n':
            m = _nl.match(src, i)
            add('NL', m.group())
            i += len(m.group())
            line += 1
            line_start = i
            continue
        elif c == '\x1a' and src[i + 1:].strip('\x1a\r\n \t') == '':
            add('CTRLZ', src[i:])                    # DOS end-of-file marker (and what follows it)
            for k, ch in enumerate(src[i:]):          # keep line numbers right for the tail
                if ch == '\n':
                    line += 1
                    line_start = i + k + 1
            i = n
            continue
        elif c == '{' or (c == '(' and src.startswith('(*', i)):
            close = '}' if c == '{' else '*)'
            start_len = 1 if c == '{' else 2
            e = src.find(close, i + start_len)
            text = src[i:] if e < 0 else src[i:e + len(close)]
            body = src[i + start_len:i + start_len + 1]
            kind = 'DIRECTIVE' if body == '$' else 'COMMENT'
            if e < 0:
                kind = 'ERROR'                       # unterminated comment: swallow to EOF, stay lossless
            add(kind, text)
            for k, ch in enumerate(text):
                if ch == '\n' or (ch == '\r' and text[k + 1:k + 2] != '\n'):
                    line += 1
                    line_start = i + k + 1
            i += len(text)
            continue
        elif c == "'":
            m = _string.match(src, i)
            if m:
                add('STRING', m.group())
            else:                                    # unterminated: up to end of line
                e = re.compile(r'[^\r\n]*').match(src, i)
                add('ERROR', e.group())
                i += len(e.group())
                continue
        elif c == '#':
            m = _charcode.match(src, i)
            if m:
                add('CHARCODE', m.group())
            else:
                add('ERROR', '#')
                i += 1
                continue
        elif '0' <= c <= '9':
            m = _real.match(src, i)
            if m:
                add('REAL', m.group())
            else:
                m = _int.match(src, i)
                add('INT', m.group())
        elif c == '$':
            m = _hex.match(src, i)
            if m:
                add('HEX', m.group())
            else:
                add('ERROR', '$')
                i += 1
                continue
        elif c == '@' and src.startswith('@@', i) and _asmlabel.match(src, i):
            m = _asmlabel.match(src, i)
            add('ASMLABEL', m.group())
        elif c == '_' or ('a' <= c <= 'z') or ('A' <= c <= 'Z'):
            m = _ident.match(src, i)
            add('KW' if m.group().lower() in RESERVED else 'IDENT', m.group())
        else:
            for s in _symbols:
                if src.startswith(s, i):
                    add('SYM', s)
                    i += len(s)
                    break
            else:
                add('ERROR', c)                      # any other character (incl. '"', '!', '?', '\\', '&', '%', non-ASCII)
                i += 1
            continue
        i += len(m.group())
    out.append(Token('EOF', '', n, line, n - line_start + 1))
    return out

_MASTER = re.compile(
    r"(?P<WS>[\x20\t\f\v]+)"
    r"|(?P<NL>\r\n|\r|\n)"
    r"|(?P<COMMENT>\{[^}]*\}|\(\*(?s:.*?)\*\))"
    r"|(?P<BADCOMMENT>\(\*)"
    r"|(?P<STRING>'(?:[^'\r\n]|'')*')"
    r"|(?P<CHARCODE>\#(?:\$[0-9A-Fa-f]+|[0-9]+))"
    r"|(?P<REAL>[0-9]+\.[0-9]+(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+)"
    r"|(?P<INT>[0-9]+)"
    r"|(?P<HEX>\$[0-9A-Fa-f]+)"
    r"|(?P<ASMLABEL>@@[A-Za-z0-9_]+)"
    r"|(?P<IDENT>[A-Za-z_][A-Za-z0-9_]*)"
    r"|(?P<SYM>:=|<=|>=|<>|\.\.|\(\.|\.\)|[-+*/=<>\[\].,():;^@])")


def lex(src: str) -> List[Token]:
    """Tokens of a source text, trivia included; same result as lex_reference(), several times faster (one regular
    expression decides the kind of every token; what it does not match is the rare broken input, handled one by one)."""
    out: List[Token] = []
    append = out.append
    match = _MASTER.match
    reserved = RESERVED
    i, n = 0, len(src)
    line, line_start = 1, 0
    while i < n:
        m = match(src, i)
        if m is None:
            c = src[i]
            if c == '{':                                       # unterminated comment: everything up to the end
                text = src[i:]
                kind = 'ERROR'
            elif c == "'":                                     # unterminated string: up to the end of the line
                text = re.compile(r'[^\r\n]*').match(src, i).group()
                kind = 'ERROR'
            elif c == '\x1a' and src[i + 1:].strip('\x1a\r\n \t') == '':
                text = src[i:]                                 # DOS end-of-file marker (and what follows it)
                kind = 'CTRLZ'
            else:                                              # '#' / '$' without digits, '"', '!', '?', '\\', non-ASCII...
                text = c
                kind = 'ERROR'
            append(Token(kind, text, i, line, i - line_start + 1))
            for k, ch in enumerate(text):
                if ch == '\n' or (ch == '\r' and kind != 'CTRLZ' and text[k + 1:k + 2] != '\n'):
                    line += 1                                  # (the tail after a Ctrl-Z counts only \n, like lex_reference)
                    line_start = i + k + 1
            i += len(text)
            continue
        kind = m.lastgroup
        text = m.group()
        col = i - line_start + 1
        if kind == 'IDENT':
            append(Token('KW' if text.lower() in reserved else 'IDENT', text, i, line, col))
        elif kind == 'WS' or kind == 'SYM':
            append(Token(kind, text, i, line, col))
        elif kind == 'NL':
            append(Token('NL', text, i, line, col))
            i += len(text)
            line += 1
            line_start = i
            continue
        elif kind == 'COMMENT' or kind == 'BADCOMMENT':
            if kind == 'BADCOMMENT':                           # `(*` that never closes
                text = src[i:]
                tk = 'ERROR'
            else:
                tk = 'DIRECTIVE' if text[1] == '$' or (text[0] == '(' and text[2] == '$') else 'COMMENT'
            append(Token(tk, text, i, line, col))
            if '\n' in text or '\r' in text:
                for k, ch in enumerate(text):
                    if ch == '\n' or (ch == '\r' and text[k + 1:k + 2] != '\n'):
                        line += 1
                        line_start = i + k + 1
        else:
            append(Token(kind, text, i, line, col))
        i += len(text)
    append(Token('EOF', '', n, line, n - line_start + 1))
    return out


def significant(tokens) -> Iterator[Token]:
    return (t for t in tokens if t.kind not in TRIVIA and t.kind != 'EOF')


def roundtrip_ok(src: str) -> bool:
    return ''.join(t.text for t in lex(src)) == src


def main(argv):
    if len(argv) < 2:
        print('usage: tp7lex.py FILE.PAS [--tokens|--sig|--check] [--enc cp866]')
        return 1
    enc = argv[argv.index('--enc') + 1] if '--enc' in argv else 'cp866'
    with open(argv[1], 'rb') as f:
        src = f.read().decode(enc)
    toks = lex(src)
    mode = next((a for a in argv[2:] if a in ('--tokens', '--sig', '--check')), '--check')
    if mode == '--check':
        bad = [t for t in toks if t.kind == 'ERROR']
        print('%d tokens, %d significant, %d errors, roundtrip %s' % (
            len(toks), len(list(significant(toks))), len(bad), 'OK' if roundtrip_ok(src) else 'BROKEN'))
        for t in bad[:20]:
            print('  ', t)
    else:
        for t in (toks if mode == '--tokens' else significant(toks)):
            print(t)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
