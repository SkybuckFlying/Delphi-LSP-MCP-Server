unit LSP.Client;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, System.SyncObjs,
  Winapi.Windows,
  Common.JsonRpc, Common.Logging, LSP.Protocol.Types, LSP.Transport.Process;

type
  TLSPRequestResult = class
  private
    FResponse: TJsonRpcResponse;
    FEvent: TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetResponse(AResponse: TJsonRpcResponse);
    function WaitFor(ATimeout: Cardinal): Boolean;
    property Response: TJsonRpcResponse read FResponse;
  end;

  TLSPClient = class
  private
    FTransport: TLSPProcessTransport;
    FInitialized: Integer; // 0=false, 1=true. Use TInterlocked for access.
    FPendingRequests: TDictionary<string, TLSPRequestResult>;
    FLock: TCriticalSection;
    FServerCapabilities: TJSONObject;

    procedure HandleMessage(const AMessage: string);
    procedure HandleResponse(AResponse: TJsonRpcResponse);
    procedure HandleNotification(ANotification: TJsonRpcNotification);
    procedure HandleRequest(ARequest: TJsonRpcRequest); // For server->client requests
    function SendRequestSync(const AMethod: string; AParams: TJSONValue; ATimeout: Cardinal): TJsonRpcResponse;
	procedure SendNotification(const AMethod: string; AParams: TJSONValue);
    function ParseLocations(AValue: TJSONValue): TArray<TLSPLocation>;
    function ParseCompletionItems(AValue: TJSONValue): TArray<TLSPCompletionItem>;
    function ParseSymbols(AValue: TJSONValue): TArray<TLSPSymbolInformation>;
    procedure ClearPendingRequests;
  public
    constructor Create(const ALSPPath: string);
    destructor Destroy; override;

    function Initialize(const ARootUri: string; AInitializationOptions: TJSONObject = nil): Boolean;
    procedure Shutdown;

    // Synchronous LSP operations - thread safe
    function GetDefinition(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPLocation>;
    function GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean): TArray<TLSPLocation>;
    function GetHover(const AUri: string; ALine, ACharacter: Integer; out AHover: TLSPHover): Boolean;
    function GetCompletion(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPCompletionItem>;
    function GetWorkspaceSymbols(const AQuery: string): TArray<TLSPSymbolInformation>;

    // Document synchronization
    procedure DidOpenTextDocument(const AUri, ALanguageId, AText: string; AVersion: Integer = 1);
    procedure DidCloseTextDocument(const AUri: string);

    function IsInitialized: Boolean;
    property ServerCapabilities: TJSONObject read FServerCapabilities;
  end;

implementation

{ TLSPRequestResult }

constructor TLSPRequestResult.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FResponse := nil;
end;

destructor TLSPRequestResult.Destroy;
begin
  FResponse.Free;
  FEvent.Free;
  inherited;
end;

procedure TLSPRequestResult.SetResponse(AResponse: TJsonRpcResponse);
begin
  // Clone to take ownership. Transport thread may free original immediately.
  FResponse := TJsonRpcResponse.Create(AResponse.Id, AResponse.Result, AResponse.Error);
  FEvent.SetEvent;
end;

function TLSPRequestResult.WaitFor(ATimeout: Cardinal): Boolean;
begin
  Result := FEvent.WaitFor(ATimeout) = wrSignaled;
end;

{ TLSPClient }

constructor TLSPClient.Create(const ALSPPath: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FPendingRequests := TDictionary<string, TLSPRequestResult>.Create;
  FTransport := TLSPProcessTransport.Create(ALSPPath);
  FTransport.OnMessageReceived := HandleMessage;
  FInitialized := 0;
  FServerCapabilities := nil;
end;

destructor TLSPClient.Destroy;
begin
  Shutdown;
  ClearPendingRequests;
  FTransport.Free;
  FPendingRequests.Free;
  FLock.Free;
  FServerCapabilities.Free;
  inherited;
end;

procedure TLSPClient.ClearPendingRequests;
var
  Req: TLSPRequestResult;
begin
  FLock.Enter;
  try
    for Req in FPendingRequests.Values do
      Req.Free;
    FPendingRequests.Clear;
  finally
    FLock.Leave;
  end;
end;

function TLSPClient.IsInitialized: Boolean;
begin
  Result := TInterlocked.CompareExchange(FInitialized, 0, 0) = 1;
end;


// LSP.Client.pas

function TLSPClient.Initialize(const ARootUri: string; AInitializationOptions: TJSONObject): Boolean;
var
  Params: TLSPInitializeParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  InitResult: TLSPInitializeResult;
  IsValid: Boolean;
  RootUriToSend: string;
begin
  Result := False;

  // Start transport (process + pipes)
  if not FTransport.Start then
  begin
    Logger.Error('Failed to start LSP transport (process may not have launched)');
    Exit;
  end;

  // Decide what to send as rootUri
  if (ARootUri = '') or SameText(ARootUri, 'file:///') then
    RootUriToSend := ''          // will serialize as null
  else
    RootUriToSend := ARootUri;

  Logger.Info('Sending LSP initialize request...');
  Logger.Info('  rootUri: %s', [RootUriToSend]);

  Params := TLSPInitializeParams.Create;
  try
    // Fill params
    Params.ProcessId   := GetCurrentProcessId;
    Params.HasProcessId := True;

    if RootUriToSend <> '' then
    begin
      Params.RootUri    := RootUriToSend;
      Params.HasRootUri := True;
    end
    else
    begin
      // rootUri present but null
      Params.RootUri    := '';
      Params.HasRootUri := True;
    end;

    // Minimal client capabilities (empty object is fine)
    Params.Capabilities := TJSONObject.Create;

    if Assigned(AInitializationOptions) then
      Params.InitializationOptions := AInitializationOptions.Clone as TJSONObject
    else
      Params.InitializationOptions := nil;

    ParamsJson := Params.ToJSON;
    try
      Logger.Debug('LSP initialize params: %s', [ParamsJson.ToJSON]);

      Resp := SendRequestSync('initialize', ParamsJson, 30000);
      try
        if not Assigned(Resp) then
        begin
          Logger.Error('LSP initialize timeout (no response within 30s)');
          Exit;
        end;

        if Resp.IsError then
        begin
          if Assigned(Resp.Error) then
            Logger.Error('LSP initialize failed: (%d) %s', [Resp.Error.Code, Resp.Error.Message])
          else
            Logger.Error('LSP initialize failed with unknown error');
          Exit;
        end;

        if not Assigned(Resp.Result) or not (Resp.Result is TJSONObject) then
        begin
          Logger.Error('LSP initialize returned invalid result (expected JSON object)');
          Exit;
        end;

        try
          InitResult := TLSPInitializeResult.FromJSON(Resp.Result as TJSONObject, IsValid);
          try
            if not IsValid then
            begin
              Logger.Error('Failed to parse LSP initialize result: invalid JSON structure');
              Exit;
            end;

            // Store server capabilities
            FServerCapabilities.Free;
            if Assigned(InitResult.Capabilities) then
              FServerCapabilities := InitResult.Capabilities.Clone as TJSONObject
            else
              FServerCapabilities := TJSONObject.Create;

            Logger.Info('LSP initialize succeeded; capabilities stored');

            // Send "initialized" notification
            SendNotification('initialized', TJSONObject.Create);

            TInterlocked.Exchange(FInitialized, 1);
            Result := True;
          finally
            InitResult.Free;
          end;
        except
          on E: Exception do
          begin
            Logger.Error('Exception while parsing LSP initialize result: %s', [E.Message]);
            Exit;
          end;
        end;
      finally
        Resp.Free;
      end;
    finally
      ParamsJson.Free;
    end;
  finally
    Params.Free; // Frees Capabilities & InitializationOptions via destructor
  end;
end;

procedure TLSPClient.Shutdown;
var
  Resp: TJsonRpcResponse;
begin
  if not IsInitialized then
  begin
    FTransport.Stop;
    Exit;
  end;

  Resp := SendRequestSync('shutdown', nil, 5000);
  if Assigned(Resp) then
  begin
    if Resp.IsError then
      Logger.Warning('LSP shutdown returned error: %s', [Resp.Error.Message]);
    Resp.Free;
  end
  else
    Logger.Warning('LSP shutdown timeout');

  SendNotification('exit', nil);
  TInterlocked.Exchange(FInitialized, 0);
  FTransport.Stop;
  ClearPendingRequests;
end;

function TLSPClient.SendRequestSync(const AMethod: string; AParams: TJSONValue; ATimeout: Cardinal): TJsonRpcResponse;
var
  Request: TJsonRpcRequest;
  RequestJson: TJSONObject;
  RequestId: string;
  ResultObj: TLSPRequestResult;
begin
  Result := nil;
  Request := TJsonRpcHelper.CreateRequest(AMethod, AParams);
  try
    RequestId := Request.Id.ToJSON;
    RequestJson := Request.ToJSON;
    try
      ResultObj := TLSPRequestResult.Create;
      try
        FLock.Enter;
        try
          if FPendingRequests.ContainsKey(RequestId) then
          begin
            Logger.Error('Duplicate request ID: %s', [RequestId]);
            Exit;
          end;
          FPendingRequests.Add(RequestId, ResultObj);
        finally
          FLock.Leave;
        end;

        try
          FTransport.SendMessage(RequestJson.ToJSON);
        except
          on E: Exception do
          begin
            Logger.Error('Failed to send request %s: %s', [AMethod, E.Message]);
            FLock.Enter;
            try
              FPendingRequests.Remove(RequestId);
            finally
              FLock.Leave;
            end;
            Exit;
          end;
        end;

        if ResultObj.WaitFor(ATimeout) then
        begin
          Result := ResultObj.Response;
          ResultObj.FResponse := nil;
        end
        else
        begin
          Logger.Error('Request %s timeout', [AMethod]);
          FLock.Enter;
          try
            FPendingRequests.Remove(RequestId);
          finally
            FLock.Leave;
          end;
        end;
      finally
        ResultObj.Free;
      end;
    finally
      RequestJson.Free;
    end;
  finally
    Request.Free;
  end;
end;

procedure TLSPClient.SendNotification(const AMethod: string; AParams: TJSONValue);
var
  Notification: TJsonRpcNotification;
  NotificationJson: TJSONObject;
begin
  Notification := TJsonRpcHelper.CreateNotification(AMethod, AParams);
  try
    NotificationJson := Notification.ToJSON;
    try
      FTransport.SendMessage(NotificationJson.ToJSON);
    finally
      NotificationJson.Free;
    end;
  finally
    Notification.Free;
  end;
end;

procedure TLSPClient.HandleMessage(const AMessage: string);
var
  MessageType: TJsonRpcMessageType;
  MessageObj: TObject;
  ErrorStr: string;
begin
  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType, ErrorStr);
  if not Assigned(MessageObj) then
  begin
    Logger.Error('Failed to parse LSP message: %s', [ErrorStr]);
    Exit;
  end;

  try
    case MessageType of
      jmtResponse:
        HandleResponse(MessageObj as TJsonRpcResponse);
      jmtNotification:
        HandleNotification(MessageObj as TJsonRpcNotification);
      jmtRequest:
        HandleRequest(MessageObj as TJsonRpcRequest);
      jmtInvalid:
        Logger.Error('Invalid LSP message received');
    end;
  finally
    MessageObj.Free;
  end;
end;

procedure TLSPClient.HandleResponse(AResponse: TJsonRpcResponse);
var
  RequestId: string;
  ResultObj: TLSPRequestResult;
begin
  if not Assigned(AResponse.Id) then
    Exit;

  RequestId := AResponse.Id.ToJSON;

  FLock.Enter;
  try
    if FPendingRequests.TryGetValue(RequestId, ResultObj) then
    begin
      FPendingRequests.Remove(RequestId);
    end
    else
    begin
      Logger.Warning('Received response for unknown request id: %s', [RequestId]);
      Exit;
    end;
  finally
    FLock.Leave;
  end;

  try
    ResultObj.SetResponse(AResponse);
  except
    on E: Exception do
      Logger.Error('Exception in response handler: %s', [E.Message]);
  end;
end;

procedure TLSPClient.HandleNotification(ANotification: TJsonRpcNotification);
begin
  Logger.Debug('LSP notification: %s', [ANotification.Method]);
  // TODO: Handle window/logMessage, textDocument/publishDiagnostics, etc
end;

procedure TLSPClient.HandleRequest(ARequest: TJsonRpcRequest);
begin
  Logger.Warning('LSP server sent request %s, not implemented', [ARequest.Method]);
  // TODO: Implement workspace/applyEdit, window/showMessageRequest, etc
end;

function TLSPClient.ParseLocations(AValue: TJSONValue): TArray<TLSPLocation>;
var
  ResultArray: TJSONArray;
  I: Integer;
  IsValid: Boolean; // FIX: Boolean, not string
begin
  SetLength(Result, 0);
  if not Assigned(AValue) then Exit;

  if AValue is TJSONArray then
  begin
    ResultArray := AValue as TJSONArray;
    SetLength(Result, ResultArray.Count);
    for I := 0 to ResultArray.Count - 1 do
      if ResultArray.Items[I] is TJSONObject then
        Result[I] := TLSPLocation.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid); // FIX
  end
  else if AValue is TJSONObject then
  begin
    SetLength(Result, 1);
    Result[0] := TLSPLocation.FromJSON(AValue as TJSONObject, IsValid); // FIX
  end;
end;

function TLSPClient.ParseCompletionItems(AValue: TJSONValue): TArray<TLSPCompletionItem>;
var
  ResultArray: TJSONArray;
  ResultObj: TJSONObject;
  I: Integer;
  IsValid: Boolean; // FIX: Boolean, not string
begin
  SetLength(Result, 0);
  if not Assigned(AValue) then Exit;

  if AValue is TJSONArray then
  begin
    ResultArray := AValue as TJSONArray;
    SetLength(Result, ResultArray.Count);
    for I := 0 to ResultArray.Count - 1 do
      if ResultArray.Items[I] is TJSONObject then
        Result[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid); // FIX
  end
  else if AValue is TJSONObject then
  begin
    ResultObj := AValue as TJSONObject;
    if ResultObj.GetValue('items') is TJSONArray then
	begin
      ResultArray := ResultObj.GetValue('items') as TJSONArray;
      SetLength(Result, ResultArray.Count);
      for I := 0 to ResultArray.Count - 1 do
        if ResultArray.Items[I] is TJSONObject then
          Result[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid); // FIX
    end;
  end;
end;

function TLSPClient.ParseSymbols(AValue: TJSONValue): TArray<TLSPSymbolInformation>;
var
  ResultArray: TJSONArray;
  I: Integer;
  IsValid: Boolean; // FIX: Boolean, not string
begin
  SetLength(Result, 0);
  if not (AValue is TJSONArray) then Exit;

  ResultArray := AValue as TJSONArray;
  SetLength(Result, ResultArray.Count);
  for I := 0 to ResultArray.Count - 1 do
    if ResultArray.Items[I] is TJSONObject then
      Result[I] := TLSPSymbolInformation.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid); // FIX
end;

function TLSPClient.GetDefinition(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPLocation>;
var
  Params: TLSPDefinitionParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
begin
  SetLength(Result, 0);
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/definition', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
        Result := ParseLocations(Resp.Result);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean): TArray<TLSPLocation>;
var
  Params: TLSPReferenceParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
begin
  SetLength(Result, 0);
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  Params.Context.IncludeDeclaration := AIncludeDeclaration;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/references', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
        Result := ParseLocations(Resp.Result);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetHover(const AUri: string; ALine, ACharacter: Integer; out AHover: TLSPHover): Boolean;
var
  Params: TLSPHoverParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  IsValid: Boolean; // FIX: Boolean, not string
begin
  Result := False;
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/hover', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError and Assigned(Resp.Result) and (Resp.Result is TJSONObject) then
      begin
        AHover := TLSPHover.FromJSON(Resp.Result as TJSONObject, IsValid); // FIX: IsValid
        if IsValid then // FIX: Check boolean
          Result := True
        else
          Logger.Error('Failed to parse hover result: invalid JSON structure');
      end;
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetCompletion(const AUri: string; ALine, ACharacter: Integer): TArray<TLSPCompletionItem>;
var
  Params: TLSPCompletionParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
begin
  SetLength(Result, 0);
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  Params.HasContext := False;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/completion', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
        Result := ParseCompletionItems(Resp.Result);
    finally
	  Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetWorkspaceSymbols(const AQuery: string): TArray<TLSPSymbolInformation>;
var
  Params: TLSPWorkspaceSymbolParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
begin
  SetLength(Result, 0);
  if not IsInitialized then Exit;

  Params.Query := AQuery;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('workspace/symbol', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
        Result := ParseSymbols(Resp.Result);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

procedure TLSPClient.DidOpenTextDocument(const AUri, ALanguageId, AText: string; AVersion: Integer);
var
  Params: TLSPDidOpenTextDocumentParams;
  ParamsJson: TJSONObject;
begin
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  Params.TextDocument.LanguageId := ALanguageId;
  Params.TextDocument.Version := AVersion;
  Params.TextDocument.Text := AText;
  ParamsJson := Params.ToJSON;
  try
    SendNotification('textDocument/didOpen', ParamsJson);
  finally
    ParamsJson.Free;
  end;
end;

procedure TLSPClient.DidCloseTextDocument(const AUri: string);
var
  Params: TLSPDidCloseTextDocumentParams;
  ParamsJson: TJSONObject;
begin
  if not IsInitialized then Exit;

  Params.TextDocument.Uri := AUri;
  ParamsJson := Params.ToJSON;
  try
    SendNotification('textDocument/didClose', ParamsJson);
  finally
    ParamsJson.Free;
  end;
end;

end.
