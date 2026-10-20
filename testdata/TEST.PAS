{$A+,B-,D+,E-,F-,G-,I+,L+,N+,O-,P-,Q+,R+,S+,T-,V+,X+,Y+}
unit test;
interface
uses vesa,dos,objects,crt,polsk,option;
const MaxVar=10;
  S = 'literal';
type
     Ident=(cmProg,cmBegin,cmEnd,cmFor,cmWhile,cmVar,cmWall,cmIf,cmThen,
            cmElse,cmForw,cmRight,cmLeft,cmGet,cmPut,cmMove,cmQuest,cmNotPrep,cmNumber,cmCh,cmStr,cmInteg,cmString,cmChar,
            cmTZ,cmTT,cmZZ,cmT,cmSL,cmSR,cmMore,cmLess,cmEqu,cmNotEqu,cmMoreEqu,cmLessEqu,cmPlus,cmMinus,cmUmnog,cmIdent);

     TProc = function(a: Integer; var b: string): Boolean;

     TIdents = set of Ident;

     str_15=string[15];

     tMainVar=array[1..MaxVar] of record
                                    name:str_15;
                                    case typ:ident of
                                    cmInteg:(i:integer;);
                                    cmString:(s:str_15;);
                                    cmChar:(c:char);
                                  end;

     pZnach=^tZnach;
     tZnach=record
              typ:Ident;
              case f:boolean of
              true:(i:integer;
                    s:str_15;
                    c:char);
              false:(p:integer);{если f=true, то k хранит число}
            end;                 {если f=false, то p хранит номер в массиве переменных}

     pNode=^tNode;
     tNode=record
             next:pNode;
             case typ:Ident of
             cmIf:(where:str_15;
                  what:integer;
                  NotPrep:boolean;
                  op1,op2:pZnach;
                  then_,else_:pNode;
                  Operation:Ident );
             cmWhile:(whereW:str_15;
                      whatW:integer;
                      NotPrepW:boolean;
                      op1W,op2W:pZnach;
                      operationW:ident;
                      bodyW:pNode);
             cmFor:(ForI:integer;
                    Body:pNode);
             cmIdent:(Name:str_15;
                      TypAss:ident;
                      WhatAssign:string);
             end;

const MaxLex=39;
      MainLex:array[ident] of str_15=('ПРОГРАММА','НАЧАЛО','КОНЕЦ','ЦИКЛ','ПОКА','ПЕРЕМЕННЫЕ','ПРЕП',
                                      'ЕСЛИ','ТО','ИНАЧЕ','ВПЕРЕД','ВПРАВО','ВЛЕВО','ВЗЯТЬ','ПОЛОЖИТЬ','ПЕРЕДВИНУТЬ','ЧТО',
                                      'НЕТ_ПРЕП','','#',#39,'ЦЕЛ','СТР','СИМ',';',':',',','.','(',')','>','<','=','<>','>=',
                                      '<=','+','-','*','');


var prog,stat:text;

    ch:ident;
    last,last_,first,pp:pNode;
    eyes,LexNum:integer;
    LexIdent,LexStr:str_15;
    MainVar:tMainVar;
    numbV:integer;
    st,lex,name:string;
    post,stg:integer;
    cursor,nach:tbeg;
    ErBegEnd:integer;
    c:char;

    Geting:boolean;
    GetObj:byte;

    x,y,posX,posY,offset:integer;
    f:text;
    Fsave,Fload:boolean;
    refresh:boolean;
    Nsave,Nload:string;
    Xsave,Xload:integer;
    Tsave:boolean;
    code:char;

    ex,WTime:byte;
    PGoth, pTexture1,Old8 : pointer;
    SBP,SSp,Ses,SSi,sdi,AddrRet:word;

implementation
end.
