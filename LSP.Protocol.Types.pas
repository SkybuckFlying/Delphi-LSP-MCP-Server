unit LSP.Protocol.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  // LSP Position
  TLSPPosition = record
    Line: Integer;
    Character: Integer;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPPosition; static;
    class function Default: TLSPPosition; static;
    class operator Equal(const A, B: TLSPPosition): Boolean;
    class operator NotEqual(const A, B: TLSPPosition): Boolean;
  end;

  // LSP Range
  TLSPRange = record
    Start: TLSPPosition;
    &End: TLSPPosition;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPRange; static;
    class function Default: TLSPRange; static;
  end;

  // LSP Location
  TLSPLocation = record
    Uri: string;
    Range: TLSPRange;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPLocation; static;
  end;

  // LSP Text Document Identifier
  TLSPTextDocumentIdentifier = record
    Uri: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentIdentifier; static;
  end;

  // LSP Text Document Item (didOpen)
  TLSPTextDocumentItem = record
    Uri: string;
    LanguageId: string;
    Version: Integer;
    Text: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentItem; static;
  end;

  // LSP Versioned Text Document Identifier (version: integer | null)
  TLSPVersionedTextDocumentIdentifier = record
    Uri: string;
    Version: Integer; // valid only when IsNull = False
	IsNull: Boolean;  // True = version is null
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPVersionedTextDocumentIdentifier; static;
    class function Default: TLSPVersionedTextDocumentIdentifier; static;
  end;

  // LSP Text Document Position Params
  TLSPTextDocumentPositionParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentPositionParams; static;
  end;

  TLSPDefinitionParams = TLSPTextDocumentPositionParams;
  TLSPHoverParams      = TLSPTextDocumentPositionParams;

  // LSP References Context
  TLSPReferenceContext = record
    IncludeDeclaration: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPReferenceContext; static;
  end;

  // LSP References Params
  TLSPReferenceParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    Context: TLSPReferenceContext;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPReferenceParams; static;
  end;

  // LSP Markup Content and legacy MarkedString/MarkedString[]
  TLSPMarkupContent = record
    Kind: string;  // "plaintext" or "markdown"
    Value: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONValue; out IsValid: Boolean): TLSPMarkupContent; static;
    function IsEmpty: Boolean;
    class function Default: TLSPMarkupContent; static;
  end;

  // LSP Hover
  TLSPHover = record
    Contents: TLSPMarkupContent; // required
    Range: TLSPRange;
    HasRange: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPHover; static;
  end;

  // LSP Completion Context
  TLSPCompletionContext = record
    TriggerKind: Integer;     // 1,2,3
    TriggerCharacter: string; // valid only when TriggerKind = 2, single UTF-16 code unit
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionContext; static;
  end;

  // LSP Completion Params
  TLSPCompletionParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    Context: TLSPCompletionContext;
    HasContext: Boolean;
	function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionParams; static;
  end;

  // LSP Completion Item
  TLSPCompletionItem = record
    Label_: string;
    Kind: Integer; // 1..25 per spec; 0 = omitted on write
    Detail: string;
    Documentation: TLSPMarkupContent;
    HasDocumentation: Boolean;
    InsertText: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionItem; static;
  end;

  // LSP Workspace Symbol Params
  TLSPWorkspaceSymbolParams = record
    Query: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPWorkspaceSymbolParams; static;
  end;

  // LSP Symbol Information
  TLSPSymbolInformation = record
    Name: string;
    Kind: Integer;
    Location: TLSPLocation;
    ContainerName: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPSymbolInformation; static;
  end;

  // LSP Initialize Params
  TLSPInitializeParams = class
  public
    ProcessId: Integer;
    HasProcessId: Boolean; // true if processId is a number (including 0)
    RootUri: string;       // string when HasRootUri and not null, '' when HasRootUri and null
    HasRootUri: Boolean;   // distinguishes missing vs present (string|null)
    Capabilities: TJSONObject;         // owned, required
    InitializationOptions: TJSONObject; // owned, optional
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPInitializeParams; static;
  end;

  // LSP Initialize Result
  TLSPInitializeResult = class
  public
    Capabilities: TJSONObject; // owned, required
    ServerInfo: TJSONObject;   // owned, optional
    constructor Create;
    destructor Destroy; override;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPInitializeResult; static;
  end;

  // LSP Did Open Text Document Params
  TLSPDidOpenTextDocumentParams = record
    TextDocument: TLSPTextDocumentItem;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPDidOpenTextDocumentParams; static;
  end;

  // LSP Text Document Content Change Event
  TLSPTextDocumentContentChangeEvent = record
    Range: TLSPRange;
    HasRange: Boolean;
    RangeLength: Integer;   // uinteger in spec; we clamp to >= 0
    HasRangeLength: Boolean;
    Text: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentContentChangeEvent; static;
    class function Empty: TLSPTextDocumentContentChangeEvent; static;
  end;

  // LSP Did Change Text Document Params
  TLSPDidChangeTextDocumentParams = record
    TextDocument: TLSPVersionedTextDocumentIdentifier;
    ContentChanges: TArray<TLSPTextDocumentContentChangeEvent>;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPDidChangeTextDocumentParams; static;
  end;

  // LSP Did Close Text Document Params
  TLSPDidCloseTextDocumentParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPDidCloseTextDocumentParams; static;
  end;

implementation

{ TLSPPosition }

class function TLSPPosition.Default: TLSPPosition;
begin
  Result.Line := 0;
  Result.Character := 0;
end;

class operator TLSPPosition.Equal(const A, B: TLSPPosition): Boolean;
begin
  Result := (A.Line = B.Line) and (A.Character = B.Character);
end;

class operator TLSPPosition.NotEqual(const A, B: TLSPPosition): Boolean;
begin
  Result := not (A = B);
end;

function TLSPPosition.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('line', TJSONNumber.Create(Line));
  Result.AddPair('character', TJSONNumber.Create(Character));
end;

class function TLSPPosition.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPPosition;
begin
  Result := Default;
  IsValid := Assigned(AJson) and
             AJson.TryGetValue<Integer>('line', Result.Line) and
             AJson.TryGetValue<Integer>('character', Result.Character);
end;

{ TLSPRange }

class function TLSPRange.Default: TLSPRange;
begin
  Result.Start := TLSPPosition.Default;
  Result.&End := TLSPPosition.Default;
end;

function TLSPRange.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('start', Start.ToJSON);
  Result.AddPair('end', &End.ToJSON);
end;

class function TLSPRange.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPRange;
var
  Val: TJSONValue;
  Ok1, Ok2: Boolean;
begin
  Result := Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('start');
  if Val is TJSONObject then
    Result.Start := TLSPPosition.FromJSON(TJSONObject(Val), Ok1)
  else
    Exit;

  Val := AJson.GetValue('end');
  if Val is TJSONObject then
    Result.&End := TLSPPosition.FromJSON(TJSONObject(Val), Ok2)
  else
    Exit;

  IsValid := Ok1 and Ok2;
end;

{ TLSPLocation }

function TLSPLocation.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
  Result.AddPair('range', Range.ToJSON);
end;

class function TLSPLocation.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPLocation;
var
  Val: TJSONValue;
begin
  Result.Uri := '';
  Result.Range := TLSPRange.Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  IsValid := AJson.TryGetValue<string>('uri', Result.Uri);
  if not IsValid then Exit;

  Val := AJson.GetValue('range');
  if Val is TJSONObject then
    Result.Range := TLSPRange.FromJSON(TJSONObject(Val), IsValid)
  else
    IsValid := False;
end;

{ TLSPTextDocumentIdentifier }

function TLSPTextDocumentIdentifier.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
end;

class function TLSPTextDocumentIdentifier.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentIdentifier;
begin
  Result.Uri := '';
  IsValid := Assigned(AJson) and AJson.TryGetValue<string>('uri', Result.Uri);
end;

{ TLSPTextDocumentItem }

function TLSPTextDocumentItem.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
  Result.AddPair('languageId', LanguageId);
  Result.AddPair('version', TJSONNumber.Create(Version));
  Result.AddPair('text', Text);
end;

class function TLSPTextDocumentItem.FromJSON(AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentItem;
var
  Ok1, Ok2, Ok3, Ok4: Boolean;
begin
  Result.Uri := '';
  Result.LanguageId := '';
  Result.Version := 0;
  Result.Text := '';
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Ok1 := AJson.TryGetValue<string>('uri', Result.Uri);
  Ok2 := AJson.TryGetValue<string>('languageId', Result.LanguageId);
  Ok3 := AJson.TryGetValue<Integer>('version', Result.Version);
  Ok4 := AJson.TryGetValue<string>('text', Result.Text);
  IsValid := Ok1 and Ok2 and Ok3 and Ok4;
end;

{ TLSPVersionedTextDocumentIdentifier }

class function TLSPVersionedTextDocumentIdentifier.Default: TLSPVersionedTextDocumentIdentifier;
begin
  Result.Uri := '';
  Result.Version := 0;
  Result.IsNull := True;
end;

function TLSPVersionedTextDocumentIdentifier.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
  if IsNull then
    Result.AddPair('version', TJSONNull.Create)
  else
    Result.AddPair('version', TJSONNumber.Create(Version));
end;

class function TLSPVersionedTextDocumentIdentifier.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPVersionedTextDocumentIdentifier;
var
  Val: TJSONValue;
begin
  Result := Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  IsValid := AJson.TryGetValue<string>('uri', Result.Uri);
  if not IsValid then Exit;

  Val := AJson.GetValue('version');
  if Val is TJSONNumber then
  begin
    Result.Version := TJSONNumber(Val).AsInt;
    Result.IsNull := False;
    IsValid := True;
  end
  else if Val is TJSONNull then
  begin
    Result.IsNull := True;
    IsValid := True;
  end
  else
    IsValid := False;
end;

{ TLSPTextDocumentPositionParams }

function TLSPTextDocumentPositionParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
  Result.AddPair('position', Position.ToJSON);
end;

class function TLSPTextDocumentPositionParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentPositionParams;
var
  Val: TJSONValue;
  Ok1, Ok2: Boolean;
begin
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
    Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(TJSONObject(Val), Ok1)
  else
    Exit;

  Val := AJson.GetValue('position');
  if Val is TJSONObject then
    Result.Position := TLSPPosition.FromJSON(TJSONObject(Val), Ok2)
  else
    Exit;

  IsValid := Ok1 and Ok2;
end;

{ TLSPReferenceContext }

function TLSPReferenceContext.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('includeDeclaration', TJSONBool.Create(IncludeDeclaration));
end;

class function TLSPReferenceContext.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPReferenceContext;
begin
  Result.IncludeDeclaration := False;
  IsValid := Assigned(AJson) and
             AJson.TryGetValue<Boolean>('includeDeclaration', Result.IncludeDeclaration);
end;

{ TLSPReferenceParams }

function TLSPReferenceParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
  Result.AddPair('position', Position.ToJSON);
  Result.AddPair('context', Context.ToJSON);
end;

class function TLSPReferenceParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPReferenceParams;
var
  Val: TJSONValue;
  Ok1, Ok2, Ok3: Boolean;
begin
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
    Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(TJSONObject(Val), Ok1)
  else
    Exit;

  Val := AJson.GetValue('position');
  if Val is TJSONObject then
    Result.Position := TLSPPosition.FromJSON(TJSONObject(Val), Ok2)
  else
    Exit;

  Val := AJson.GetValue('context');
  if Val is TJSONObject then
    Result.Context := TLSPReferenceContext.FromJSON(TJSONObject(Val), Ok3)
  else
    Exit;

  IsValid := Ok1 and Ok2 and Ok3;
end;

{ TLSPMarkupContent }

function TLSPMarkupContent.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('kind', Kind);
  Result.AddPair('value', Value);
end;

function TLSPMarkupContent.IsEmpty: Boolean;
begin
  Result := Value = '';
end;

class function TLSPMarkupContent.Default: TLSPMarkupContent;
begin
  Result.Kind := 'plaintext';
  Result.Value := '';
end;

class function TLSPMarkupContent.FromJSON(
  AJson: TJSONValue; out IsValid: Boolean): TLSPMarkupContent;
var
  Obj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  SB: TStringBuilder;
  ItemObj: TJSONObject;
  Lang, Code: string;
  KindVal, ValueVal: TJSONValue;
begin
  Result := Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  if AJson is TJSONObject then
  begin
    Obj := TJSONObject(AJson);
    KindVal  := Obj.GetValue('kind');
    ValueVal := Obj.GetValue('value');
    if (KindVal is TJSONString) and (ValueVal is TJSONString) then
    begin
      Result.Kind  := TJSONString(KindVal).Value;
      Result.Value := TJSONString(ValueVal).Value;
      IsValid := (Result.Kind = 'plaintext') or (Result.Kind = 'markdown');
    end;
  end
  else if AJson is TJSONString then
  begin
    Result.Kind  := 'plaintext';
    Result.Value := TJSONString(AJson).Value;
    IsValid := True;
  end
  else if AJson is TJSONArray then
  begin
    Arr := TJSONArray(AJson);
    if Arr.Count = 0 then Exit;
    Result.Kind := 'markdown';
    SB := TStringBuilder.Create;
    try
      for I := 0 to Arr.Count - 1 do
      begin
        if Arr.Items[I] is TJSONString then
          SB.AppendLine(TJSONString(Arr.Items[I]).Value)
        else if Arr.Items[I] is TJSONObject then
        begin
          ItemObj := TJSONObject(Arr.Items[I]);
          if not ItemObj.TryGetValue<string>('value', Code) then Exit;
          if ItemObj.TryGetValue<string>('language', Lang) then
            SB.AppendFormat('```%s' + sLineBreak + '%s' + sLineBreak + '```' + sLineBreak, [Lang, Code])
          else
            SB.AppendLine(Code);
        end
        else
          Exit;
      end;
      Result.Value := SB.ToString.TrimRight([#10, #13]);
      IsValid := True;
    finally
      SB.Free;
    end;
  end;
end;

{ TLSPHover }

function TLSPHover.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('contents', Contents.ToJSON);
  if HasRange then
    Result.AddPair('range', Range.ToJSON);
end;

class function TLSPHover.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPHover;
var
  Val: TJSONValue;
  Ok: Boolean;
begin
  Result.HasRange := False;
  Result.Contents := TLSPMarkupContent.Default;
  Result.Range    := TLSPRange.Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('contents');
  if not Assigned(Val) or (Val is TJSONNull) then Exit;
  Result.Contents := TLSPMarkupContent.FromJSON(Val, Ok);
  if not Ok then Exit;

  Val := AJson.GetValue('range');
  if Val is TJSONObject then
  begin
    Result.Range := TLSPRange.FromJSON(TJSONObject(Val), Ok);
    Result.HasRange := Ok;
    IsValid := Ok;
  end
  else
    IsValid := True;
end;

{ TLSPCompletionContext }

function TLSPCompletionContext.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('triggerKind', TJSONNumber.Create(TriggerKind));
  if (TriggerKind = 2) and (TriggerCharacter <> '') then
    Result.AddPair('triggerCharacter', TriggerCharacter);
end;

class function TLSPCompletionContext.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionContext;
var
  TempChar: string;
begin
  Result.TriggerKind := 1;
  Result.TriggerCharacter := '';
  IsValid := True;
  if not Assigned(AJson) then Exit;

  AJson.TryGetValue<Integer>('triggerKind', Result.TriggerKind);
  if (Result.TriggerKind < 1) or (Result.TriggerKind > 3) then
    Result.TriggerKind := 1;

  if AJson.TryGetValue<string>('triggerCharacter', TempChar) then
  begin
    Result.TriggerCharacter := TempChar;
    if (Result.TriggerKind <> 2) or (Length(Result.TriggerCharacter) <> 1) then
      Result.TriggerCharacter := '';
  end;
end;

{ TLSPCompletionParams }

function TLSPCompletionParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
  Result.AddPair('position', Position.ToJSON);
  if HasContext then
    Result.AddPair('context', Context.ToJSON);
end;

class function TLSPCompletionParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionParams;
var
  Val: TJSONValue;
  Ok1, Ok2, Ok3: Boolean;
begin
  Result.HasContext := False;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
    Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(TJSONObject(Val), Ok1)
  else
    Exit;

  Val := AJson.GetValue('position');
  if Val is TJSONObject then
    Result.Position := TLSPPosition.FromJSON(TJSONObject(Val), Ok2)
  else
    Exit;

  Val := AJson.GetValue('context');
  if Val is TJSONObject then
  begin
    Result.Context := TLSPCompletionContext.FromJSON(TJSONObject(Val), Ok3);
    Result.HasContext := Ok3;
  end;

  IsValid := Ok1 and Ok2;
end;

{ TLSPCompletionItem }

function TLSPCompletionItem.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('label', Label_);
  if Kind > 0 then
    Result.AddPair('kind', TJSONNumber.Create(Kind));
  if Detail <> '' then
    Result.AddPair('detail', Detail);
  if HasDocumentation then
    Result.AddPair('documentation', Documentation.ToJSON);
  if InsertText <> '' then
    Result.AddPair('insertText', InsertText);
end;

class function TLSPCompletionItem.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPCompletionItem;
var
  Val: TJSONValue;
  Ok: Boolean;
begin
  Result.Label_ := '';
  Result.Kind := 0;
  Result.Detail := '';
  Result.InsertText := '';
  Result.Documentation := TLSPMarkupContent.Default;
  Result.HasDocumentation := False;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  IsValid := AJson.TryGetValue<string>('label', Result.Label_);
  if not IsValid then Exit;

  AJson.TryGetValue<Integer>('kind', Result.Kind);
  AJson.TryGetValue<string>('detail', Result.Detail);
  AJson.TryGetValue<string>('insertText', Result.InsertText);

  Val := AJson.GetValue('documentation');
  if Assigned(Val) and not (Val is TJSONNull) then
  begin
    Result.Documentation := TLSPMarkupContent.FromJSON(Val, Ok);
    Result.HasDocumentation := Ok;
  end;
end;

{ TLSPWorkspaceSymbolParams }

function TLSPWorkspaceSymbolParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('query', Query);
end;

class function TLSPWorkspaceSymbolParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPWorkspaceSymbolParams;
begin
  Result.Query := '';
  IsValid := Assigned(AJson) and AJson.TryGetValue<string>('query', Result.Query);
end;

{ TLSPSymbolInformation }

function TLSPSymbolInformation.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('kind', TJSONNumber.Create(Kind));
  Result.AddPair('location', Location.ToJSON);
  if ContainerName <> '' then
    Result.AddPair('containerName', ContainerName);
end;

class function TLSPSymbolInformation.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPSymbolInformation;
var
  Val: TJSONValue;
  Ok1, Ok2, Ok3: Boolean;
begin
  Result.Name := '';
  Result.Kind := 0;
  Result.ContainerName := '';
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Ok1 := AJson.TryGetValue<string>('name', Result.Name);
  Ok2 := AJson.TryGetValue<Integer>('kind', Result.Kind);
  AJson.TryGetValue<string>('containerName', Result.ContainerName);

  Val := AJson.GetValue('location');
  if Val is TJSONObject then
    Result.Location := TLSPLocation.FromJSON(TJSONObject(Val), Ok3)
  else
    Ok3 := False;

  IsValid := Ok1 and Ok2 and Ok3;
end;

{ TLSPInitializeParams }

constructor TLSPInitializeParams.Create;
begin
  inherited Create;
  ProcessId := 0;
  HasProcessId := False;
  RootUri := '';
  HasRootUri := False;
  Capabilities := nil;
  InitializationOptions := nil;
end;

destructor TLSPInitializeParams.Destroy;
begin
  Capabilities.Free;
  InitializationOptions.Free;
  inherited;
end;

function TLSPInitializeParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;

  if HasProcessId then
    Result.AddPair('processId', TJSONNumber.Create(ProcessId))
  else
    Result.AddPair('processId', TJSONNull.Create);

  if HasRootUri then
  begin
    if RootUri = '' then
      Result.AddPair('rootUri', TJSONNull.Create)
    else
      Result.AddPair('rootUri', RootUri);
  end;

  if Assigned(Capabilities) then
    Result.AddPair('capabilities', Capabilities.Clone as TJSONObject)
  else
    Result.AddPair('capabilities', TJSONObject.Create);

  if Assigned(InitializationOptions) then
    Result.AddPair('initializationOptions', InitializationOptions.Clone as TJSONObject);
end;

class function TLSPInitializeParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPInitializeParams;
var
  Val: TJSONValue;
begin
  Result := TLSPInitializeParams.Create;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('processId');
  if Val is TJSONNumber then
  begin
    Result.ProcessId := TJSONNumber(Val).AsInt;
    Result.HasProcessId := True;
  end;

  Val := AJson.GetValue('rootUri');
  if Val is TJSONString then
  begin
    Result.RootUri := TJSONString(Val).Value;
    Result.HasRootUri := True;
  end
  else if Val is TJSONNull then
  begin
    Result.RootUri := '';
    Result.HasRootUri := True;
  end
  else
    Result.HasRootUri := False;

  Val := AJson.GetValue('capabilities');
  if Val is TJSONObject then
    Result.Capabilities := TJSONObject(Val).Clone as TJSONObject
  else
    Exit; // capabilities is required

  Val := AJson.GetValue('initializationOptions');
  if Val is TJSONObject then
    Result.InitializationOptions := TJSONObject(Val).Clone as TJSONObject;

  IsValid := True;
end;

{ TLSPInitializeResult }

constructor TLSPInitializeResult.Create;
begin
  inherited Create;
  Capabilities := nil;
  ServerInfo := nil;
end;

destructor TLSPInitializeResult.Destroy;
begin
  Capabilities.Free;
  ServerInfo.Free;
  inherited;
end;

function TLSPInitializeResult.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if Assigned(Capabilities) then
    Result.AddPair('capabilities', Capabilities.Clone as TJSONObject)
  else
    Result.AddPair('capabilities', TJSONObject.Create);
  if Assigned(ServerInfo) then
	Result.AddPair('serverInfo', ServerInfo.Clone as TJSONObject);
end;

class function TLSPInitializeResult.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPInitializeResult;
var
  Val: TJSONValue;
begin
  Result := TLSPInitializeResult.Create;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('capabilities');
  if Val is TJSONObject then
    Result.Capabilities := TJSONObject(Val).Clone as TJSONObject
  else
    Exit; // capabilities required by spec

  Val := AJson.GetValue('serverInfo');
  if Val is TJSONObject then
    Result.ServerInfo := TJSONObject(Val).Clone as TJSONObject;

  IsValid := True;
end;

{ TLSPDidOpenTextDocumentParams }

function TLSPDidOpenTextDocumentParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
end;

class function TLSPDidOpenTextDocumentParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPDidOpenTextDocumentParams;
var
  Val: TJSONValue;
begin
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
  begin
    Result.TextDocument := TLSPTextDocumentItem.FromJSON(TJSONObject(Val), IsValid);
  end;
end;

{ TLSPTextDocumentContentChangeEvent }

class function TLSPTextDocumentContentChangeEvent.Empty: TLSPTextDocumentContentChangeEvent;
begin
  Result.HasRange := False;
  Result.Range := TLSPRange.Default;
  Result.HasRangeLength := False;
  Result.RangeLength := 0;
  Result.Text := '';
end;

function TLSPTextDocumentContentChangeEvent.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if HasRange then
  begin
    Result.AddPair('range', Range.ToJSON);
    if HasRangeLength then
      Result.AddPair('rangeLength', TJSONNumber.Create(RangeLength));
  end;
  Result.AddPair('text', Text);
end;

class function TLSPTextDocumentContentChangeEvent.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPTextDocumentContentChangeEvent;
var
  Val: TJSONValue;
  Ok: Boolean;
begin
  Result := Empty;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('range');
  if Val is TJSONObject then
  begin
    Result.Range := TLSPRange.FromJSON(TJSONObject(Val), Ok);
    Result.HasRange := Ok;
  end;

  Val := AJson.GetValue('rangeLength');
  if Val is TJSONNumber then
  begin
    Result.RangeLength := TJSONNumber(Val).AsInt;
    if Result.RangeLength < 0 then
      Result.RangeLength := 0;
    Result.HasRangeLength := True;
  end;

  IsValid := AJson.TryGetValue<string>('text', Result.Text);
end;

{ TLSPDidChangeTextDocumentParams }

function TLSPDidChangeTextDocumentParams.ToJSON: TJSONObject;
var
  ChangesArray: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);

  ChangesArray := TJSONArray.Create;
  for I := 0 to High(ContentChanges) do
    ChangesArray.Add(ContentChanges[I].ToJSON);
  Result.AddPair('contentChanges', ChangesArray);
end;

class function TLSPDidChangeTextDocumentParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPDidChangeTextDocumentParams;
var
  Val: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
  OkDoc, OkChange: Boolean;
begin
  SetLength(Result.ContentChanges, 0);
  Result.TextDocument := TLSPVersionedTextDocumentIdentifier.Default;
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
    Result.TextDocument := TLSPVersionedTextDocumentIdentifier.FromJSON(TJSONObject(Val), OkDoc)
  else
    Exit;

  Val := AJson.GetValue('contentChanges');
  if not (Val is TJSONArray) then Exit;
  Arr := TJSONArray(Val);
  SetLength(Result.ContentChanges, Arr.Count);
  IsValid := OkDoc and (Arr.Count > 0);
  for I := 0 to Arr.Count - 1 do
  begin
    if Arr.Items[I] is TJSONObject then
    begin
      Result.ContentChanges[I] := TLSPTextDocumentContentChangeEvent.FromJSON(
        TJSONObject(Arr.Items[I]), OkChange);
      IsValid := IsValid and OkChange;
    end
    else
    begin
      Result.ContentChanges[I] := TLSPTextDocumentContentChangeEvent.Empty;
      IsValid := False;
    end;
  end;
end;

{ TLSPDidCloseTextDocumentParams }

function TLSPDidCloseTextDocumentParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
end;

class function TLSPDidCloseTextDocumentParams.FromJSON(
  AJson: TJSONObject; out IsValid: Boolean): TLSPDidCloseTextDocumentParams;
var
  Val: TJSONValue;
begin
  IsValid := False;
  if not Assigned(AJson) then Exit;

  Val := AJson.GetValue('textDocument');
  if Val is TJSONObject then
  begin
    Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(TJSONObject(Val), IsValid);
  end;
end;

end.
