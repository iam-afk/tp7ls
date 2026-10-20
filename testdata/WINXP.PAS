{$A+,B-,D+,E-,F-,G+,I+,L+,N+,O-,P-,Q+,R+,S+,T-,V+,X+}
{$M 65520,0,655360}
Unit WinXP;
Interface
Const
  cmNothing   = 0;
  cmMouse     = 1;
  cmKeyboard  = 2;
  cmBroadcast = 3;

  cmYes       = 1;
  cmNo        = 2;
  cmOk        = 3;
  cmCancel    = 4;
  cmClose     = 5;
  cmExit      = 6;

  Pasive      = 0;
  Active      = 1;
  Press       = 2;

  Tab         = #9;

Type pView=^tView;
     pGroup=^tGroup;
     pWindow=^tWindow;
     pDeskTop=^tDeskTop;
     pButton=^tButton;
     pString=^tString;
     tEvent=Record
              Case Watch:Word of
              cmMouse:(Mx,My:Integer; { Координаты }
                       bMask:Byte);   { Статус кнопок }
              cmKeyboard:(Scan,Key:Char); { Событие от клавиатуры }
              cmBroadcast:(Code:Word;     { Код события - константа }
                           Addr,InfoPtr:pView); { Кому, от кого }
            End;
{ Хранит все свойства видимых объектов }
     tView=Object
             Owner:pGroup;
             Next:pView;
             x,y:Integer;
             SizeX,SizeY:Integer;
             Status:Byte;         { Статус объекта (видимый, активный и т д)}
             Options:Word;       { Возможные операции над окном }
             DataSize:Word;
             EventMask:Word;
             Focus:Boolean;
             Constructor Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte);
             Procedure ClearEvent(Var E:tEvent);Virtual;  { Очистить событие }
             Procedure Execute;Virtual;
             Procedure GetData(Var Rec);
             Procedure GetEvent(Var E:tEvent);
             Procedure HandleEvent(Var E:tEvent);Virtual;
             Procedure Hide;
             Procedure MakeLocal(Var xl,yl:Integer);
             Procedure MakeGlobal(var xg,yg:Integer);
             Function Prev:pView;
             Procedure PutEvent(Var e:tEvent);Virtual;
             Procedure SetData(Var Rec);
             Procedure Show;Virtual;
             Function Valid:Boolean;Virtual;
             Function MouseContaine:Boolean;
           End;
{ Определяет возможности работы с групой элементов }
     tGroup=Object(tView)
              Last:pView;
              Current:pView;
              Elem:pView;
              Pashe:Byte;
              Constructor Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte);
              Procedure Execute;Virtual;
              Function First:pView;
              Procedure ForEach;
              Procedure HandleEvent(Var e:tEvent);Virtual;
              Procedure Insert(p:pView);
              Procedure SelectNext;
              Procedure Show;Virtual;
              Function Valid:Boolean;Virtual;
            End;
     tWindow=Object(tGroup)
               Name:String;
               Constructor Init(Xn,Yn,SizeXn,SizeYn:Integer;Namen:String);
               Procedure HandleEvent(Var e:tEvent);Virtual;
               Procedure SetName(NewName:String);
               Procedure Show;Virtual;
               Function Valid:Boolean;Virtual;
             End;
     tDeskTop=Object(tGroup)
                Picture:String;
                ExitProg:Boolean;
                Constructor Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte;Pic:String);
                Procedure GetEvent(Var e:tEvent);Virtual;
                Procedure HandleEvent(Var e:tEvent);Virtual;
                Procedure Show;Virtual;
                Procedure PutEvent(Var e:tEvent);Virtual;
                Procedure Run;
                Function Quit:Boolean;
              End;
     tButton=Object(tView)
               Name:String;
               Code:Word;
               HotKey:Char;
               Constructor Init(Xn,Yn,SizeXn,SizeYn:Integer;Active:Byte;ButName:String;Coden:Word;NewHot:Char);
               Function MouseContaine:Boolean;
               Procedure Show;Virtual;
               Procedure HandleEvent(Var e:tEvent);Virtual;
             End;
     tString=Object(tView)
               Str:^String;
               Num:Byte;
               Constructor Init(ax,ay,aSizeX:Integer;Len:Byte;s:String);
               Procedure SetData(Var Rec);
               Procedure GetData(Var Rec);
               Procedure Show;Virtual;
             End;
Var DeskTop:pDeskTop;
    SaveEvent,e:tEvent;

Implementation
Uses Vesa,Objects,Crt;
Const
  HeadSize = 20;   { Высота заголовка окна }
Var Page:Byte;
{==========================================}
Procedure ReadMouse(Var b:Byte);
Begin
  If MouseButton=LeftButton
  Then b:=LeftButton;
  If MouseButton=RightButton
  Then b:=RightButton;
  If MouseButton=NoButton
  Then b:=NoButton;
  If MouseButton=BothButtons
  Then b:=BothButtons;
End;
{==========================================}
Procedure SwitchPage;
Begin
  SetActivePage(Page);
  SetVisualPage(1-Page);
  SetColor(0);
  Bar(0,0,GetMaxX,GetMaxY);
  Page:=1-Page;
End;
{==========================================}
Function Bit(b:Byte;k:Byte):Boolean;
Label m1;
Var i:Byte;
Begin
  Asm
    push ax
    mov  ah,b
    test ah,k
    pop  ax
    jz   @m2
    mov  i,1
    jmp  m1
@m2:mov  i,0
  End;
m1:
  Bit:=(i=1);
End;
{==========================================}
{========== Описание методов ==============}
{==========================================}
{ Объект tView }
Constructor tView.Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte);
Begin
  x:=Xn;y:=Yn;SizeX:=SizeXn;SizeY:=SizeYn;
  Status:=Statusn;
End;
{==========================================}
Procedure tView.ClearEvent(Var E:tEvent);
Begin
  e.Watch:=cmNothing;
End;
{==========================================}
Procedure tView.Execute;
Begin
End;
{==========================================}
Procedure tView.GetData;
Begin
End;
Procedure tView.GetEvent;
Begin
End;
{==========================================}
Procedure tView.HandleEvent;
Begin
End;
{==========================================}
Procedure tView.Hide;
Begin
End;
{==========================================}
Procedure tView.MakeLocal(Var xl,yl:Integer);
Begin
End;
{==========================================}
Procedure tView.MakeGlobal(Var xg,yg:Integer);
Begin
End;
{==========================================}
Function tView.Prev:pView;
Begin
End;
{==========================================}
Procedure tView.PutEvent(Var e:tEvent);
Begin
  If Owner<>nil
  Then Owner^.PutEvent(e);
End;
{==========================================}
Procedure tView.SetData;
Begin
End;
{==========================================}
Procedure tView.Show;
Begin
End;
Function tView.Valid:Boolean;
Begin
End;
{==========================================}
Function tView.MouseContaine:Boolean;
Begin
  If (x<=MouseX)and(MouseX<=x+SizeX)and(y<=MouseY)and(MouseY<=y+SizeY)
  Then MouseContaine:=True
  Else mouseContaine:=False;
End;
{==========================================}
{ Объект tGroup }
Constructor tGroup.Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte);
Begin
  Inherited Init(Xn,Yn,SizeXn,SizeYn,Statusn);
  Last:=nil;Current:=nil;Elem:=nil;
End;
{==========================================}
Procedure tGroup.Execute;
Begin
End;
{==========================================}
Function tGroup.First;
Begin
End;
{==========================================}
Procedure tGroup.ForEach;
Begin
End;
{==========================================}
Procedure tGroup.HandleEvent(Var e:tEvent);
Var p:pView;
Begin
  p:=Last;
  If p<>nil
  Then Begin
         Repeat
           p:=p^.Next;
           p^.HandleEvent(e)
         Until (p=Last)or(e.Watch=cmNothing)
       End;
End;
{==========================================}
Procedure tGroup.Insert(p:pView);
Var t:pView;
Begin
  t:=Last;p^.Owner:=@Self;
  If t=nil
  Then Begin
         Last:=p;
         p^.Next:=p;
       End
  Else Begin
         p^.Next:=t^.Next;
         t^.Next:=p;
         Last:=Last^.Next;
         Current:=Last;
       End;
End;
{==========================================}
Procedure tGroup.SelectNext;
Begin
  Current:=Current^.Next;
End;
{==========================================}
Procedure tGroup.Show;
Var p:pView;
Begin
  p:=Last;
  If p<>nil
  Then Begin
         Repeat
           p:=p^.Next;
           p^.Show;
         Until p=Last;
       End;
End;
Function tGroup.Valid:Boolean;
Var p:pView;
    f:Boolean;
Begin
  p:=Last;f:=True;
  If p<>nil
  Then Begin
         Repeat
           p:=p^.Next;
           f:=p^.Valid;
         Until (p=Last)or(not f);
       End;
  Valid:=f;
End;
{==========================================}
{ Объект tWindow }
Constructor tWindow.Init(xn,yn,SizeXn,SizeYn:Integer;Namen:String);
Begin
  SetName(Namen);
  Inherited Init(Xn,Yn,SizeXn,SizeYn,Active);
End;
{==========================================}
Procedure tWindow.HandleEvent(Var e:tEvent);
Begin
  Case e.Watch of
  cmMouse:Begin
            If MouseContaine
            Then Begin
                   If Owner^.Current<>@Self
                   Then Begin
                          Owner^.Current^.Status:=Owner^.Current^.Status and 254;
                          Status:=Status or Active;
                          Owner^.Current:=@Self;
                          ClearEvent(e);
                        End
                   Else Begin
                          Inherited HandleEvent(e);
                          If e.Watch<>cmNothing
                          Then Begin
                                 { Анализ возможности перемещения окна }
                                 ClearEvent(e);
                               End;
                        End;
                 End;
          End;
  cmKeyBoard:Begin
               Case e.Key of
               Tab:SelectNext;
               Else Inherited HandleEvent(e);
               End;
             End;
  cmBroadCast:Begin
                If e.Addr=@Self
                Then Case e.Code of
                     cmYes,
                     cmOk:Begin
                            e.Watch:=cmBroadCast;
                            e.Code:=cmClose;
                            e.Addr:=Owner;
                            e.InfoPtr:=@Self;
                            Owner^.PutEvent(e);
                            ClearEvent(e);
                          End;
                     End;
              End;
  End;
End;
{==========================================}
Procedure tWindow.SetName(NewName:String);
Begin
  Name:=NewName;
End;
{==========================================}
Procedure tWindow.Show;
Begin
  SetColor(7);
  Bar(x,y,x+SizeX,y+SizeY);
  Ramka(x,y,x+SizeX,y+SizeY);
{  Rectangle(x,y,x+SizeX,y+SizeY,0,0);}
  If Owner^.Current=@Self
  Then SetLabelTexture('Labels.dat')
  Else SetLabelTexture('Texture.dat');
  DrawLabel(x,y,x+SizeX,y+HeadSize,Name);
  Inherited Show;
End;
{==========================================}
Function tWindow.Valid;
Begin
  Valid:=Inherited Valid;
End;
{==========================================}
{ Объект tDeskTop }
Constructor tDeskTop.Init(Xn,Yn,SizeXn,SizeYn:Integer;Statusn:Byte;Pic:String);
Begin
  Inherited Init(Xn,Yn,SizeXn,SizeYn,Statusn);
  Picture:=Pic;
End;
{==========================================}
Procedure tDeskTop.GetEvent(Var e:tEvent);
Begin
  If SaveEvent.Watch<>cmNothing
  Then Begin
         e:=SaveEvent;SaveEvent.Watch:=cmNothing;
       End
  Else Begin
         ReadMouse(e.bMask);
         If e.bMask<>0
         Then Begin
                e.Watch:=cmMouse;
                e.Mx:=Mousex;
                e.My:=MouseY;
              End
         Else If KeyPressed
              Then Begin
                     e.Watch:=cmKeyBoard;e.Key:=ReadKey;
                     If e.Key=#0 Then e.Scan:=ReadKey
                     Else e.Scan:=#0
                   End
              Else e.Watch:=cmNothing;
       End;
End;
{==========================================}
Procedure tDeskTop.HandleEvent(Var e:tEvent);
Begin
  Case e.Watch of
  cmBroadCast:Begin
                If e.Addr=@Self
                Then Case e.Code of
                     cmExit:Begin
                              ClearEvent(e);
                              ExitProg:=Inherited Valid;
                            End;
                     End
                Else Inherited HandleEvent(e);
              End;
  Else Inherited handleEvent(e);
  End;
End;
{==========================================}
Procedure tDeskTop.Show;
Begin
{  DrawScreen(0,0,GetMaxX,GetMaxX,Picture);}
  Inherited Show;
End;
{==========================================}
Procedure tDeskTop.PutEvent(Var e:tEvent);
Begin
  SaveEvent:=e;
  ClearEvent(e);
End;
{==========================================}
Procedure tDeskTop.Run;
Begin
  ExitProg:=False;
  Repeat
    HideMouse;
    Show;
    ShowMouse;
    GetEvent(e);
   {PutEvent(e);}
    HandleEvent(e);
    ClearEvent(e);
    SwitchPage;
  Until Quit;
End;
{==========================================}
Function tDeskTop.Quit:Boolean;
Begin
  Quit:=ExitProg;
End;
{==========================================}
{ Объект tButton }
Constructor tButton.Init(Xn,Yn,SizeXn,SizeYn:Integer;Active:Byte;ButName:String;Coden:Word;NewHot:Char);
Begin
  Name:=Butname;
  Code:=Coden;
  HotKey:=NewHot;
  Inherited Init(Xn,Yn,SizeXn,SizeYn,Active);
End;
{==========================================}
Function tButton.MouseContaine:Boolean;
Begin
  If (Owner^.x+x<=MouseX)and(MouseX<=Owner^.x+x+SizeX)and
     (Owner^.y+y<=MouseY)and(MouseY<=Owner^.y+y+SizeY)
  Then MouseContaine:=True
  Else mouseContaine:=False;

End;
{==========================================}
Procedure tButton.Show;
Begin
  Case Status of
  0:DrawButton(Owner^.x+x,Owner^.y+y,Owner^.x+x+SizeX,Owner^.y+y+SizeY,Name,False,True);
  1:DrawButton(Owner^.x+x,Owner^.y+y,Owner^.x+x+SizeX,Owner^.y+y+SizeY,Name,False,False);
  3:DrawButton(Owner^.x+x,Owner^.y+y,Owner^.x+x+SizeX,Owner^.y+y+SizeY,Name,True,True);
  End;
End;
{==========================================}
Procedure tButton.HandleEvent(Var e:tEvent);
Begin
  Case e.Watch of
  cmMouse:Begin
            If MouseContaine
            Then Begin
                   If Bit(Status,1)
                   Then Begin
                          Status:=Status or Press;
                          Show;
                          ClearEvent(e);
                          e.Watch:=cmBroadCast;
                          e.Code:=Code;
                          e.InfoPtr:=@Self;
                          e.Addr:=Owner;
                          Owner^.PutEvent(e);
                          ClearEvent(e);
                          Status:=Status and 253;
                        End
                   Else ClearEvent(e);
                 End;
          End;
  cmKeyBoard:Begin
               If e.Key=HotKey
               Then Begin
                      Status:=Status or Press;
                      Show;
                      ClearEvent(e);
                      e.Watch:=cmBroadCast;
                      e.Code:=Code;
                      e.InfoPtr:=@Self;
                      e.Addr:=Owner;
                      Owner^.PutEvent(e);
                      ClearEvent(e);
                      Status:=Status and 253;
                    End;
             End;
  End;
End;
{==========================================}
{ Объект tString }
Constructor tString.Init(ax,ay,aSizeX:Integer;Len:Byte;s:String);
Begin
  x:=ax;y:=ay;DataSize:=Len;SizeX:=aSizeX;
  GetMem(Str,Len+1);Str^:=s;Num:=1;
End;
{==========================================}
Procedure tString.SetData(Var Rec);
Type tStr=String;
Begin
  Str^:=Copy(tStr(Rec),1,DataSize);
End;
{==========================================}
Procedure tString.GetData(Var Rec);
Type tStr=String;
Begin
  tStr(Rec):=Copy(Str^,1,DataSize);
End;
{==========================================}
Procedure tString.Show;
Var i,k:Integer;
    s:String;
Begin
  s:=Copy(Str^,Num,(SizeX-6) div 8-1);
  DrawEdit(Owner^.x+x,Owner^.y+y,Owner^.x+x+SizeX,Owner^.y+y+25,s);
{  OutTextXY(Owner^.x+x,Owner^.y+y,s);}
End;
{==========================================}
{==========================================}
{==========================================}
Begin
  DeskTop:=New(pDeskTop,Init(0,0,GetMaxX,GetMaxy,Active,'logo.spr'));
End.