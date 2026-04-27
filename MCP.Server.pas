unit MCP.Server;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  Winapi.Windows,
  Common.JsonRpc, Common.Logging, MCP.Protocol.Types, MCP.Transport.Stdio,
  MCP.Tools.LSP, LSP.Client;

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

    function GetInitialized: Boolean;
    procedure SetInitialized(AValue: Boolean);
    function InitializeLSP: Boolean;
  public
    constructor Create(const ALSPPath, AWorkspaceRoot: string);
    destructor Destroy; override;

    procedure Run;
    procedure Stop;

    property Initialized: Boolean read GetInitialized;
  end;

const
  MCP_NOT_INITIALIZED   = -32002;
  MCP_PROTOCOL_VERSION  = '2024-11-05';

implementation

{ TMCPServer }

constructor TMCPServer.Create(const ALSPPath, AWorkspaceRoot: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  SetInitialized(False);

  FLSPPath := ALSPPath;
  FWorkspaceRoot := AWorkspaceRoot;

  FServerInfo.Name := 'delphi-lsp-mcp-server';
  FServerInfo.Version := '0.1.0';

  FCapabilities.HasTools := True;
  FCapabilities.Tools.ListChanged := False;

  FLSPClient := TLSPClient.Create(FLSPPath);
  FTools := TMCPLSPTools.Create(FLSPClient);

  FTransport := TMCPStdioTransport.Create;
  FTransport.OnMessageReceived := HandleMessage;

  Logger.Info('MCP Server created successfully');
end;

destructor TMCPServer.Destroy;
begin
  Stop;
  FTools.Free;
  FLSPClient.Free;
  FTransport.Free;
  FStopEvent.Free;
  FLock.Free;
  inherited;
end;

function TMCPServer.GetInitialized: Boolean;
begin
  Result := TInterlocked.CompareExchange(FInitializedFlag, 0, 0) <> 0;
end;

procedure TMCPServer.SetInitialized(AValue: Boolean);
begin
  TInterlocked.Exchange(FInitializedFlag, Ord(AValue));
end;

function TMCPServer.InitializeLSP: Boolean;
var
  InitOptions: TJSONObject;
  Patterns: TJSONArray;
begin
  Result := False;

  InitOptions := TJSONObject.Create;
  try
    Patterns := TJSONArray.Create;
    Patterns.Add('*.pas');
    Patterns.Add('*.pp');
    Patterns.Add('*.dpr');
    Patterns.Add('*.lpr');
    Patterns.Add('*.inc');
    InitOptions.AddPair('scanFilePatterns', Patterns);

    Logger.Info('Initializing LSP client...');
    Logger.Info('  LSP Path   : %s', [FLSPPath]);
    Logger.Info('  Workspace  : %s', [FWorkspaceRoot]);
    Logger.Debug('  InitOptions: %s', [InitOptions.ToJSON]);

    Result := FLSPClient.Initialize(FWorkspaceRoot, InitOptions);
    if not Result then
      Logger.Error('Failed to initialize LSP client')
    else
      Logger.Info('LSP client initialized successfully');
  finally
    InitOptions.Free;
  end;
end;


procedure TMCPServer.Run;
begin
  Logger.Info('Starting MCP Server...');

  if FStopEvent.WaitFor(0) = wrSignaled then
  begin
    Logger.Warning('Run called after Stop; exiting immediately');
    Exit;
  end;

  FTransport.Start;
  Logger.Info('MCP Server running, waiting for messages...');
  FStopEvent.WaitFor;
end;

procedure TMCPServer.Stop;
begin
  if FStopEvent.WaitFor(0) = wrSignaled then
    Exit;

  Logger.Info('Stopping MCP Server...');
  SetInitialized(False);

  if Assigned(FTransport) then
    FTransport.Stop;
  if Assigned(FLSPClient) then
    FLSPClient.Shutdown;

  FStopEvent.SetEvent;
  Logger.Info('MCP Server stopped');
end;

procedure TMCPServer.HandleMessage(const AMessage: string);
var
  MessageType: TJsonRpcMessageType;
  MessageObj: TObject;
  ErrorStr: string;
begin
  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType, ErrorStr);
  if not Assigned(MessageObj) then
  begin
    Logger.Warning('Failed to parse message: %s', [ErrorStr]);
    Exit;
  end;

  try
    case MessageType of
      jmtRequest:      HandleRequest(MessageObj as TJsonRpcRequest);
      jmtNotification: HandleNotification(MessageObj as TJsonRpcNotification);
      jmtResponse:     Logger.Debug('Received response - servers should not receive responses');
      jmtInvalid:      Logger.Warning('Invalid message received');
    end;
  finally
    MessageObj.Free;
  end;
end;

procedure TMCPServer.HandleRequest(ARequest: TJsonRpcRequest);
begin
  Logger.Info('Handling request: %s', [ARequest.Method]);

  try
    if ARequest.Method = 'initialize' then
      HandleInitialize(ARequest)
    else if ARequest.Method = 'tools/list' then
      HandleToolsList(ARequest)
    else if ARequest.Method = 'tools/call' then
      HandleToolsCall(ARequest)
    else if ARequest.Method = 'shutdown' then
      HandleShutdown(ARequest)
    else if ARequest.Method = 'resources/list' then
      HandleResourcesList(ARequest)
    else if ARequest.Method = 'prompts/list' then
      HandlePromptsList(ARequest)
	else
      SendError(ARequest.Id, TJsonRpcErrorCode.MethodNotFound,
        'Method not found: ' + ARequest.Method);
  except
    on E: Exception do
    begin
      Logger.Error('Error handling request %s: %s', [ARequest.Method, E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;
end;

procedure TMCPServer.HandleNotification(ANotification: TJsonRpcNotification);
begin
  Logger.Debug('Received notification: %s', [ANotification.Method]);

  if ANotification.Method = 'notifications/initialized' then
    Logger.Info('Client confirmed initialization')
  else if ANotification.Method = 'notifications/cancelled' then
    Logger.Info('Request cancelled by client')
  else if ANotification.Method = 'exit' then
  begin
    Logger.Info('Exit notification received');
    Stop;
  end;
end;

procedure TMCPServer.HandleInitialize(ARequest: TJsonRpcRequest);
var
  Params: TMCPInitializeParams;
  ResultInit: TMCPInitializeResult;
  ResultJson: TJSONObject;
  IsValid: Boolean;
begin
  if not Assigned(ARequest.Params) or not (ARequest.Params is TJSONObject) then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'params must be an object');
    Exit;
  end;

  Params := TMCPInitializeParams.FromJSON(ARequest.Params as TJSONObject, IsValid);
  if not IsValid then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Invalid params');
    Exit;
  end;

  try
    if Params.ProtocolVersion <> MCP_PROTOCOL_VERSION then
      Logger.Warning('Client protocol version mismatch: %s (server: %s)',
        [Params.ProtocolVersion, MCP_PROTOCOL_VERSION]);

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
      Logger.Error('Initialize error: %s', [E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;
end;

procedure TMCPServer.HandleToolsList(ARequest: TJsonRpcRequest);
var
  Tools: TArray<TMCPTool>;
  ToolsArray: TJSONArray;
  ResultObj: TJSONObject;
  I: Integer;
begin
  if not GetInitialized then
  begin
    SendError(ARequest.Id, MCP_NOT_INITIALIZED, 'Server not initialized');
    Exit;
  end;

  Tools := TMCPLSPTools.GetToolDefinitions;
  Logger.Info('Sending %d tool definitions', [Length(Tools)]);

  ToolsArray := TJSONArray.Create;
  try
    try
      for I := 0 to High(Tools) do
        ToolsArray.Add(Tools[I].ToJSON);
    finally
      for I := 0 to High(Tools) do
        Tools[I].Free;
    end;

    ResultObj := TJSONObject.Create;
    try
      ResultObj.AddPair('tools', ToolsArray);
      SendResponse(ARequest.Id, ResultObj);
    finally
      ResultObj.Free;
    end;
  except
    ToolsArray.Free;
    raise;
  end;
end;

procedure TMCPServer.HandleToolsCall(ARequest: TJsonRpcRequest);
var
  Params: TMCPToolCallParams;
  CallResult: TMCPToolCallResult;
  ResultJson: TJSONObject;
  IsValid: Boolean;
begin
  if not GetInitialized then
  begin
    SendError(ARequest.Id, MCP_NOT_INITIALIZED, 'Server not initialized');
    Exit;
  end;

  if not Assigned(ARequest.Params) or not (ARequest.Params is TJSONObject) then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'params must be an object');
    Exit;
  end;

  Params := TMCPToolCallParams.FromJSON(ARequest.Params as TJSONObject, IsValid);
  if not IsValid then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Invalid params');
    Exit;
  end;

  try
    try
      Logger.Info('Executing tool: %s', [Params.Name]);

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
        Logger.Error('Tool call error: %s', [E.Message]);
        SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
      end;
    end;
  finally
    Params.Free;
  end;
end;

procedure TMCPServer.HandleResourcesList(ARequest: TJsonRpcRequest);
var
  ResultObj: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  try
    ResultObj.AddPair('resources', TJSONArray.Create);
    SendResponse(ARequest.Id, ResultObj);
  finally
    ResultObj.Free;
  end;
end;

procedure TMCPServer.HandlePromptsList(ARequest: TJsonRpcRequest);
var
  ResultObj: TJSONObject;
begin
  ResultObj := TJSONObject.Create;
  try
    ResultObj.AddPair('prompts', TJSONArray.Create);
    SendResponse(ARequest.Id, ResultObj);
  finally
	ResultObj.Free;
  end;
end;

procedure TMCPServer.HandleShutdown(ARequest: TJsonRpcRequest);
begin
  Logger.Info('Shutdown requested');
  SendResponse(ARequest.Id, TJSONNull.Create);
  SetInitialized(False);
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

