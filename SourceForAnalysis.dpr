program SourceForAnalysis;

{$APPTYPE CONSOLE}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

type
  { --- Interfaces --- }
  ILoggable = interface
    ['{A1B2C3D4-E5F6-4321-8765-432109876543}']
    procedure Log(const Msg: string);
  end;

  { --- Generics --- }
  TDataStore<T> = class
  private
    FItems: TList<T>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Item: T);
    function GetCount: Integer;
    property Items: TList<T> read FItems;
  end;

  { --- Inheritance & Overloading --- }
  TBaseShape = class(TInterfacedObject, ILoggable)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    procedure Log(const Msg: string); virtual;
    function GetArea: Double; virtual; abstract;
    property Name: string read FName;
  end;

  TCircle = class(TBaseShape)
  private
    FRadius: Double;
  public
    constructor Create(const AName: string; ARadius: Double);
    procedure Log(const Msg: string); override;
    function GetArea: Double; override;
  end;

  TRectangle = class(TBaseShape)
  private
    FWidth, FHeight: Double;
  public
    constructor Create(const AName: string; AWidth, AHeight: Double);
    function GetArea: Double; override;
    // Overloading
    procedure Resize(ANewWidth: Double); overload;
    procedure Resize(ANewWidth, ANewHeight: Double); overload;
  end;

  { --- Records & Enums --- }
  TColorMode = (cmRGB, cmCMYK, cmGrayscale);

  TPointRecord = record
    X, Y: Double;
    procedure Offset(DX, DY: Double);
  end;

{ TDataStore<T> }

constructor TDataStore<T>.Create;
begin
  FItems := TList<T>.Create;
end;

destructor TDataStore<T>.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TDataStore<T>.Add(const Item: T);
begin
  FItems.Add(Item);
end;

function TDataStore<T>.GetCount: Integer;
begin
  Result := FItems.Count;
end;

{ TBaseShape }

constructor TBaseShape.Create(const AName: string);
begin
  FName := AName;
end;

procedure TBaseShape.Log(const Msg: string);
begin
  WriteLn(Format('[%s] %s', [FName, Msg]));
end;

{ TCircle }

constructor TCircle.Create(const AName: string; ARadius: Double);
begin
  inherited Create(AName);
  FRadius := ARadius;
end;

function TCircle.GetArea: Double;
begin
  Result := 3.14159 * FRadius * FRadius;
end;

procedure TCircle.Log(const Msg: string);
begin
  inherited Log('Circle: ' + Msg);
end;

{ TRectangle }

constructor TRectangle.Create(const AName: string; AWidth, AHeight: Double);
begin
  inherited Create(AName);
  FWidth := AWidth;
  FHeight := AHeight;
end;

function TRectangle.GetArea: Double;
begin
  Result := FWidth * FHeight;
end;

procedure TRectangle.Resize(ANewWidth: Double);
begin
  FWidth := ANewWidth;
end;

procedure TRectangle.Resize(ANewWidth, ANewHeight: Double);
begin
  FWidth := ANewWidth;
  FHeight := ANewHeight;
end;

{ TPointRecord }

procedure TPointRecord.Offset(DX, DY: Double);
begin
  X := X + DX;
  Y := Y + DY;
end;

{ --- Main --- }

procedure PerformAnalysis;
var
  Shapes: TDataStore<TBaseShape>;
  Circle: TCircle;
  Rect: TRectangle;
  I: Integer;
  P: TPointRecord;
  Mode: TColorMode;
begin
  Shapes := TDataStore<TBaseShape>.Create;
  try
    Circle := TCircle.Create('MyCircle', 5.0);
    Shapes.Add(Circle);

    Rect := TRectangle.Create('MyRect', 10.0, 20.0);
    Shapes.Add(Rect);

    WriteLn('Total Shapes: ', Shapes.GetCount);

    for I := 0 to Shapes.GetCount - 1 do
    begin
      Shapes.Items[I].Log('Area is ' + FloatToStr(Shapes.Items[I].GetArea));
    end;

    // Test overloaded methods
    Rect.Resize(15.0);
    Rect.Resize(15.0, 25.0);

    // Test records
    P.X := 10;
    P.Y := 10;
    P.Offset(5, 5);

    // Test enums
    Mode := cmRGB;
    if Mode = cmRGB then
      WriteLn('Using RGB mode');

  finally
    Shapes.Free; // Note: In a real app, we'd need to free the objects in the list too
  end;
end;

begin
  try
    PerformAnalysis;
  except
    on E: Exception do
      WriteLn(E.ClassName, ': ', E.Message);
  end;
  
  WriteLn('Analysis complete. Press Enter to exit.');
  ReadLn;
end.
