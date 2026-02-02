program SourceForAnalysis;

{$APPTYPE CONSOLE}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

uses
  SysUtils;

type
  TFoo = class
    procedure Bar;
  end;

procedure TFoo.Bar;
begin
  WriteLn('Hello World');
end;

var
  F: TFoo;
begin
  F := TFoo.Create;
  try
    F.Bar;
  finally
    F.Free;
  end;
end.
