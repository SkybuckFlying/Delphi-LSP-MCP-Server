unit LSP.Client;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  System.SyncObjs,
  Winapi.Windows,
  Common.JsonRpc,
  Common.Logging,
  LSP.Protocol.Types,
  LSP.Transport.Process;

type
  TLSPRequestResult = class
  private
    FResponse: TJsonRpcResponse;
	FEvent: TEvent;
    FStartTime: TDateTime;
    FRequestId: string;
  public
    constructor Create(const ARequestId: string);
    destructor Destroy; override;
    procedure SetResponse(AResponse: TJsonRpcResponse);
    function WaitFor(ATimeout: Cardinal): Boolean;
    property Response: TJsonRpcResponse read FResponse;
    property RequestId: string read FRequestId;
  end;

  TLSPClient = class
  private
    FTransport: TLSPProcessTransport;
    FInitialized: Integer;
    FPendingRequests: TDictionary<string, TLSPRequestResult>;
    FLock: TCriticalSection;
    FServerCapabilities: TJSONObject;
    FDebugMode: Boolean;
    FLogContext: ILogContext;
    FRequestCounter: Integer;

    // Statistics
    FTotalRequests: Integer;
    FTotalResponses: Integer;
    FTotalErrors: Integer;
    FTotalTimeouts: Integer;
	FStartTime: TDateTime;

	// Add this method to the private section
	procedure SetDebugMode(AValue: Boolean);

    procedure HandleMessage(const AMessage: string);
    function HandleResponse(AResponse: TJsonRpcResponse): Boolean;
    procedure HandleNotification(ANotification: TJsonRpcNotification);
    procedure HandleRequest(ARequest: TJsonRpcRequest);
    function SendRequestSync(const AMethod: string; AParams: TJSONValue; ATimeout: Cardinal): TJsonRpcResponse;
    procedure SendNotification(const AMethod: string; AParams: TJSONValue);
    function ParseLocations(AValue: TJSONValue): TArray<TLSPLocation>;
    function ParseCompletionItems(AValue: TJSONValue): TArray<TLSPCompletionItem>;
    function ParseSymbols(AValue: TJSONValue): TArray<TLSPSymbolInformation>;
    procedure ClearPendingRequests;
    procedure LogDebug(const Msg: string; const Args: array of const);
    procedure LogStatistics;
    function GetNextRequestId: Integer;
  public
    constructor Create(const ALSPPath: string);
    destructor Destroy; override;

    function Initialize(const ARootUri: string; AInitializationOptions: TJSONObject = nil): Boolean;
	procedure Shutdown;

    // Synchronous LSP operations - thread safe
    function GetDefinition(const AUri: string; ALine, ACharacter: Integer; out ALocations: TArray<TLSPLocation>): Boolean;
    function GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean; out ALocations: TArray<TLSPLocation>): Boolean;
    function GetHover(const AUri: string; ALine, ACharacter: Integer; out AHover: TLSPHover): Boolean;
    function GetCompletion(const AUri: string; ALine, ACharacter: Integer; out AItems: TArray<TLSPCompletionItem>): Boolean;
	function GetWorkspaceSymbols(const AQuery: string; out ASymbols: TArray<TLSPSymbolInformation>): Boolean;

	// Document synchronization
    procedure DidOpenTextDocument(const AUri, ALanguageId, AText: string; AVersion: Integer = 1);
    procedure DidCloseTextDocument(const AUri: string);

    function IsInitialized: Boolean;
    function GetStatistics: string;

    property ServerCapabilities: TJSONObject read FServerCapabilities;
	property DebugMode: Boolean read FDebugMode write SetDebugMode;
  end;

implementation

uses
	System.StrUtils;

{ TLSPRequestResult }

constructor TLSPRequestResult.Create(const ARequestId: string);
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FResponse := nil;
  FStartTime := Now;
  FRequestId := ARequestId;
end;

destructor TLSPRequestResult.Destroy;
begin
  FResponse.Free;
  FEvent.Free;
  inherited;
end;

procedure TLSPRequestResult.SetResponse(AResponse: TJsonRpcResponse);
begin
  FResponse := AResponse;
  FEvent.SetEvent;
end;

function TLSPRequestResult.WaitFor(ATimeout: Cardinal): Boolean;
var
  WaitResult: TWaitResult;
begin
  WaitResult := FEvent.WaitFor(ATimeout);
  Result := WaitResult = wrSignaled;
end;

{ TLSPClient }

constructor TLSPClient.Create(const ALSPPath: string);
begin
  inherited Create;
  FLogContext := Logger.CreateContext('LSPClient');
  FLogContext.Enter('Create');

  try
    FLock := TCriticalSection.Create;
    FPendingRequests := TDictionary<string, TLSPRequestResult>.Create;
    FTransport := TLSPProcessTransport.Create(ALSPPath);
    FTransport.OnMessageReceived := HandleMessage;
	FInitialized := 0;
    FServerCapabilities := nil;
    FDebugMode := False;
    FRequestCounter := 0;
    FTotalRequests := 0;
    FTotalResponses := 0;
    FTotalErrors := 0;
    FTotalTimeouts := 0;
    FStartTime := Now;

    LogDebug('LSP Client created for: %s', [ALSPPath]);
  finally
    FLogContext.Exit('Create');
  end;
end;

destructor TLSPClient.Destroy;
begin
  FLogContext.Enter('Destroy');
  try
    LogStatistics;
    Shutdown;
    ClearPendingRequests;
    FTransport.Free;
    FPendingRequests.Free;
    FLock.Free;
    FServerCapabilities.Free;
    LogDebug('LSP Client destroyed - Stats: Req=%d, Resp=%d, Err=%d, Timeout=%d',
      [FTotalRequests, FTotalResponses, FTotalErrors, FTotalTimeouts]);
  finally
	FLogContext.Exit('Destroy');
    inherited;
  end;
end;

procedure TLSPClient.LogDebug(const Msg: string; const Args: array of const);
begin
  if FDebugMode then
  begin
    if Length(Args) > 0 then
      FLogContext.LogFmt(Msg, Args)
    else
      FLogContext.Log(Msg);
  end;
end;

procedure TLSPClient.LogStatistics;
begin
  if not FDebugMode then
    Exit;

  Logger.Info('[LSPClient Statistics]');
  Logger.Info('  Uptime: %s', [FormatDateTime('hh:nn:ss', Now - FStartTime)]);
  Logger.Info('  Total Requests: %d', [FTotalRequests]);
  Logger.Info('  Total Responses: %d', [FTotalResponses]);
  Logger.Info('  Total Errors: %d', [FTotalErrors]);
  Logger.Info('  Total Timeouts: %d', [FTotalTimeouts]);
  Logger.Info('  Pending Requests: %d', [FPendingRequests.Count]);
end;

procedure TLSPClient.SetDebugMode(AValue: Boolean);
begin
  if FDebugMode <> AValue then
  begin
	FDebugMode := AValue;
	if Assigned(FTransport) then
	  FTransport.DebugMode := AValue;
	Logger.Info('LSP Client debug mode %s', [IfThen(AValue, 'enabled', 'disabled')]);
  end;
end;

function TLSPClient.GetStatistics: string;
begin
  Result := Format('LSP Client: Req=%d, Resp=%d, Err=%d, Timeout=%d, Pending=%d',
    [FTotalRequests, FTotalResponses, FTotalErrors, FTotalTimeouts, FPendingRequests.Count]);
end;

function TLSPClient.GetNextRequestId: Integer;
begin
  Result := TInterlocked.Increment(FRequestCounter);
end;

procedure TLSPClient.ClearPendingRequests;
var
  Req: TLSPRequestResult;
begin
  FLock.Enter;
  try
    LogDebug('Clearing %d pending requests', [FPendingRequests.Count]);
    for Req in FPendingRequests.Values do
      Req.FEvent.SetEvent;
    FPendingRequests.Clear;
  finally
    FLock.Leave;
  end;
end;

function TLSPClient.IsInitialized: Boolean;
begin
  Result := TInterlocked.CompareExchange(FInitialized, 0, 0) = 1;
end;

function TLSPClient.Initialize(const ARootUri: string; AInitializationOptions: TJSONObject): Boolean;
var
  Params: TLSPInitializeParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  InitResult: TLSPInitializeResult;
  IsValid: Boolean;
  RootUriToSend: string;
  StartTime: UInt64;
begin
  Result := False;
  StartTime := GetTickCount64;
  FLogContext.Enter('Initialize');

  try
    LogDebug('Starting LSP initialization - RootUri: %s', [ARootUri]);

    // Start transport (process + pipes)
    if not FTransport.Start then
    begin
	  Logger.Error('Failed to start LSP transport (process may not have launched)');
      LogDebug('Transport start failed', []);
      Exit;
    end;

    // Decide what to send as rootUri
    if (ARootUri = '') or SameText(ARootUri, 'file:///') then
      RootUriToSend := ''
    else
      RootUriToSend := ARootUri;

    Logger.Info('Sending LSP initialize request...');
    Logger.Info('  rootUri: %s', [RootUriToSend]);
    LogDebug('Initialize params - ProcessId: %d', [GetCurrentProcessId]);

    Params := TLSPInitializeParams.Create;
    try
      Params.ProcessId := GetCurrentProcessId;
      Params.HasProcessId := True;

      if RootUriToSend <> '' then
      begin
        Params.RootUri := RootUriToSend;
        Params.HasRootUri := True;
      end
      else
      begin
        Params.RootUri := '';
        Params.HasRootUri := True;
      end;

      Params.Capabilities := TJSONObject.Create;

      if Assigned(AInitializationOptions) then
        Params.InitializationOptions := AInitializationOptions.Clone as TJSONObject
      else
        Params.InitializationOptions := nil;

      ParamsJson := Params.ToJSON;
      try
        if FDebugMode then
          Logger.Debug('LSP initialize params: %s', [ParamsJson.ToJSON]);

        Resp := SendRequestSync('initialize', ParamsJson, 30000);
        try
          if not Assigned(Resp) then
          begin
            Inc(FTotalTimeouts);
            Logger.Error('LSP initialize timeout (no response within 30s)');
            LogDebug('Initialize timeout after 30 seconds', []);
            Exit;
		  end;

          if Resp.IsError then
          begin
            Inc(FTotalErrors);
            if Assigned(Resp.Error) then
              Logger.Error('LSP initialize failed: (%d) %s', [Resp.Error.Code, Resp.Error.Message])
            else
              Logger.Error('LSP initialize failed with unknown error');
            LogDebug('Initialize failed with error', []);
			Exit;
          end;

          if not Assigned(Resp.Result) or not (Resp.Result is TJSONObject) then
          begin
            Inc(FTotalErrors);
            Logger.Error('LSP initialize returned invalid result (expected JSON object)');
            LogDebug('Invalid response type', []);
            Exit;
          end;

          try
            InitResult := TLSPInitializeResult.FromJSON(Resp.Result as TJSONObject, IsValid);
            try
              if not IsValid then
              begin
                Inc(FTotalErrors);
                Logger.Error('Failed to parse LSP initialize result: invalid JSON structure');
                LogDebug('Parse failed', []);
                Exit;
              end;

              // Store server capabilities
              FServerCapabilities.Free;
              if Assigned(InitResult.Capabilities) then
                FServerCapabilities := InitResult.Capabilities.Clone as TJSONObject
              else
                FServerCapabilities := TJSONObject.Create;

              Logger.Info('LSP initialize succeeded; capabilities stored');
              LogDebug('Initialize complete - Duration: %d ms', [GetTickCount64 - StartTime]);

              // Send "initialized" notification
              SendNotification('initialized', TJSONObject.Create);
              LogDebug('Initialized notification sent', []);

              TInterlocked.Exchange(FInitialized, 1);
              Result := True;
            finally
              InitResult.Free;
            end;
          except
            on E: Exception do
            begin
              Inc(FTotalErrors);
              Logger.Error('Exception while parsing LSP initialize result: %s', [E.Message]);
              LogDebug('Exception in parse: %s - %s', [E.ClassName, E.Message]);
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
      Params.Free;
    end;
  finally
    FLogContext.Exit('Initialize');
  end;
end;

procedure TLSPClient.Shutdown;
var
  Resp: TJsonRpcResponse;
  StartTime: UInt64;
begin
  StartTime := GetTickCount64;
  FLogContext.Enter('Shutdown');

  try
    if not IsInitialized then
    begin
      LogDebug('Shutdown called but not initialized', []);
      FTransport.Stop;
      Exit;
    end;

    LogDebug('Starting shutdown sequence', []);
    Resp := SendRequestSync('shutdown', nil, 5000);
    if Assigned(Resp) then
    begin
      if Resp.IsError then
      begin
        Inc(FTotalErrors);
        Logger.Warning('LSP shutdown returned error: %s', [Resp.Error.Message]);
        LogDebug('Shutdown returned error', []);
      end
      else
        LogDebug('Shutdown request successful', []);
      Resp.Free;
    end
    else
    begin
      Inc(FTotalTimeouts);
      Logger.Warning('LSP shutdown timeout');
      LogDebug('Shutdown timeout', []);
    end;

    SendNotification('exit', nil);
    LogDebug('Exit notification sent', []);

    TInterlocked.Exchange(FInitialized, 0);
    FTransport.Stop;
    ClearPendingRequests;

    LogDebug('Shutdown complete - Duration: %d ms', [GetTickCount64 - StartTime]);
  finally
    FLogContext.Exit('Shutdown');
  end;
end;

function TLSPClient.SendRequestSync(const AMethod: string; AParams: TJSONValue; ATimeout: Cardinal): TJsonRpcResponse;
var
  Request: TJsonRpcRequest;
  RequestJson: TJSONObject;
  RequestId: string;
  ResultObj: TLSPRequestResult;
  StartTime: UInt64;
  RequestIdNum: Integer;
begin
  Result := nil;
  StartTime := GetTickCount64;
  RequestIdNum := GetNextRequestId;

  FLogContext.Enter(Format('SendRequestSync.%s', [AMethod]));

  try
    Inc(FTotalRequests);
    LogDebug('Sending request: %s (ID: %d, Timeout: %d ms)', [AMethod, RequestIdNum, ATimeout]);

    Request := TJsonRpcHelper.CreateRequest(AMethod, AParams);
    try
      // Override the auto-generated ID with our counter for consistency
      Request.Id.Free;
      Request.Id := TJSONNumber.Create(RequestIdNum);

      RequestId := Request.Id.ToJSON;
      RequestJson := Request.ToJSON;
      try
        ResultObj := TLSPRequestResult.Create(RequestId);
        try
          FLock.Enter;
          try
            if FPendingRequests.ContainsKey(RequestId) then
            begin
              Inc(FTotalErrors);
              Logger.Error('Duplicate request ID: %s', [RequestId]);
              LogDebug('Duplicate request ID detected', []);
              Exit;
            end;
            FPendingRequests.Add(RequestId, ResultObj);
            LogDebug('Request added to pending list (total pending: %d)', [FPendingRequests.Count]);
          finally
            FLock.Leave;
          end;

          try
            FTransport.SendMessage(RequestJson.ToJSON);
            LogDebug('Request sent successfully', []);
          except
            on E: Exception do
            begin
              Inc(FTotalErrors);
              Logger.Error('Failed to send request %s: %s', [AMethod, E.Message]);
              LogDebug('Failed to send request: %s - %s', [E.ClassName, E.Message]);
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
            FLock.Enter;
            try
              Result := ResultObj.Response;
              ResultObj.FResponse := nil;
            finally
              FLock.Leave;
            end;
            Inc(FTotalResponses);
			LogDebug('Response received in %d ms', [GetTickCount64 - StartTime]);
          end
          else
          begin
            FLock.Enter;
            try
              FPendingRequests.Remove(RequestId);
              if Assigned(ResultObj.Response) then
              begin
                Result := ResultObj.Response;
                ResultObj.FResponse := nil;
                Inc(FTotalResponses);
              end;
            finally
              FLock.Leave;
            end;

            if not Assigned(Result) then
            begin
              Inc(FTotalTimeouts);
              Logger.Error('Request %s timeout after %d ms', [AMethod, ATimeout]);
              LogDebug('Request timeout - Duration: %d ms', [GetTickCount64 - StartTime]);
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
  finally
    FLogContext.Exit('SendRequestSync.' + AMethod);
  end;
end;

procedure TLSPClient.SendNotification(const AMethod: string; AParams: TJSONValue);
var
  Notification: TJsonRpcNotification;
  NotificationJson: TJSONObject;
begin
  LogDebug('Sending notification: %s', [AMethod]);

  Notification := TJsonRpcHelper.CreateNotification(AMethod, AParams);
  try
    NotificationJson := Notification.ToJSON;
    try
      FTransport.SendMessage(NotificationJson.ToJSON);
      LogDebug('Notification sent: %s', [AMethod]);
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
  RetainMessageObj: Boolean;
begin
  LogDebug('Handling incoming message (length: %d)', [Length(AMessage)]);

  MessageObj := TJsonRpcHelper.ParseMessage(AMessage, MessageType, ErrorStr);
  if not Assigned(MessageObj) then
  begin
    Inc(FTotalErrors);
	Logger.Error('Failed to parse LSP message: %s', [ErrorStr]);
    LogDebug('Parse error: %s', [ErrorStr]);
    Exit;
  end;

  RetainMessageObj := False;
  try
    case MessageType of
      jmtResponse:
        RetainMessageObj := HandleResponse(MessageObj as TJsonRpcResponse);
      jmtNotification:
		HandleNotification(MessageObj as TJsonRpcNotification);
      jmtRequest:
        HandleRequest(MessageObj as TJsonRpcRequest);
      jmtInvalid:
        begin
          Inc(FTotalErrors);
          Logger.Error('Invalid LSP message received');
        end;
    end;
  finally
    if not RetainMessageObj then
      MessageObj.Free;
  end;
end;

function TLSPClient.HandleResponse(AResponse: TJsonRpcResponse): Boolean;
var
  RequestId: string;
  ResultObj: TLSPRequestResult;
begin
  Result := False;
  if not Assigned(AResponse.Id) then
  begin
    LogDebug('Response without ID received', []);
    Exit;
  end;

  RequestId := AResponse.Id.ToJSON;
  LogDebug('Handling response for request ID: %s', [RequestId]);

  FLock.Enter;
  try
    if FPendingRequests.TryGetValue(RequestId, ResultObj) then
    begin
      FPendingRequests.Remove(RequestId);
      LogDebug('Found matching pending request (remaining: %d)', [FPendingRequests.Count]);
      ResultObj.SetResponse(AResponse);
      Result := True;
      LogDebug('Response set successfully', []);
    end
    else
    begin
      Logger.Warning('Received response for unknown request id: %s', [RequestId]);
      LogDebug('Unknown request ID', []);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLSPClient.HandleNotification(ANotification: TJsonRpcNotification);
var
  LogMsg: string;
  LogType: Integer;
begin
  LogDebug('Handling notification: %s', [ANotification.Method]);

  if ANotification.Method = 'window/logMessage' then
  begin
    if ANotification.Params.TryGetValue<Integer>('type', LogType) and
       ANotification.Params.TryGetValue<string>('message', LogMsg) then
    begin
      case LogType of
        1: Logger.Error('LSP Server: %s', [LogMsg]);
        2: Logger.Warning('LSP Server: %s', [LogMsg]);
        3: Logger.Info('LSP Server: %s', [LogMsg]);
        else Logger.Debug('LSP Server: %s', [LogMsg]);
      end;
      LogDebug('Log message from LSP: [%d] %s', [LogType, Copy(LogMsg, 1, 200)]);
    end;
  end
  else if ANotification.Method = 'textDocument/publishDiagnostics' then
  begin
    var Uri := ANotification.Params.GetValue<string>('uri');
    Logger.Info('LSP Diagnostics received for %s', [Uri]);
    LogDebug('Diagnostics for: %s', [Uri]);
  end
  else
    Logger.Debug('LSP notification: %s', [ANotification.Method]);
end;

procedure TLSPClient.HandleRequest(ARequest: TJsonRpcRequest);
begin
  Logger.Warning('LSP server sent request %s, not implemented', [ARequest.Method]);
  LogDebug('Unhandled server request: %s', [ARequest.Method]);
end;

function TLSPClient.ParseLocations(AValue: TJSONValue): TArray<TLSPLocation>;
var
  ResultArray: TJSONArray;
  I: Integer;
  IsValid: Boolean;
begin
  SetLength(Result, 0);
  if not Assigned(AValue) then
  begin
    LogDebug('ParseLocations: nil value', []);
    Exit;
  end;

  LogDebug('ParseLocations: parsing value of type %s', [AValue.ClassName]);

  if AValue is TJSONArray then
  begin
	ResultArray := AValue as TJSONArray;
    SetLength(Result, ResultArray.Count);
    for I := 0 to ResultArray.Count - 1 do
      if ResultArray.Items[I] is TJSONObject then
        Result[I] := TLSPLocation.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid);
    LogDebug('ParseLocations: parsed %d locations', [Length(Result)]);
  end
  else if AValue is TJSONObject then
  begin
    SetLength(Result, 1);
    Result[0] := TLSPLocation.FromJSON(AValue as TJSONObject, IsValid);
    LogDebug('ParseLocations: parsed single location', []);
  end;
end;

function TLSPClient.ParseCompletionItems(AValue: TJSONValue): TArray<TLSPCompletionItem>;
var
  ResultArray: TJSONArray;
  ResultObj: TJSONObject;
  I: Integer;
  IsValid: Boolean;
begin
  SetLength(Result, 0);
  if not Assigned(AValue) then
  begin
    LogDebug('ParseCompletionItems: nil value', []);
    Exit;
  end;

  LogDebug('ParseCompletionItems: parsing value of type %s', [AValue.ClassName]);

  if AValue is TJSONArray then
  begin
    ResultArray := AValue as TJSONArray;
    SetLength(Result, ResultArray.Count);
    for I := 0 to ResultArray.Count - 1 do
      if ResultArray.Items[I] is TJSONObject then
        Result[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid);
    LogDebug('ParseCompletionItems: parsed %d items', [Length(Result)]);
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
          Result[I] := TLSPCompletionItem.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid);
      LogDebug('ParseCompletionItems: parsed %d items from items array', [Length(Result)]);
    end;
  end;
end;

function TLSPClient.ParseSymbols(AValue: TJSONValue): TArray<TLSPSymbolInformation>;
var
  ResultArray: TJSONArray;
  I: Integer;
  IsValid: Boolean;
begin
  SetLength(Result, 0);
  if not (AValue is TJSONArray) then
  begin
    LogDebug('ParseSymbols: value is not an array', []);
    Exit;
  end;

  ResultArray := AValue as TJSONArray;
  SetLength(Result, ResultArray.Count);
  for I := 0 to ResultArray.Count - 1 do
    if ResultArray.Items[I] is TJSONObject then
      Result[I] := TLSPSymbolInformation.FromJSON(ResultArray.Items[I] as TJSONObject, IsValid);

  LogDebug('ParseSymbols: parsed %d symbols', [Length(Result)]);
end;

function TLSPClient.GetDefinition(const AUri: string; ALine, ACharacter: Integer; out ALocations: TArray<TLSPLocation>): Boolean;
var
  Params: TLSPDefinitionParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  StartTime: UInt64;
begin
  Result := False;
  SetLength(ALocations, 0);
  StartTime := GetTickCount64;

  if not IsInitialized then
  begin
    LogDebug('GetDefinition called but not initialized', []);
    Exit;
  end;

  LogDebug('GetDefinition: %s at (%d,%d)', [AUri, ALine, ACharacter]);

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/definition', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
      begin
        ALocations := ParseLocations(Resp.Result);
        Result := True;
        LogDebug('GetDefinition succeeded - found %d locations in %d ms',
          [Length(ALocations), GetTickCount64 - StartTime]);
      end
      else
        LogDebug('GetDefinition failed or returned error', []);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetReferences(const AUri: string; ALine, ACharacter: Integer; AIncludeDeclaration: Boolean; out ALocations: TArray<TLSPLocation>): Boolean;
var
  Params: TLSPReferenceParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  StartTime: UInt64;
begin
  Result := False;
  SetLength(ALocations, 0);
  StartTime := GetTickCount64;

  if not IsInitialized then
  begin
    LogDebug('GetReferences called but not initialized', []);
    Exit;
  end;

  LogDebug('GetReferences: %s at (%d,%d), includeDecl=%s',
    [AUri, ALine, ACharacter, BoolToStr(AIncludeDeclaration, True)]);

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  Params.Context.IncludeDeclaration := AIncludeDeclaration;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/references', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
      begin
        ALocations := ParseLocations(Resp.Result);
        Result := True;
		LogDebug('GetReferences succeeded - found %d locations in %d ms',
          [Length(ALocations), GetTickCount64 - StartTime]);
      end
      else
        LogDebug('GetReferences failed or returned error', []);
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
  IsValid: Boolean;
  StartTime: UInt64;
begin
  Result := False;
  StartTime := GetTickCount64;

  if not IsInitialized then
  begin
    LogDebug('GetHover called but not initialized', []);
    Exit;
  end;

  LogDebug('GetHover: %s at (%d,%d)', [AUri, ALine, ACharacter]);

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/hover', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError and Assigned(Resp.Result) and (Resp.Result is TJSONObject) then
      begin
        AHover := TLSPHover.FromJSON(Resp.Result as TJSONObject, IsValid);
        if IsValid then
        begin
          Result := True;
          LogDebug('GetHover succeeded in %d ms', [GetTickCount64 - StartTime]);
        end
        else
        begin
          Inc(FTotalErrors);
          Logger.Error('Failed to parse hover result: invalid JSON structure');
          LogDebug('GetHover parse failed', []);
        end;
      end
      else
        LogDebug('GetHover failed or returned error', []);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetCompletion(const AUri: string; ALine, ACharacter: Integer; out AItems: TArray<TLSPCompletionItem>): Boolean;
var
  Params: TLSPCompletionParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  StartTime: UInt64;
begin
  Result := False;
  SetLength(AItems, 0);
  StartTime := GetTickCount64;

  if not IsInitialized then
  begin
    LogDebug('GetCompletion called but not initialized', []);
    Exit;
  end;

  LogDebug('GetCompletion: %s at (%d,%d)', [AUri, ALine, ACharacter]);

  Params.TextDocument.Uri := AUri;
  Params.Position.Line := ALine;
  Params.Position.Character := ACharacter;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('textDocument/completion', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
      begin
		AItems := ParseCompletionItems(Resp.Result);
        Result := True;
        LogDebug('GetCompletion succeeded - found %d items in %d ms',
          [Length(AItems), GetTickCount64 - StartTime]);
      end
      else
        LogDebug('GetCompletion failed or returned error', []);
    finally
      Resp.Free;
    end;
  finally
    ParamsJson.Free;
  end;
end;

function TLSPClient.GetWorkspaceSymbols(const AQuery: string; out ASymbols: TArray<TLSPSymbolInformation>): Boolean;
var
  Params: TLSPWorkspaceSymbolParams;
  ParamsJson: TJSONObject;
  Resp: TJsonRpcResponse;
  StartTime: UInt64;
begin
  Result := False;
  SetLength(ASymbols, 0);
  StartTime := GetTickCount64;

  if not IsInitialized then
  begin
    LogDebug('GetWorkspaceSymbols called but not initialized', []);
    Exit;
  end;

  LogDebug('GetWorkspaceSymbols: query="%s"', [AQuery]);

  Params.Query := AQuery;
  ParamsJson := Params.ToJSON;
  try
    Resp := SendRequestSync('workspace/symbol', ParamsJson, 10000);
    try
      if Assigned(Resp) and not Resp.IsError then
	  begin
        ASymbols := ParseSymbols(Resp.Result);
        Result := True;
        LogDebug('GetWorkspaceSymbols succeeded - found %d symbols in %d ms',
          [Length(ASymbols), GetTickCount64 - StartTime]);
      end
      else
        LogDebug('GetWorkspaceSymbols failed or returned error', []);
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
  if not IsInitialized then
  begin
    LogDebug('DidOpenTextDocument called but not initialized', []);
    Exit;
  end;

  LogDebug('DidOpenTextDocument: %s (lang=%s, version=%d, size=%d)',
    [AUri, ALanguageId, AVersion, Length(AText)]);

  Params.TextDocument.Uri := AUri;
  Params.TextDocument.LanguageId := ALanguageId;
  Params.TextDocument.Version := AVersion;
  Params.TextDocument.Text := AText;
  ParamsJson := Params.ToJSON;
  try
    SendNotification('textDocument/didOpen', ParamsJson);
    LogDebug('DidOpenTextDocument notification sent', []);
  finally
    ParamsJson.Free;
  end;
end;

procedure TLSPClient.DidCloseTextDocument(const AUri: string);
var
  Params: TLSPDidCloseTextDocumentParams;
  ParamsJson: TJSONObject;
begin
  if not IsInitialized then
  begin
    LogDebug('DidCloseTextDocument called but not initialized', []);
    Exit;
  end;

  LogDebug('DidCloseTextDocument: %s', [AUri]);

  Params.TextDocument.Uri := AUri;
  ParamsJson := Params.ToJSON;
  try
    SendNotification('textDocument/didClose', ParamsJson);
    LogDebug('DidCloseTextDocument notification sent', []);
  finally
    ParamsJson.Free;
  end;
end;

end.
