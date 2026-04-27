unit MCP.Tools.LSP;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, System.Math, System.IOUtils, Winapi.Windows,
  MCP.Protocol.Types, LSP.Client, LSP.Protocol.Types, Common.Logging;

type
  TMCPLSPTools = class
  private
    FLSPClient: TLSPClient;
    FOpenedFiles: THashSet<string>;

    function CreateTextContent(const AText: string): TMCPContentItem;
    function LocationToText(const ALocation: TLSPLocation): string;
    function EnsureDocumentOpen(const AUri: string): Boolean;
    function RetryLSPCall<T>(ARequest: TFunc<TArray<T>>; const AContext: string; out AHadTimeout: Boolean): TArray<T>;
  public
    // FIX: Move constants here so generic method can see them
    const
      LSP_RETRY_COUNT = 3;
      LSP_RETRY_DELAY_MS: array[0..2] of Integer = (100, 300, 600);
      LSP_TIMEOUT_MSG = '[LSP server not responding] ';

    constructor Create(ALSPClient: TLSPClient);
    destructor Destroy; override;

    class function GetToolDefinitions: TArray<TMCPTool>;
    function ExecuteTool(const AToolName: string; AArguments: TJSONObject): TMCPToolCallResult;

    // Individual tool implementations
    function ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteFindReferences(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteHover(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteCompletion(AArguments: TJSONObject): TMCPToolCallResult;
    function ExecuteWorkspaceSymbols(AArguments: TJSONObject): TMCPToolCallResult;
  end;

implementation

uses
  System.NetEncoding;

{ TMCPLSPTools }

constructor TMCPLSPTools.Create(ALSPClient: TLSPClient);
begin
  inherited Create;
  FLSPClient := ALSPClient;
  FOpenedFiles := THashSet<string>.Create;
end;

destructor TMCPLSPTools.Destroy;
begin
  FOpenedFiles.Free;
  inherited;
end;

function TMCPLSPTools.EnsureDocumentOpen(const AUri: string): Boolean;
var
  FilePath: string;
  FileContent: string;
begin
  Result := False;
  if FOpenedFiles.Contains(AUri) then
    Exit(True);

  // Convert URI to FilePath
  if AUri.StartsWith('file:///', True) then
  begin
    FilePath := AUri.Substring(8); // Remove file:///
    FilePath := TNetEncoding.URL.Decode(FilePath);
    FilePath := StringReplace(FilePath, '/', '\', [rfReplaceAll]);
  end
  else
    Exit; // Not a file URI we can handle

  if FileExists(FilePath) then
  begin
    try
      FileContent := TFile.ReadAllText(FilePath);
      FLSPClient.DidOpenTextDocument(AUri, 'pascal', FileContent, 1);
      FOpenedFiles.Add(AUri);
      Logger.Info('Auto-opened document: %s', [AUri]);
      Result := True;
    except
      on E: Exception do
        Logger.Error('Failed to auto-open document %s: %s', [FilePath, E.Message]);
    end;
  end;
end;

function TMCPLSPTools.RetryLSPCall<T>(ARequest: TFunc<TArray<T>>; const AContext: string; out AHadTimeout: Boolean): TArray<T>;
var
  I: Integer;
begin
  AHadTimeout := False;
  for I := 0 to LSP_RETRY_COUNT - 1 do
  begin
    Result := ARequest();
    if Length(Result) > 0 then
      Exit; // Got results, done

    if I < LSP_RETRY_COUNT - 1 then
    begin
      Logger.Debug('%s returned 0 results, retrying in %dms (attempt %d/%d)',
        [AContext, LSP_RETRY_DELAY_MS[I], I + 2, LSP_RETRY_COUNT]);
      Sleep(LSP_RETRY_DELAY_MS[I]);
    end
    else
    begin
      AHadTimeout := True;
      Logger.Warning('%s timed out after %d retries', [AContext, LSP_RETRY_COUNT]);
    end;
  end;
end;

class function TMCPLSPTools.GetToolDefinitions: TArray<TMCPTool>;
  function MakeSchema(ARequired: TArray<string>; AProps: TJSONObject): TMCPToolInputSchema;
  begin
    Result := TMCPToolInputSchema.Create;
    Result.SchemaType := 'object';
    Result.Properties := AProps;
    Result.Required := ARequired;
  end;

  function MakeTool(const AName, ADesc: string; ASchema: TMCPToolInputSchema): TMCPTool;
  begin
    Result := TMCPTool.Create;
    Result.Name := AName;
    Result.Description := ADesc;
    Result.InputSchema := ASchema;
  end;

var
  Props: TJSONObject;
begin
  SetLength(Result, 5);

  // delphi_goto_definition
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Result[0] := MakeTool('delphi_goto_definition',
    'Find the definition of a symbol at a specific position in a Delphi source file',
    MakeSchema(['uri', 'line', 'character'], Props));

  // delphi_find_references
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Props.AddPair('includeDeclaration', TJSONObject.Create.AddPair('type', 'boolean').AddPair('description', 'Include the declaration in results').AddPair('default', TJSONBool.Create(True)));
  Result[1] := MakeTool('delphi_find_references',
    'Find all references to a symbol at a specific position in a Delphi source file',
    MakeSchema(['uri', 'line', 'character'], Props));

  // delphi_hover
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Result[2] := MakeTool('delphi_hover',
    'Get hover information (documentation, type info) for a symbol at a specific position',
    MakeSchema(['uri', 'line', 'character'], Props));

  // delphi_completion
  Props := TJSONObject.Create;
  Props.AddPair('uri', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'File URI (e.g., file:///C:/path/to/file.pas)'));
  Props.AddPair('line', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based line number'));
  Props.AddPair('character', TJSONObject.Create.AddPair('type', 'integer').AddPair('description', 'Zero-based character offset'));
  Result[3] := MakeTool('delphi_completion',
    'Get code completion suggestions at a specific position in a Delphi source file',
    MakeSchema(['uri', 'line', 'character'], Props));

  // delphi_workspace_symbols
  Props := TJSONObject.Create;
  Props.AddPair('query', TJSONObject.Create.AddPair('type', 'string').AddPair('description', 'Search query string'));
  Result[4] := MakeTool('delphi_workspace_symbols',
    'Search for symbols (classes, functions, procedures, etc.) across the entire workspace',
    MakeSchema(['query'], Props));
end;

function TMCPLSPTools.ExecuteTool(const AToolName: string; AArguments: TJSONObject): TMCPToolCallResult;
begin
  try
    if AToolName = 'delphi_goto_definition' then
      Result := ExecuteGotoDefinition(AArguments)
    else if AToolName = 'delphi_find_references' then
      Result := ExecuteFindReferences(AArguments)
    else if AToolName = 'delphi_hover' then
      Result := ExecuteHover(AArguments)
    else if AToolName = 'delphi_completion' then
      Result := ExecuteCompletion(AArguments)
    else if AToolName = 'delphi_workspace_symbols' then
      Result := ExecuteWorkspaceSymbols(AArguments)
    else
    begin
      Result := TMCPToolCallResult.Create;
      Result.IsError := True;
      Result.Content.Add(CreateTextContent('Unknown tool: ' + AToolName));
    end;
  except
    on E: Exception do
    begin
      Logger.Error('Tool execution error (%s): %s', [AToolName, E.Message]);
      Result := TMCPToolCallResult.Create;
      Result.IsError := True;
      Result.Content.Add(CreateTextContent('Error: ' + E.Message));
    end;
  end;
end;

function TMCPLSPTools.ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
  WasJustOpened, HadTimeout: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;

  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');

  WasJustOpened := EnsureDocumentOpen(Uri);

  Locations := RetryLSPCall<TLSPLocation>(
    function: TArray<TLSPLocation>
    begin
      Result := FLSPClient.GetDefinition(Uri, Line, Character);
    end,
    'GetDefinition',
    HadTimeout);

  if Length(Locations) = 0 then
  begin
    if HadTimeout then
      ResultText := LSP_TIMEOUT_MSG + 'No definition found after 3 retries'
    else if WasJustOpened then
      ResultText := 'No definition found (document was just opened, LSP may still be indexing)'
    else
      ResultText := 'No definition found';
  end
  else
  begin
    ResultText := Format('Found %d definition(s):'#13#10, [Length(Locations)]);
    for I := 0 to Min(High(Locations), 19) do
      ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
    if Length(Locations) > 20 then
      ResultText := ResultText + Format('... and %d more', [Length(Locations) - 20]);
  end;

  Result.Content.Add(CreateTextContent(ResultText));
end;

function TMCPLSPTools.ExecuteFindReferences(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  IncludeDeclaration: Boolean;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
  HadTimeout: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;

  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');

  if not AArguments.TryGetValue<Boolean>('includeDeclaration', IncludeDeclaration) then
    IncludeDeclaration := True;

  EnsureDocumentOpen(Uri);

  Locations := RetryLSPCall<TLSPLocation>(
    function: TArray<TLSPLocation>
    begin
      Result := FLSPClient.GetReferences(Uri, Line, Character, IncludeDeclaration);
    end,
    'GetReferences',
    HadTimeout);

  if Length(Locations) = 0 then
  begin
    if HadTimeout then
      ResultText := LSP_TIMEOUT_MSG + 'No references found after 3 retries'
    else
      ResultText := 'No references found';
  end
  else
  begin
    ResultText := Format('Found %d reference(s):'#13#10, [Length(Locations)]);
    for I := 0 to Min(High(Locations), 49) do
      ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
    if Length(Locations) > 50 then
      ResultText := ResultText + Format('... and %d more', [Length(Locations) - 50]);
  end;

  Result.Content.Add(CreateTextContent(ResultText));
end;

function TMCPLSPTools.ExecuteHover(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Hover: TLSPHover;
  ResultText: string;
  RetryCount: Integer;
  HadTimeout: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;

  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');

  EnsureDocumentOpen(Uri);

  ResultText := 'No hover information available';
  HadTimeout := True;
  for RetryCount := 0 to LSP_RETRY_COUNT - 1 do
  begin
    if FLSPClient.GetHover(Uri, Line, Character, Hover) then
    begin
      if Hover.Contents.Value <> '' then
      begin
        ResultText := Hover.Contents.Value;
        HadTimeout := False;
        Break;
      end;
    end;
    if RetryCount < LSP_RETRY_COUNT - 1 then
      Sleep(LSP_RETRY_DELAY_MS[RetryCount]);
  end;

  if HadTimeout and (ResultText = 'No hover information available') then
    ResultText := LSP_TIMEOUT_MSG + 'No hover information available after 3 retries';

  Result.Content.Add(CreateTextContent(ResultText));
end;

function TMCPLSPTools.ExecuteCompletion(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Character: Integer;
  Items: TArray<TLSPCompletionItem>;
  I: Integer;
  ResultText: string;
  HadTimeout: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;

  Uri := AArguments.GetValue<string>('uri');
  Line := AArguments.GetValue<Integer>('line');
  Character := AArguments.GetValue<Integer>('character');

  EnsureDocumentOpen(Uri);

  Items := RetryLSPCall<TLSPCompletionItem>(
    function: TArray<TLSPCompletionItem>
    begin
      Result := FLSPClient.GetCompletion(Uri, Line, Character);
    end,
    'GetCompletion',
    HadTimeout);

  if Length(Items) = 0 then
  begin
    if HadTimeout then
      ResultText := LSP_TIMEOUT_MSG + 'No completion suggestions available after 3 retries'
    else
      ResultText := 'No completion suggestions available';
  end
  else
  begin
    ResultText := Format('Found %d completion suggestion(s):'#13#10, [Length(Items)]);
    for I := 0 to Min(High(Items), 49) do
    begin
      ResultText := ResultText + Format('%d. %s', [I + 1, Items[I].Label_]);
      if Items[I].Detail <> '' then
        ResultText := ResultText + ' - ' + Items[I].Detail;
      ResultText := ResultText + #13#10;
    end;
    if Length(Items) > 50 then
      ResultText := ResultText + Format('... and %d more', [Length(Items) - 50]);
  end;

  Result.Content.Add(CreateTextContent(ResultText));
end;

function TMCPLSPTools.ExecuteWorkspaceSymbols(AArguments: TJSONObject): TMCPToolCallResult;
var
  Query: string;
  Symbols: TArray<TLSPSymbolInformation>;
  I: Integer;
  ResultText: string;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;

  Query := AArguments.GetValue<string>('query');

  Symbols := FLSPClient.GetWorkspaceSymbols(Query);

  if Length(Symbols) = 0 then
  begin
    ResultText := Format('No symbols found matching "%s"', [Query]);
  end
  else
  begin
    ResultText := Format('Found %d symbol(s) matching "%s":'#13#10, [Length(Symbols), Query]);
    for I := 0 to Min(High(Symbols), 49) do
    begin
      ResultText := ResultText + Format('%d. %s', [I + 1, Symbols[I].Name]);
      if Symbols[I].ContainerName <> '' then
        ResultText := ResultText + ' (in ' + Symbols[I].ContainerName + ')';
      ResultText := ResultText + #13#10' ' + LocationToText(Symbols[I].Location) + #13#10;
    end;
    if Length(Symbols) > 50 then
      ResultText := ResultText + Format('... and %d more', [Length(Symbols) - 50]);
  end;

  Result.Content.Add(CreateTextContent(ResultText));
end;

function TMCPLSPTools.CreateTextContent(const AText: string): TMCPContentItem;
begin
  Result := TMCPContentItem.Create;
  Result.ContentType := 'text';
  Result.Text := AText;
end;

function TMCPLSPTools.LocationToText(const ALocation: TLSPLocation): string;
begin
  Result := Format('%s:%d:%d', [
    ALocation.Uri,
    ALocation.Range.Start.Line + 1, // Convert to 1-based for display
    ALocation.Range.Start.Character + 1
  ]);
end;

end.
