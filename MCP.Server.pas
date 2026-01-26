unit MCP.Server;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  Common.JsonRpc, Common.Logging, MCP.Protocol.Types, MCP.Transport.Stdio,
  MCP.Tools.LSP, LSP.Client;

type
  TMCPServer = class
  private
    FTransport: TMCPStdioTransport;
    FLSPClient: TLSPClient;
    FTools: TMCPLSPTools;
    FInitialized: Boolean;
    FServerInfo: TMCPServerInfo;
    FCapabilities: TMCPCapabilities;
    FLock: TCriticalSection;
    
    procedure HandleMessage(const AMessage: string);
    procedure HandleRequest(ARequest: TJsonRpcRequest);
    procedure HandleNotification(ANotification: TJsonRpcNotification);
    
    procedure SendResponse(AId: TJSONValue; AResult: TJSONValue);
    procedure SendError(AId: TJSONValue; ACode: Integer; const AMessage: string);
    
    // MCP method handlers
    procedure HandleInitialize(ARequest: TJsonRpcRequest);
    procedure HandleToolsList(ARequest: TJsonRpcRequest);
    procedure HandleToolsCall(ARequest: TJsonRpcRequest);
    procedure HandleShutdown(ARequest: TJsonRpcRequest);
  public
    constructor Create(const ALSPPath, AWorkspaceRoot: string);
    destructor Destroy; override;
    
    procedure Run;
    procedure Stop;
    
    property Initialized: Boolean read FInitialized;
  end;

implementation

{ TMCPServer }

constructor TMCPServer.Create(const ALSPPath, AWorkspaceRoot: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FInitialized := False;
  
  // Setup server info
  FServerInfo.Name := 'delphi-lsp-mcp-server';
  FServerInfo.Version := '0.1.0';
  
  // Setup capabilities
  FCapabilities := TMCPCapabilities.Default;
  
  // Create LSP client
  FLSPClient := TLSPClient.Create(ALSPPath);
  if not FLSPClient.Initialize(AWorkspaceRoot) then
  begin
    Logger.Error('Failed to initialize LSP client');
    raise Exception.Create('Failed to initialize LSP client');
  end;
  
  // Create tools
  FTools := TMCPLSPTools.Create(FLSPClient);
  
  // Create transport
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
  FLock.Free;
  inherited;
end;

procedure TMCPServer.Run;
begin
  Logger.Info('Starting MCP Server...');
  FTransport.Start;
  Logger.Info('MCP Server running, waiting for messages...');
  
  // Keep the main thread alive as long as the transport is running
  while FTransport.Running do
    Sleep(100);
end;

procedure TMCPServer.Stop;
begin
  Logger.Info('Stopping MCP Server...');
  if Assigned(FTransport) then
    FTransport.Stop;
  if Assigned(FLSPClient) then
    FLSPClient.Shutdown;
  Logger.Info('MCP Server stopped');
end;

procedure TMCPServer.HandleMessage(const AMessage: string);
var
  MessageType: TJsonRpcMessageType;
  MessageObj: TObject;
begin
  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType);
  if not Assigned(MessageObj) then
  begin
    Logger.Warning('Failed to parse message');
    Exit;
  end;
  
  try
    case MessageType of
      jmtRequest:
        HandleRequest(MessageObj as TJsonRpcRequest);
      jmtNotification:
        HandleNotification(MessageObj as TJsonRpcNotification);
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
    else
    begin
      Logger.Warning('Unknown method: %s', [ARequest.Method]);
      SendError(ARequest.Id, TJsonRpcErrorCode.MethodNotFound, 
        'Method not found: ' + ARequest.Method);
    end;
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
  // Handle notifications if needed
end;

procedure TMCPServer.HandleInitialize(ARequest: TJsonRpcRequest);
var
  Params: TMCPInitializeParams;
  Result: TMCPInitializeResult;
  ResultJson: TJSONObject;
begin
  if not Assigned(ARequest.Params) then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Missing params');
    Exit;
  end;
  
  try
    Params := TMCPInitializeParams.FromJSON(ARequest.Params as TJSONObject);
    
    // Validate protocol version
    if Params.ProtocolVersion <> MCP_PROTOCOL_VERSION then
    begin
      Logger.Warning('Client protocol version mismatch: %s (expected %s)', 
        [Params.ProtocolVersion, MCP_PROTOCOL_VERSION]);
    end;
    
    // Build result
    Result.ProtocolVersion := MCP_PROTOCOL_VERSION;
    Result.Capabilities := FCapabilities;
    Result.ServerInfo := FServerInfo;
    
    ResultJson := Result.ToJSON;
    SendResponse(ARequest.Id, ResultJson);
    
    FInitialized := True;
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
  if not FInitialized then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.ServerErrorStart, 'Server not initialized');
    Exit;
  end;
  
  Tools := TMCPLSPTools.GetToolDefinitions;
  ToolsArray := TJSONArray.Create;
  
  for I := 0 to High(Tools) do
    ToolsArray.Add(Tools[I].ToJSON);
  
  ResultObj := TJSONObject.Create;
  ResultObj.AddPair('tools', ToolsArray);
  
  SendResponse(ARequest.Id, ResultObj);
  Logger.Info('Sent %d tool definitions', [Length(Tools)]);
end;

procedure TMCPServer.HandleToolsCall(ARequest: TJsonRpcRequest);
var
  Params: TMCPToolCallParams;
  Result: TMCPToolCallResult;
  ResultJson: TJSONObject;
begin
  if not FInitialized then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.ServerErrorStart, 'Server not initialized');
    Exit;
  end;
  
  if not Assigned(ARequest.Params) then
  begin
    SendError(ARequest.Id, TJsonRpcErrorCode.InvalidParams, 'Missing params');
    Exit;
  end;
  
  try
    Params := TMCPToolCallParams.FromJSON(ARequest.Params as TJSONObject);
    Logger.Info('Executing tool: %s', [Params.Name]);
    
    Result := FTools.ExecuteTool(Params.Name, Params.Arguments);
    ResultJson := Result.ToJSON;
    
    SendResponse(ARequest.Id, ResultJson);
    Logger.Info('Tool execution completed: %s (error=%s)', [Params.Name, BoolToStr(Result.IsError, True)]);
  except
    on E: Exception do
    begin
      Logger.Error('Tool call error: %s', [E.Message]);
      SendError(ARequest.Id, TJsonRpcErrorCode.InternalError, E.Message);
    end;
  end;
end;

procedure TMCPServer.HandleShutdown(ARequest: TJsonRpcRequest);
begin
  Logger.Info('Shutdown requested');
  SendResponse(ARequest.Id, TJSONNull.Create);
  FInitialized := False;
end;

procedure TMCPServer.SendResponse(AId: TJSONValue; AResult: TJSONValue);
var
  Response: TJsonRpcResponse;
  ResponseJson: TJSONObject;
begin
  Response := TJsonRpcHelper.CreateSuccessResponse(TJsonRpcHelper.CloneJSONValue(AId), AResult);
  try
    ResponseJson := Response.ToJSON;
    try
      FTransport.SendMessage(ResponseJson.ToJSON);
    finally
      ResponseJson.Free;
    end;
  finally
    Response.Free;
  end;
end;

procedure TMCPServer.SendError(AId: TJSONValue; ACode: Integer; const AMessage: string);
var
  Response: TJsonRpcResponse;
  ResponseJson: TJSONObject;
begin
  Response := TJsonRpcHelper.CreateErrorResponse(TJsonRpcHelper.CloneJSONValue(AId), ACode, AMessage, nil);
  try
    ResponseJson := Response.ToJSON;
    try
      FTransport.SendMessage(ResponseJson.ToJSON);
    finally
      ResponseJson.Free;
    end;
  finally
    Response.Free;
  end;
end;

end.
