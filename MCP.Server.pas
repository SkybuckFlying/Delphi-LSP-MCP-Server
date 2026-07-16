unit MCP.Server;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs, System.IOUtils,
  System.Generics.Collections,
  Winapi.Windows,
  Common.JsonRpc, Common.Logging, MCP.Protocol.Types, MCP.Transport.Stdio,
  MCP.Tools.LSP, LSP.Client, System.NetEncoding, Common.Utils;

type
  TMCPServer = class
  private
    FTransport: TMCPStdioTransport;
    FLSPClient: TLSPClient;
    FTools: TMCPLSPTools;
    FInitializedFlag: Integer; // atomic
    FServerInfo: TMCPServerInfo;
    FCapabilities: TMCPCapabilities;
    FLock: TCriticalSection;
    FStopEvent: TEvent;
    FLSPPath: string;
    FWorkspaceRoot: string;
    FShutdownRequested: Boolean;
    FDebugMode: Boolean;
    FRequestCount: Integer;
    FStartTime: TDateTime;
    FLogContext: ILogContext;

    // Statistics
	FTotalRequests: Integer;
    FTotalNotifications: Integer;
	FTotalErrors: Integer;
    FLastErrorTime: TDateTime;
    FMethodStats: TDictionary<string, Integer>;

	// Add this method to the private section (after LogStatistics declaration)
	procedure SetDebugMode(AValue: Boolean);

	procedure HandleMessage(const AMessage: string);
    procedure HandleRequest(ARequest: TJsonRpcRequest);
    procedure HandleNotification(ANotification: TJsonRpcNotification);

    procedure SendResponse(AId: TJSONValue; AResult: TJSONValue);
    procedure SendError(AId: TJSONValue; ACode: Integer; const AMessage: string; AData: TJSONValue = nil);

    procedure HandleInitialize(ARequest: TJsonRpcRequest);
    procedure HandleToolsList(ARequest: TJsonRpcRequest);
    procedure HandleToolsCall(ARequest: TJsonRpcRequest);
    procedure HandleShutdown(ARequest: TJsonRpcRequest);
    procedure HandleResourcesList(ARequest: TJsonRpcRequest);
    procedure HandlePromptsList(ARequest: TJsonRpcRequest);
    procedure HandleStdinClosed;
    procedure HandleUnknownMethod(ARequest: TJsonRpcRequest);

    function GetInitialized: Boolean;
    procedure SetInitialized(AValue: Boolean);
    function InitializeLSP: Boolean;
    procedure LogDebug(const Msg: string); overload;
    procedure LogDebug(const Msg: string; const Args: array of const); overload;
	procedure LogTiming(const Operation: string; StartTime: UInt64);
	procedure UpdateMethodStats(const Method: string);
    procedure LogStatistics;
	procedure CheckLSPHealth;
  public
	constructor Create(const ALSPPath, AWorkspaceRoot: string);
    destructor Destroy; override;

    procedure Run;
    procedure Stop;

    property Initialized: Boolean read GetInitialized;
	property DebugMode: Boolean read FDebugMode write SetDebugMode;
  end;

const
  MCP_NOT_INITIALIZED   = -32002;

implementation

uses
	System.StrUtils;

{ TMCPServer }

constructor TMCPServer.Create(const ALSPPath, AWorkspaceRoot: string);
begin
  inherited Create;
  FLogContext := Logger.CreateContext('MCPServer');
  FLogContext.Enter('Create');

  try
    FLock := TCriticalSection.Create;
    FStopEvent := TEvent.Create(nil, True, False, '');
    SetInitialized(False);
    FShutdownRequested := False;
    FDebugMode := False;
    FRequestCount := 0;
    FStartTime := Now;
    FTotalRequests := 0;
    FTotalNotifications := 0;
    FTotalErrors := 0;
    FMethodStats := TDictionary<string, Integer>.Create;

    FLSPPath := ALSPPath;
    FWorkspaceRoot := AWorkspaceRoot;

    FServerInfo.Name := 'delphi-lsp-mcp-server';
    FServerInfo.Version := '0.1.0';

    FCapabilities.HasTools := True;
    FCapabilities.Tools.ListChanged := False;
    FCapabilities.HasResources := True;
	FCapabilities.HasPrompts := True;

    LogDebug('Creating LSP client with path: %s', [FLSPPath]);
    FLSPClient := TLSPClient.Create(FLSPPath);

    LogDebug('Creating LSP tools', []);
    FTools := TMCPLSPTools.Create(FLSPClient);
	FTools.DebugMode := FDebugMode;

	LogDebug('Creating stdio transport', []);
    FTransport := TMCPStdioTransport.Create;
    FTransport.OnMessageReceived := HandleMessage;
    FTransport.DebugMode := FDebugMode;

    Logger.Info('MCP Server created successfully - Workspace: %s', [FWorkspaceRoot]);
    LogDebug('Server configuration - Version: %s, Capabilities: Tools=%s, Resources=%s, Prompts=%s',
      [FServerInfo.Version,
       BoolToStr(FCapabilities.HasTools, True),
       BoolToStr(FCapabilities.HasResources, True),
       BoolToStr(FCapabilities.HasPrompts, True)]);

  finally
    FLogContext.Exit('Create');
  end;
end;

destructor TMCPServer.Destroy;
var
  Pair: TPair<string, Integer>;
begin
  FLogContext.Enter('Destroy');
  try
	LogStatistics;
    Stop;

    LogDebug('Freeing resources', []);
    FTools.Free;
    FLSPClient.Free;
    FTransport.Free;
    FStopEvent.Free;
    FLock.Free;

    for Pair in FMethodStats do
      ; // Just iterate to avoid warning, dictionary will be freed
    FMethodStats.Free;

    Logger.Info('MCP Server destroyed - Total requests: %d, Errors: %d',
      [FTotalRequests, FTotalErrors]);
  finally
    FLogContext.Exit('Destroy');
    inherited;
  end;
end;

procedure TMCPServer.LogDebug(const Msg: string);
begin
  if FDebugMode then
    FLogContext.Log(Msg);
end;

procedure TMCPServer.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
  begin
    if Length(Args) > 0 then
      FLogContext.LogFmt(Msg, Args)
    else
      FLogContext.Log(Msg);
  end;
end;

procedure TMCPServer.LogTiming(const Operation: string; StartTime: UInt64);
var
  ElapsedMs: Integer;
begin
  if FDebugMode then
  begin
	ElapsedMs := GetTickCount64 - StartTime;
	Logger.Debug('[MCPServer Timing] %s took %d ms', [Operation, ElapsedMs]);
  end;
end;

// Add this implementation
procedure TMCPServer.SetDebugMode(AValue: Boolean);
begin
  if FDebugMode <> AValue then
  begin
	FDebugMode := AValue;

	// Propagate to all child components
	if Assigned(FTools) then
	  FTools.DebugMode := AValue;

	if Assigned(FTransport) then
	  FTransport.DebugMode := AValue;

	if Assigned(FLSPClient) then
	  FLSPClient.DebugMode := AValue;

	// Also enable JSON-RPC helper debug mode
	TJsonRpcHelper.DebugMode := AValue;

	// Also enable path utils debug mode
	TPathUtils.DebugMode := AValue;

	// Also enable logger detailed output
	if AValue then
	  Logger.LogLevel := llDebug;

	Logger.Info('Debug mode %s for all components', [IfThen(AValue, 'enabled', 'disabled')]);
  end;
end;

procedure TMCPServer.UpdateMethodStats(const Method: string);
var
  Count: Integer;
begin
  if FMethodStats.TryGetValue(Method, Count) then
    FMethodStats.AddOrSetValue(Method, Count + 1)
  else
    FMethodStats.Add(Method, 1);
end;

procedure TMCPServer.LogStatistics;
var
  Pair: TPair<string, Integer>;
begin
  if not FDebugMode then
    Exit;

  Logger.Info('[MCPServer Statistics]');
  Logger.Info('  Uptime: %s', [FormatDateTime('hh:nn:ss', Now - FStartTime)]);
  Logger.Info('  Total Requests: %d', [FTotalRequests]);
  Logger.Info('  Total Notifications: %d', [FTotalNotifications]);
  Logger.Info('  Total Errors: %d', [FTotalErrors]);
  Logger.Info('  Initialized: %s', [BoolToStr(GetInitialized, True)]);

  if FLastErrorTime > 0 then
    Logger.Info('  Last Error: %s', [DateTimeToStr(FLastErrorTime)]);

  if FMethodStats.Count > 0 then
  begin
    Logger.Info('  Method Statistics:');
    for Pair in FMethodStats do
      Logger.Info('    %s: %d calls', [Pair.Key, Pair.Value]);
  end;
end;

procedure TMCPServer.CheckLSPHealth;
begin
  if not GetInitialized then
    Exit;

  LogDebug('Performing LSP health check');
  if Assigned(FLSPClient) and not FLSPClient.IsInitialized then
  begin
    Logger.Warning('LSP client not healthy, attempting reinitialization');
    SetInitialized(False);
    if InitializeLSP then
    begin
      SetInitialized(True);
      Logger.Info('LSP client reinitialized successfully');
	end
    else
      Logger.Error('Failed to reinitialize LSP client');
  end;
end;

function TMCPServer.GetInitialized: Boolean;
begin
  Result := TInterlocked.CompareExchange(FInitializedFlag, 0, 0) <> 0;
end;

procedure TMCPServer.SetInitialized(AValue: Boolean);
begin
  TInterlocked.Exchange(FInitializedFlag, Ord(AValue));
  LogDebug('Initialized flag set to: %s', [BoolToStr(AValue, True)]);
end;

function TMCPServer.InitializeLSP: Boolean;
var
  InitOptions: TJSONObject;
  Patterns: TJSONArray;
  StartTime: UInt64;
  FpcOptions: TJSONArray;
  WorkspacePath: string;
  ProjectFiles: TArray<string>;
begin
  StartTime := GetTickCount64;

  FLogContext.Enter('InitializeLSP');
  try
    LogDebug('Initializing LSP with workspace: %s', [FWorkspaceRoot]);

    InitOptions := TJSONObject.Create;
    try
      Patterns := TJSONArray.Create;
      Patterns.Add('*.pas');
      Patterns.Add('*.pp');
      Patterns.Add('*.dpr');
      Patterns.Add('*.lpr');
      Patterns.Add('*.inc');
      InitOptions.AddPair('scanFilePatterns', Patterns);

      // Add FPC specific options to help pasls find the RTL
      InitOptions.AddPair('fpcPath', 'C:\Tools\FPC\3.2.2\bin\i386-Win32\fpc.exe');
      FpcOptions := TJSONArray.Create;
      FpcOptions.Add('-Mdelphi');
      FpcOptions.Add('@C:\Tools\FPC\3.2.2\bin\i386-Win32\fpc.cfg');
      FpcOptions.Add('-FuC:\Tools\FPC\3.2.2\units\i386-win32\rtl');
      FpcOptions.Add('-FuC:\Tools\FPC\3.2.2\units\i386-win32\fcl-base');
      InitOptions.AddPair('fpcOptions', FpcOptions);

      InitOptions.AddPair('checkSyntax', TJSONBool.Create(True));
      InitOptions.AddPair('publishDiagnostics', TJSONBool.Create(True));

      // Dynamically find a project file in the workspace
      WorkspacePath := FileUriToPath(FWorkspaceRoot);
      LogDebug('Workspace path: %s', [WorkspacePath]);

      ProjectFiles := TDirectory.GetFiles(WorkspacePath, '*.dpr');
      if Length(ProjectFiles) = 0 then
        ProjectFiles := TDirectory.GetFiles(WorkspacePath, '*.lpr');

      if Length(ProjectFiles) > 0 then
      begin
        InitOptions.AddPair('program', ProjectFiles[0]);
        LogDebug('Found project file: %s', [ProjectFiles[0]]);
      end
      else
        LogDebug('No project file found in workspace');

      Logger.Info('Initializing LSP client...');
      Logger.Info('  LSP Path   : %s', [FLSPPath]);
      Logger.Info('  Workspace  : %s', [FWorkspaceRoot]);

      if FDebugMode then
        Logger.Debug('  InitOptions: %s', [InitOptions.ToJSON]);

      // Directly return the result without intermediate assignment
      Result := FLSPClient.Initialize(FWorkspaceRoot, InitOptions);

      if Result then
      begin
        Logger.Info('LSP client initialized successfully in %d ms',
          [GetTickCount64 - StartTime]);
      end
      else
        Logger.Error('Failed to initialize LSP client after %d ms',
          [GetTickCount64 - StartTime]);

    finally
      InitOptions.Free;
    end;
  finally
    FLogContext.Exit('InitializeLSP');
  end;
end;

procedure TMCPServer.Run;
begin
  FLogContext.Enter('Run');
  try
    Logger.Info('Starting MCP Server...');

    if FStopEvent.WaitFor(0) = wrSignaled then
    begin
      Logger.Warning('Run called after Stop; exiting immediately');
      Exit;
    end;

    LogDebug('Starting stdio transport');
    FTransport.Start;

    Logger.Info('MCP Server running, waiting for messages...');
    LogDebug('Server ready - Waiting for stop signal');

    FStopEvent.WaitFor;

    LogDebug('Stop signal received, exiting run loop');
  finally
    FLogContext.Exit('Run');
  end;
end;

procedure TMCPServer.Stop;
var
  StartTime: UInt64;
begin
  StartTime := GetTickCount64;
  FLogContext.Enter('Stop');

  try
    FLock.Enter;
    try
      if FShutdownRequested then
      begin
        LogDebug('Stop already requested, exiting');
        Exit;
      end;
      FShutdownRequested := True;
	finally
      FLock.Leave;
    end;

    if FStopEvent.WaitFor(0) = wrSignaled then
    begin
      LogDebug('Stop event already signaled');
      Exit;
    end;

    Logger.Info('Stopping MCP Server...');
    SetInitialized(False);

    LogDebug('Stopping stdio transport');
    if Assigned(FTransport) then
      FTransport.Stop;

    LogDebug('Shutting down LSP client');
    if Assigned(FLSPClient) then
      FLSPClient.Shutdown;

    FStopEvent.SetEvent;
    Logger.Info('MCP Server stopped in %d ms', [GetTickCount64 - StartTime]);
  finally
    FLogContext.Exit('Stop');
  end;
end;

procedure TMCPServer.HandleStdinClosed;
begin
  FLogContext.Enter('HandleStdinClosed');
  try
    Logger.Info('Stdin closed by parent process, shutting down...');
    LogDebug('Initiating shutdown due to stdin closure');
    Stop;
  finally
    FLogContext.Exit('HandleStdinClosed');
  end;
end;

procedure TMCPServer.HandleMessage(const AMessage: string);
var
  MessageType: TJsonRpcMessageType;
  MessageObj: TObject;
  ErrorStr: string;
begin
  // Empty message signals stdin closed (parent process terminated)
  if AMessage = '' then
  begin
    HandleStdinClosed;
    Exit;
  end;

  LogDebug('Parsing message: %s', [Copy(AMessage, 1, 100)]);

  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType, ErrorStr);
  if not Assigned(MessageObj) then
  begin
    Inc(FTotalErrors);
    FLastErrorTime := Now;
    Logger.Warning('Failed to parse message: %s', [ErrorStr]);
    LogDebug('Parse error: %s', [ErrorStr]);
    Exit;
  end;

  try
	case MessageType of
      jmtRequest:
        begin
          Inc(FTotalRequests);
          HandleRequest(MessageObj as TJsonRpcRequest);
        end;
      jmtNotification:
        begin
          Inc(FTotalNotifications);
          HandleNotification(MessageObj as TJsonRpcNotification);
        end;
      jmtResponse:
        Logger.Debug('Received response - servers should not receive responses');
      jmtInvalid:
        begin
          Inc(FTotalErrors);
          Logger.Warning('Invalid message received');
        end;
    end;
  finally
    MessageObj.Free;
  end;
end;

procedure TMCPServer.HandleRequest(ARequest: TJsonRpcRequest);
var
  Method: string;
begin
  Method := ARequest.Method;

  FLogContext.Enter('HandleRequest.' + Method);
  try
    UpdateMethodStats(Method);
    Logger.Info('Handling request: %s (ID: %s)', [Method, ARequest.Id.ToJSON]);

    if Assigned(ARequest.Params) then
      LogDebug('Request params: %s', [ARequest.Params.ToJSON])
    else
      LogDebug('Request has no params');

    if Method = 'initialize' then
      HandleInitialize(ARequest)
    else if Method = 'tools/list' then
      HandleToolsList(ARequest)
    else if Method = 'tools/call' then
      HandleToolsCall(ARequest)
    else if Method = 'shutdown' then
      HandleShutdown(ARequest)
    else if Method = 'resources/list' then
      HandleResourcesList(ARequest)
    else if Method = 'prompts/list' then
      HandlePromptsList(ARequest)
    else
      HandleUnknownMethod(ARequest);

  except
    on E: Exception do
    begin
      Inc(FTotalErrors);
      FLastErrorTime := Now;
      Logger.Error('Error handling request %s: %s', [Method, E.Message]);
      LogDebug('Exception in HandleRequest: %s - %s', [E.ClassName, E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;
  FLogContext.Exit('HandleRequest.' + Method);
end;

procedure TMCPServer.HandleUnknownMethod(ARequest: TJsonRpcRequest);
begin
  LogDebug('Unknown method requested: %s', [ARequest.Method]);
  SendError(ARequest.Id, TJsonRpcErrorCode.MethodNotFound,
    'Method not found: ' + ARequest.Method);
end;

procedure TMCPServer.HandleNotification(ANotification: TJsonRpcNotification);
begin
  FLogContext.Enter('HandleNotification.' + ANotification.Method);
  try
    UpdateMethodStats(ANotification.Method);
    Logger.Debug('Received notification: %s', [ANotification.Method]);

    if Assigned(ANotification.Params) then
      LogDebug('Notification params: %s', [ANotification.Params.ToJSON])
    else
      LogDebug('Notification has no params');

    if ANotification.Method = 'notifications/initialized' then
    begin
      Logger.Info('Client confirmed initialization');
      LogDebug('Client initialization confirmed');
    end
    else if ANotification.Method = 'notifications/cancelled' then
    begin
      Logger.Info('Request cancelled by client');
      LogDebug('Request cancellation notification received');
    end
    else if ANotification.Method = 'exit' then
    begin
      Logger.Info('Exit notification received');
      LogDebug('Exit notification - initiating shutdown');
      Stop;
    end
    else
    begin
      LogDebug('Unhandled notification type: %s', [ANotification.Method]);
    end;
  finally
    FLogContext.Exit('HandleNotification.' + ANotification.Method);
  end;
end;

procedure TMCPServer.HandleInitialize(ARequest: TJsonRpcRequest);
var
  Params: TMCPInitializeParams;
  ResultInit: TMCPInitializeResult;
  ResultJson: TJSONObject;
  IsValid: Boolean;
  NewRoot: string;
  RootObj: TJSONObject;
  RootVal: TJSONValue;
begin
  FLogContext.Enter('HandleInitialize');

  try
    LogDebug('Processing initialize request');

    if not Assigned(ARequest.Params) or not (ARequest.Params is TJSONObject) then
    begin
      LogDebug('Invalid params: params is not an object');
      SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'params must be an object');
      Exit;
	end;

    Params := TMCPInitializeParams.FromJSON(ARequest.Params as TJSONObject, IsValid);
    if not IsValid then
    begin
      LogDebug('Failed to parse initialize params');
      SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Invalid params');
      Exit;
    end;

    LogDebug('Client info: %s %s', [Params.ClientInfo.Name, Params.ClientInfo.Version]);
    LogDebug('Protocol version: %s (server: %s)',
      [Params.ProtocolVersion, MCP_PROTOCOL_VERSION]);

    // Try to extract workspace root from initialize params if provided
    NewRoot := '';
    if (ARequest.Params <> nil) and (ARequest.Params is TJSONObject) then
    begin
      RootObj := TJSONObject(ARequest.Params);
      RootVal := RootObj.GetValue('rootUri');
      if RootVal = nil then
        RootVal := RootObj.GetValue('rootPath');

      if RootVal <> nil then
        NewRoot := RootVal.Value;
    end;

    if NewRoot <> '' then
    begin
      if not NewRoot.StartsWith('file://', True) then
        NewRoot := PathToFileUri(NewRoot);

      if NewRoot <> FWorkspaceRoot then
      begin
        Logger.Info('Switching workspace from %s to %s', [FWorkspaceRoot, NewRoot]);
        LogDebug('Workspace changed: %s -> %s', [FWorkspaceRoot, NewRoot]);
        FWorkspaceRoot := NewRoot;
      end;
    end;

    if Params.ProtocolVersion <> MCP_PROTOCOL_VERSION then
      Logger.Warning('Client protocol version mismatch: %s (server: %s)',
        [Params.ProtocolVersion, MCP_PROTOCOL_VERSION]);

    LogDebug('Initializing LSP...');
    if not InitializeLSP then
    begin
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, 'Failed to initialize LSP server');
      Exit;
    end;

    ResultInit.ProtocolVersion := MCP_PROTOCOL_VERSION;
    ResultInit.Capabilities := FCapabilities;
    ResultInit.ServerInfo := FServerInfo;
    ResultInit.HasInstructions := False;

    ResultJson := ResultInit.ToJSON;
    try
      LogDebug('Sending initialize response with capabilities');
      SendResponse(ARequest.Id, ResultJson);
    finally
      ResultJson.Free;
    end;

    SetInitialized(True);
    Logger.Info('MCP Server initialized for client: %s %s',
	  [Params.ClientInfo.Name, Params.ClientInfo.Version]);

  except
    on E: Exception do
    begin
      Inc(FTotalErrors);
      FLastErrorTime := Now;
      Logger.Error('Initialize error: %s', [E.Message]);
      LogDebug('Exception in HandleInitialize: %s - %s', [E.ClassName, E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;

  FLogContext.Exit('HandleInitialize');
end;

procedure TMCPServer.HandleToolsList(ARequest: TJsonRpcRequest);
var
  Tools: TArray<TMCPTool>;
  ToolsArray: TJSONArray;
  ResultObj: TJSONObject;
  I: Integer;
begin
  FLogContext.Enter('HandleToolsList');

  try
    if not GetInitialized then
    begin
      LogDebug('Tools list requested but server not initialized');
      SendError(ARequest.Id, MCP_NOT_INITIALIZED, 'Server not initialized');
      Exit;
    end;

    LogDebug('Getting tool definitions');
    Tools := TMCPLSPTools.GetToolDefinitions;
    Logger.Info('Sending %d tool definitions', [Length(Tools)]);

    ToolsArray := TJSONArray.Create;
    try
      for I := 0 to High(Tools) do
        ToolsArray.Add(Tools[I].ToJSON);

      ResultObj := TJSONObject.Create;
      try
        ResultObj.AddPair('tools', ToolsArray);
        SendResponse(ARequest.Id, ResultObj);
	  finally
		ResultObj.Free;  // This will also free ToolsArray
      end;
	finally
      // Fixed:
	  // Don't free ToolsArray here - it's already freed by ResultObj
{
	  for I := 0 to High(Tools) do
		Tools[I].Free;
	  ToolsArray.Free;
}
	end;
  except
	on E: Exception do
	begin
	  Inc(FTotalErrors);
	  FLastErrorTime := Now;
	  Logger.Error('Tools list error: %s', [E.Message]);
	  LogDebug('Exception in HandleToolsList: %s - %s', [E.ClassName, E.Message]);
	  SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
	end;
  end;

  FLogContext.Exit('HandleToolsList');
end;

procedure TMCPServer.HandleToolsCall(ARequest: TJsonRpcRequest);
var
  Params: TMCPToolCallParams;
  CallResult: TMCPToolCallResult;
  ResultJson: TJSONObject;
  IsValid: Boolean;
begin
  Params := nil;
  FLogContext.Enter('HandleToolsCall');

  try
    if not GetInitialized then
    begin
      LogDebug('Tools call requested but server not initialized');
      SendError(ARequest.Id, MCP_NOT_INITIALIZED, 'Server not initialized');
      Exit;
    end;

    if not Assigned(ARequest.Params) or not (ARequest.Params is TJSONObject) then
    begin
      LogDebug('Invalid params in tools/call');
      SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'params must be an object');
      Exit;
    end;

    Params := TMCPToolCallParams.FromJSON(ARequest.Params as TJSONObject, IsValid);
    if not IsValid then
    begin
      LogDebug('Failed to parse tool call params');
      SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Invalid params');
      Exit;
    end;

    try
      Logger.Info('Executing tool: %s', [Params.Name]);
      if Assigned(Params.Arguments) then
        LogDebug('Tool arguments: %s', [Params.Arguments.ToJSON]);

      CallResult := FTools.ExecuteTool(Params.Name, Params.Arguments);
      try
        ResultJson := CallResult.ToJSON;
        try
          SendResponse(ARequest.Id, ResultJson);
          Logger.Info('Tool execution completed: %s (error=%s)',
            [Params.Name, BoolToStr(CallResult.IsError, True)]);
        finally
          ResultJson.Free;
        end;
      finally
        CallResult.Free;
      end;
    except
      on E: Exception do
      begin
        Inc(FTotalErrors);
        FLastErrorTime := Now;
        Logger.Error('Tool call error: %s', [E.Message]);
        LogDebug('Exception in tool execution: %s - %s', [E.ClassName, E.Message]);
        SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
      end;
    end;
  finally
    if Assigned(Params) then
      Params.Free;
  end;

  FLogContext.Exit('HandleToolsCall');
end;

procedure TMCPServer.HandleResourcesList(ARequest: TJsonRpcRequest);
var
  ResultObj: TJSONObject;
begin
  FLogContext.Enter('HandleResourcesList');

  try
    LogDebug('Processing resources/list request');
    ResultObj := TJSONObject.Create;
    try
      ResultObj.AddPair('resources', TJSONArray.Create);
      SendResponse(ARequest.Id, ResultObj);
    finally
      ResultObj.Free;
    end;
  except
    on E: Exception do
    begin
      Inc(FTotalErrors);
      FLastErrorTime := Now;
      Logger.Error('Resources list error: %s', [E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;

  FLogContext.Exit('HandleResourcesList');
end;

procedure TMCPServer.HandlePromptsList(ARequest: TJsonRpcRequest);
var
  ResultObj: TJSONObject;
begin
  FLogContext.Enter('HandlePromptsList');

  try
    LogDebug('Processing prompts/list request');
    ResultObj := TJSONObject.Create;
    try
      ResultObj.AddPair('prompts', TJSONArray.Create);
      SendResponse(ARequest.Id, ResultObj);
    finally
      ResultObj.Free;
    end;
  except
    on E: Exception do
    begin
      Inc(FTotalErrors);
      FLastErrorTime := Now;
      Logger.Error('Prompts list error: %s', [E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;

  FLogContext.Exit('HandlePromptsList');
end;

procedure TMCPServer.HandleShutdown(ARequest: TJsonRpcRequest);
begin
  FLogContext.Enter('HandleShutdown');
  try
    Logger.Info('Shutdown requested');
    LogDebug('Processing shutdown request');
	SendResponse(ARequest.Id, TJSONNull.Create);
    SetInitialized(False);
    LogDebug('Shutdown complete, stopping server');
    Stop;
  finally
    FLogContext.Exit('HandleShutdown');
  end;
end;

procedure TMCPServer.SendResponse(AId: TJSONValue; AResult: TJSONValue);
var
  Response: TJsonRpcResponse;
  ResponseJson: TJSONObject;
begin
  Response := TJsonRpcHelper.CreateSuccessResponse(
    TJsonRpcHelper.CloneJSONValue(AId),
    AResult
  );
  try
    ResponseJson := Response.ToJSON;
    try
      FLock.Enter;
      try
        FTransport.SendMessage(ResponseJson.ToJSON);
        LogDebug('Response sent for ID: %s', [AId.ToJSON]);
      finally
        FLock.Leave;
      end;
    finally
      ResponseJson.Free;
    end;
  finally
    Response.Free;
  end;
end;

procedure TMCPServer.SendError(AId: TJSONValue; ACode: Integer; const AMessage: string; AData: TJSONValue);
var
  Response: TJsonRpcResponse;
  ResponseJson: TJSONObject;
begin
  LogDebug('Sending error response - Code: %d, Message: %s', [ACode, AMessage]);

  Response := TJsonRpcHelper.CreateErrorResponse(
    TJsonRpcHelper.CloneJSONValue(AId),
    ACode,
    AMessage,
    AData
  );
  try
    ResponseJson := Response.ToJSON;
    try
      FLock.Enter;
      try
        FTransport.SendMessage(ResponseJson.ToJSON);
      finally
        FLock.Leave;
      end;
    finally
      ResponseJson.Free;
    end;
  finally
    Response.Free;
  end;
end;

end.
