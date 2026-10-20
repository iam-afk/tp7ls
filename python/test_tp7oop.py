#!/usr/bin/env python3
"""Protocol tests of tp7lsp.py for object types and methods (the server runs as a subprocess).
Run: python3 test_tp7oop.py [DIR_WITH_SAMPLES]   (DIR must contain TURBO.TPL and GRAPH.TPU, like test_tp7lsp.py)"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tp7lsp import Base, Definition, apply_edits, uri          # noqa: E402

SRC = ('program a;\n'
       'uses Crt;\n'
       'type\n'
       '  PShape = ^TShape;\n'
       '  TShape = object\n'
       '    X, Y: Integer;\n'
       '    constructor Init(AX, AY: Integer);\n'
       '    procedure Draw; virtual;\n'
       '  end;\n'
       '  PCircle = ^TCircle;\n'
       '  TCircle = object(TShape)\n'
       '  private\n'
       '    R: Integer;\n'
       '  public\n'
       '    constructor Init(AX, AY, AR: Integer);\n'
       '    procedure Draw; virtual;\n'
       '  end;\n'
       'var\n'
       '  C: TCircle;\n'
       '  P: PCircle;\n'
       '\n'
       'constructor TShape.Init(AX, AY: Integer);\n'
       'begin\n'
       '  X := AX;\n'
       '  Y := AY;\n'
       'end;\n'
       '\n'
       'procedure TShape.Draw;\n'
       'begin\n'
       "  WriteLn(X, ' ', Y);\n"
       'end;\n'
       '\n'
       'constructor TCircle.Init(AX, AY, AR: Integer);\n'
       'begin\n'
       '  inherited Init(AX, AY);\n'
       '  R := AR;\n'
       'end;\n'
       '\n'
       'procedure TCircle.Draw;\n'
       'begin\n'
       '  inherited Draw;\n'
       '  WriteLn(Self.R, X);\n'
       'end;\n'
       '\n'
       'begin\n'
       '  C.Init(1, 2, 3);\n'
       '  C.Draw;\n'
       '  New(P, Init(4, 5, 6));\n'
       '  P^.Draw;\n'
       'end.\n')

pos = Definition.pos


def span(loc):
    r = loc['range']
    return (r['start']['line'], r['start']['character'], r['end']['line'], r['end']['character'])


def at(src, needle, nth=0, off=0, length=None):
    """(line, col, line, col + length) of `length` characters at needle+off; the default length is the identifier."""
    p = pos(src, needle, nth, off)
    if length is None:
        i = src.index(needle) if nth == 0 else None
        line = src.split('\n')[p['line']]
        j = p['character']
        k = j
        while k < len(line) and (line[k].isalnum() or line[k] == '_'):
            k += 1
        length = k - j
    return (p['line'], p['character'], p['line'], p['character'] + length)


class ObjectProtocol(Base):
    def proj(self, files=None):
        d = tempfile.mkdtemp(prefix='oop_', dir=self.tmp)
        for name, text in (files or {}).items():
            self.write(name, text, root=d)
        return d

    def ask(self, c, method, u, src, needle, nth=0, off=0, **extra):
        params = {'textDocument': {'uri': u}, 'position': pos(src, needle, nth, off)}
        params.update(extra)
        return c.request('textDocument/' + method, params)

    def open_single(self, src=SRC):
        d = self.proj()
        c = self.start(root=d)
        return d, c, c.open(os.path.join(d, 'a.pas'), src)

    # -- diagnostics ------------------------------------------------------------------------------------
    def test_object_code_has_no_diagnostics(self):
        d, c, u = self.open_single()
        m = c.wait_for('textDocument/publishDiagnostics', lambda m: m['params']['uri'] == u)
        self.assertEqual([x for x in m['params']['diagnostics'] if x['severity'] < 4], [])

    # -- definition / declaration -----------------------------------------------------------------------
    def test_call_goes_to_the_implementation_and_the_declaration(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'definition', u, SRC, 'C.Draw', 0, 2)['result']
        self.assertEqual(span(r), at(SRC, 'procedure TCircle.Draw', 0, len('procedure TCircle.')))
        r = self.ask(c, 'declaration', u, SRC, 'C.Draw', 0, 2)['result']
        self.assertEqual(span(r), at(SRC, 'procedure Draw; virtual;', 1, len('procedure ')))

    def test_inherited_goes_to_the_ancestor(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'definition', u, SRC, 'inherited Draw', 0, len('inherited '))['result']
        self.assertEqual(span(r), at(SRC, 'procedure TShape.Draw', 0, len('procedure TShape.')))
        r = self.ask(c, 'definition', u, SRC, 'inherited Init', 0, len('inherited '))['result']
        self.assertEqual(span(r), at(SRC, 'constructor TShape.Init', 0, len('constructor TShape.')))

    def test_ancestor_field_used_in_a_descendant_method(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'definition', u, SRC, 'WriteLn(Self.R, X)', 0, len('WriteLn(Self.R, '))['result']
        self.assertEqual(span(r), at(SRC, '    X, Y: Integer;', 0, 4))

    def test_the_header_of_an_implementation_goes_both_ways(self):
        d, c, u = self.open_single()
        # declaration inside the object <- from the T.M header
        r = self.ask(c, 'declaration', u, SRC, 'procedure TShape.Draw', 0, len('procedure TShape.'))['result']
        self.assertEqual(span(r), at(SRC, 'procedure Draw; virtual;', 0, len('procedure ')))
        # the owner name in the header is a reference to the type
        r = self.ask(c, 'definition', u, SRC, 'procedure TShape.Draw', 0, len('procedure '))['result']
        self.assertEqual(span(r), at(SRC, 'TShape = object', 0, 0))

    def test_self_goes_to_its_type(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'definition', u, SRC, 'Self.R')['result']
        self.assertEqual(span(r), at(SRC, 'TCircle = object', 0, 0))
        r = self.ask(c, 'typeDefinition', u, SRC, 'Self.R')['result']
        self.assertEqual(span(r), at(SRC, 'TCircle = object', 0, 0))

    def test_constructor_in_new_belongs_to_the_pointed_to_object(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'declaration', u, SRC, 'New(P, Init', 0, len('New(P, '))['result']
        self.assertEqual(span(r), at(SRC, 'constructor Init(AX, AY, AR', 0, len('constructor ')))

    def test_type_definition_of_an_object_variable_and_a_pointer(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'typeDefinition', u, SRC, 'C.Draw')['result']
        self.assertEqual(span(r), at(SRC, 'TCircle = object', 0, 0))
        r = self.ask(c, 'typeDefinition', u, SRC, 'P^.Draw')['result']
        self.assertEqual(span(r), at(SRC, 'PCircle = ^TCircle', 0, 0))

    # -- hover ------------------------------------------------------------------------------------------
    def hover(self, c, u, needle, nth=0, off=0):
        r = self.ask(c, 'hover', u, SRC, needle, nth, off)
        self.assertNotIn('error', r, r)
        return r['result']['contents']['value']

    def test_hover_on_methods_fields_self_and_object_types(self):
        d, c, u = self.open_single()
        v = self.hover(c, u, 'C.Draw', 0, 2)
        self.assertIn('procedure TCircle.Draw; virtual', v)
        self.assertIn('*method of TCircle*', v)
        v = self.hover(c, u, 'C.Init', 0, 2)
        self.assertIn('constructor TCircle.Init(AX, AY, AR: Integer)', v)
        v = self.hover(c, u, 'WriteLn(Self.R, X)', 0, len('WriteLn(Self.R, '))
        self.assertIn('X: Integer', v)
        self.assertIn('*field of TShape*', v)
        v = self.hover(c, u, 'Self.R')
        self.assertIn('Self: TCircle', v)
        v = self.hover(c, u, 'TCircle = object')
        for line in ('type TCircle = object(TShape)', '\nprivate\n', '  R: Integer;', '\npublic\n',
                     '  constructor Init(AX, AY, AR: Integer);', '  procedure Draw; virtual;', 'end'):
            self.assertIn(line, v)

    # -- outline ----------------------------------------------------------------------------------------
    def test_outline(self):
        d, c, u = self.open_single()
        r = c.request('textDocument/documentSymbol', {'textDocument': {'uri': u}})['result']
        top = r[0]['children']
        names = [x['name'] for x in top]
        self.assertEqual(names, ['PShape', 'TShape', 'PCircle', 'TCircle', 'C', 'P', 'TShape.Init', 'TShape.Draw',
                                 'TCircle.Init', 'TCircle.Draw'])
        by = {x['name']: x for x in top}
        self.assertEqual(by['TShape']['kind'], 5)                                          # class
        self.assertEqual(by['TCircle']['detail'], 'object(TShape)')
        self.assertEqual([(x['name'], x['kind']) for x in by['TCircle']['children']],
                         [('R', 8), ('Init', 9), ('Draw', 6)])                               # field, constructor, method
        self.assertEqual(by['TShape.Init']['kind'], 9)
        self.assertEqual(by['TShape.Draw']['kind'], 6)
        for x in top:
            for ch in x.get('children') or []:
                self.assertTrue(span({'range': x['range']})[0] <= span({'range': ch['range']})[0])
        s = by['TShape.Draw']
        self.assertEqual(span({'range': s['selectionRange']}), at(SRC, 'procedure TShape.Draw', 0, len('procedure TShape.')))

    # -- semantic tokens ----------------------------------------------------------------------------------
    def test_semantic_tokens(self):
        d, c, u = self.open_single()
        data = c.request('textDocument/semanticTokens/full', {'textDocument': {'uri': u}})['result']['data']
        types = ['namespace', 'type', 'enumMember', 'function', 'parameter', 'variable', 'property', 'label',
                 'comment', 'macro', 'keyword', 'method']
        out, line, col = {}, 0, 0
        for i in range(0, len(data), 5):
            dl, ds, n, t, m = data[i:i + 5]
            line += dl
            col = ds if dl else col + ds
            out[(line, col)] = (n, types[t], m)
        p = pos(SRC, 'C.Draw', 0, 2)
        self.assertEqual(out[(p['line'], p['character'])][1], 'method')
        p = pos(SRC, 'procedure Draw; virtual;', 0, len('procedure '))
        self.assertEqual(out[(p['line'], p['character'])][1:], ('method', 1))                 # declaration
        p = pos(SRC, 'inherited Draw')
        self.assertEqual(out[(p['line'], p['character'])][1], 'keyword')
        p = pos(SRC, '  private')
        self.assertEqual(out[(p['line'], p['character'] + 2)][1], 'keyword')
        p = pos(SRC, 'Self.R')
        self.assertEqual(out[(p['line'], p['character'])][1], 'parameter')
        p = pos(SRC, 'Self.R', 0, 5)
        self.assertEqual(out[(p['line'], p['character'])][1], 'property')
        p = pos(SRC, 'virtual;')
        self.assertEqual(out[(p['line'], p['character'])][1], 'keyword')

    # -- references / rename ------------------------------------------------------------------------------
    def test_references_of_a_method_cover_declaration_implementation_and_calls(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'references', u, SRC, 'C.Draw', 0, 2, context={'includeDeclaration': True})['result']
        got = sorted(span(x) for x in r)
        want = sorted([at(SRC, 'procedure Draw; virtual;', 1, len('procedure ')),
                       at(SRC, 'procedure TCircle.Draw', 0, len('procedure TCircle.')),
                       at(SRC, 'C.Draw', 0, 2), at(SRC, 'P^.Draw', 0, 3)])
        self.assertEqual(got, want)

    def test_references_of_an_ancestor_field_include_implicit_uses(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'references', u, SRC, '    X, Y: Integer;', 0, 4, context={'includeDeclaration': True})['result']
        lines = sorted(x['range']['start']['line'] for x in r)
        self.assertEqual(lines, [5, 23, 29, 41])          # declaration, X := AX, WriteLn(X, ...), WriteLn(Self.R, X)

    def test_rename_a_method_everywhere(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'rename', u, SRC, 'C.Draw', 0, 2, newName='Paint')
        self.assertNotIn('error', r, r)
        out = apply_edits(SRC, r['result']['changes'][u])
        self.assertIn('    constructor Init(AX, AY, AR: Integer);\n    procedure Paint; virtual;\n  end;', out)
        self.assertIn('procedure TCircle.Paint;', out)
        self.assertIn('  C.Paint;\n', out)
        self.assertIn('procedure TShape.Paint;', out)           # a virtual method is renamed with all its overrides,
        self.assertIn('  inherited Paint;', out)                #   otherwise the override would silently become a new method
        self.assertNotIn('Draw', out)

    def test_rename_a_virtual_method_from_the_ancestor_reaches_every_override(self):
        src = SRC.replace('begin\n  C.Init(1, 2, 3);', 'type\n  TSquare = object(TShape)\n    procedure Draw; virtual;\n  end;\n\n'
                          'procedure TSquare.Draw;\nbegin\n  inherited Draw;\nend;\n\nbegin\n  C.Init(1, 2, 3);')
        d, c, u = self.open_single(src)
        r = self.ask(c, 'rename', u, src, 'procedure Draw; virtual;', 0, len('procedure '), newName='Paint')
        self.assertNotIn('error', r, r)
        out = apply_edits(src, r['result']['changes'][u])
        self.assertNotIn('Draw', out)
        self.assertEqual(out.count('Paint'), src.count('Draw'))

    def test_rename_of_a_static_method_leaves_the_same_name_in_a_descendant(self):
        src = SRC.replace('procedure Draw; virtual;', 'procedure Draw;')
        d, c, u = self.open_single(src)
        r = self.ask(c, 'rename', u, src, 'procedure TShape.Draw', 0, len('procedure TShape.'), newName='Paint')
        self.assertNotIn('error', r, r)
        out = apply_edits(src, r['result']['changes'][u])
        self.assertIn('procedure TShape.Paint;', out)
        self.assertIn('procedure TCircle.Draw;', out)                    # hides the ancestor's method: another symbol

    def test_rename_a_virtual_method_reaches_an_override_in_another_unit(self):
        base = ('unit base;\ninterface\ntype\n  TShape = object\n    procedure Draw; virtual;\n  end;\nimplementation\n'
                'procedure TShape.Draw;\nbegin\nend;\nend.\n')
        child = ('unit child;\ninterface\nuses Base;\ntype\n  TCircle = object(TShape)\n    procedure Draw; virtual;\n  end;\n'
                 'implementation\nprocedure TCircle.Draw;\nbegin\n  inherited Draw;\nend;\nend.\n')
        d = self.proj({'base.pas': base, 'child.pas': child})
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'child.pas'), child)
        r = self.ask(c, 'rename', u, child, 'procedure TCircle.Draw', 0, len('procedure TCircle.'), newName='Paint')
        self.assertNotIn('error', r, r)
        ch = r['result']['changes']
        self.assertEqual(len(ch), 2)
        self.assertNotIn('Draw', apply_edits(child, ch[u]))
        self.assertNotIn('Draw', apply_edits(base, ch[uri(os.path.join(d, 'base.pas'))]))

    def test_rename_a_field_used_implicitly(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'rename', u, SRC, '    R: Integer;', 0, 4, newName='Radius')
        self.assertNotIn('error', r, r)
        out = apply_edits(SRC, r['result']['changes'][u])
        self.assertIn('    Radius: Integer;', out)
        self.assertIn('  Radius := AR;', out)
        self.assertIn('WriteLn(Self.Radius, X)', out)

    def test_rename_refuses_a_name_that_exists_in_the_ancestor(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'rename', u, SRC, '    R: Integer;', 0, 4, newName='X')
        self.assertEqual(r['error']['code'], -32803)
        self.assertIn('already', r['error']['message'])

    def test_rename_does_not_clash_with_a_global_of_the_same_name(self):
        src = SRC.replace('begin\n  C.Init(1, 2, 3);', 'procedure Paint;\nbegin\nend;\n\nbegin\n  C.Init(1, 2, 3);')
        d, c, u = self.open_single(src)
        r = self.ask(c, 'rename', u, src, 'C.Draw', 0, 2, newName='Paint')
        self.assertNotIn('error', r, r)                                   # the global Paint is another scope

    def test_rename_self_is_refused(self):
        d, c, u = self.open_single()
        r = self.ask(c, 'prepareRename', u, SRC, 'Self.R')
        self.assertEqual(r['error']['code'], -32803)

    # -- units --------------------------------------------------------------------------------------------
    UNIT = ('unit Shapes;\r\ninterface\r\ntype\r\n  TShape = object\r\n    X: Integer;\r\n    procedure Move(DX: Integer); virtual;\r\n'
            '  end;\r\nimplementation\r\nprocedure TShape.Move(DX: Integer);\r\nbegin\r\n  X := X + DX\r\nend;\r\nend.\r\n')
    MAIN = ('program m;\r\nuses Shapes;\r\ntype TKid = object(TShape)\r\n  procedure Jump;\r\nend;\r\nvar K: TKid;\r\n'
            'procedure TKid.Jump;\r\nbegin\r\n  Move(2);\r\n  x := 0\r\nend;\r\nbegin\r\n  K.Move(1)\r\nend.\r\n')

    def test_object_across_units(self):
        d = self.proj({'SHAPES.PAS': self.UNIT})
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'm.pas'), self.MAIN)
        r = self.ask(c, 'definition', u, self.MAIN, 'K.Move', 0, 2)['result']
        self.assertEqual(r['uri'], uri(os.path.join(d, 'SHAPES.PAS')))
        self.assertEqual(span(r), (8, len('procedure TShape.'), 8, len('procedure TShape.Move')))
        r = self.ask(c, 'declaration', u, self.MAIN, 'Move(2)')['result']
        self.assertEqual(span(r), (5, len('    procedure '), 5, len('    procedure Move')))
        r = self.ask(c, 'definition', u, self.MAIN, 'x := 0')['result']
        self.assertEqual((r['uri'], span(r)), (uri(os.path.join(d, 'SHAPES.PAS')), (4, 4, 4, 5)))

    def test_rename_a_method_in_another_unit_changes_both_files(self):
        d = self.proj({'SHAPES.PAS': self.UNIT})
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'm.pas'), self.MAIN)
        r = self.ask(c, 'rename', u, self.MAIN, 'K.Move', 0, 2, newName='Shift')
        self.assertNotIn('error', r, r)
        ch = r['result']['changes']
        self.assertEqual(len(ch), 2)
        main = apply_edits(self.MAIN, ch[u])
        self.assertIn('  Shift(2);', main)
        self.assertIn('  K.Shift(1)', main)
        unit = apply_edits(self.UNIT, ch[uri(os.path.join(d, 'SHAPES.PAS'))])
        self.assertIn('procedure Shift(DX: Integer); virtual;', unit)
        self.assertIn('procedure TShape.Shift(DX: Integer);', unit)

    def test_formatting_normalises_objects_across_units(self):
        d = self.proj({'SHAPES.PAS': self.UNIT})
        c = self.start(root=d)
        src = self.MAIN.replace('Move(2)', 'MOVE(2)').replace('K.Move', 'k.MOVE')
        u = c.open(os.path.join(d, 'm.pas'), src)
        out = c.formatted(u, src)
        self.assertIn('  Move(2);\r\n  X := 0;\r\nend;', out)                 # the field is spelled X in SHAPES.PAS
        self.assertIn('  K.Move(1);', out)
        self.assertIn('TKid = object(TShape)', out)


    # -- implementation / type hierarchy -------------------------------------------------------------------
    DEEP = ('program d;\n'
            'type\n'
            '  TA = object\n'
            '    procedure Go; virtual;\n'
            '    procedure Stay;\n'
            '  end;\n'
            '  TB = object(TA)\n'
            '    procedure Go; virtual;\n'
            '  end;\n'
            '  TC = object(TB)\n'
            '    procedure Stay;\n'
            '  end;\n'
            '  TD = object(TB)\n'
            '    procedure Go; virtual;\n'
            '  end;\n'
            'var A: TA;\n'
            'procedure TA.Go; begin end;\n'
            'procedure TA.Stay; begin end;\n'
            'procedure TB.Go; begin end;\n'
            'procedure TC.Stay; begin end;\n'
            'procedure TD.Go; begin end;\n'
            'begin\n'
            '  A.Go;\n'
            '  A.Stay\n'
            'end.\n')

    def test_implementation_of_a_virtual_method_lists_every_override(self):
        d, c, u = self.open_single(self.DEEP)
        r = self.ask(c, 'implementation', u, self.DEEP, 'A.Go', 0, 2)['result']
        self.assertEqual([span(x) for x in r], [at(self.DEEP, 'procedure TA.Go', 0, len('procedure TA.')),
                                                at(self.DEEP, 'procedure TB.Go', 0, len('procedure TB.')),
                                                at(self.DEEP, 'procedure TD.Go', 0, len('procedure TD.'))])

    def test_implementation_of_a_static_method_is_its_own_body(self):
        d, c, u = self.open_single(self.DEEP)
        r = self.ask(c, 'implementation', u, self.DEEP, 'A.Stay', 0, 2)['result']
        self.assertEqual([span(x) for x in r], [at(self.DEEP, 'procedure TA.Stay', 0, len('procedure TA.'))])

    def test_implementation_of_an_object_type_is_all_its_descendants(self):
        d, c, u = self.open_single(self.DEEP)
        r = self.ask(c, 'implementation', u, self.DEEP, 'TA = object', 0, 0)['result']
        self.assertEqual(sorted(span(x) for x in r), sorted([at(self.DEEP, 'TB = object(TA)'), at(self.DEEP, 'TC = object(TB)'),
                                                            at(self.DEEP, 'TD = object(TB)')]))
        r = self.ask(c, 'implementation', u, self.DEEP, 'TC = object', 0, 0)['result']
        self.assertEqual(r, [])

    def test_implementation_finds_overrides_in_files_that_are_not_open(self):
        kid = ('program m;\r\nuses Shapes;\r\ntype TKid = object(TShape)\r\n  procedure Move(DX: Integer); virtual;\r\nend;\r\n'
               'procedure TKid.Move(DX: Integer);\r\nbegin\r\nend;\r\nbegin\r\nend.\r\n')
        d = self.proj({'SHAPES.PAS': self.UNIT, 'm.pas': kid})
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'SHAPES.PAS'), self.UNIT)
        r = self.ask(c, 'implementation', u, self.UNIT, 'procedure Move', 0, len('procedure '))['result']
        self.assertEqual([(x['uri'], span(x)) for x in r],
                         [(u, (8, len('procedure TShape.'), 8, len('procedure TShape.Move'))),
                          (uri(os.path.join(d, 'm.pas')), (5, len('procedure TKid.'), 5, len('procedure TKid.Move')))])

    def test_type_hierarchy_up_and_down(self):
        d, c, u = self.open_single(self.DEEP)
        items = self.ask(c, 'prepareTypeHierarchy', u, self.DEEP, 'TB = object', 0, 0)['result']
        self.assertEqual([(i['name'], i['detail']) for i in items], [('TB', 'object(TA)')])
        sup = c.request('typeHierarchy/supertypes', {'item': items[0]})['result']
        self.assertEqual([i['name'] for i in sup], ['TA'])
        self.assertEqual(sup[0]['detail'], 'object')
        sub = c.request('typeHierarchy/subtypes', {'item': items[0]})['result']
        self.assertEqual(sorted(i['name'] for i in sub), ['TC', 'TD'])
        top = c.request('typeHierarchy/supertypes', {'item': sup[0]})['result']
        self.assertEqual(top, [])

    def test_type_hierarchy_from_a_variable_a_method_and_self(self):
        d, c, u = self.open_single(self.DEEP)
        for needle, off in (('A: TA', 0), ('A.Go', 2), ('procedure TB.Go', len('procedure TB.'))):
            items = self.ask(c, 'prepareTypeHierarchy', u, self.DEEP, needle, 0, off)['result']
            self.assertEqual(len(items), 1, needle)
        self.assertEqual(self.ask(c, 'prepareTypeHierarchy', u, self.DEEP, 'begin\n  A.Go', 0, 0)['result'], None)

    def test_type_hierarchy_across_units(self):
        d = self.proj({'SHAPES.PAS': self.UNIT})
        c = self.start(root=d)
        u = c.open(os.path.join(d, 'm.pas'), self.MAIN)
        items = self.ask(c, 'prepareTypeHierarchy', u, self.MAIN, 'TKid = object', 0, 0)['result']
        sup = c.request('typeHierarchy/supertypes', {'item': items[0]})['result']
        self.assertEqual([(i['name'], i['uri']) for i in sup], [('TShape', uri(os.path.join(d, 'SHAPES.PAS')))])
        sub = c.request('typeHierarchy/subtypes', {'item': sup[0]})['result']          # the unit's file is not open
        self.assertEqual([(i['name'], i['uri']) for i in sub], [('TKid', u)])


if __name__ == '__main__':
    unittest.main(verbosity=2)
