unit MCP.Tools.LSP;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.Math, System.IOUtils, Winapi.Windows, System.DateUtils,
  MCP.Protocol.Types, LSP.Client, LSP.Protocol.Types, Common.Logging;

type
{$IFNDEF FPC}
  {$IF CompilerVersion < 36.0}
  THashSet<T> = class
  private
    FDict: TDictionary<T, Byte>;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const Item: T): Boolean;
    function Contains(const Item: T): Boolean;
    function Remove(const Item: T): Boolean;
    procedure Clear;
    function Count: Integer;
  end;
  {$ENDIF}
{$ENDIF}

  TLSPCallFunc<T> = reference to function(out AResults: TArray<T>): Boolean;

  TMCPLSPTools = class
  private
    FLSPClient: TLSPClient;
    FOpenedFiles: THashSet<string>;
    FDebugMode: Boolean;
    FCallTimeouts: TDictionary<string, Integer>;
    FStats: TDictionary<string, TDictionary<string, Integer>>;
    FLogContext: ILogContext;

    function CreateTextContent(const AText: string): TMCPContentItem;
    function LocationToText(const ALocation: TLSPLocation): string;
    function EnsureDocumentOpen(const AUri: string): Boolean;
    function RetryLSPCall<T>(ACall: TLSPCallFunc<T>; const AContext: string;
      out AHadTimeout: Boolean; ATimeoutMs: Integer = 15000): TArray<T>;
    procedure LogDebug(const Msg: string); overload;
    procedure LogDebug(const Msg: string; const Args: array of const); overload;
    procedure LogTiming(const Operation: string; StartTime: UInt64);
    procedure UpdateStats(const Category, Key: string);
    procedure LogStats;
  public
    const
      LSP_RETRY_COUNT = 2;
      LSP_RETRY_DELAY_MS: array[0..1] of Integer = (500, 1000);
      LSP_TIMEOUT_MSG = '[LSP server not responding] ';
      LSP_OPERATION_TIMEOUT = 15000;

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

    property DebugMode: Boolean read FDebugMode write FDebugMode;
  end;

implementation

uses
  System.NetEncoding;

{$IFNDEF FPC}
  {$IF CompilerVersion < 36.0}
constructor THashSet<T>.Create;
begin
  inherited Create;
  FDict := TDictionary<T, Byte>.Create;
end;

destructor THashSet<T>.Destroy;
begin
  FDict.Free;
  inherited;
end;

function THashSet<T>.Add(const Item: T): Boolean;
begin
  Result := not FDict.ContainsKey(Item);
  if Result then
    FDict.Add(Item, 0);
end;

function THashSet<T>.Contains(const Item: T): Boolean;
begin
  Result := FDict.ContainsKey(Item);
end;

function THashSet<T>.Remove(const Item: T): Boolean;
begin
  Result := FDict.ContainsKey(Item);
  if Result then
    FDict.Remove(Item);
end;

procedure THashSet<T>.Clear;
begin
  FDict.Clear;
end;

function THashSet<T>.Count: Integer;
begin
  Result := FDict.Count;
end;
  {$ENDIF}
{$ENDIF}

{ TMCPLSPTools }

constructor TMCPLSPTools.Create(ALSPClient: TLSPClient);
var
  Categories: array of string;
  Cat: string;
  StatsDict: TDictionary<string, Integer>;
begin
  inherited Create;
  FLSPClient := ALSPClient;
  FOpenedFiles := THashSet<string>.Create;
  FCallTimeouts := TDictionary<string, Integer>.Create;
  FStats := TDictionary<string, TDictionary<string, Integer>>.Create;
  FDebugMode := False;
  FLogContext := Logger.CreateContext('LSPTools');

  FLogContext.Enter('Create');
  try
    // Initialize timeout tracking
    FCallTimeouts.Add('GetDefinition', 0);
    FCallTimeouts.Add('GetReferences', 0);
    FCallTimeouts.Add('GetHover', 0);
    FCallTimeouts.Add('GetCompletion', 0);
    FCallTimeouts.Add('GetWorkspaceSymbols', 0);

    // Initialize statistics
    Categories := ['GetDefinition', 'GetReferences', 'GetHover',
                   'GetCompletion', 'GetWorkspaceSymbols'];
    for Cat in Categories do
    begin
      StatsDict := TDictionary<string, Integer>.Create;
      StatsDict.Add('TotalCalls', 0);
      StatsDict.Add('SuccessCount', 0);
      StatsDict.Add('FailureCount', 0);
      StatsDict.Add('TimeoutCount', 0);
      StatsDict.Add('TotalTimeMs', 0);
      FStats.Add(Cat, StatsDict);
    end;

    LogDebug('TMCPLSPTools created with stats tracking');
  finally
    FLogContext.Exit('Create');
  end;
end;

destructor TMCPLSPTools.Destroy;
var
  StatsDict: TDictionary<string, Integer>;
begin
  FLogContext.Enter('Destroy');
  try
    LogStats;
    for StatsDict in FStats.Values do
      StatsDict.Free;
    FStats.Free;
    FCallTimeouts.Free;
    FOpenedFiles.Free;
    LogDebug('TMCPLSPTools destroyed');
  finally
    FLogContext.Exit('Destroy');
    inherited;
  end;
end;

procedure TMCPLSPTools.UpdateStats(const Category, Key: string);
var
  StatsDict: TDictionary<string, Integer>;
  CurrentValue: Integer;
begin
  if FStats.TryGetValue(Category, StatsDict) then
  begin
    if StatsDict.TryGetValue(Key, CurrentValue) then
      StatsDict.AddOrSetValue(Key, CurrentValue + 1)
    else
      StatsDict.Add(Key, 1);
  end;
end;

procedure TMCPLSPTools.LogStats;
var
  Category: string;
  StatsDict: TDictionary<string, Integer>;
  TotalCalls, SuccessCount, FailureCount, TimeoutCount, TotalTimeMs, AvgTimeMs: Integer;
begin
  if not FDebugMode then
    Exit;

  Logger.Info('[LSPTools Statistics]');
  for Category in FStats.Keys do
  begin
    StatsDict := FStats[Category];
    TotalCalls := StatsDict['TotalCalls'];
    SuccessCount := StatsDict['SuccessCount'];
    FailureCount := StatsDict['FailureCount'];
    TimeoutCount := StatsDict['TimeoutCount'];
    TotalTimeMs := StatsDict['TotalTimeMs'];
    AvgTimeMs := 0;
    if TotalCalls > 0 then
      AvgTimeMs := TotalTimeMs div TotalCalls;

    Logger.Info('  %s: Calls=%d, Success=%d, Fail=%d, Timeout=%d, AvgTime=%dms',
      [Category, TotalCalls, SuccessCount, FailureCount, TimeoutCount, AvgTimeMs]);
  end;
end;

procedure TMCPLSPTools.LogDebug(const Msg: string);
begin
  if FDebugMode then
    FLogContext.Log(Msg);
end;

procedure TMCPLSPTools.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
    FLogContext.LogFmt(Msg, Args);
end;

procedure TMCPLSPTools.LogTiming(const Operation: string; StartTime: UInt64);
var
  ElapsedMs: Integer;
  Category: string;
  DotPos: Integer;
  Count: Integer;
  StatsDict: TDictionary<string, Integer>;
  TotalTime: Integer;
  TimeoutCount: Integer;
begin
  if FDebugMode then
  begin
    ElapsedMs := GetTickCount64 - StartTime;
    Logger.Debug('[LSPTools Timing] %s took %d ms', [Operation, ElapsedMs]);

    // Update statistics
    Category := Operation;
    DotPos := Pos('.', Operation);
    if DotPos > 0 then
      Category := Copy(Operation, 1, DotPos - 1);

    if FStats.ContainsKey(Category) then
    begin
      StatsDict := FStats[Category];
      TotalTime := StatsDict['TotalTimeMs'];
      StatsDict.AddOrSetValue('TotalTimeMs', TotalTime + ElapsedMs);
    end;

    // Track timeouts for statistics
    if ElapsedMs > LSP_OPERATION_TIMEOUT then
    begin
      if FCallTimeouts.TryGetValue(Operation, Count) then
        FCallTimeouts.AddOrSetValue(Operation, Count + 1);
      Logger.Warning('[LSPTools] %s exceeded timeout (%d ms > %d ms)',
        [Operation, ElapsedMs, LSP_OPERATION_TIMEOUT]);

      if FStats.ContainsKey(Category) then
      begin
        StatsDict := FStats[Category];
        TimeoutCount := StatsDict['TimeoutCount'];
        StatsDict.AddOrSetValue('TimeoutCount', TimeoutCount + 1);
      end;
    end;
  end;
end;

function TMCPLSPTools.EnsureDocumentOpen(const AUri: string): Boolean;
var
  FilePath: string;
  FileContent: string;
  StartTime: UInt64;
begin
  Result := False;
  StartTime := GetTickCount64;

  LogDebug('EnsureDocumentOpen called for URI: %s', [AUri]);

  if FOpenedFiles.Contains(AUri) then
  begin
    LogDebug('Document already open: %s', [AUri]);
    Exit(True);
  end;

  // Convert URI to FilePath
  if AUri.StartsWith('file:///', True) then
  begin
    FilePath := AUri.Substring(8);
    FilePath := TNetEncoding.URL.Decode(FilePath);
    FilePath := StringReplace(FilePath, '/', '\', [rfReplaceAll]);
    LogDebug('Converted URI to path: %s', [FilePath]);
  end
  else
  begin
    LogDebug('Not a file URI, cannot open: %s', [AUri]);
    Exit;
  end;

  if FileExists(FilePath) then
  begin
    try
      LogDebug('Reading file content: %s', [FilePath]);
      FileContent := TFile.ReadAllText(FilePath);
      LogDebug('File size: %d bytes', [Length(FileContent)]);

      FLSPClient.DidOpenTextDocument(AUri, 'pascal', FileContent, 1);
      FOpenedFiles.Add(AUri);
      Logger.Info('Auto-opened document: %s', [AUri]);
      Result := True;
      LogTiming('EnsureDocumentOpen.' + ExtractFileName(FilePath), StartTime);
    except
      on E: Exception do
      begin
        Logger.Error('Failed to auto-open document %s: %s', [FilePath, E.Message]);
        LogDebug('Exception in EnsureDocumentOpen: %s', [E.Message]);
      end;
    end;
  end
  else
  begin
    LogDebug('File does not exist: %s', [FilePath]);
  end;
end;

function TMCPLSPTools.RetryLSPCall<T>(ACall: TLSPCallFunc<T>; const AContext: string;
  out AHadTimeout: Boolean; ATimeoutMs: Integer = 15000): TArray<T>;
var
  I: Integer;
  StartTime: UInt64;
  OverallStart: UInt64;
  Success: Boolean;
  StatsDict: TDictionary<string, Integer>;
  TotalCalls, SuccessCount, FailureCount: Integer;
begin
  AHadTimeout := False;
  SetLength(Result, 0);
  OverallStart := GetTickCount64;

  // Update statistics
  if FStats.ContainsKey(AContext) then
  begin
    StatsDict := FStats[AContext];
    TotalCalls := StatsDict['TotalCalls'];
    StatsDict.AddOrSetValue('TotalCalls', TotalCalls + 1);
  end;

  LogDebug('RetryLSPCall started: %s, timeout=%d ms', [AContext, ATimeoutMs]);

  for I := 0 to LSP_RETRY_COUNT - 1 do
  begin
    // Check overall timeout before each attempt
    if GetTickCount64 - OverallStart > ATimeoutMs then
    begin
      LogDebug('Overall timeout exceeded for %s after %d ms',
        [AContext, GetTickCount64 - OverallStart]);
      AHadTimeout := True;
      Break;
    end;

    StartTime := GetTickCount64;
    LogDebug('Attempt %d/%d for %s', [I + 1, LSP_RETRY_COUNT, AContext]);

    Success := ACall(Result);

    if Success then
    begin
      LogTiming(AContext + '.Success', StartTime);
      LogDebug('%s succeeded on attempt %d', [AContext, I + 1]);

      // Update success statistics
      if FStats.ContainsKey(AContext) then
      begin
        StatsDict := FStats[AContext];
        SuccessCount := StatsDict['SuccessCount'];
        StatsDict.AddOrSetValue('SuccessCount', SuccessCount + 1);
      end;

      Exit;
    end;

    LogTiming(AContext + '.Failed', StartTime);

    // Update failure statistics
    if FStats.ContainsKey(AContext) then
    begin
      StatsDict := FStats[AContext];
      FailureCount := StatsDict['FailureCount'];
      StatsDict.AddOrSetValue('FailureCount', FailureCount + 1);
    end;

    if I < LSP_RETRY_COUNT - 1 then
    begin
      LogDebug('%s failed, retrying in %dms (attempt %d/%d)',
        [AContext, LSP_RETRY_DELAY_MS[I], I + 2, LSP_RETRY_COUNT]);
      Sleep(LSP_RETRY_DELAY_MS[I]);
    end
    else
    begin
      AHadTimeout := True;
      Logger.Warning('%s failed after %d retries (total time: %d ms)',
        [AContext, LSP_RETRY_COUNT, GetTickCount64 - OverallStart]);
    end;
  end;

  LogTiming(AContext + '.TotalFailure', OverallStart);
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
  Logger.Info('Generating tool definitions');
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
  Props.AddPair('includeDeclaration', TJSONObject.Create.AddPair('type', 'boolean').AddPair('description', 'Include the declaration in results').AddPair('default', True));
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

  Logger.Info('Generated %d tool definitions', [Length(Result)]);
end;

function TMCPLSPTools.ExecuteTool(const AToolName: string; AArguments: TJSONObject): TMCPToolCallResult;
var
  StartTime: UInt64;
begin
  StartTime := GetTickCount64;
  FLogContext.Enter('ExecuteTool.' + AToolName);

  try
    LogDebug('ExecuteTool called: %s', [AToolName]);

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
      LogDebug('Unknown tool: %s', [AToolName]);
      Result := TMCPToolCallResult.Create;
      Result.IsError := True;
      Result.Content.Add(CreateTextContent('Unknown tool: ' + AToolName));
    end;

    LogTiming('ExecuteTool.' + AToolName, StartTime);
  except
    on E: Exception do
    begin
      Logger.Error('Tool execution error (%s): %s', [AToolName, E.Message]);
      LogDebug('Exception in ExecuteTool: %s - %s', [AToolName, E.Message]);
      Result := TMCPToolCallResult.Create;
      Result.IsError := True;
      Result.Content.Add(CreateTextContent('Error: ' + E.Message));
    end;
  end;

  FLogContext.Exit('ExecuteTool.' + AToolName);
end;

function TMCPLSPTools.ExecuteGotoDefinition(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Char: Integer;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
  WasJustOpened, HadTimeout: Boolean;
  StartTime: UInt64;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;
  StartTime := GetTickCount64;

  FLogContext.Enter('ExecuteGotoDefinition');
  try
    LogDebug('ExecuteGotoDefinition called');

    Uri := AArguments.GetValue<string>('uri');
    Line := AArguments.GetValue<Integer>('line');
    Char := AArguments.GetValue<Integer>('character');

    LogDebug('Params: uri=%s, line=%d, char=%d', [Uri, Line, Char]);

    WasJustOpened := EnsureDocumentOpen(Uri);

    Locations := RetryLSPCall<TLSPLocation>(
      function(out L: TArray<TLSPLocation>): Boolean
      begin
        Result := FLSPClient.GetDefinition(Uri, Line, Char, L);
        if FDebugMode and Result then
          LogDebug('GetDefinition returned %d locations', [Length(L)]);
        Exit(Result);
      end,
      'GetDefinition', HadTimeout, LSP_OPERATION_TIMEOUT);

    if Length(Locations) = 0 then
    begin
      if HadTimeout then
      begin
        ResultText := LSP_TIMEOUT_MSG + 'No definition found after timeout';
		LogDebug('GetDefinition timeout for %s:%d:%d', [Uri, Line, Char]);
      end
      else if WasJustOpened then
      begin
        ResultText := 'No definition found (document was just opened, LSP may still be indexing)';
        LogDebug('Document just opened, LSP may be indexing');
      end
      else
      begin
        ResultText := 'No definition found';
        LogDebug('No definition found at position');
      end;
    end
    else
    begin
      ResultText := Format('Found %d definition(s):'#13#10, [Length(Locations)]);
      for I := 0 to Min(High(Locations), 19) do
        ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
      if Length(Locations) > 20 then
        ResultText := ResultText + Format('... and %d more', [Length(Locations) - 20]);
      LogDebug('Found %d definitions', [Length(Locations)]);
    end;

    Result.Content.Add(CreateTextContent(ResultText));
  finally
    FLogContext.Exit('ExecuteGotoDefinition');
  end;

  LogTiming('ExecuteGotoDefinition', StartTime);
end;

function TMCPLSPTools.ExecuteFindReferences(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Char: Integer;
  IncludeDecl: Boolean;
  Locations: TArray<TLSPLocation>;
  I: Integer;
  ResultText: string;
  HadTimeout: Boolean;
  StartTime: UInt64;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;
  StartTime := GetTickCount64;

  FLogContext.Enter('ExecuteFindReferences');
  try
    LogDebug('ExecuteFindReferences called');

    Uri := AArguments.GetValue<string>('uri');
    Line := AArguments.GetValue<Integer>('line');
    Char := AArguments.GetValue<Integer>('character');

    if not AArguments.TryGetValue<Boolean>('includeDeclaration', IncludeDecl) then
      IncludeDecl := True;

    LogDebug('Params: uri=%s, line=%d, char=%d, includeDecl=%s',
      [Uri, Line, Char, BoolToStr(IncludeDecl, True)]);

    EnsureDocumentOpen(Uri);

    Locations := RetryLSPCall<TLSPLocation>(
      function(out L: TArray<TLSPLocation>): Boolean
      begin
        Result := FLSPClient.GetReferences(Uri, Line, Char, IncludeDecl, L);
		if FDebugMode and Result then
          LogDebug('GetReferences returned %d locations', [Length(L)]);
        Exit(Result);
      end,
      'GetReferences', HadTimeout, LSP_OPERATION_TIMEOUT);

    if Length(Locations) = 0 then
    begin
      if HadTimeout then
      begin
        ResultText := LSP_TIMEOUT_MSG + 'No references found after timeout';
        LogDebug('GetReferences timeout for %s:%d:%d', [Uri, Line, Char]);
      end
      else
      begin
        ResultText := 'No references found';
        LogDebug('No references found at position');
      end;
    end
    else
    begin
      ResultText := Format('Found %d reference(s):'#13#10, [Length(Locations)]);
      for I := 0 to Min(High(Locations), 49) do
        ResultText := ResultText + Format('%d. %s'#13#10, [I + 1, LocationToText(Locations[I])]);
      if Length(Locations) > 50 then
        ResultText := ResultText + Format('... and %d more', [Length(Locations) - 50]);
      LogDebug('Found %d references', [Length(Locations)]);
    end;

    Result.Content.Add(CreateTextContent(ResultText));
  finally
    FLogContext.Exit('ExecuteFindReferences');
  end;

  LogTiming('ExecuteFindReferences', StartTime);
end;

function TMCPLSPTools.ExecuteHover(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Char: Integer;
  Hover: TLSPHover;
  ResultText: string;
  IsValid, HadTimeout: Boolean;
  I: Integer;
  StartTime: UInt64;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;
  StartTime := GetTickCount64;

  FLogContext.Enter('ExecuteHover');
  try
    LogDebug('ExecuteHover called');

    Uri := AArguments.GetValue<string>('uri');
    Line := AArguments.GetValue<Integer>('line');
    Char := AArguments.GetValue<Integer>('character');

    LogDebug('Params: uri=%s, line=%d, char=%d', [Uri, Line, Char]);

    EnsureDocumentOpen(Uri);

    IsValid := False;
    HadTimeout := False;
    for I := 0 to LSP_RETRY_COUNT - 1 do
	begin
      if FLSPClient.GetHover(Uri, Line, Char, Hover) then
      begin
        IsValid := True;
        LogDebug('GetHover succeeded on attempt %d', [I + 1]);
        Break;
      end;

      if I < LSP_RETRY_COUNT - 1 then
      begin
        LogDebug('GetHover failed, retrying in %dms (attempt %d/%d)',
          [LSP_RETRY_DELAY_MS[I], I + 2, LSP_RETRY_COUNT]);
        Sleep(LSP_RETRY_DELAY_MS[I]);
      end
      else
      begin
        HadTimeout := True;
        Logger.Warning('GetHover failed after %d retries', [LSP_RETRY_COUNT]);
        LogDebug('GetHover failed after %d retries');
      end;
    end;

    if not IsValid then
    begin
      if HadTimeout then
      begin
        ResultText := LSP_TIMEOUT_MSG + 'No hover info found after timeout';
        LogDebug('GetHover timeout for %s:%d:%d', [Uri, Line, Char]);
      end
      else
      begin
        ResultText := 'No hover info found';
        LogDebug('No hover info found at position');
      end;
    end
    else
    begin
      ResultText := Hover.Contents.Value;
      LogDebug('Hover text length: %d', [Length(ResultText)]);
    end;

    Result.Content.Add(CreateTextContent(ResultText));
  finally
    FLogContext.Exit('ExecuteHover');
  end;

  LogTiming('ExecuteHover', StartTime);
end;

function TMCPLSPTools.ExecuteCompletion(AArguments: TJSONObject): TMCPToolCallResult;
var
  Uri: string;
  Line, Char: Integer;
  Items: TArray<TLSPCompletionItem>;
  I: Integer;
  ResultText: string;
  HadTimeout: Boolean;
  StartTime: UInt64;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;
  StartTime := GetTickCount64;

  FLogContext.Enter('ExecuteCompletion');
  try
    LogDebug('ExecuteCompletion called');

    Uri := AArguments.GetValue<string>('uri');
    Line := AArguments.GetValue<Integer>('line');
    Char := AArguments.GetValue<Integer>('character');

    LogDebug('Params: uri=%s, line=%d, char=%d', [Uri, Line, Char]);

    EnsureDocumentOpen(Uri);

    Items := RetryLSPCall<TLSPCompletionItem>(
      function(out L: TArray<TLSPCompletionItem>): Boolean
      begin
        Result := FLSPClient.GetCompletion(Uri, Line, Char, L);
        if FDebugMode and Result then
          LogDebug('GetCompletion returned %d items', [Length(L)]);
        Exit(Result);
      end,
      'GetCompletion', HadTimeout, LSP_OPERATION_TIMEOUT);

    if Length(Items) = 0 then
    begin
      if HadTimeout then
      begin
        ResultText := LSP_TIMEOUT_MSG + 'No completion suggestions available after timeout';
        LogDebug('GetCompletion timeout for %s:%d:%d', [Uri, Line, Char]);
      end
      else
      begin
        ResultText := 'No completion suggestions available';
        LogDebug('No completion items found at position');
      end;
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
      LogDebug('Found %d completion items', [Length(Items)]);
    end;

    Result.Content.Add(CreateTextContent(ResultText));
  finally
    FLogContext.Exit('ExecuteCompletion');
  end;

  LogTiming('ExecuteCompletion', StartTime);
end;

function TMCPLSPTools.ExecuteWorkspaceSymbols(AArguments: TJSONObject): TMCPToolCallResult;
var
  Query: string;
  Symbols: TArray<TLSPSymbolInformation>;
  I: Integer;
  ResultText: string;
  StartTime: UInt64;
  Success: Boolean;
begin
  Result := TMCPToolCallResult.Create;
  Result.IsError := False;
  StartTime := GetTickCount64;

  FLogContext.Enter('ExecuteWorkspaceSymbols');
  try
    LogDebug('ExecuteWorkspaceSymbols called');

    Query := AArguments.GetValue<string>('query');
    LogDebug('Query: "%s"', [Query]);

    Success := FLSPClient.GetWorkspaceSymbols(Query, Symbols);

    if Success then
    begin
      if Length(Symbols) = 0 then
      begin
        ResultText := Format('No symbols found matching "%s"', [Query]);
        LogDebug('No symbols found for query: %s', [Query]);
      end
      else
      begin
        ResultText := Format('Found %d symbol(s) matching "%s":'#13#10, [Length(Symbols), Query]);
        for I := 0 to Min(High(Symbols), 49) do
        begin
          ResultText := ResultText + Format('%d. %s', [I + 1, Symbols[I].Name]);
          if Symbols[I].ContainerName <> '' then
            ResultText := ResultText + ' (in ' + Symbols[I].ContainerName + ')';
          ResultText := ResultText + #13#10'  ' + LocationToText(Symbols[I].Location) + #13#10;
        end;
        if Length(Symbols) > 50 then
          ResultText := ResultText + Format('... and %d more', [Length(Symbols) - 50]);
        LogDebug('Found %d symbols for query: %s', [Length(Symbols), Query]);
      end;
    end
    else
    begin
      ResultText := 'Error searching for workspace symbols';
      Logger.Error('GetWorkspaceSymbols failed for query: %s', [Query]);
      LogDebug('GetWorkspaceSymbols failed for query: %s', [Query]);
    end;

    Result.Content.Add(CreateTextContent(ResultText));
  finally
    FLogContext.Exit('ExecuteWorkspaceSymbols');
  end;

  LogTiming('ExecuteWorkspaceSymbols', StartTime);
end;

function TMCPLSPTools.CreateTextContent(const AText: string): TMCPContentItem;
begin
  Result := TMCPContentItem.Create;
  Result.ContentType := 'text';
  Result.Text := AText;
  if FDebugMode and (Length(AText) > 0) then
    LogDebug('Created text content (%d bytes)', [Length(AText)]);
end;

function TMCPLSPTools.LocationToText(const ALocation: TLSPLocation): string;
begin
  Result := Format('%s:%d:%d', [
    ALocation.Uri,
    ALocation.Range.Start.Line + 1,
    ALocation.Range.Start.Character + 1
  ]);
end;

end.
