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
    class function FromJSON(AJson: TJSONObject): TLSPPosition; static;
  end;

  // LSP Range
  TLSPRange = record
    Start: TLSPPosition;
    &End: TLSPPosition;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPRange; static;
  end;

  // LSP Location
  TLSPLocation = record
    Uri: string;
    Range: TLSPRange;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPLocation; static;
  end;

  // LSP Text Document Identifier
  TLSPTextDocumentIdentifier = record
    Uri: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPTextDocumentIdentifier; static;
  end;

  // LSP Text Document Position Params
  TLSPTextDocumentPositionParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPTextDocumentPositionParams; static;
  end;

  // LSP Definition Params
  TLSPDefinitionParams = TLSPTextDocumentPositionParams;

  // LSP References Context
  TLSPReferenceContext = record
    IncludeDeclaration: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPReferenceContext; static;
  end;

  // LSP References Params
  TLSPReferenceParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    Context: TLSPReferenceContext;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPReferenceParams; static;
  end;

  // LSP Hover Params
  TLSPHoverParams = TLSPTextDocumentPositionParams;

  // LSP Markup Content
  TLSPMarkupContent = record
    Kind: string; // "plaintext" or "markdown"
    Value: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPMarkupContent; static;
  end;

  // LSP Hover Result
  TLSPHover = record
    Contents: TLSPMarkupContent;
    Range: TLSPRange;
    HasRange: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPHover; static;
  end;

  // LSP Completion Context
  TLSPCompletionContext = record
    TriggerKind: Integer; // 1=Invoked, 2=TriggerCharacter, 3=TriggerForIncompleteCompletions
    TriggerCharacter: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPCompletionContext; static;
  end;

  // LSP Completion Params
  TLSPCompletionParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    Position: TLSPPosition;
    Context: TLSPCompletionContext;
    HasContext: Boolean;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPCompletionParams; static;
  end;

  // LSP Completion Item
  TLSPCompletionItem = record
    Label_: string;
    Kind: Integer;
    Detail: string;
    Documentation: string;
    InsertText: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPCompletionItem; static;
  end;

  // LSP Workspace Symbol Params
  TLSPWorkspaceSymbolParams = record
    Query: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPWorkspaceSymbolParams; static;
  end;

  // LSP Symbol Information
  TLSPSymbolInformation = record
    Name: string;
    Kind: Integer;
    Location: TLSPLocation;
    ContainerName: string;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPSymbolInformation; static;
  end;

  // LSP Initialize Params
  TLSPInitializeParams = record
    ProcessId: Integer;
    RootUri: string;
    Capabilities: TJSONObject;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPInitializeParams; static;
  end;

  // LSP Initialize Result
  TLSPInitializeResult = record
    Capabilities: TJSONObject;
    ServerInfo: TJSONObject;
    function ToJSON: TJSONObject;
    class function FromJSON(AJson: TJSONObject): TLSPInitializeResult; static;
  end;

  // LSP Did Open Text Document Params
  TLSPDidOpenTextDocumentParams = record
    TextDocument: record
      Uri: string;
      LanguageId: string;
      Version: Integer;
      Text: string;
    end;
    function ToJSON: TJSONObject;
  end;

  // LSP Did Change Text Document Params
  TLSPDidChangeTextDocumentParams = record
    TextDocument: record
      Uri: string;
      Version: Integer;
    end;
    ContentChanges: TArray<TJSONObject>;
    function ToJSON: TJSONObject;
  end;

  // LSP Did Close Text Document Params
  TLSPDidCloseTextDocumentParams = record
    TextDocument: TLSPTextDocumentIdentifier;
    function ToJSON: TJSONObject;
  end;

implementation

{ TLSPPosition }

function TLSPPosition.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('line', TJSONNumber.Create(Line));
  Result.AddPair('character', TJSONNumber.Create(Character));
end;

class function TLSPPosition.FromJSON(AJson: TJSONObject): TLSPPosition;
begin
  Result.Line := AJson.GetValue<Integer>('line');
  Result.Character := AJson.GetValue<Integer>('character');
end;

{ TLSPRange }

function TLSPRange.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('start', Start.ToJSON);
  Result.AddPair('end', &End.ToJSON);
end;

class function TLSPRange.FromJSON(AJson: TJSONObject): TLSPRange;
begin
  Result.Start := TLSPPosition.FromJSON(AJson.GetValue('start') as TJSONObject);
  Result.&End := TLSPPosition.FromJSON(AJson.GetValue('end') as TJSONObject);
end;

{ TLSPLocation }

function TLSPLocation.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
  Result.AddPair('range', Range.ToJSON);
end;

class function TLSPLocation.FromJSON(AJson: TJSONObject): TLSPLocation;
begin
  Result.Uri := AJson.GetValue<string>('uri');
  Result.Range := TLSPRange.FromJSON(AJson.GetValue('range') as TJSONObject);
end;

{ TLSPTextDocumentIdentifier }

function TLSPTextDocumentIdentifier.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Uri);
end;

class function TLSPTextDocumentIdentifier.FromJSON(AJson: TJSONObject): TLSPTextDocumentIdentifier;
begin
  Result.Uri := AJson.GetValue<string>('uri');
end;

{ TLSPTextDocumentPositionParams }

function TLSPTextDocumentPositionParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
  Result.AddPair('position', Position.ToJSON);
end;

class function TLSPTextDocumentPositionParams.FromJSON(AJson: TJSONObject): TLSPTextDocumentPositionParams;
begin
  Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(AJson.GetValue('textDocument') as TJSONObject);
  Result.Position := TLSPPosition.FromJSON(AJson.GetValue('position') as TJSONObject);
end;

{ TLSPReferenceContext }

function TLSPReferenceContext.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('includeDeclaration', TJSONBool.Create(IncludeDeclaration));
end;

class function TLSPReferenceContext.FromJSON(AJson: TJSONObject): TLSPReferenceContext;
begin
  Result.IncludeDeclaration := AJson.GetValue<Boolean>('includeDeclaration');
end;

{ TLSPReferenceParams }

function TLSPReferenceParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
  Result.AddPair('position', Position.ToJSON);
  Result.AddPair('context', Context.ToJSON);
end;

class function TLSPReferenceParams.FromJSON(AJson: TJSONObject): TLSPReferenceParams;
begin
  Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(AJson.GetValue('textDocument') as TJSONObject);
  Result.Position := TLSPPosition.FromJSON(AJson.GetValue('position') as TJSONObject);
  Result.Context := TLSPReferenceContext.FromJSON(AJson.GetValue('context') as TJSONObject);
end;

{ TLSPMarkupContent }

function TLSPMarkupContent.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('kind', Kind);
  Result.AddPair('value', Value);
end;

class function TLSPMarkupContent.FromJSON(AJson: TJSONObject): TLSPMarkupContent;
begin
  Result.Kind := AJson.GetValue<string>('kind');
  Result.Value := AJson.GetValue<string>('value');
end;

{ TLSPHover }

function TLSPHover.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('contents', Contents.ToJSON);
  if HasRange then
    Result.AddPair('range', Range.ToJSON);
end;

class function TLSPHover.FromJSON(AJson: TJSONObject): TLSPHover;
var
  ContentsValue: TJSONValue;
begin
  ContentsValue := AJson.GetValue('contents');
  if ContentsValue is TJSONObject then
    Result.Contents := TLSPMarkupContent.FromJSON(ContentsValue as TJSONObject)
  else if ContentsValue is TJSONString then
  begin
    Result.Contents.Kind := 'plaintext';
    Result.Contents.Value := (ContentsValue as TJSONString).Value;
  end;
  
  Result.HasRange := Assigned(AJson.GetValue('range'));
  if Result.HasRange then
    Result.Range := TLSPRange.FromJSON(AJson.GetValue('range') as TJSONObject);
end;

{ TLSPCompletionContext }

function TLSPCompletionContext.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('triggerKind', TJSONNumber.Create(TriggerKind));
  if TriggerCharacter <> '' then
    Result.AddPair('triggerCharacter', TriggerCharacter);
end;

class function TLSPCompletionContext.FromJSON(AJson: TJSONObject): TLSPCompletionContext;
begin
  Result.TriggerKind := AJson.GetValue<Integer>('triggerKind');
  AJson.TryGetValue<string>('triggerCharacter', Result.TriggerCharacter);
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

class function TLSPCompletionParams.FromJSON(AJson: TJSONObject): TLSPCompletionParams;
begin
  Result.TextDocument := TLSPTextDocumentIdentifier.FromJSON(AJson.GetValue('textDocument') as TJSONObject);
  Result.Position := TLSPPosition.FromJSON(AJson.GetValue('position') as TJSONObject);
  Result.HasContext := Assigned(AJson.GetValue('context'));
  if Result.HasContext then
    Result.Context := TLSPCompletionContext.FromJSON(AJson.GetValue('context') as TJSONObject);
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
  if Documentation <> '' then
    Result.AddPair('documentation', Documentation);
  if InsertText <> '' then
    Result.AddPair('insertText', InsertText);
end;

class function TLSPCompletionItem.FromJSON(AJson: TJSONObject): TLSPCompletionItem;
begin
  Result.Label_ := AJson.GetValue<string>('label');
  AJson.TryGetValue<Integer>('kind', Result.Kind);
  AJson.TryGetValue<string>('detail', Result.Detail);
  AJson.TryGetValue<string>('documentation', Result.Documentation);
  AJson.TryGetValue<string>('insertText', Result.InsertText);
end;

{ TLSPWorkspaceSymbolParams }

function TLSPWorkspaceSymbolParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('query', Query);
end;

class function TLSPWorkspaceSymbolParams.FromJSON(AJson: TJSONObject): TLSPWorkspaceSymbolParams;
begin
  Result.Query := AJson.GetValue<string>('query');
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

class function TLSPSymbolInformation.FromJSON(AJson: TJSONObject): TLSPSymbolInformation;
begin
  Result.Name := AJson.GetValue<string>('name');
  Result.Kind := AJson.GetValue<Integer>('kind');
  Result.Location := TLSPLocation.FromJSON(AJson.GetValue('location') as TJSONObject);
  AJson.TryGetValue<string>('containerName', Result.ContainerName);
end;

{ TLSPInitializeParams }

function TLSPInitializeParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if ProcessId > 0 then
    Result.AddPair('processId', TJSONNumber.Create(ProcessId))
  else
    Result.AddPair('processId', TJSONNull.Create);
  if RootUri <> '' then
    Result.AddPair('rootUri', RootUri)
  else
    Result.AddPair('rootUri', TJSONNull.Create);
  if Assigned(Capabilities) then
    Result.AddPair('capabilities', Capabilities.Clone as TJSONObject)
  else
    Result.AddPair('capabilities', TJSONObject.Create);
end;

class function TLSPInitializeParams.FromJSON(AJson: TJSONObject): TLSPInitializeParams;
begin
  AJson.TryGetValue<Integer>('processId', Result.ProcessId);
  AJson.TryGetValue<string>('rootUri', Result.RootUri);
  Result.Capabilities := AJson.GetValue('capabilities') as TJSONObject;
  if Assigned(Result.Capabilities) then
    Result.Capabilities := Result.Capabilities.Clone as TJSONObject;
end;

{ TLSPInitializeResult }

function TLSPInitializeResult.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if Assigned(Capabilities) then
    Result.AddPair('capabilities', Capabilities.Clone as TJSONObject);
  if Assigned(ServerInfo) then
    Result.AddPair('serverInfo', ServerInfo.Clone as TJSONObject);
end;

class function TLSPInitializeResult.FromJSON(AJson: TJSONObject): TLSPInitializeResult;
begin
  Result.Capabilities := AJson.GetValue('capabilities') as TJSONObject;
  if Assigned(Result.Capabilities) then
    Result.Capabilities := Result.Capabilities.Clone as TJSONObject;
  Result.ServerInfo := AJson.GetValue('serverInfo') as TJSONObject;
  if Assigned(Result.ServerInfo) then
    Result.ServerInfo := Result.ServerInfo.Clone as TJSONObject;
end;

{ TLSPDidOpenTextDocumentParams }

function TLSPDidOpenTextDocumentParams.ToJSON: TJSONObject;
var
  TextDocObj: TJSONObject;
begin
  Result := TJSONObject.Create;
  TextDocObj := TJSONObject.Create;
  TextDocObj.AddPair('uri', TextDocument.Uri);
  TextDocObj.AddPair('languageId', TextDocument.LanguageId);
  TextDocObj.AddPair('version', TJSONNumber.Create(TextDocument.Version));
  TextDocObj.AddPair('text', TextDocument.Text);
  Result.AddPair('textDocument', TextDocObj);
end;

{ TLSPDidChangeTextDocumentParams }

function TLSPDidChangeTextDocumentParams.ToJSON: TJSONObject;
var
  TextDocObj: TJSONObject;
  ChangesArray: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  TextDocObj := TJSONObject.Create;
  TextDocObj.AddPair('uri', TextDocument.Uri);
  TextDocObj.AddPair('version', TJSONNumber.Create(TextDocument.Version));
  Result.AddPair('textDocument', TextDocObj);
  
  ChangesArray := TJSONArray.Create;
  for I := 0 to High(ContentChanges) do
    ChangesArray.Add(ContentChanges[I].Clone as TJSONObject);
  Result.AddPair('contentChanges', ChangesArray);
end;

{ TLSPDidCloseTextDocumentParams }

function TLSPDidCloseTextDocumentParams.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('textDocument', TextDocument.ToJSON);
end;

end.
