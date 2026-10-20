#!/usr/bin/env python3
"""Scratch verification for documentSymbol (not part of the suite): drives symbols_for directly and the
Server dispatch in-process (fake transport, no sample files needed)."""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tp7lsp import Server, Transport, symbols_for, RequestError, INVALID_PARAMS

KIND = {3: 'namespace', 8: 'field', 10: 'enum', 12: 'function', 13: 'variable', 14: 'constant',
        22: 'enumMember', 23: 'struct'}


def tree(syms, depth=0):
    out = []
    for s in syms:
        out.append((depth, s['name'], KIND[s['kind']], s.get('detail', '')))
        out += tree(s.get('children') or [], depth + 1)
    return out


def show(title, text):
    print('=' * 20, title, '=' * 20)
    for d, name, kind, detail in tree(symbols_for(text)):
        print('  ' * d + '%-14s %-10s %s' % (name, kind, ('[' + detail + ']') if detail else ''))
    print()


UNIT = ('unit Foo;\r\ninterface\r\ntype\r\n  TColor = (Red, Green, Blue);\r\n  TRec = record\r\n'
        '    Count: Integer;\r\n    Name: string[10];\r\n  end;\r\nconst\r\n  Limit = 10;\r\n'
        '  MaxLen: Integer = 100;\r\nvar\r\n  R: TRec;\r\n  A, B: Integer;\r\nprocedure Init;\r\n'
        'procedure DoWork(X: Integer; Y: string): Boolean;\r\nprocedure Local;\r\nimplementation\r\n'
        'procedure Init;\r\nvar Tmp: Integer;\r\nbegin\r\n  Tmp := 1;\r\nend;\r\n'
        'procedure DoWork(X: Integer; Y: string): Boolean;\r\nbegin\r\n  DoWork := True;\r\nend;\r\n'
        'procedure Local;\r\nbegin\r\nend;\r\nbegin\r\nend.\r\n')

PROG = ('program Demo;\nuses Crt;\nvar\n  N: Integer;\nprocedure Outer(P: Integer);\n'
        '  procedure Inner;\n  begin\n  end;\nbegin\n  Inner;\nend;\nbegin\n  N := 1;\nend.\n')

VARIANT = ('unit V;\ninterface\ntype\n  TTag = (Lo, Hi);\n  TV = record\n    Id: Integer;\n'
           '    case TTag of\n      Lo: (A: Integer; B: Byte);\n      Hi: (C: string);\n  end;\n'
           'implementation\nend.\n')

OBJ = ('unit U;\ninterface\ntype\n  TFoo = object\n    X: Integer;\n  end;\nconstructor TFoo.Create;\n'
       'destructor TFoo.Destroy;\nimplementation\nconstructor TFoo.Create; begin end;\n'
       'destructor TFoo.Destroy; begin end;\nend.\n')

BROKEN = 'unit B;\ninterface\ntype\n  T = record\n    X: \nimplementation\n???;\nend.\n'


def check(name, cond):
    print('%-72s %s' % (name, 'OK' if cond else 'FAIL'))
    if not cond:
        sys.exit(1)


# ---------------------------------------------------------------- direct symbols_for
show('unit', UNIT)
u = symbols_for(UNIT)[0]
check('unit top is one Namespace', u['name'] == 'Foo' and u['kind'] == 3)
check('unit children names', [s['name'] for s in u['children']] ==
      ['TColor', 'TRec', 'Limit', 'MaxLen', 'R', 'A', 'B', 'Init', 'DoWork', 'Local'])
by = {s['name']: s for s in u['children']}
check('kinds', [KIND[by[n]['kind']] for n in ('TColor', 'TRec', 'Limit', 'R', 'Init')] ==
      ['enum', 'struct', 'constant', 'variable', 'function'])
check('enum members', [s['name'] for s in by['TColor']['children']] == ['Red', 'Green', 'Blue'])
check('enum member kind', all(s['kind'] == 22 for s in by['TColor']['children']))
check('record fields', [s['name'] for s in by['TRec']['children']] == ['Count', 'Name'])
check('field detail', by['TRec']['children'][0].get('detail') == 'Integer'
      and by['TRec']['children'][1].get('detail') == 'string[10]')
check('type detail', by['TRec'].get('detail') == 'record')
check('const details', by['Limit'].get('detail') == '10' and by['MaxLen'].get('detail') == 'Integer = 100')
check('var details', by['R'].get('detail') == 'TRec' and by['A'].get('detail') == 'Integer')
check('Init merged into one, body range lines 18..22',
      by['Init']['range']['start']['line'] == 18 and by['Init']['range']['end']['line'] == 22)
sel = by['Init']['selectionRange']
check('Init selectionRange exact',
      sel == {'start': {'line': 18, 'character': 10}, 'end': {'line': 18, 'character': 14}})
check('Init local var child', [s['name'] for s in by['Init']['children']] == ['Tmp']
      and by['Init']['children'][0].get('detail') == 'Integer')
check('DoWork detail', by['DoWork'].get('detail') == '(X: Integer; Y: string): Boolean')
check('DoWork params', [(s['name'], s.get('detail')) for s in by['DoWork']['children']] ==
      [('X', 'Integer'), ('Y', 'string')])
check('DoWork merged range', by['DoWork']['range']['start']['line'] == 23)
check('Local merged range', by['Local']['range']['start']['line'] == 27 and not by['Local'].get('children'))
check('unit selection', u['selectionRange']['start'] == {'line': 0, 'character': 5}
      and u['selectionRange']['end'] == {'line': 0, 'character': 8})
check('unit range to final dot', u['range']['end'] == {'line': 31, 'character': 4})

show('program', PROG)
p = symbols_for(PROG)[0]
check('program top', p['name'] == 'Demo' and p['kind'] == 3)
check('program children', [s['name'] for s in p['children']] == ['N', 'Outer'])
outer = p['children'][1]
check('Outer detail', outer.get('detail') == '(P: Integer)')
check('Outer children', [(s['name'], KIND[s['kind']]) for s in outer['children']] ==
      [('P', 'variable'), ('Inner', 'function')])

show('variants', VARIANT)
v = symbols_for(VARIANT)[0]
tv = {s['name']: s for s in v['children']}['TV']
check('TV children', [s['name'] for s in tv['children']] == ['Id', 'case TTag'])
case = tv['children'][1]
check('case detail', case.get('detail') == 'TTag' and KIND[case['kind']] == 'struct')
check('arms', [(s['name'], KIND[s['kind']], [c['name'] for c in s.get('children', [])])
               for s in case['children']] ==
      [('Lo', 'enumMember', ['A', 'B']), ('Hi', 'enumMember', ['C'])])

show('object/constructor', OBJ)
o = symbols_for(OBJ)[0]
on = {s['name']: s for s in o['children']}
check('constructor names', 'TFoo.Create' in on and 'TFoo.Destroy' in on)
check('constructor merged', on['TFoo.Create']['range']['start']['line'] == 9
      and on['TFoo.Create']['selectionRange'] == {'start': {'line': 9, 'character': 17},
                                                  'end': {'line': 9, 'character': 23}})
check('object type struct', on['TFoo']['kind'] == 23)

show('broken', BROKEN)
b = symbols_for(BROKEN)
check('broken unit still listed', len(b) == 1 and b[0]['name'] == 'B')
bt = {s['name']: s for s in b[0]['children']}
check('broken type kept, no crash', 'T' in bt and 'X' in {s['name'] for s in bt['T'].get('children', [])})
check('empty file -> []', symbols_for('') == [])
g = symbols_for('? @ # $ % ^ & *\n\n')
# the tolerant parser reads any file as a program: one fallback symbol, no children, no crash
check('garbage -> one nameless-header program symbol',
      len(g) == 1 and g[0]['name'] == 'program' and g[0]['kind'] == 3 and not g[0].get('children'))

# ---------------------------------------------------------------- in-process dispatch
class FakeTransport(Transport):
    def __init__(self):
        self.out = []

    def read(self):
        return None

    def send(self, msg):
        self.out.append(msg)


def run_server():
    t = FakeTransport()
    s = Server(t)
    s.initialized = False
    s.dispatch({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                'params': {'processId': None, 'rootUri': None, 'capabilities': {}, 'workspaceFolders': None}})
    s.dispatch({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
    s.docs['file:///x/foo.pas'] = type('D', (), {'uri': 'file:///x/foo.pas', 'version': 1,
                                                 'text': UNIT, 'path': None})()
    s.dispatch({'jsonrpc': '2.0', 'id': 2, 'method': 'textDocument/documentSymbol',
                'params': {'textDocument': {'uri': 'file:///x/foo.pas'}}})
    s.dispatch({'jsonrpc': '2.0', 'id': 3, 'method': 'textDocument/documentSymbol',
                'params': {'textDocument': {'uri': 'file:///x/nope.pas'}}})
    return t


t = run_server()
by_id = {m['id']: m for m in t.out if 'id' in m}
check('capability announced', by_id[1]['result']['capabilities'].get('documentSymbolProvider') is True)
check('dispatched result matches symbols_for', by_id[2]['result'] == symbols_for(UNIT))
check('unopened doc -> -32602', by_id[3]['error']['code'] == INVALID_PARAMS)
json.dumps(t.out)  # everything is JSON-serializable

# ---------------------------------------------------------------- fuzz
rnd = random.Random(7)
pieces = ['unit A;\n', 'interface\n', 'implementation\n', 'end.\n', 'procedure P(', '): Integer;',
          'begin', 'end;', 'var X: Integer;', 'type T = record', 'case Q of', '1: (A: Integer);',
          'constructor T.M;', '{ c }', '(* c *)', '{$IFDEF X}', '??', '\U0001F600', 'string[3]',
          'array[1..9] of Byte', '']
for i in range(3000):
    src = ''.join(rnd.choice(pieces) for _ in range(rnd.randint(0, 12)))
    try:
        syms = symbols_for(src)
    except Exception as e:
        print('FUZZ CRASH:', repr(src), e)
        sys.exit(1)

    def wellformed(s, depth):
        assert isinstance(s['name'], str) and s['name'], (src, s)
        assert s['kind'] in KIND, (src, s)
        for r in (s['range'], s['selectionRange']):
            assert r['start']['line'] <= r['end']['line'] and (
                r['start']['line'] < r['end']['line'] or r['start']['character'] <= r['end']['character']), (src, s)
        for c in s.get('children', []):
            wellformed(c, depth + 1)
    for s in syms:
        wellformed(s, 0)
print('fuzz: 3000 random sources, no crash, all symbols well-formed')
print()
print('ALL CHECKS PASSED')
